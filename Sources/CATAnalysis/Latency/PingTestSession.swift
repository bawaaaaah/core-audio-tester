import CATEngine
import Foundation
import Synchronization

/// Drives one buffer size's latency ping test: emits MLS bursts on the selected outputs (all at
/// once with distinct sequences, or one pair at a time) and correlates the looped-back capture
/// against the known templates to estimate the round-trip latency.
///
/// Both timelines are indexed by device sample time relative to the first IO cycle: output index
/// `k` is played at `outputOrigin + k`, capture index `j` holds the input at `inputOrigin + j`.
/// A burst found at capture index `j` for output index `k` gives the round trip `j - k` — immune to
/// skipped cycles or capture records dropped along the way, which leave zeros instead of shifting
/// everything after them.
public final class PingTestSession: PingSession {
    private let plan: TestPlan
    private let sampleRate: Double
    private let repsPerPair: Int
    private let mode: PingMode
    private let gapFrames: Int
    private let searchMarginFrames: Int
    private let trackLength: Int
    private let templatesByOutputChannel: [Int: [Float]]

    // Realtime rendering state (read-only after init, apart from the origin).
    private let outputSlotByChannel: [Int]
    private let outputTracks: UnsafeMutablePointer<Float>
    private let outputOrigin = Atomic<Int64>(Int64.min)
    private let inputOrigin = Atomic<Int64>(Int64.min)

    // Capture state (drain thread, then finalize() once the engine has stopped).
    private let inputSlotByChannel: [Int: Int]
    private let captures: UnsafeMutablePointer<Float>
    private let captureStorageCount: Int
    private let outputStorageCount: Int
    private let anySignalFlag = Atomic<Bool>(false)
    private let captureLock = NSLock()

    public init(plan: TestPlan, grantedBufferFrames: UInt32, sampleRate: Double) {
        let reps = max(plan.pingRepetitions, 1)
        let amplitude = plan.outputPeakAmplitude
        let burstLength = (1 << MLSSignalGenerator.pingOrder) - 1
        // Scales with buffer size so the round trip at large buffers still lands inside the
        // per-repetition search window, while staying short enough at small buffers not to reach
        // the next repetition's burst.
        let margin = max(Int(sampleRate * 0.05), Int(grantedBufferFrames) * 8)
        let gap = burstLength + margin + Int(sampleRate * 0.05)
        let burstSlots = plan.pingMode == .parallel ? reps : plan.pairs.count * reps
        let length = burstSlots * gap + burstLength + Int(sampleRate * 0.5)

        let outputs = plan.outputChannels
        var templates: [Int: [Float]] = [:]
        switch plan.pingMode {
        case .parallel:
            let sequences = MLSSignalGenerator.distinctPingSequences(count: outputs.count)
            for (index, channel) in outputs.enumerated() { templates[channel] = sequences[index] }
        case .sequential:
            let base = MLSSignalGenerator.generate(order: MLSSignalGenerator.pingOrder)
            for channel in outputs { templates[channel] = base }
        }

        var outputSlots = [Int](repeating: -1, count: (outputs.max() ?? 0) + 1)
        for (slot, channel) in outputs.enumerated() { outputSlots[channel] = slot }
        let outputCount = max(outputs.count * length, 1)
        let tracks = UnsafeMutablePointer<Float>.allocate(capacity: outputCount)
        tracks.initialize(repeating: 0, count: outputCount)
        for (pairIndex, pair) in plan.pairs.enumerated() {
            guard let template = templates[pair.outputChannel] else { continue }
            let track = tracks + outputSlots[pair.outputChannel] * length
            for repetition in 0..<reps {
                let burst = plan.pingMode == .parallel ? repetition : pairIndex * reps + repetition
                let offset = burst * gap
                for (i, value) in template.enumerated() where offset + i < length {
                    track[offset + i] = value * amplitude
                }
            }
        }

        let inputs = plan.inputChannels
        let captureCount = max(inputs.count * length, 1)
        let captureBuffer = UnsafeMutablePointer<Float>.allocate(capacity: captureCount)
        captureBuffer.initialize(repeating: 0, count: captureCount)

        self.plan = plan
        self.sampleRate = sampleRate
        self.repsPerPair = reps
        self.mode = plan.pingMode
        self.gapFrames = gap
        self.searchMarginFrames = margin
        self.trackLength = length
        self.templatesByOutputChannel = templates
        self.outputSlotByChannel = outputSlots
        self.outputTracks = tracks
        self.outputStorageCount = outputCount
        self.inputSlotByChannel = Dictionary(uniqueKeysWithValues: inputs.enumerated().map { ($0.element, $0.offset) })
        self.captures = captureBuffer
        self.captureStorageCount = captureCount
    }

    deinit {
        outputTracks.deallocate()
        captures.deallocate()
    }

    public var estimatedDuration: TimeInterval { Double(trackLength) / sampleRate }
    public var receivedAnyInputSignal: Bool { anySignalFlag.load(ordering: .relaxed) }

    // MARK: OutputSignalProvider (realtime thread)

    public func beginIOCycle(inputSampleTime: Int64, outputSampleTime: Int64) {
        guard outputOrigin.load(ordering: .relaxed) == Int64.min else { return }
        inputOrigin.store(inputSampleTime, ordering: .relaxed)
        outputOrigin.store(outputSampleTime, ordering: .releasing)
    }

    public func renderOutput(channel: Int, buffer: UnsafeMutableBufferPointer<Float>, absoluteSampleTime: Int64) {
        guard channel >= 0, channel < outputSlotByChannel.count else { return }
        let slot = outputSlotByChannel[channel]
        let origin = outputOrigin.load(ordering: .acquiring)
        guard slot >= 0, origin != Int64.min else { return }
        let track = outputTracks + slot * trackLength
        let first = absoluteSampleTime - origin
        let length = Int64(trackLength)
        for i in 0..<buffer.count {
            let index = first + Int64(i)
            if index >= 0 && index < length {
                buffer[i] = track[Int(index)]
            }
        }
    }

    // MARK: InputCaptureSink (drain thread)

    public func consume(_ chunk: CapturedChunk) {
        if !anySignalFlag.load(ordering: .relaxed), chunk.samples.contains(where: { $0 != 0 }) {
            anySignalFlag.store(true, ordering: .relaxed)
        }
        // The ring buffer's release/acquire hand-off orders this after the first cycle's
        // beginIOCycle, which set the origin.
        let origin = inputOrigin.load(ordering: .acquiring)
        guard origin != Int64.min, let slot = inputSlotByChannel[chunk.channel] else { return }
        captureLock.lock()
        defer { captureLock.unlock() }
        let track = captures + slot * trackLength
        let first = chunk.sampleTime - origin
        let length = Int64(trackLength)
        for i in 0..<chunk.samples.count {
            let index = first + Int64(i)
            if index >= 0 && index < length {
                track[Int(index)] = chunk.samples[i]
            }
        }
    }

    // MARK: Finalization (after engine.stop())

    public func finalize() -> [PairLatencyResult] {
        captureLock.lock()
        defer { captureLock.unlock() }
        var results: [PairLatencyResult] = []
        for (pairIndex, pair) in plan.pairs.enumerated() {
            guard let slot = inputSlotByChannel[pair.inputChannel], let template = templatesByOutputChannel[pair.outputChannel] else { continue }
            let captured = UnsafeBufferPointer(start: captures + slot * trackLength, count: trackLength)
            var latenciesMs: [Double] = []
            var ambiguous = 0
            for repetition in 0..<repsPerPair {
                let burst = mode == .parallel ? repetition : pairIndex * repsPerPair + repetition
                let searchStart = burst * gapFrames
                let searchEnd = min(trackLength, searchStart + template.count + searchMarginFrames)
                guard searchEnd - searchStart > template.count else { continue }
                let window = Array(captured[searchStart..<searchEnd])
                guard let peak = CrossCorrelationOnsetDetector.detect(window: window, template: template, polarityInsensitive: true),
                      peak.normalizedScore >= 0.35
                else { continue }
                if peak.secondaryPeakRatio < 2.0 { ambiguous += 1 }
                let latencyFrames = Double(peak.lag) + peak.fractionalOffset
                latenciesMs.append(latencyFrames / sampleRate * 1000.0)
            }
            let stats = LatencyStats.summarize(latenciesMs)
            results.append(PairLatencyResult(
                pair: pair,
                repetitionsRequested: repsPerPair,
                repetitionsDetected: latenciesMs.count,
                meanMs: stats.mean,
                medianMs: stats.median,
                minMs: stats.min,
                maxMs: stats.max,
                stddevMs: stats.stddev,
                ambiguousCount: ambiguous,
                outlierCount: stats.outliers
            ))
        }
        return results
    }
}
