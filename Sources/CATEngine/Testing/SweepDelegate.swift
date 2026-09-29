import Foundation

/// What the engine observed while one phase (a ping pass or a stability pass) was running.
public struct PhaseMeasurement: Sendable {
    public var plannedDuration: TimeInterval
    public var actualDuration: TimeInterval
    public var overloadCount: Int
    public var ioStoppedAbnormallyCount: Int
    public var droppedCaptureRecords: Int
    public var wasInterrupted: Bool

    public init(
        plannedDuration: TimeInterval,
        actualDuration: TimeInterval,
        overloadCount: Int,
        ioStoppedAbnormallyCount: Int,
        droppedCaptureRecords: Int,
        wasInterrupted: Bool
    ) {
        self.plannedDuration = plannedDuration
        self.actualDuration = actualDuration
        self.overloadCount = overloadCount
        self.ioStoppedAbnormallyCount = ioStoppedAbnormallyCount
        self.droppedCaptureRecords = droppedCaptureRecords
        self.wasInterrupted = wasInterrupted
    }
}

/// One ping test pass for a given buffer size. Implemented by CATAnalysis (MLS bursts +
/// cross-correlation); wired into the engine as its output and input ports.
public protocol PingSession: OutputSignalProvider, InputCaptureSink {
    /// Wall-clock time the orchestrator should let this session run before finalizing.
    var estimatedDuration: TimeInterval { get }
    /// True once at least one non-zero sample was captured on any selected input — detects the
    /// "silent zeros" a denied microphone permission produces, independently of the correlation.
    var receivedAnyInputSignal: Bool { get }
    /// Called after the engine stopped (all captured audio delivered).
    func finalize() -> [PairLatencyResult]
}

/// One stability test pass for a given buffer size. Implemented by CATAnalysis.
public protocol StabilitySession: OutputSignalProvider, InputCaptureSink {
    /// Audio incidents recorded so far across all channels; safe to call from any thread while
    /// the pass is running (drives the live console line).
    func liveIncidentCount() -> Int
    /// Called after the engine stopped (all captured audio delivered).
    func finalize(_ measurement: PhaseMeasurement) -> StabilityResult
}

public protocol SweepDelegate: AnyObject {
    func makePingSession(plan: TestPlan, grantedBufferFrames: UInt32, sampleRate: Double) -> PingSession
    /// `cpuLoadPercent` is nil for the idle pass.
    func makeStabilitySession(plan: TestPlan, grantedBufferFrames: UInt32, sampleRate: Double, cpuLoadPercent: Int?) -> StabilitySession
}
