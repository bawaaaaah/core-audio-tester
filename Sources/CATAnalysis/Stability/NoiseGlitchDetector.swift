import CATEngine
import Foundation

/// Streaming glitch detector for the noise-based stability signals (white or pink). Unlike
/// `StreamingGlitchDetector` (which models a sine and adapts a running amplitude estimate), the
/// exact expected sample is always known in advance via `NoiseSignalKind` — once the round-trip
/// sample offset is located, detection is a direct comparison against a known value rather than a
/// statistical fit, so there's no amplitude envelope to track and no "cold start" class of bug to
/// worry about.
public final class NoiseGlitchDetector {
    public let channel: Int
    private let sampleRate: Double
    private let amplitude: Float
    private let noiseKind: NoiseSignalKind
    private let audioDumper: IncidentAudioDumper?

    private var noiseFloor: Float = 0.0005

    // Diagnostic-only (active when audioDumper != nil): a rolling pre-incident window of the
    // exact (captured, expected) pairs, so a flagged incident's surrounding audio can be dumped
    // to WAV and inspected/listened to directly rather than trusting the classification alone.
    private var capturedHistory: RingHistory
    private var expectedHistory: RingHistory
    private var pendingDump: PendingDump?
    private let dumpPostFrames: Int

    private struct PendingDump {
        let incidentType: String
        let timestampSeconds: Double
        let capturedPre: [Float]
        let expectedPre: [Float]
        var capturedPost: [Float] = []
        var expectedPost: [Float] = []
    }

    private struct RingHistory {
        private var buffer: [Float]
        private var writeIndex = 0
        private var count = 0
        init(capacity: Int) { buffer = [Float](repeating: 0, count: max(capacity, 1)) }
        mutating func append(_ value: Float) {
            buffer[writeIndex] = value
            writeIndex = (writeIndex + 1) % buffer.count
            count = min(count + 1, buffer.count)
        }
        func snapshot() -> [Float] {
            guard count > 0 else { return [] }
            if count < buffer.count { return Array(buffer[0..<count]) }
            return Array(buffer[writeIndex...]) + Array(buffer[..<writeIndex])
        }
    }

    private var totalSamples: Int64 = 0
    private var incidents: [Incident] = []
    private var truncatedCount = 0
    private let maxDetailedIncidents = 2000
    private var incidentAffectedSamples: Int64 = 0

    // True per-type incident counts, incremented unconditionally regardless of whether the
    // detailed `Incident` itself got stored: `maxDetailedIncidents` only bounds memory for the
    // full per-incident record list, so filtering that (possibly-truncated) list for a per-type
    // count would silently plateau at whatever the cap let through — observed on hardware as
    // every heavily-affected channel reporting an identical, suspicious "2000 clicks" instead of
    // its real (much higher) count.
    private var dropoutCount = 0
    private var silenceCount = 0
    private var clickCount = 0
    private var clipCount = 0

    private var inClick = false
    private var clickRunLength = 0
    private var clickPeakDeviation: Float = 0
    private var clickStartSample: Int64 = 0

    private var inSilence = false
    private var silenceRunLength = 0
    private var silenceStartSample: Int64 = 0

    private var errorWindowSumSq: Double = 0
    private var errorWindowCount = 0
    private let errorWindowSize = 32
    private var consecutiveElevatedWindows = 0
    private var inDropout = false
    private var dropoutStartSample: Int64 = 0

    // The round trip introduces an unknown integer sample offset between what was sent and what
    // comes back. Note this is the OPPOSITE role assignment from the ping test's MLS matched
    // filter: there, the known short burst is the template and captured audio is the (wider)
    // window. Here, the reference stream never repeats, so by the time calibration finishes,
    // "frameIndex 0" has already flowed past and is gone — searching for it would never match.
    // Instead: take a short snippet of real captured audio as the (known, but unlabeled)
    // template, and search for it inside a wide *synthetic* window covering every plausible
    // candidate frameIndex the round trip could put it at.
    private var lockBuffer: [Float] = []
    private let lockTemplateFrames = 2048
    private let latencyMarginFrames: Int
    private var locked = false
    private var gaveUp = false
    private var referenceOffset: Int64 = 0 // frameIndex = sampleIndex - referenceOffset, once locked

    public init(channel: Int, sampleRate: Double, amplitude: Float, grantedBufferFrames: UInt32, noiseKind: NoiseSignalKind = .white, audioDumper: IncidentAudioDumper? = nil) {
        self.channel = channel
        self.sampleRate = sampleRate
        self.amplitude = amplitude
        self.noiseKind = noiseKind
        self.audioDumper = audioDumper
        self.latencyMarginFrames = max(Int(sampleRate * 0.1), Int(grantedBufferFrames) * 8)
        let dumpWindowFrames = Int(sampleRate * 0.3)
        self.capturedHistory = RingHistory(capacity: dumpWindowFrames)
        self.expectedHistory = RingHistory(capacity: dumpWindowFrames)
        self.dumpPostFrames = dumpWindowFrames
    }

    public func calibrateNoiseFloor(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        var sumSq: Float = 0
        var maxAbs: Float = 0
        for s in samples {
            sumSq += s * s
            maxAbs = max(maxAbs, abs(s))
        }
        let rms = sqrtf(sumSq / Float(samples.count))
        noiseFloor = max(rms, 0.0002)
        if audioDumper != nil {
            Log.info("[calib] channel=\(channel) samples=\(samples.count) rms=\(rms) maxAbs=\(maxAbs) noiseFloor=\(noiseFloor)")
        }
    }

    public func process(_ samples: [Float], startTimestampSeconds: Double) {
        guard !gaveUp else { return }
        guard locked else {
            let needed = lockTemplateFrames - lockBuffer.count
            let takeCount = max(min(needed, samples.count), 0)
            lockBuffer.append(contentsOf: samples.prefix(takeCount))
            totalSamples += Int64(takeCount)
            if lockBuffer.count >= lockTemplateFrames {
                attemptLock()
                guard locked else {
                    gaveUp = true
                    lockBuffer = []
                    // A channel that never locks silently reports zero incidents and 100% clean —
                    // indistinguishable in the summary from a channel that genuinely verified
                    // clean, unless this is surfaced: a real dropped cable, muted channel, or wrong
                    // routing should read as "unverified", not "safe".
                    Log.warn("stability: channel \(channel) never locked onto its reference noise signal — no input detected on this channel, or its round-trip latency exceeds the search window; its \"clean\" result for this buffer size is unverified, not confirmed.")
                    return
                }
                if takeCount < samples.count {
                    let remainder = Array(samples[takeCount...])
                    processDetection(remainder, startTimestampSeconds: startTimestampSeconds + Double(takeCount) / sampleRate)
                }
            }
            return
        }
        processDetection(samples, startTimestampSeconds: startTimestampSeconds)
    }

    /// `lockBuffer` (exactly `lockTemplateFrames` real captured samples, starting at the very
    /// first sample handed to `process()`) is the template; the window is a synthetic reference
    /// covering every frameIndex the round trip could plausibly have landed this template at.
    private func attemptLock() {
        let windowLen = Int(Double(latencyMarginFrames) * 1.25) + lockTemplateFrames
        let syntheticWindow = (0..<windowLen).map {
            noiseKind.sample(channel: channel, frameIndex: Int64($0)) * amplitude
        }
        guard let peak = CrossCorrelationOnsetDetector.detect(window: syntheticWindow, template: lockBuffer),
              peak.normalizedScore >= 0.3 else {
            return // caller treats a still-unlocked result as a give-up
        }
        // Local sample index 0 (the very first sample ever passed to process()) lines up with
        // referenceFrameIndex == peak.lag, and it's a fixed 1:1 offset from there.
        referenceOffset = -Int64(peak.lag)
        locked = true
        if audioDumper != nil {
            Log.info("[lock] channel=\(channel) score=\(peak.normalizedScore) lag=\(peak.lag) secondaryPeakRatio=\(peak.secondaryPeakRatio)")
        }
        lockBuffer = []
    }

    private func processDetection(_ samples: [Float], startTimestampSeconds: Double) {
        let clickThreshold = max(noiseFloor * 9, 0.02)
        let silenceThreshold = max(noiseFloor * 4, powf(10, -40.0 / 20.0))
        let dropoutErrorRatioThreshold = 0.35
        // Defense in depth against a miscalibrated (too-high) noiseFloor — e.g. from a
        // contaminated calibration window — pushing silenceThreshold up toward the signal's own
        // amplitude ceiling, which would flag routine low-amplitude (but healthy) samples as
        // silence instead of only genuine dropouts. Mirrors StreamingGlitchDetector's analogous
        // `amplitudeEstimate > silenceThreshold * 2` guard, using the known reference ceiling
        // (`amplitude`) in place of a tracked envelope since the noise reference has no envelope.
        let silenceThresholdIsSane = silenceThreshold * 2 < amplitude

        for (i, sample) in samples.enumerated() {
            let sampleIndex = totalSamples + Int64(i)
            let frameIndex = sampleIndex - referenceOffset
            let expected = noiseKind.sample(channel: channel, frameIndex: frameIndex) * amplitude
            let error = sample - expected
            let t = startTimestampSeconds + Double(i) / sampleRate

            if audioDumper != nil {
                advanceDumpState(captured: sample, expected: expected)
            }

            if abs(sample) > 0.99 {
                recordIncident(type: .clip, timestamp: t, durationMs: 1000.0 / sampleRate, severity: Double(abs(sample)))
            } else {
                if abs(error) > clickThreshold {
                    if !inClick {
                        inClick = true
                        clickRunLength = 0
                        clickPeakDeviation = 0
                        clickStartSample = sampleIndex
                    }
                    clickRunLength += 1
                    clickPeakDeviation = max(clickPeakDeviation, abs(error))
                } else if inClick {
                    if clickRunLength <= 20 {
                        let durationMs = Double(clickRunLength) / sampleRate * 1000.0
                        let severityDb = 20 * log10(Double(max(clickPeakDeviation, 1e-6)) / Double(max(noiseFloor, 1e-6)))
                        let ts = startTimestampSeconds + Double(clickStartSample - totalSamples) / sampleRate
                        recordIncident(type: .click, timestamp: ts, durationMs: durationMs, severity: severityDb)
                    }
                    inClick = false
                }

                // Also require the *reference* not be quiet at this instant: white/pink noise
                // never legitimately dips near zero, so this is a no-op for those (preserves
                // existing behavior exactly) — but an arbitrary WAV file can have genuine quiet
                // passages (fades, gaps), and without this check those would misreport as
                // "silence" incidents exactly like the calibration-window bug this detector
                // already had to be fixed for once this session.
                let isQuiet = abs(sample) < silenceThreshold && abs(expected) >= silenceThreshold && silenceThresholdIsSane
                if isQuiet {
                    if !inSilence {
                        inSilence = true
                        silenceRunLength = 0
                        silenceStartSample = sampleIndex
                    }
                    silenceRunLength += 1
                } else if inSilence {
                    let durationMs = Double(silenceRunLength) / sampleRate * 1000.0
                    if durationMs >= 3.0 {
                        let ts = startTimestampSeconds + Double(silenceStartSample - totalSamples) / sampleRate
                        recordIncident(type: .silence, timestamp: ts, durationMs: durationMs, severity: durationMs)
                    }
                    inSilence = false
                }
            }

            errorWindowSumSq += Double(error * error)
            errorWindowCount += 1
            if errorWindowCount >= errorWindowSize {
                let rmsError = sqrt(errorWindowSumSq / Double(errorWindowCount))
                let normalized = rmsError / Double(amplitude)
                if normalized > dropoutErrorRatioThreshold {
                    consecutiveElevatedWindows += 1
                    if !inDropout && consecutiveElevatedWindows >= 3 {
                        inDropout = true
                        dropoutStartSample = sampleIndex - Int64(errorWindowSize * 2)
                    }
                } else {
                    if inDropout {
                        let skippedSamples = Double(max(sampleIndex - dropoutStartSample, 0))
                        let durationMs = skippedSamples / sampleRate * 1000.0
                        let ts = startTimestampSeconds + Double(dropoutStartSample - totalSamples) / sampleRate
                        recordIncident(type: .dropout, timestamp: ts, durationMs: durationMs, severity: skippedSamples)
                        inDropout = false
                    }
                    consecutiveElevatedWindows = 0
                }
                errorWindowSumSq = 0
                errorWindowCount = 0
            }
        }
        totalSamples += Int64(samples.count)
    }

    /// Same ground-truth HAL sample-counter check as `StreamingGlitchDetector` — independent of
    /// the content-based comparison above.
    public func recordHardDropout(timestampSeconds: Double, missingFrames: Int64) {
        guard missingFrames > 0 else { return }
        let durationMs = Double(missingFrames) / sampleRate * 1000.0
        recordIncident(type: .dropout, timestamp: timestampSeconds, durationMs: durationMs, severity: Double(missingFrames))
    }

    private func recordIncident(type: IncidentType, timestamp: Double, durationMs: Double, severity: Double) {
        if incidents.count < maxDetailedIncidents {
            incidents.append(Incident(type: type, channel: channel, timestampSeconds: max(timestamp, 0), durationMs: durationMs, severity: severity))
        } else {
            truncatedCount += 1
        }
        switch type {
        case .dropout: dropoutCount += 1
        case .silence: silenceCount += 1
        case .click: clickCount += 1
        case .clip: clipCount += 1
        }
        if type != .clip {
            incidentAffectedSamples += Int64(durationMs / 1000.0 * sampleRate)
        }
        if audioDumper != nil {
            maybeStartDump(type: type, timestampSeconds: timestamp)
        }
    }

    private func advanceDumpState(captured: Float, expected: Float) {
        capturedHistory.append(captured)
        expectedHistory.append(expected)
        if pendingDump != nil {
            pendingDump!.capturedPost.append(captured)
            pendingDump!.expectedPost.append(expected)
            if pendingDump!.capturedPost.count >= dumpPostFrames {
                flushPendingDump()
            }
        }
    }

    private func maybeStartDump(type: IncidentType, timestampSeconds: Double) {
        guard let audioDumper, pendingDump == nil, audioDumper.shouldDump(channel: channel) else { return }
        pendingDump = PendingDump(
            incidentType: type.rawValue,
            timestampSeconds: timestampSeconds,
            capturedPre: capturedHistory.snapshot(),
            expectedPre: expectedHistory.snapshot()
        )
    }

    private func flushPendingDump() {
        guard let dump = pendingDump else { return }
        audioDumper?.dump(
            channel: channel,
            incidentType: dump.incidentType,
            timestampSeconds: dump.timestampSeconds,
            captured: dump.capturedPre + dump.capturedPost,
            expected: dump.expectedPre + dump.expectedPost
        )
        pendingDump = nil
    }

    public var liveIncidentCount: Int { incidents.count + truncatedCount }

    public func finish(totalDurationSeconds: Double) -> (incidents: [Incident], truncated: Int, channelSummary: ChannelStabilitySummary) {
        flushPendingDump()
        let affectedSeconds = Double(incidentAffectedSamples) / sampleRate
        let clean = totalDurationSeconds > 0 ? max(0, (totalDurationSeconds - affectedSeconds) / totalDurationSeconds * 100.0) : 100.0
        let channelSummary = ChannelStabilitySummary(channel: channel, dropoutCount: dropoutCount, silenceCount: silenceCount, clickCount: clickCount, clipCount: clipCount, cleanPercentage: clean, verified: !gaveUp)
        return (incidents, truncatedCount, channelSummary)
    }
}
