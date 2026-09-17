import Foundation

/// One ping test pass for a given buffer size. Implemented by CATAnalysis (drives the MLS
/// generator + cross-correlation detector); wired into the engine as its Output/Input ports.
public protocol PingSession: OutputSignalProvider, InputCaptureSink {
    /// Wall-clock time the orchestrator should let this session run before finalizing.
    var estimatedDuration: TimeInterval { get }
    /// True once at least one non-zero sample has been captured on any selected input channel —
    /// used to detect the TCC "silent zeros" failure mode independent of the ping's own correlation.
    var receivedAnyInputSignal: Bool { get }
    func finalize() -> [PairLatencyResult]
}

/// One stability test pass for a given buffer size. Implemented by CATAnalysis (drives the
/// per-channel sine generator + streaming glitch detector).
public protocol StabilitySession: OutputSignalProvider, InputCaptureSink {
    /// Total incidents recorded so far (across all channels), safe to call from any thread
    /// while the test is still running — used to drive a live console dashboard.
    func liveIncidentCount() -> Int
    func finalize(overloadCount: Int, ioStoppedAbnormallyCount: Int, droppedRingBufferRecords: Int, actualDuration: TimeInterval) -> StabilityResult
}

public protocol SweepDelegate: AnyObject {
    func makePingSession(plan: TestPlan, grantedBufferFrames: UInt32, sampleRate: Double) -> PingSession
    func makeStabilitySession(plan: TestPlan, grantedBufferFrames: UInt32, sampleRate: Double) -> StabilitySession
}
