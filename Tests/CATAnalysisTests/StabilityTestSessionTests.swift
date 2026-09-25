import Testing
@testable import CATAnalysis
@testable import CATEngine

@Suite struct StabilityTestSessionTests {
    let sampleRate = 48000.0
    let duration = 1.5

    private func run(
        signal: StabilityTestSession.Signal,
        kind: StabilitySignalKind,
        pairs: [ChannelPair],
        simulator: LoopbackSimulator,
        lostCaptureCycles: Set<Int> = [],
        skippedDeviceCycles: Set<Int> = []
    ) -> StabilityResult {
        let plan = LoopbackSimulator.plan(pairs: pairs, signal: kind, duration: duration)
        let session = StabilityTestSession(plan: plan, grantedBufferFrames: UInt32(simulator.bufferFrames), sampleRate: sampleRate, signal: signal, passLabel: "test")
        let cycles = Int(duration * sampleRate) / simulator.bufferFrames
        simulator.run(provider: session, sink: session, cycles: cycles, lostCaptureCycles: lostCaptureCycles, skippedDeviceCycles: skippedDeviceCycles)
        return session.finalize(LoopbackSimulator.measurement(duration: duration))
    }

    private let twoPairs = [ChannelPair(outputChannel: 1, inputChannel: 1), ChannelPair(outputChannel: 2, inputChannel: 2)]

    @Test func cleanSineLoopbackIsVerifiedAndClean() {
        let result = run(signal: .sine, kind: .tone, pairs: twoPairs, simulator: LoopbackSimulator(pairs: twoPairs))
        #expect(result.allChannelsVerified)
        #expect(result.isClean)
        #expect(result.totalIncidentCount == 0)
    }

    /// Frames lost by our own capture ring buffer are not the device's fault: no incident.
    @Test func captureRingLossIsNotReportedAsADeviceDropout() {
        let result = run(signal: .sine, kind: .tone, pairs: twoPairs, simulator: LoopbackSimulator(pairs: twoPairs), lostCaptureCycles: [150, 151])
        #expect(result.dropoutCount == 0)
        #expect(result.totalIncidentCount == 0)
        #expect(result.allChannelsVerified)
    }

    @Test func deviceGapIsReportedAsADropoutOnEveryChannel() {
        let result = run(signal: .sine, kind: .tone, pairs: twoPairs, simulator: LoopbackSimulator(pairs: twoPairs), skippedDeviceCycles: [150])
        #expect(result.perChannel.allSatisfy { $0.dropoutCount >= 1 })
        #expect(result.allChannelsVerified)
    }

    @Test func whiteNoiseLoopbackWithAttenuationIsClean() {
        var simulator = LoopbackSimulator(pairs: twoPairs)
        simulator.gain = 0.5
        let result = run(signal: .noise(.white), kind: .whiteNoise, pairs: twoPairs, simulator: simulator)
        #expect(result.allChannelsVerified)
        #expect(result.totalIncidentCount == 0)
    }

    /// Regression: the noise detector generated its reference from the *input* channel number, so
    /// a cross-patched pair (output 1 → input 2) never locked.
    @Test func crossPatchedNoisePairsLockOntoTheirOutputsSequence() {
        let crossed = [ChannelPair(outputChannel: 1, inputChannel: 2), ChannelPair(outputChannel: 2, inputChannel: 1)]
        let result = run(signal: .noise(.pink), kind: .pinkNoise, pairs: crossed, simulator: LoopbackSimulator(pairs: crossed))
        #expect(result.allChannelsVerified)
        #expect(result.totalIncidentCount == 0)
    }

    @Test func deviceGapInNoiseModeIsReported() {
        let result = run(signal: .noise(.white), kind: .whiteNoise, pairs: twoPairs, simulator: LoopbackSimulator(pairs: twoPairs), skippedDeviceCycles: [200])
        #expect(result.perChannel.allSatisfy { $0.dropoutCount >= 1 })
    }

    @Test func silentInputIsUnverifiedNotClean() {
        var simulator = LoopbackSimulator(pairs: twoPairs)
        simulator.gain = 0
        let result = run(signal: .sine, kind: .tone, pairs: twoPairs, simulator: simulator)
        #expect(!result.allChannelsVerified)
        #expect(!result.isTrustworthy)
        #expect(result.perChannel.allSatisfy { $0.unverifiedReason != nil })
    }
}
