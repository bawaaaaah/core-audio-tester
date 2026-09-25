import Testing
@testable import CATEngine

@Suite struct ResultModelTests {
    private func stability(
        overloads: Int = 0,
        ioStops: Int = 0,
        channels: [ChannelStabilitySummary] = [ChannelStabilitySummary(channel: 1, dropoutCount: 0, silenceCount: 0, clickCount: 0, clipCount: 0, cleanPercentage: 100)],
        dropped: Int = 0,
        duration: Double = 60,
        interrupted: Bool = false
    ) -> StabilityResult {
        StabilityResult(
            plannedDurationSeconds: 60, durationSeconds: duration, overloadCount: overloads,
            ioStoppedAbnormallyCount: ioStops, incidents: [], truncatedIncidentCount: 0, perChannel: channels,
            droppedRingBufferRecords: dropped, wasInterrupted: interrupted
        )
    }

    private func latency(detected: Int, mean: Double, ambiguous: Int = 0) -> PairLatencyResult {
        PairLatencyResult(
            pair: ChannelPair(outputChannel: 1, inputChannel: 1), repetitionsRequested: 10, repetitionsDetected: detected,
            meanMs: mean, medianMs: mean, minMs: mean, maxMs: mean, stddevMs: 0, ambiguousCount: ambiguous, outlierCount: 0
        )
    }

    private func result(_ stability: StabilityResult, pings: [PairLatencyResult] = [], loaded: [LoadedStabilityResult] = []) -> BufferSizeResult {
        BufferSizeResult(
            requestedFrames: 64, grantedFrames: 64, sampleRate: 48000,
            halLatency: HALLatencyInfo(inputDeviceLatencyFrames: 0, outputDeviceLatencyFrames: 0, inputSafetyOffsetFrames: 0, outputSafetyOffsetFrames: 0, inputStreamLatencyFrames: 0, outputStreamLatencyFrames: 0, bufferFrames: 64),
            pingResults: pings, stability: stability, loadedStability: loaded
        )
    }

    @Test func cleanAndTrustworthyPass() {
        let s = stability()
        #expect(s.isClean && s.isTrustworthy && s.isFullyClean)
    }

    /// Regression: abnormal IO stops were counted by the engine and then thrown away.
    @Test func abnormalIOStopMakesAPassUnclean() {
        #expect(!stability(ioStops: 1).isClean)
    }

    @Test func unanalyzedAudioInterruptionAndUnverifiedChannelsAreNotTrustworthy() {
        #expect(!stability(dropped: 3).isTrustworthy)
        #expect(!stability(duration: 2, interrupted: true).isTrustworthy)
        #expect(!stability(duration: 30).isTrustworthy)
        let unverified = ChannelStabilitySummary(channel: 2, dropoutCount: 0, silenceCount: 0, clickCount: 0, clipCount: 0, cleanPercentage: 100, verified: false, unverifiedReason: "x")
        #expect(!stability(channels: [unverified]).isTrustworthy)
    }

    @Test func weightedRateCountsOverloadsAndIOStops() {
        let s = stability(overloads: 1, ioStops: 1, channels: [ChannelStabilitySummary(channel: 1, dropoutCount: 1, silenceCount: 1, clickCount: 1, clipCount: 50, cleanPercentage: 99)])
        #expect(s.totalIncidentCount == 3)
        #expect(abs(s.weightedIncidentRatePerMinute() - 12.0) < 1e-9)
    }

    /// Regression: a pair with no detection counted as 0 ms and dragged the mean latency down.
    @Test func latencyAveragesIgnoreUnmeasuredPairs() {
        let r = result(stability(), pings: [latency(detected: 10, mean: 6), latency(detected: 0, mean: 0)])
        #expect(r.meanLatencyMs == 6)
        #expect(r.bestLatencyMs == 6)
        #expect(r.hasUnreliablePings)
        #expect(!latency(detected: 10, mean: 6).isUnreliable)
        #expect(latency(detected: 10, mean: 6, ambiguous: 6).isUnreliable)
    }

    @Test func loadedPassesDecideCleanUnderLoad() {
        let loaded = [
            LoadedStabilityResult(cpuLoadPercent: 50, stability: stability()),
            LoadedStabilityResult(cpuLoadPercent: 90, stability: stability(overloads: 2)),
        ]
        let r = result(stability(), loaded: loaded)
        #expect(r.isFullyClean)
        #expect(!r.isCleanUnderLoad)
        #expect(r.highestCleanCPULoadPercent == 50)
    }
}
