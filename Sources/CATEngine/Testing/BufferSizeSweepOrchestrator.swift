import CoreAudio
import Foundation

public enum SweepError: Error, CustomStringConvertible {
    case noInputSignalDetected

    public var description: String {
        switch self {
        case .noInputSignalDetected:
            return "No input signal detected on any selected input channel during the first ping test. Check that microphone permission is granted (System Settings > Privacy & Security > Microphone) and that the device/routing/cabling is correct."
        }
    }
}

public struct SweepProgress {
    public let bufferSizeIndex: Int
    public let totalBufferSizes: Int
    public let requestedFrames: UInt32
    public let grantedFrames: UInt32
    public let phase: String
    /// Simulated CPU load percent for this pass, nil for the ping phase and the idle stability pass.
    public let cpuLoadPercent: Int?
}

/// Fired periodically (a few times per second) while a phase is running, to drive a live
/// console dashboard. `liveIncidentCount` is nil during the ping phase (not meaningful there).
public struct SweepLiveTick {
    public let bufferSizeIndex: Int
    public let totalBufferSizes: Int
    public let grantedFrames: UInt32
    public let phase: String
    public let elapsed: TimeInterval
    public let total: TimeInterval
    public let liveIncidentCount: Int?
    /// Simulated CPU load percent for this pass, nil for the ping phase and the idle stability pass.
    public let cpuLoadPercent: Int?
}

public final class BufferSizeSweepOrchestrator {
    private let device: DeviceInfo
    private let plan: TestPlan
    private let delegate: SweepDelegate
    private let progressHandler: (SweepProgress) -> Void
    private let liveTickHandler: (SweepLiveTick) -> Void

    public init(
        device: DeviceInfo,
        plan: TestPlan,
        delegate: SweepDelegate,
        progressHandler: @escaping (SweepProgress) -> Void = { _ in },
        liveTickHandler: @escaping (SweepLiveTick) -> Void = { _ in }
    ) {
        self.device = device
        self.plan = plan
        self.delegate = delegate
        self.progressHandler = progressHandler
        self.liveTickHandler = liveTickHandler
    }

    public func run() throws -> (results: [BufferSizeResult], wasInterrupted: Bool) {
        let configurator = try DeviceConfigurator(deviceID: device.audioObjectID)
        defer { configurator.restoreOriginalSettings() }

        var results: [BufferSizeResult] = []
        var interrupted = false
        let maxFrames = Int(plan.bufferSizes.max() ?? 2048)

        for (index, requested) in plan.bufferSizes.enumerated() {
            if CancellationController.shared.isCancelled { interrupted = true; break }

            let previousStopped = try? AudioObjectProperty.read(device.audioObjectID, AudioObjectProperty.address(kAudioDevicePropertyBufferFrameSize), as: UInt32.self)
            _ = previousStopped
            let granted = try configurator.setBufferFrameSize(requested)
            let sampleRate = try AudioObjectProperty.read(device.audioObjectID, AudioObjectProperty.address(kAudioDevicePropertyNominalSampleRate), as: Float64.self)

            let engine = try AudioIOEngine(deviceID: device.audioObjectID, maxFramesPerCallback: max(maxFrames, Int(granted)) + 16)
            engine.selectedOutputChannels = plan.outputChannels
            engine.selectedInputChannels = plan.inputChannels

            // --- Ping phase ---
            progressHandler(SweepProgress(bufferSizeIndex: index, totalBufferSizes: plan.bufferSizes.count, requestedFrames: requested, grantedFrames: granted, phase: "ping", cpuLoadPercent: nil))
            let pingSession = delegate.makePingSession(plan: plan, grantedBufferFrames: granted, sampleRate: sampleRate)
            engine.outputProvider = pingSession
            engine.inputSink = pingSession
            try engine.start()
            let pingTotal = pingSession.estimatedDuration + 0.5
            waitCooperatively(duration: pingTotal) { elapsed in
                self.liveTickHandler(SweepLiveTick(
                    bufferSizeIndex: index, totalBufferSizes: plan.bufferSizes.count, grantedFrames: granted,
                    phase: "ping", elapsed: elapsed, total: pingTotal, liveIncidentCount: nil, cpuLoadPercent: nil
                ))
            }
            engine.stop()
            let pingResults = pingSession.finalize()

            if index == 0 && !plan.inputChannels.isEmpty && !pingSession.receivedAnyInputSignal {
                throw SweepError.noInputSignalDetected
            }

            if CancellationController.shared.isCancelled { interrupted = true; break }

            // --- Stability phase, idle (reuse the engine, fresh counters) ---
            progressHandler(SweepProgress(bufferSizeIndex: index, totalBufferSizes: plan.bufferSizes.count, requestedFrames: requested, grantedFrames: granted, phase: "stability", cpuLoadPercent: nil))
            engine.resetCountersForNewPhase()
            let stabilitySession = delegate.makeStabilitySession(plan: plan, grantedBufferFrames: granted, sampleRate: sampleRate)
            engine.outputProvider = stabilitySession
            engine.inputSink = stabilitySession
            try engine.start()
            let stabilityStart = Date()
            waitCooperatively(duration: plan.stabilityDurationSeconds) { elapsed in
                self.liveTickHandler(SweepLiveTick(
                    bufferSizeIndex: index, totalBufferSizes: plan.bufferSizes.count, grantedFrames: granted,
                    phase: "stability", elapsed: elapsed, total: plan.stabilityDurationSeconds,
                    liveIncidentCount: stabilitySession.liveIncidentCount(), cpuLoadPercent: nil
                ))
            }
            let actualDuration = Date().timeIntervalSince(stabilityStart)
            let overloadCount = engine.overloadCount
            let ioStoppedCount = engine.ioStoppedAbnormallyCount
            let dropped = engine.ringBuffer.droppedRecords
            engine.stop()
            let stability = stabilitySession.finalize(
                overloadCount: overloadCount,
                ioStoppedAbnormallyCount: ioStoppedCount,
                droppedRingBufferRecords: dropped,
                actualDuration: actualDuration
            )

            // --- Stability phase, repeated under simulated CPU load (opt-in, additive) ---
            var loadedResults: [LoadedStabilityResult] = []
            for loadPercent in plan.cpuLoadLevelsPercent {
                if CancellationController.shared.isCancelled { interrupted = true; break }

                progressHandler(SweepProgress(bufferSizeIndex: index, totalBufferSizes: plan.bufferSizes.count, requestedFrames: requested, grantedFrames: granted, phase: "stability", cpuLoadPercent: loadPercent))
                engine.resetCountersForNewPhase()
                let loadedSession = delegate.makeStabilitySession(plan: plan, grantedBufferFrames: granted, sampleRate: sampleRate)
                engine.outputProvider = loadedSession
                engine.inputSink = loadedSession
                let loadGenerator = CPULoadGenerator(targetLoadPercent: Double(loadPercent))
                loadGenerator.start()
                let memoryGenerator = plan.memoryPressureMB > 0 ? MemoryPressureGenerator(targetMB: plan.memoryPressureMB) : nil
                memoryGenerator?.start()
                try engine.start()
                let loadedStart = Date()
                waitCooperatively(duration: plan.stabilityDurationSeconds) { elapsed in
                    self.liveTickHandler(SweepLiveTick(
                        bufferSizeIndex: index, totalBufferSizes: plan.bufferSizes.count, grantedFrames: granted,
                        phase: "stability", elapsed: elapsed, total: plan.stabilityDurationSeconds,
                        liveIncidentCount: loadedSession.liveIncidentCount(), cpuLoadPercent: loadPercent
                    ))
                }
                let loadedActualDuration = Date().timeIntervalSince(loadedStart)
                let loadedOverloadCount = engine.overloadCount
                let loadedIOStoppedCount = engine.ioStoppedAbnormallyCount
                let loadedDropped = engine.ringBuffer.droppedRecords
                engine.stop()
                loadGenerator.stop()
                memoryGenerator?.stop()
                let loadedStability = loadedSession.finalize(
                    overloadCount: loadedOverloadCount,
                    ioStoppedAbnormallyCount: loadedIOStoppedCount,
                    droppedRingBufferRecords: loadedDropped,
                    actualDuration: loadedActualDuration
                )
                loadedResults.append(LoadedStabilityResult(
                    cpuLoadPercent: loadPercent, memoryPressureActive: memoryGenerator != nil, stability: loadedStability
                ))
            }

            let inputStreamIDs = engine.inputMap.streamIDs(forDeviceChannels: plan.inputChannels)
            let outputStreamIDs = engine.outputMap.streamIDs(forDeviceChannels: plan.outputChannels)
            let halLatency = configurator.readLatencyInfo(inputStreamIDs: inputStreamIDs, outputStreamIDs: outputStreamIDs, bufferFrames: granted)

            results.append(BufferSizeResult(
                requestedFrames: requested,
                grantedFrames: granted,
                sampleRate: sampleRate,
                halLatency: halLatency,
                pingResults: pingResults,
                stability: stability,
                loadedStability: loadedResults
            ))

            if CancellationController.shared.isCancelled { interrupted = true; break }
        }

        return (results, interrupted)
    }

    private func waitCooperatively(duration: TimeInterval, onTick: (TimeInterval) -> Void = { _ in }) {
        let start = Date()
        let deadline = start.addingTimeInterval(duration)
        var lastTick = Date.distantPast
        let tickInterval: TimeInterval = 0.2
        while Date() < deadline {
            if CancellationController.shared.isCancelled { return }
            let now = Date()
            if now.timeIntervalSince(lastTick) >= tickInterval {
                onTick(now.timeIntervalSince(start))
                lastTick = now
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        onTick(Date().timeIntervalSince(start))
    }
}
