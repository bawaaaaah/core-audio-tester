import CATEngine
import Foundation
import Synchronization

/// Drives one buffer size's stability test using a noise signal mode (white or pink): plays a
/// deterministic, stateless noise sequence (`NoiseSignalKind`) per output channel, with the
/// same silent pre-roll and calibration-window sizing already validated for the sine mode
/// (`StabilityTestSession`), then verifies the captured signal against the exact expected values
/// instead of a statistical sine model.
public final class NoiseStabilityTestSession: StabilitySession {
    private let plan: TestPlan
    private let sampleRate: Double
    private let silencePrerollFrames: Int
    private let calibrationFrameTarget: Int
    private let detectionStartTarget: Int
    private let noiseAmplitude: Float = 0.25
    private let noiseKind: NoiseSignalKind

    private var outputFrameCounter: [Int: Int64] = [:]
    private let firstSampleTime = Atomic<Int64>(Int64.min)

    private var detectors: [Int: NoiseGlitchDetector] = [:]
    private var calibrationBuffers: [Int: [Float]] = [:]
    private var channelSampleCount: [Int: Int64] = [:]
    private var expectedNextSampleTime: [Int: Int64] = [:]
    private let lock = NSLock()

    public init(plan: TestPlan, grantedBufferFrames: UInt32, sampleRate: Double) {
        self.plan = plan
        self.sampleRate = sampleRate
        switch plan.stabilitySignalKind {
        case .pinkNoise:
            self.noiseKind = .pink
        case .wavFile:
            // Already validated (exists, decodes, sample rate matches the device) by
            // `TestPlanResolver.resolve` before the sweep ever started — re-decoding here (once
            // per buffer size) trades a little redundant I/O for keeping `TestPlan` a lightweight,
            // Codable path reference instead of carrying the whole decoded buffer around.
            if let path = plan.wavFilePath, let decoded = try? WAVReader.read(url: URL(fileURLWithPath: path)) {
                let outputChannelsInOrder = plan.pairs.map(\.outputChannel)
                self.noiseKind = .wavFile(WAVFileReference(decoded: decoded, outputChannelsInOrder: outputChannelsInOrder))
            } else {
                self.noiseKind = .white
            }
        case .whiteNoise, .tone:
            self.noiseKind = .white
        }
        // Three phases on the input side, gated by a single running per-channel sample count:
        // (1) calibration, which must finish reading BEFORE the render's own silent pre-roll
        // ends — `latencyMargin` is an upper bound on the round trip, spent here as a safety
        // cushion subtracted from the pre-roll's end, since real interfaces round-trip in a few
        // ms, far under the ~100ms floor, and a calibration window extending past the pre-roll
        // reads actual signal as "noise floor" (confirmed on hardware: inflated noiseFloor from
        // ~0.0002 to ~0.06-0.08, pushing the silence threshold up near the signal's own amplitude
        // ceiling); (2) a dead zone that's discarded outright, covering the uncertain stretch
        // where the round trip may or may not have delivered the real signal yet; (3) detection,
        // which must only start once the round trip has DEFINITELY delivered real signal — using
        // the same latencyMargin as an upper-bound cushion, but added past the pre-roll this time,
        // since understating it here would start the lock/phase-lock template on trailing silence
        // instead of the real signal and corrupt the lock for the rest of the run.
        let latencyMargin = max(Int(sampleRate * 0.1), Int(grantedBufferFrames) * 8)
        let minCalibrationFrames = Int(sampleRate * 0.05)
        self.silencePrerollFrames = max(Int(sampleRate * 0.2), latencyMargin + minCalibrationFrames)
        self.calibrationFrameTarget = silencePrerollFrames - latencyMargin
        self.detectionStartTarget = silencePrerollFrames + latencyMargin

        let audioDumper = plan.incidentAudioDumpPath.map { IncidentAudioDumper(directory: $0, sampleRate: sampleRate) }

        for pair in plan.pairs {
            outputFrameCounter[pair.outputChannel] = 0
            detectors[pair.inputChannel] = NoiseGlitchDetector(
                channel: pair.inputChannel, sampleRate: sampleRate, amplitude: noiseAmplitude, grantedBufferFrames: grantedBufferFrames,
                noiseKind: noiseKind, audioDumper: audioDumper
            )
            calibrationBuffers[pair.inputChannel] = []
        }
    }

    // MARK: OutputSignalProvider (realtime thread)

    public func renderOutput(channel: Int, buffer: UnsafeMutableBufferPointer<Float>, absoluteSampleTime: Int64) {
        _ = firstSampleTime.compareExchange(expected: Int64.min, desired: absoluteSampleTime, ordering: .relaxed)
        guard let counter0 = outputFrameCounter[channel] else { return }
        var counter = counter0
        for i in 0..<buffer.count {
            if counter < Int64(silencePrerollFrames) {
                buffer[i] = 0
            } else {
                let frameIndex = counter - Int64(silencePrerollFrames)
                buffer[i] = noiseKind.sample(channel: channel, frameIndex: frameIndex) * noiseAmplitude
            }
            counter += 1
        }
        outputFrameCounter[channel] = counter
    }

    // MARK: InputCaptureSink (drain thread)

    public func consume(channel: Int, samples: UnsafeBufferPointer<Float>, sampleTime: Int64, hostTime: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard let detector = detectors[channel] else { return }

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
