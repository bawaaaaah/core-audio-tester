import CATEngine
import Foundation
import Synchronization

/// Drives one buffer size's latency ping test: emits MLS bursts on the selected output
/// channels (parallel by default, or paired-only in sequential mode) and correlates the
/// looped-back capture against the known template(s) to estimate round-trip latency.
public final class PingTestSession: PingSession {
    private let plan: TestPlan
    private let sampleRate: Double
    private let repsPerPair: Int
    private let mode: PingMode
    private let gapSeconds: Double
    private let searchMarginFrames: Int
    private let mlsOrder = 10
    private let baseTemplate: [Float]
    private let grantedBufferFrames: UInt32

    private var templatesByOutputChannel: [Int: [Float]] = [:]
    private var outputSchedule: [Int: [Float]] = [:]
    private var outputCursor: [Int: Int] = [:]
    private var trackLengthFrames: Int = 0

    private var captureBuffers: [Int: [Float]] = [:]
    private var captureWriteIndex: [Int: Int] = [:]
    private let anySignalFlag = Atomic<Bool>(false)
    private let captureLock = NSLock()

    public init(plan: TestPlan, grantedBufferFrames: UInt32, sampleRate: Double) {
        self.plan = plan
        self.grantedBufferFrames = grantedBufferFrames
        self.sampleRate = sampleRate
        self.repsPerPair = max(plan.pingRepetitions, 1)
        self.mode = plan.pingMode
        let length = (1 << mlsOrder) - 1
        self.baseTemplate = MLSSignalGenerator.generate(order: mlsOrder, shift: 0)
        let captureMarginFrames = Int(sampleRate * 0.5)
        // Scales with buffer size so the round trip at large buffers still lands inside the
        // per-repetition search window, while staying tight enough at small buffers to avoid
        // picking up the next (identical) repetition's burst and flagging it "ambiguous".
        let margin = max(Int(sampleRate * 0.05), Int(grantedBufferFrames) * 8)
        self.searchMarginFrames = margin
        self.gapSeconds = Double(length + margin + Int(sampleRate * 0.05)) / sampleRate
        let gapFrames = Int(gapSeconds * sampleRate)

        switch mode {
        case .parallel:
            trackLengthFrames = repsPerPair * gapFrames + length + captureMarginFrames
        case .sequential:
            trackLengthFrames = plan.pairs.count * repsPerPair * gapFrames + length + captureMarginFrames
        }

        for (idx, pair) in plan.pairs.enumerated() {
            switch mode {
            case .parallel:
                let shiftStep = max(length / max(plan.pairs.count, 1), 1)
                templatesByOutputChannel[pair.outputChannel] = MLSSignalGenerator.generate(order: mlsOrder, shift: idx * shiftStep)
            case .sequential:
                templatesByOutputChannel[pair.outputChannel] = baseTemplate
            }
        }

        for (idx, pair) in plan.pairs.enumerated() {
            guard let tmpl = templatesByOutputChannel[pair.outputChannel] else { continue }
            var track = [Float](repeating: 0, count: trackLengthFrames)
            for r in 0..<repsPerPair {
                let slot: Int
                switch mode {
                case .parallel: slot = r
                case .sequential: slot = idx * repsPerPair + r
                }
                let offset = slot * gapFrames
                for (i, v) in tmpl.enumerated() where offset + i < track.count {
                    track[offset + i] = v * 0.5
                }
            }
            outputSchedule[pair.outputChannel] = track
            outputCursor[pair.outputChannel] = 0
        }

        for channel in plan.inputChannels {
            captureBuffers[channel] = [Float](repeating: 0, count: trackLengthFrames)
            captureWriteIndex[channel] = 0
        }
    }

    public var estimatedDuration: TimeInterval { Double(trackLengthFrames) / sampleRate }
    public var receivedAnyInputSignal: Bool { anySignalFlag.load(ordering: .relaxed) }

    // MARK: OutputSignalProvider (realtime thread)

    public func renderOutput(channel: Int, buffer: UnsafeMutableBufferPointer<Float>, absoluteSampleTime: Int64) {
        guard let track = outputSchedule[channel] else { return }
        let cursor = outputCursor[channel] ?? 0
        let remaining = track.count - cursor
        guard remaining > 0 else { return }
        let n = min(remaining, buffer.count)
        track.withUnsafeBufferPointer { src in
            for i in 0..<n { buffer[i] = src[cursor + i] }
        }
        outputCursor[channel] = cursor + n
    }

    // MARK: InputCaptureSink (drain thread)

    public func consume(channel: Int, samples: UnsafeBufferPointer<Float>, sampleTime: Int64, hostTime: UInt64) {
        if !anySignalFlag.load(ordering: .relaxed) {
            for s in samples where s != 0 {
                anySignalFlag.store(true, ordering: .relaxed)
                break
            }
        }
        captureLock.lock()
        defer { captureLock.unlock() }
        guard var buffer = captureBuffers[channel] else { return }
        let writeIdx = captureWriteIndex[channel] ?? 0
        let remaining = buffer.count - writeIdx
        guard remaining > 0 else { return }
        let n = min(remaining, samples.count)
        buffer.withUnsafeMutableBufferPointer { dst in
            for i in 0..<n { dst[writeIdx + i] = samples[i] }
        }
        captureBuffers[channel] = buffer
        captureWriteIndex[channel] = writeIdx + n
    }

    // MARK: Finalization (called after engine.stop(), single-threaded)

    public func finalize() -> [PairLatencyResult] {
        var results: [PairLatencyResult] = []
        let gapFrames = Int(gapSeconds * sampleRate)
        for (idx, pair) in plan.pairs.enumerated() {
            guard let captured = captureBuffers[pair.inputChannel], let tmpl = templatesByOutputChannel[pair.outputChannel] else { continue }
            var latenciesMs: [Double] = []
            var ambiguous = 0
            for r in 0..<repsPerPair {
                let slot: Int
                switch mode {
                case .parallel: slot = r
                case .sequential: slot = idx * repsPerPair + r
                }
                let offset = slot * gapFrames
                let searchStart = offset
                let searchEnd = min(captured.count, offset + tmpl.count + searchMarginFrames)
                guard searchEnd > searchStart, searchEnd - searchStart > tmpl.count else { continue }
                let windowSamples = Array(captured[searchStart..<searchEnd])
                guard let peak = CrossCorrelationOnsetDetector.detect(window: windowSamples, template: tmpl) else { continue }
                guard peak.normalizedScore >= 0.35 else { continue }
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
