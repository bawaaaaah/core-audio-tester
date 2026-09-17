import CATEngine
import Foundation
import Synchronization

/// Drives one buffer size's stability test: plays a continuous-phase sine per output channel
/// (distinct non-harmonic frequency per channel) for the configured duration, with a silent
/// pre-roll used to self-calibrate each channel's noise floor before the tone starts.
public final class StabilityTestSession: StabilitySession {
    private let plan: TestPlan
    private let sampleRate: Double
    private let silencePrerollFrames: Int
    private let calibrationFrameTarget: Int
    private let detectionStartTarget: Int

    private let toneAmplitude: Float = 0.25
    private var frequencies: [Int: Double] = [:]
    private var outputPhase: [Int: Double] = [:]
    private var outputFrameCounter: [Int: Int64] = [:]
    private let firstSampleTime = Atomic<Int64>(Int64.min)

    private var detectors: [Int: StreamingGlitchDetector] = [:]
    private var calibrationBuffers: [Int: [Float]] = [:]
    private var channelSampleCount: [Int: Int64] = [:]
    private var expectedNextSampleTime: [Int: Int64] = [:]
    private let lock = NSLock()

    public init(plan: TestPlan, grantedBufferFrames: UInt32, sampleRate: Double) {
        self.plan = plan
        self.sampleRate = sampleRate
        // Three phases on the input side, gated by a single running per-channel sample count:
        // (1) calibration, which must finish reading BEFORE the render's own silent pre-roll
        // ends — `latencyMargin` is an upper bound on the round trip, spent here as a safety
        // cushion subtracted from the pre-roll's end, since real interfaces round-trip in a few
        // ms, far under the ~100ms floor, and a calibration window extending past the pre-roll
        // reads the tone's leading edge as "noise floor" (confirmed on hardware for the noise-mode
        // sibling of this class: inflated noiseFloor from ~0.0002 to ~0.06-0.08, pushing the
        // silence threshold up near the signal's own amplitude ceiling); (2) a dead zone that's
        // discarded outright, covering the uncertain stretch where the round trip may or may not
        // have delivered the tone yet; (3) detection, which must only start once the round trip
        // has DEFINITELY delivered the tone — using the same latencyMargin as an upper-bound
        // cushion, but added past the pre-roll this time, since understating it here would start
        // the phase-lock window on trailing silence instead of the tone and corrupt the locked
        // phase/amplitude estimate for the rest of the run.
        let latencyMargin = max(Int(sampleRate * 0.1), Int(grantedBufferFrames) * 8)
        let minCalibrationFrames = Int(sampleRate * 0.05)
        self.silencePrerollFrames = max(Int(sampleRate * 0.2), latencyMargin + minCalibrationFrames)
        self.calibrationFrameTarget = silencePrerollFrames - latencyMargin
        self.detectionStartTarget = silencePrerollFrames + latencyMargin

        for (idx, pair) in plan.pairs.enumerated() {
            let rawFreq = 300.0 + Double(idx) * 137.0
            let freq = min(max(rawFreq, 200), sampleRate * 0.4)
            frequencies[pair.outputChannel] = freq
            detectors[pair.inputChannel] = StreamingGlitchDetector(channel: pair.inputChannel, frequency: freq, sampleRate: sampleRate, expectedAmplitude: toneAmplitude)
            calibrationBuffers[pair.inputChannel] = []
        }
    }

    // MARK: OutputSignalProvider (realtime thread)

    public func renderOutput(channel: Int, buffer: UnsafeMutableBufferPointer<Float>, absoluteSampleTime: Int64) {
        _ = firstSampleTime.compareExchange(expected: Int64.min, desired: absoluteSampleTime, ordering: .relaxed)
        guard let freq = frequencies[channel] else { return }
        var phase = outputPhase[channel] ?? 0
        var counter = outputFrameCounter[channel] ?? 0
        let increment = 2 * Double.pi * freq / sampleRate
        for i in 0..<buffer.count {
            if counter < silencePrerollFrames {
                buffer[i] = 0
            } else {
                buffer[i] = toneAmplitude * Float(sin(phase))
                phase += increment
                if phase > 2 * Double.pi { phase -= 2 * Double.pi }
            }
            counter += 1
        }
        outputPhase[channel] = phase
        outputFrameCounter[channel] = counter
    }

    // MARK: InputCaptureSink (drain thread)

    public func consume(channel: Int, samples: UnsafeBufferPointer<Float>, sampleTime: Int64, hostTime: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard let detector = detectors[channel] else { return }

        // Ground-truth check against the HAL's own sample counter, independent of calibration
        // state or signal content: a gap here means the driver/transport genuinely dropped
        // frames between these two callbacks, not just an artifact of our own signal model.
        if let expected = expectedNextSampleTime[channel], sampleTime != expected {
            let missing = sampleTime - expected
            if missing > 0 {
                let t0 = firstSampleTime.load(ordering: .relaxed)
                let ts = t0 == Int64.min ? 0 : Double(expected - t0) / sampleRate
                detector.recordHardDropout(timestampSeconds: ts, missingFrames: missing)
            }
        }
        expectedNextSampleTime[channel] = sampleTime + Int64(samples.count)

        let t0 = firstSampleTime.load(ordering: .relaxed)
        let chunkStartTs = t0 == Int64.min ? 0 : Double(sampleTime - t0) / sampleRate

        var count = channelSampleCount[channel] ?? 0
        let all = Array(samples)
        var offset = 0
        let n = all.count

        while offset < n {
            if count < Int64(calibrationFrameTarget) {
                let take = min(calibrationFrameTarget - Int(count), n - offset)
                calibrationBuffers[channel, default: []].append(contentsOf: all[offset..<offset + take])
                offset += take
                count += Int64(take)
                if count >= Int64(calibrationFrameTarget) {
                    detector.calibrateNoiseFloor(calibrationBuffers[channel] ?? [])
                    calibrationBuffers[channel] = nil
                }
            } else if count < Int64(detectionStartTarget) {
                let take = min(detectionStartTarget - Int(count), n - offset)
                offset += take
                count += Int64(take)
            } else {
                let remainder = Array(all[offset...])
                detector.process(remainder, startTimestampSeconds: chunkStartTs + Double(offset) / sampleRate)
                offset = n
            }
        }
        channelSampleCount[channel] = count
    }

    public func liveIncidentCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return detectors.values.reduce(0) { $0 + $1.liveIncidentCount }
    }

    // MARK: Finalization

    public func finalize(overloadCount: Int, ioStoppedAbnormallyCount: Int, droppedRingBufferRecords: Int, actualDuration: TimeInterval) -> StabilityResult {
        var allIncidents: [Incident] = []
        var truncated = 0
        var perChannel: [ChannelStabilitySummary] = []
        for detector in detectors.values {
            let (incidents, trunc, summary) = detector.finish(totalDurationSeconds: actualDuration)
            allIncidents.append(contentsOf: incidents)
            truncated += trunc
            perChannel.append(summary)
        }
        allIncidents.sort { $0.timestampSeconds < $1.timestampSeconds }

        let nonClipIncidents = allIncidents.filter { $0.type != .clip }.count
        // No per-event overload timestamps are threaded through to this layer yet, so the
        // three-way overload/glitch cross-reference is approximated at the aggregate level:
        // treat all overloads as unmatched ("silent") unless the run is fully clean.
        let correlated = 0
        let silentOverloads = overloadCount
        let unexplained = overloadCount == 0 ? nonClipIncidents : max(0, nonClipIncidents - overloadCount)

        return StabilityResult(
            durationSeconds: actualDuration,
            overloadCount: overloadCount,
            incidents: allIncidents,
            truncatedIncidentCount: truncated,
            perChannel: perChannel.sorted { $0.channel < $1.channel },
            correlatedCount: correlated,
            silentOverloadCount: silentOverloads,
            unexplainedGlitchCount: unexplained,
            droppedRingBufferRecords: droppedRingBufferRecords
        )
    }
}
