import CATEngine
import Foundation

public final class AnalysisSweepDelegate: SweepDelegate {
    private let stabilitySignal: StabilityTestSession.Signal

    /// Decodes the reference WAV file once for the whole sweep (WAV mode); throws if it can no
    /// longer be read, rather than silently falling back to another signal.
    public init(plan: TestPlan) throws {
        switch plan.stabilitySignalKind {
        case .tone:
            stabilitySignal = .sine
        case .whiteNoise:
            stabilitySignal = .noise(.white)
        case .pinkNoise:
            stabilitySignal = .noise(.pink)
        case .wavFile:
            guard let path = plan.wavFilePath else { throw TestPlanResolverError.wavFilePathMissing }
            let decoded = try WAVReader.read(url: URL(fileURLWithPath: path))
            stabilitySignal = .noise(.wavFile(WAVFileReference(decoded: decoded, outputChannelsInOrder: plan.outputChannels)))
        }
    }

    public func makePingSession(plan: TestPlan, grantedBufferFrames: UInt32, sampleRate: Double) -> PingSession {
        PingTestSession(plan: plan, grantedBufferFrames: grantedBufferFrames, sampleRate: sampleRate)
    }

    public func makeStabilitySession(plan: TestPlan, grantedBufferFrames: UInt32, sampleRate: Double, cpuLoadPercent: Int?) -> StabilitySession {
        let passLabel = "buf\(grantedBufferFrames)_" + (cpuLoadPercent.map { "cpu\($0)" } ?? "repos")
        return StabilityTestSession(plan: plan, grantedBufferFrames: grantedBufferFrames, sampleRate: sampleRate, signal: stabilitySignal, passLabel: passLabel)
    }
}
