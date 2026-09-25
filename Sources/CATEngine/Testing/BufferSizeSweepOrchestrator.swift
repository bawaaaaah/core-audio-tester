import CoreAudio
import Foundation

public enum SweepError: Error, CustomStringConvertible {
    case noInputSignalDetected
    case deviceDisconnected
    case sampleRateChanged(expected: Double)

    public var description: String {
        switch self {
        case .noInputSignalDetected:
            return "Aucun signal reçu sur les entrées testées pendant le premier ping. Vérifie l'autorisation micro (Réglages Système > Confidentialité et sécurité > Microphone), le routage et le câblage de la boucle."
        case .deviceDisconnected:
            return "L'interface a disparu pendant le test (débranchée ou redémarrée)."
        case .sampleRateChanged(let expected):
            return "La fréquence d'échantillonnage de l'interface a changé pendant le test (attendue : \(Int(expected)) Hz). Les mesures en cours ne sont plus comparables."
        }
    }
}

public enum SweepPhase: String, Sendable {
    case ping
    case stability
}

public struct SweepProgress {
    public let bufferSizeIndex: Int
    public let totalBufferSizes: Int
    public let requestedFrames: UInt32
    public let grantedFrames: UInt32
    public let phase: SweepPhase
    /// Simulated CPU load percent for this pass, nil for the ping phase and the idle stability pass.
    public let cpuLoadPercent: Int?
}

/// Fired a few times per second while a phase runs, to drive a live console line.
/// `liveIncidentCount` is nil during the ping phase.
public struct SweepLiveTick {
    public let bufferSizeIndex: Int
    public let totalBufferSizes: Int
    public let grantedFrames: UInt32
    public let phase: SweepPhase
    public let elapsed: TimeInterval
    public let total: TimeInterval
    public let liveIncidentCount: Int?
    /// Simulated CPU load percent for this pass, nil for the ping phase and the idle stability pass.
    public let cpuLoadPercent: Int?
}

/// Everything a sweep produced. `error` is set when the sweep stopped early on a failure; the
/// buffer sizes completed before it are still in `results`.
public struct SweepOutcome {
    public let results: [BufferSizeResult]
    public let wasInterrupted: Bool
    public let error: Error?
}

public final class BufferSizeSweepOrchestrator {
    private let device: DeviceInfo
    private let plan: TestPlan
    private let delegate: SweepDelegate
    private let progressHandler: (SweepProgress) -> Void
    private let liveTickHandler: (SweepLiveTick) -> Void
    private let noticeHandler: (String) -> Void

    public init(
        device: DeviceInfo,
        plan: TestPlan,
        delegate: SweepDelegate,
        progressHandler: @escaping (SweepProgress) -> Void = { _ in },
        liveTickHandler: @escaping (SweepLiveTick) -> Void = { _ in },
        noticeHandler: @escaping (String) -> Void = { Log.warn($0) }
    ) {
        self.device = device
        self.plan = plan
        self.delegate = delegate
        self.progressHandler = progressHandler
        self.liveTickHandler = liveTickHandler
        self.noticeHandler = noticeHandler
    }

    public func run() -> SweepOutcome {
        let configurator: DeviceConfigurator
        do {
            configurator = try DeviceConfigurator(deviceID: device.audioObjectID)
        } catch {
            return SweepOutcome(results: [], wasInterrupted: false, error: error)
        }
        defer { configurator.restoreOriginalSettings() }

        var results: [BufferSizeResult] = []
        var interrupted = false
        var testedGrantedSizes = Set<UInt32>()
        do {
            if plan.exclusiveAccess {
                try configurator.acquireExclusiveAccess()
            }
            for (index, requested) in plan.bufferSizes.enumerated() {
                if CancellationController.shared.isCancelled { interrupted = true; break }

                let granted = try configurator.setBufferFrameSize(requested)
                guard testedGrantedSizes.insert(granted).inserted else {
                    noticeHandler("buffer \(requested) demandé, le driver accorde \(granted) frames — taille déjà testée, ignorée.")
                    continue
                }
                if granted != requested {
                    noticeHandler("buffer \(requested) demandé, le driver accorde \(granted) frames.")
                }
                guard let result = try measureBufferSize(index: index, requested: requested, granted: granted, configurator: configurator) else {
                    interrupted = true
                    break
                }
                results.append(result)
                if result.wasInterrupted || CancellationController.shared.isCancelled { interrupted = true; break }
            }
        } catch {
            return SweepOutcome(results: results, wasInterrupted: interrupted, error: error)
        }
        return SweepOutcome(results: results, wasInterrupted: interrupted, error: nil)
    }

    /// Returns nil when interrupted before any stability data was gathered for this size.
    private func measureBufferSize(index: Int, requested: UInt32, granted: UInt32, configurator: DeviceConfigurator) throws -> BufferSizeResult? {
        let sampleRate = try AudioObjectProperty.read(device.audioObjectID, AudioObjectProperty.address(kAudioDevicePropertyNominalSampleRate), as: Float64.self)
        let engine = try AudioIOEngine(
            deviceID: device.audioObjectID,
            bufferFrames: Int(granted),
            sampleRate: sampleRate,
            inputChannelCount: plan.inputChannels.count
        )
        engine.selectedOutputChannels = plan.outputChannels
        engine.selectedInputChannels = plan.inputChannels
        let total = plan.bufferSizes.count
        let ioLoadFraction = Double(plan.ioLoadPercent) / 100.0

        func announce(_ phase: SweepPhase, cpuLoad: Int?) {
            progressHandler(SweepProgress(
                bufferSizeIndex: index, totalBufferSizes: total, requestedFrames: requested,
                grantedFrames: granted, phase: phase, cpuLoadPercent: cpuLoad
            ))
        }
        func tick(_ phase: SweepPhase, cpuLoad: Int?, total phaseTotal: TimeInterval, incidents: Int?, elapsed: TimeInterval) {
            liveTickHandler(SweepLiveTick(
                bufferSizeIndex: index, totalBufferSizes: total, grantedFrames: granted, phase: phase,
                elapsed: elapsed, total: phaseTotal, liveIncidentCount: incidents, cpuLoadPercent: cpuLoad
            ))
        }

        // --- Ping phase ---
        announce(.ping, cpuLoad: nil)
        let pingSession = delegate.makePingSession(plan: plan, grantedBufferFrames: granted, sampleRate: sampleRate)
        let pingDuration = pingSession.estimatedDuration + 0.5
        let pingMeasurement = try runPhase(engine: engine, provider: pingSession, sink: pingSession, duration: pingDuration, sampleRate: sampleRate, ioLoadFraction: 0) { elapsed in
            tick(.ping, cpuLoad: nil, total: pingDuration, incidents: nil, elapsed: elapsed)
        }
        if pingMeasurement.wasInterrupted { return nil }
        let pingResults = pingSession.finalize()
        if index == 0 && !plan.inputChannels.isEmpty && !pingSession.receivedAnyInputSignal {
            throw SweepError.noInputSignalDetected
        }

        // --- Stability phase, idle ---
        announce(.stability, cpuLoad: nil)
        let idleSession = delegate.makeStabilitySession(plan: plan, grantedBufferFrames: granted, sampleRate: sampleRate, cpuLoadPercent: nil)
        let idleMeasurement = try runPhase(engine: engine, provider: idleSession, sink: idleSession, duration: plan.stabilityDurationSeconds, sampleRate: sampleRate, ioLoadFraction: ioLoadFraction) { elapsed in
            tick(.stability, cpuLoad: nil, total: plan.stabilityDurationSeconds, incidents: idleSession.liveIncidentCount(), elapsed: elapsed)
        }
        let stability = idleSession.finalize(idleMeasurement)
        var interrupted = idleMeasurement.wasInterrupted

        // --- Stability phase, repeated under simulated CPU (and memory) load ---
        var loadedResults: [LoadedStabilityResult] = []
        if !interrupted {
            for loadPercent in plan.cpuLoadLevelsPercent {
                if CancellationController.shared.isCancelled { interrupted = true; break }
                announce(.stability, cpuLoad: loadPercent)
                let session = delegate.makeStabilitySession(plan: plan, grantedBufferFrames: granted, sampleRate: sampleRate, cpuLoadPercent: loadPercent)
                let measurement = try withSimulatedLoad(cpuPercent: loadPercent) {
                    try runPhase(engine: engine, provider: session, sink: session, duration: plan.stabilityDurationSeconds, sampleRate: sampleRate, ioLoadFraction: ioLoadFraction) { elapsed in
                        tick(.stability, cpuLoad: loadPercent, total: plan.stabilityDurationSeconds, incidents: session.liveIncidentCount(), elapsed: elapsed)
                    }
                }
                loadedResults.append(LoadedStabilityResult(
                    cpuLoadPercent: loadPercent,
                    memoryPressureActive: plan.memoryPressureMB > 0,
                    stability: session.finalize(measurement)
                ))
                if measurement.wasInterrupted { interrupted = true; break }
            }
        }

        let inputStreamIDs = engine.inputMap.streamIDs(forDeviceChannels: plan.inputChannels)
        let outputStreamIDs = engine.outputMap.streamIDs(forDeviceChannels: plan.outputChannels)
        let halLatency = configurator.readLatencyInfo(inputStreamIDs: inputStreamIDs, outputStreamIDs: outputStreamIDs, bufferFrames: granted)

        return BufferSizeResult(
            requestedFrames: requested,
            grantedFrames: granted,
            sampleRate: sampleRate,
            halLatency: halLatency,
            pingResults: pingResults,
            stability: stability,
            loadedStability: loadedResults,
            wasInterrupted: interrupted
        )
    }

    /// Runs `body` with the simulated CPU (and, if configured, memory) load active, and always
    /// winds the load down before returning or throwing.
    private func withSimulatedLoad<T>(cpuPercent: Int, _ body: () throws -> T) rethrows -> T {
        let cpu = CPULoadGenerator(targetLoadPercent: Double(cpuPercent))
        let memory = plan.memoryPressureMB > 0 ? MemoryPressureGenerator(targetMB: plan.memoryPressureMB) : nil
        cpu.start()
        memory?.start()
        defer {
            cpu.stop()
            memory?.stop()
        }
        return try body()
    }

    private enum WaitEnd {
        case completed
        case cancelled
        case deviceLost
    }

    /// Starts the engine on the given ports, waits `duration` (or until Ctrl-C / device loss),
    /// stops it, and reports what the engine counted. The engine is always stopped on return.
    private func runPhase(
        engine: AudioIOEngine,
        provider: OutputSignalProvider,
        sink: InputCaptureSink,
        duration: TimeInterval,
        sampleRate: Double,
        ioLoadFraction: Double,
        onTick: (TimeInterval) -> Void
    ) throws -> PhaseMeasurement {
        engine.outputProvider = provider
        engine.inputSink = sink
        engine.ioLoadFraction = ioLoadFraction
        engine.resetCountersForNewPhase()
        try engine.start()
        let started = Date()
        let end = waitCooperatively(duration: duration, engine: engine, onTick: onTick)
        let elapsed = Date().timeIntervalSince(started)
        engine.stop()

        if end == .deviceLost {
            throw SweepError.deviceDisconnected
        }
        if engine.sampleRateChangeCount > 0 {
            throw SweepError.sampleRateChanged(expected: sampleRate)
        }
        return PhaseMeasurement(
            plannedDuration: duration,
            actualDuration: elapsed,
            overloadCount: engine.overloadCount,
            ioStoppedAbnormallyCount: engine.ioStoppedAbnormallyCount,
            droppedCaptureRecords: engine.droppedCaptureRecords,
            wasInterrupted: end == .cancelled
        )
    }

    private func waitCooperatively(duration: TimeInterval, engine: AudioIOEngine, onTick: (TimeInterval) -> Void) -> WaitEnd {
        let start = Date()
        let deadline = start.addingTimeInterval(duration)
        var lastTick = Date.distantPast
        let tickInterval: TimeInterval = 0.2
        while Date() < deadline {
            if CancellationController.shared.isCancelled { return .cancelled }
            if !engine.isDeviceAlive { return .deviceLost }
            let now = Date()
            if now.timeIntervalSince(lastTick) >= tickInterval {
                onTick(now.timeIntervalSince(start))
                lastTick = now
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        onTick(Date().timeIntervalSince(start))
        return .completed
    }
}
