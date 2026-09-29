import CATEngine
import Foundation
import Synchronization

/// Drives one stability pass for one buffer size: plays a continuous test signal on every selected
/// output after a silent pre-roll, and checks what comes back on each paired input.
///
/// Timelines: output frame `n` (counted from the first IO cycle's output time) plays signal frame
/// `n - preroll`; input stream index `j` is the capture at the first cycle's input time plus `j`.
/// Each input goes through three stretches:
/// 1. calibration `[0, preroll - margin)`: the round trip hasn't delivered anything yet, so this is
///    the channel's own noise floor;
/// 2. a dead zone up to `preroll + margin`, where the signal may or may not have arrived;
/// 3. detection from there on. `margin` is an upper bound on the round trip.
public final class StabilityTestSession: StabilitySession {
    public enum Signal {
        /// A distinct continuous sine per output channel.
        case sine
        /// A deterministic noise (or WAV) sequence per output channel, compared sample-exactly.
        case noise(NoiseSignalKind)
    }

    private let sampleRate: Double
    private let amplitude: Float
    private let prerollFrames: Int
    private let calibrationEndIndex: Int64
    private let detectionStartIndex: Int64

    // Realtime rendering state (read-only after init, apart from the origins).
    private let voiceByChannel: [Int]
    private let voicePhaseIncrements: [Double]
    private let noiseKind: NoiseSignalKind?
    private let outputOrigin = Atomic<Int64>(Int64.min)
    private let inputOrigin = Atomic<Int64>(Int64.min)

    // Capture state (drain thread; read by the console tick and finalize under the lock).
    private final class ChannelState {
        let detector: GlitchDetector
        var calibration: [Float] = []
        var calibrated = false
        var nextSampleTime: Int64?

        init(detector: GlitchDetector) {
            self.detector = detector
        }
    }

    private let lock = NSLock()
    private let channels: [Int: ChannelState]
    private let dumper: IncidentAudioDumper?

    /// Sine frequencies per output channel, in pair order: 300 Hz + 137 Hz steps (non-harmonic),
    /// kept below 40% of the sample rate.
    public static func sineFrequencies(outputChannels: [Int], sampleRate: Double) -> [Int: Double] {
        var frequencies: [Int: Double] = [:]
        for (index, channel) in outputChannels.enumerated() {
            frequencies[channel] = min(max(300.0 + Double(index) * 137.0, 200), sampleRate * 0.4)
        }
        return frequencies
    }

    public init(plan: TestPlan, grantedBufferFrames: UInt32, sampleRate: Double, signal: Signal, passLabel: String) {
        let latencyMargin = max(Int(sampleRate * 0.1), Int(grantedBufferFrames) * 8)
        let minCalibrationFrames = Int(sampleRate * 0.05)
        let preroll = max(Int(sampleRate * 0.2), latencyMargin + minCalibrationFrames)
        let amplitude = plan.outputPeakAmplitude
        self.sampleRate = sampleRate
        self.amplitude = amplitude
        self.prerollFrames = preroll
        self.calibrationEndIndex = Int64(preroll - latencyMargin)
        self.detectionStartIndex = Int64(preroll + latencyMargin)

        let outputs = plan.outputChannels
        var voices = [Int](repeating: -1, count: (outputs.max() ?? 0) + 1)
        for (voice, channel) in outputs.enumerated() { voices[channel] = voice }
        self.voiceByChannel = voices
        let frequencies = StabilityTestSession.sineFrequencies(outputChannels: outputs, sampleRate: sampleRate)
        self.voicePhaseIncrements = outputs.map { 2 * Double.pi * (frequencies[$0] ?? 440) / sampleRate }

        let dumper = plan.incidentAudioDumpPath.map { IncidentAudioDumper(directory: $0, sampleRate: sampleRate, passLabel: passLabel) }
        self.dumper = dumper

        var states: [Int: ChannelState] = [:]
        switch signal {
        case .sine:
            self.noiseKind = nil
            for pair in plan.pairs {
                let tracker = SineReferenceTracker(frequency: frequencies[pair.outputChannel] ?? 440, sampleRate: sampleRate)
                states[pair.inputChannel] = ChannelState(detector: GlitchDetector(channel: pair.inputChannel, sampleRate: sampleRate, tracker: tracker, dumper: dumper))
            }
        case .noise(let kind):
            self.noiseKind = kind
            for pair in plan.pairs {
                let tracker = NoiseReferenceTracker(
                    outputChannel: pair.outputChannel, noiseKind: kind, amplitude: amplitude,
                    prerollFrames: preroll, maxRoundTripFrames: latencyMargin, sampleRate: sampleRate
                )
                states[pair.inputChannel] = ChannelState(detector: GlitchDetector(channel: pair.inputChannel, sampleRate: sampleRate, tracker: tracker, dumper: dumper))
            }
        }
        self.channels = states
    }

    // MARK: OutputSignalProvider (realtime thread)

    public func beginIOCycle(inputSampleTime: Int64, outputSampleTime: Int64) {
        guard outputOrigin.load(ordering: .relaxed) == Int64.min else { return }
        inputOrigin.store(inputSampleTime, ordering: .relaxed)
        outputOrigin.store(outputSampleTime, ordering: .releasing)
    }

    public func renderOutput(channel: Int, buffer: UnsafeMutableBufferPointer<Float>, absoluteSampleTime: Int64) {
        guard channel >= 0, channel < voiceByChannel.count else { return }
        let voice = voiceByChannel[channel]
        let origin = outputOrigin.load(ordering: .acquiring)
        guard voice >= 0, origin != Int64.min else { return }
        let firstFrame = absoluteSampleTime - origin - Int64(prerollFrames)
        if let noiseKind {
            for i in 0..<buffer.count {
                let frame = firstFrame + Int64(i)
                if frame >= 0 {
                    buffer[i] = noiseKind.sample(channel: channel, frameIndex: frame) * amplitude
                }
            }
        } else {
            let increment = voicePhaseIncrements[voice]
            for i in 0..<buffer.count {
                let frame = firstFrame + Int64(i)
                if frame >= 0 {
                    buffer[i] = amplitude * Float(sin(increment * Double(frame)))
                }
            }
        }
    }

    // MARK: InputCaptureSink (drain thread)

    public func consume(_ chunk: CapturedChunk) {
        // Ordered after the first cycle's beginIOCycle by the ring buffer's release/acquire hand-off.
        let origin = inputOrigin.load(ordering: .acquiring)
        guard origin != Int64.min else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let state = channels[chunk.channel] else { return }

        let startIndex = chunk.sampleTime - origin
        if let expected = state.nextSampleTime, chunk.sampleTime != expected {
            // Whatever the ring buffer dropped is ours (analysis fell behind); the rest of the jump
            // is frames the device itself never delivered.
            let deviceMissing = (chunk.sampleTime - expected) - Int64(chunk.framesLostBefore)
            if deviceMissing != 0 {
                state.detector.recordDeviceGap(atIndex: expected - origin, missingFrames: abs(deviceMissing))
            }
        }
        state.nextSampleTime = chunk.sampleTime + Int64(chunk.samples.count)

        let count = Int64(chunk.samples.count)
        let endIndex = startIndex + count
        if !state.calibrated {
            let from = max(startIndex, 0)
            let to = min(endIndex, calibrationEndIndex)
            if from < to {
                state.calibration.append(contentsOf: chunk.samples[Int(from - startIndex)..<Int(to - startIndex)])
            }
            if endIndex >= calibrationEndIndex {
                state.detector.calibrateNoiseFloor(state.calibration)
                state.calibration = []
                state.calibrated = true
            }
        }
        if endIndex > detectionStartIndex {
            let from = max(startIndex, detectionStartIndex)
            let slice = UnsafeBufferPointer(rebasing: chunk.samples[Int(from - startIndex)...])
            state.detector.process(slice, startIndex: from)
        }
    }

    public func liveIncidentCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return channels.values.reduce(0) { $0 + $1.detector.liveIncidentCount }
    }

    // MARK: Finalization (after engine.stop())

    public func finalize(_ measurement: PhaseMeasurement) -> StabilityResult {
        lock.lock()
        defer { lock.unlock() }
        var incidents: [Incident] = []
        var truncated = 0
        var perChannel: [ChannelStabilitySummary] = []
        for (_, state) in channels.sorted(by: { $0.key < $1.key }) {
            let outcome = state.detector.finish(totalDurationSeconds: measurement.actualDuration)
            incidents.append(contentsOf: outcome.incidents)
            truncated += outcome.truncatedCount
            perChannel.append(outcome.summary)
        }
        incidents.sort { $0.timestampSeconds < $1.timestampSeconds }
        dumper?.waitUntilWritten()

        let unverified = perChannel.filter { !$0.verified }
        if let first = unverified.first, !measurement.wasInterrupted {
            let list = unverified.map { String($0.channel) }.joined(separator: ", ")
            Log.warn("stabilité : \(unverified.count) canal(aux) non vérifié(s) (entrée \(list)) — \(first.unverifiedReason ?? "raison inconnue"). Leur résultat \"propre\" n'est pas une preuve.")
        }

        return StabilityResult(
            plannedDurationSeconds: measurement.plannedDuration,
            durationSeconds: measurement.actualDuration,
            overloadCount: measurement.overloadCount,
            ioStoppedAbnormallyCount: measurement.ioStoppedAbnormallyCount,
            incidents: incidents,
            truncatedIncidentCount: truncated,
            perChannel: perChannel,
            droppedRingBufferRecords: measurement.droppedCaptureRecords,
            wasInterrupted: measurement.wasInterrupted
        )
    }
}
