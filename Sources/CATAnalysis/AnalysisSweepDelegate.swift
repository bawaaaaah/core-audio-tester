import CATEngine

public final class AnalysisSweepDelegate: SweepDelegate {
    public init() {}

    public func makePingSession(plan: TestPlan, grantedBufferFrames: UInt32, sampleRate: Double) -> PingSession {
        PingTestSession(plan: plan, grantedBufferFrames: grantedBufferFrames, sampleRate: sampleRate)
    }

    public func makeStabilitySession(plan: TestPlan, grantedBufferFrames: UInt32, sampleRate: Double) -> StabilitySession {
        switch plan.stabilitySignalKind {
        case .tone:
            return StabilityTestSession(plan: plan, grantedBufferFrames: grantedBufferFrames, sampleRate: sampleRate)
        case .whiteNoise, .pinkNoise, .wavFile:
            return NoiseStabilityTestSession(plan: plan, grantedBufferFrames: grantedBufferFrames, sampleRate: sampleRate)
        }
    }
}
