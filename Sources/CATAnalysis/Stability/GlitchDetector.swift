import CATEngine
import Foundation

struct ChannelDetectionOutcome {
    let incidents: [Incident]
    let truncatedCount: Int
    let summary: ChannelStabilitySummary
}

/// Streaming glitch detector for one input channel, shared by every stability signal: a
/// `ReferenceTracker` says what should arrive, this class decides what went wrong.
///
/// Lifecycle: acquire (lock onto the reference) → track (compare sample by sample) → re-acquire
/// whenever the comparison stays broken for `resyncAfterSeconds` (a slip in the device's stream
/// never heals by itself; without this, everything after it would read as one endless error and
/// hide any later incident). The stretch between losing and regaining the reference is reported
/// as one dropout.
///
/// Classification while tracking:
/// - clip: |sample| above 0.99 (reported, not counted as an incident);
/// - click: a run of samples whose error exceeds the click threshold, ended before it could
///   become a dropout;
/// - silence: the capture stays quiet for ≥ 3 ms while the reference carries signal;
/// - dropout: the windowed RMS error stays above 35% of the reference amplitude for 3 windows.
final class GlitchDetector {
    static let clipLevel: Float = 0.99
    static let errorWindowSize = 32
    static let windowsToOpenDropout = 3
    static let dropoutErrorRatio = 0.35
    static let initialAcquisitionAttempts = 3
    static let resyncAfterSeconds = 0.05
    static let minSilenceSeconds = 0.003
    static let dumpContextSeconds = 0.3

    let channel: Int
    private let sampleRate: Double
    private let tracker: ReferenceTracker
    private let log: IncidentLog
    private let resyncAfterFrames: Int64
    private let minSilenceFrames: Int
    private var noiseFloor: Float = 0.0005
    private var clickThreshold: Float = 0.02
    private var silenceThreshold: Float = 0.01

    private enum State {
        case acquiring
        case waitingToRetry(until: Int64)
        case tracking
        case gaveUp(reason: String)
    }

    private var state: State = .acquiring
    private var hasEverLocked = false
    private var initialAttemptsLeft = GlitchDetector.initialAcquisitionAttempts
    private var lastFailureReason: String?
    private var acquisitionBuffer: [Float] = []
    private var acquisitionStart: Int64 = 0
    private var nextIndex: Int64?
    private var settleRemaining = 0
    private(set) var reacquisitionCount = 0

    private var clickOpen = false
    private var clickStart: Int64 = 0
    private var clickLength = 0
    private var clickPeak: Float = 0
    private var silenceOpen = false
    private var silenceStart: Int64 = 0
    private var silenceLength = 0
    private var windowSumSquares = 0.0
    private var windowCount = 0
    private var elevatedWindows = 0
    private var dropoutOpen = false
    private var dropoutStart: Int64 = 0

    // Diagnostic dumps (--dump-incident-audio): a rolling window of (captured, expected) pairs so
    // the audio around an incident can be written out and listened to.
    private let dumper: IncidentAudioDumper?
    private let dumpContextFrames: Int
    private var capturedHistory: RingHistory
    private var expectedHistory: RingHistory
    private var pendingDump: PendingDump?

    private struct PendingDump {
        let incidentType: String
        let timestampSeconds: Double
        let capturedPre: [Float]
        let expectedPre: [Float]
        var capturedPost: [Float] = []
        var expectedPost: [Float] = []
    }

    init(channel: Int, sampleRate: Double, tracker: ReferenceTracker, dumper: IncidentAudioDumper? = nil) {
        self.channel = channel
        self.sampleRate = sampleRate
        self.tracker = tracker
        self.log = IncidentLog(channel: channel, sampleRate: sampleRate)
        self.resyncAfterFrames = Int64(sampleRate * GlitchDetector.resyncAfterSeconds)
        self.minSilenceFrames = Int(sampleRate * GlitchDetector.minSilenceSeconds)
        self.dumper = dumper
        let contextFrames = Int(sampleRate * GlitchDetector.dumpContextSeconds)
        self.dumpContextFrames = contextFrames
        self.capturedHistory = RingHistory(capacity: dumper == nil ? 1 : contextFrames)
        self.expectedHistory = RingHistory(capacity: dumper == nil ? 1 : contextFrames)
        if dumper != nil {
            log.onRecord = { [weak self] type, timestamp in
                self?.maybeStartDump(type: type, timestampSeconds: timestamp)
            }
        }
    }

    var liveIncidentCount: Int { log.incidentCount }

    func calibrateNoiseFloor(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        var sumSquares: Float = 0
        for s in samples { sumSquares += s * s }
        noiseFloor = max(sqrtf(sumSquares / Float(samples.count)), 0.0002)
    }

    /// `startIndex` is the stream index of `samples[0]`; a jump from the previous call's end means
    /// frames are missing (the caller records device gaps itself via `recordDeviceGap`).
    func process(_ samples: UnsafeBufferPointer<Float>, startIndex: Int64) {
        if case .gaveUp = state { return }
        if let expected = nextIndex, expected != startIndex {
            handleDiscontinuity()
        }
        nextIndex = startIndex + Int64(samples.count)
        for offset in 0..<samples.count {
            let sample = samples[offset]
            let index = startIndex + Int64(offset)
            switch state {
            case .gaveUp:
                return
            case .tracking:
                track(sample, at: index)
            case .waitingToRetry(let until):
                recordClipIfNeeded(sample, at: index)
                if index >= until {
                    state = .acquiring
                    accumulate(sample, at: index)
                }
            case .acquiring:
                recordClipIfNeeded(sample, at: index)
                accumulate(sample, at: index)
            }
        }
    }

    func process(_ samples: [Float], startIndex: Int64) {
        samples.withUnsafeBufferPointer { process($0, startIndex: startIndex) }
    }

    /// Frames the device itself failed to deliver (a jump in its sample time), starting at `index`.
    func recordDeviceGap(atIndex index: Int64, missingFrames: Int64) {
        guard missingFrames > 0 else { return }
        log.record(.dropout, startIndex: index, frameCount: missingFrames, severity: Double(missingFrames))
    }

    func finish(totalDurationSeconds: Double) -> ChannelDetectionOutcome {
        if clickOpen { closeClick() }
        if silenceOpen { closeSilence() }
        if dropoutOpen { closeDropout(at: nextIndex ?? dropoutStart) }
        flushPendingDump()

        let verified: Bool
        let reason: String?
        switch state {
        case .gaveUp(let failure):
            verified = false
            reason = failure
        default:
            verified = hasEverLocked
            reason = hasEverLocked ? nil : (lastFailureReason ?? "aucun signal analysé sur ce canal pendant la passe")
        }
        let summary = ChannelStabilitySummary(
            channel: channel,
            dropoutCount: log.dropoutCount,
            silenceCount: log.silenceCount,
            clickCount: log.clickCount,
            clipCount: log.clipCount,
            cleanPercentage: log.cleanPercentage(totalDurationSeconds: totalDurationSeconds),
            verified: verified,
            unverifiedReason: reason,
            reacquisitionCount: reacquisitionCount
        )
        return ChannelDetectionOutcome(incidents: log.incidents, truncatedCount: log.truncatedCount, summary: summary)
    }

    // MARK: Acquisition

    private func accumulate(_ sample: Float, at index: Int64) {
        if acquisitionBuffer.isEmpty { acquisitionStart = index }
        acquisitionBuffer.append(sample)
        guard acquisitionBuffer.count >= tracker.acquisitionFrameCount else { return }

        let start = acquisitionStart
        let outcome = tracker.acquire(acquisitionBuffer, startIndex: start, noiseFloor: noiseFloor)
        acquisitionBuffer.removeAll(keepingCapacity: true)
        switch outcome {
        case .locked:
            if dropoutOpen { closeDropout(at: start) }
            let amplitude = tracker.referencePeakAmplitude
            clickThreshold = max(noiseFloor * 9, 0.08 * amplitude)
            silenceThreshold = max(noiseFloor * 4, 0.04 * amplitude)
            hasEverLocked = true
            lastFailureReason = nil
            resetClassification()
            settleRemaining = tracker.settleFrameCount
            state = .tracking
        case .failed(let reason):
            lastFailureReason = reason
            if !hasEverLocked {
                initialAttemptsLeft -= 1
                if initialAttemptsLeft <= 0 {
                    state = .gaveUp(reason: reason)
                    return
                }
            }
            state = .waitingToRetry(until: index + 1 + Int64(tracker.retryIntervalFrames))
        }
    }

    private func beginReacquisition() {
        reacquisitionCount += 1
        // The open dropout stays open: it closes where the reference is found again (or at the end).
        clickOpen = false
        if silenceOpen { closeSilence() }
        resetErrorWindow()
        flushPendingDump()
        capturedHistory.reset()
        expectedHistory.reset()
        acquisitionBuffer.removeAll(keepingCapacity: true)
        state = .acquiring
    }

    private func handleDiscontinuity() {
        // Runs can't span a hole in the stream.
        clickOpen = false
        if silenceOpen { closeSilence() }
        resetErrorWindow()
        flushPendingDump()
        capturedHistory.reset()
        expectedHistory.reset()
        if case .acquiring = state {
            acquisitionBuffer.removeAll(keepingCapacity: true)
        }
    }

    // MARK: Tracking

    private func track(_ sample: Float, at index: Int64) {
        let expected = tracker.expectedSample(at: index, captured: sample)
        let error = sample - expected
        if dumper != nil {
            appendHistory(captured: sample, expected: expected)
        }
        if settleRemaining > 0 {
            settleRemaining -= 1
            return
        }
        if abs(sample) > Self.clipLevel {
            log.record(.clip, startIndex: index, frameCount: 1, severity: Double(abs(sample)))
        } else {
            updateClick(error: error, at: index)
            updateSilence(sample: sample, expected: expected, at: index)
        }
        updateErrorWindow(error: error, at: index)
        if dropoutOpen && index - dropoutStart >= resyncAfterFrames {
            beginReacquisition()
        }
    }

    private func updateClick(error: Float, at index: Int64) {
        guard !dropoutOpen else {
            clickOpen = false
            return
        }
        let magnitude = abs(error)
        if magnitude > clickThreshold {
            if !clickOpen {
                clickOpen = true
                clickStart = index
                clickLength = 0
                clickPeak = 0
            }
            clickLength += 1
            clickPeak = max(clickPeak, magnitude)
        } else if clickOpen {
            closeClick()
        }
    }

    private func closeClick() {
        clickOpen = false
        let severityDb = 20 * log10(Double(max(clickPeak, 1e-6)) / Double(max(noiseFloor, 1e-6)))
        log.record(.click, startIndex: clickStart, frameCount: Int64(clickLength), severity: severityDb)
    }

    private func updateSilence(sample: Float, expected: Float, at index: Int64) {
        let capturedQuiet = abs(sample - tracker.restingLevel) < silenceThreshold
        if capturedQuiet {
            if silenceOpen {
                silenceLength += 1
            } else if tracker.expectsSignal(expected: expected, silenceThreshold: silenceThreshold) {
                // A reference that is itself momentarily quiet (noise near zero, a quiet WAV
                // passage) neither starts a silence nor ends one in progress.
                silenceOpen = true
                silenceStart = index
                silenceLength = 1
            }
        } else if silenceOpen {
            closeSilence()
        }
    }

    private func closeSilence() {
        silenceOpen = false
        guard silenceLength >= minSilenceFrames else { return }
        log.record(.silence, startIndex: silenceStart, frameCount: Int64(silenceLength), severity: Double(silenceLength) / sampleRate * 1000.0)
    }

    private func updateErrorWindow(error: Float, at index: Int64) {
        windowSumSquares += Double(error) * Double(error)
        windowCount += 1
        guard windowCount >= Self.errorWindowSize else { return }
        let reference = Double(tracker.referencePeakAmplitude)
        let normalized = reference > 0.0001 ? (windowSumSquares / Double(windowCount)).squareRoot() / reference : 0
        windowSumSquares = 0
        windowCount = 0
        if normalized > Self.dropoutErrorRatio {
            elevatedWindows += 1
            if !dropoutOpen && elevatedWindows >= Self.windowsToOpenDropout {
                dropoutOpen = true
                dropoutStart = index + 1 - Int64(Self.errorWindowSize * Self.windowsToOpenDropout)
                clickOpen = false
            }
        } else {
            if dropoutOpen { closeDropout(at: index + 1) }
            elevatedWindows = 0
        }
    }

    private func closeDropout(at end: Int64) {
        dropoutOpen = false
        let frames = max(end - dropoutStart, 0)
        log.record(.dropout, startIndex: dropoutStart, frameCount: frames, severity: Double(frames))
    }

    private func resetErrorWindow() {
        windowSumSquares = 0
        windowCount = 0
        elevatedWindows = 0
    }

    private func resetClassification() {
        clickOpen = false
        silenceOpen = false
        resetErrorWindow()
    }

    private func recordClipIfNeeded(_ sample: Float, at index: Int64) {
        if abs(sample) > Self.clipLevel {
            log.record(.clip, startIndex: index, frameCount: 1, severity: Double(abs(sample)))
        }
    }

    // MARK: Diagnostic dumps

    private func appendHistory(captured: Float, expected: Float) {
        capturedHistory.append(captured)
        expectedHistory.append(expected)
        guard pendingDump != nil else { return }
        pendingDump!.capturedPost.append(captured)
        pendingDump!.expectedPost.append(expected)
        if pendingDump!.capturedPost.count >= dumpContextFrames {
            flushPendingDump()
        }
    }

    private func maybeStartDump(type: IncidentType, timestampSeconds: Double) {
        guard let dumper, pendingDump == nil, dumper.shouldDump(channel: channel) else { return }
        pendingDump = PendingDump(
            incidentType: type.rawValue,
            timestampSeconds: timestampSeconds,
            capturedPre: capturedHistory.snapshot(),
            expectedPre: expectedHistory.snapshot()
        )
    }

    private func flushPendingDump() {
        guard let dump = pendingDump else { return }
        pendingDump = nil
        dumper?.dump(
            channel: channel,
            incidentType: dump.incidentType,
            timestampSeconds: dump.timestampSeconds,
            captured: dump.capturedPre + dump.capturedPost,
            expected: dump.expectedPre + dump.expectedPost
        )
    }
}

/// Fixed-capacity FIFO of the most recent samples.
struct RingHistory {
    private var buffer: [Float]
    private var writeIndex = 0
    private var count = 0

    init(capacity: Int) {
        buffer = [Float](repeating: 0, count: max(capacity, 1))
    }

    mutating func append(_ value: Float) {
        buffer[writeIndex] = value
        writeIndex = (writeIndex + 1) % buffer.count
        count = min(count + 1, buffer.count)
    }

    mutating func reset() {
        writeIndex = 0
        count = 0
    }

    func snapshot() -> [Float] {
        guard count > 0 else { return [] }
        if count < buffer.count { return Array(buffer[0..<count]) }
        return Array(buffer[writeIndex...]) + Array(buffer[..<writeIndex])
    }
}
