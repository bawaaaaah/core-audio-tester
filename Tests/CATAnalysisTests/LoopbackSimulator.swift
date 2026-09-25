@testable import CATEngine

/// Drives a session exactly the way `AudioIOEngine` does (beginIOCycle, then renderOutput per
/// output, then the captured chunks through the drain path), over a perfect digital loopback.
///
/// Device time: cycle `c` captures input at `c * bufferFrames` and renders output at that time
/// plus `ioOffset`. What an output emits reaches its paired input `physicalDelay` frames later,
/// scaled by `gain`. The round-trip latency a session should measure is `ioOffset + physicalDelay`.
struct LoopbackSimulator {
    var pairs: [ChannelPair]
    var bufferFrames = 256
    var ioOffset: Int64 = 512
    var physicalDelay: Int64 = 137
    var gain: Float = 1

    var roundTripFrames: Int64 { ioOffset + physicalDelay }

    /// - `lostCaptureCycles`: chunks the capture ring buffer "drops" (reported to the sink through
    ///   `framesLostBefore` on the next chunk of the same channel).
    /// - `skippedDeviceCycles`: cycles the device never runs — nothing rendered, nothing captured,
    ///   device time moves on anyway.
    func run(
        provider: OutputSignalProvider,
        sink: InputCaptureSink,
        cycles: Int,
        lostCaptureCycles: Set<Int> = [],
        skippedDeviceCycles: Set<Int> = []
    ) {
        let outputs = Array(Set(pairs.map(\.outputChannel))).sorted()
        let timelineLength = (cycles + 4) * bufferFrames + Int(ioOffset)
        var timeline: [Int: [Float]] = [:]
        for channel in outputs { timeline[channel] = [Float](repeating: 0, count: timelineLength) }

        var buffer = [Float](repeating: 0, count: bufferFrames)
        for cycle in 0..<cycles where !skippedDeviceCycles.contains(cycle) {
            let inputTime = Int64(cycle * bufferFrames)
            let outputTime = inputTime + ioOffset
            provider.beginIOCycle(inputSampleTime: inputTime, outputSampleTime: outputTime)
            for channel in outputs {
                for i in buffer.indices { buffer[i] = 0 }
                buffer.withUnsafeMutableBufferPointer { provider.renderOutput(channel: channel, buffer: $0, absoluteSampleTime: outputTime) }
                for i in 0..<bufferFrames { timeline[channel]![Int(outputTime) + i] = buffer[i] }
            }
        }

        var pendingLost: [Int: Int] = [:]
        for cycle in 0..<cycles where !skippedDeviceCycles.contains(cycle) {
            let inputTime = Int64(cycle * bufferFrames)
            for pair in pairs {
                if lostCaptureCycles.contains(cycle) {
                    pendingLost[pair.inputChannel, default: 0] += bufferFrames
                    continue
                }
                var samples = [Float](repeating: 0, count: bufferFrames)
                let source = timeline[pair.outputChannel]!
                for i in 0..<bufferFrames {
                    let at = Int(inputTime) + i - Int(physicalDelay)
                    if at >= 0 && at < source.count { samples[i] = gain * source[at] }
                }
                let lost = pendingLost.removeValue(forKey: pair.inputChannel) ?? 0
                samples.withUnsafeBufferPointer {
                    sink.consume(CapturedChunk(channel: pair.inputChannel, samples: $0, sampleTime: inputTime, hostTime: 0, framesLostBefore: lost))
                }
            }
        }
    }

    static func plan(pairs: [ChannelPair], signal: StabilitySignalKind = .tone, pingRepetitions: Int = 3, pingMode: PingMode = .parallel, duration: Double = 1.5) -> TestPlan {
        TestPlan(
            deviceUID: "sim", deviceName: "Simulated", pairs: pairs, bufferSizes: [256], pingRepetitions: pingRepetitions,
            pingMode: pingMode, stabilityDurationSeconds: duration, sporadicToleranceWeightedPerMinute: 0.2, isAutoMode: false,
            exclusiveAccess: false, outputBasePath: "/tmp/cat-test", skipConfirmation: true, stabilitySignalKind: signal
        )
    }

    static func measurement(duration: Double) -> PhaseMeasurement {
        PhaseMeasurement(plannedDuration: duration, actualDuration: duration, overloadCount: 0, ioStoppedAbnormallyCount: 0, droppedCaptureRecords: 0, wasInterrupted: false)
    }
}
