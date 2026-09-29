import Foundation
import Testing
@testable import CATAnalysis
@testable import CATEngine

@Suite struct RecommendationEngineTests {
    private func stability(clicks: Int = 0, overloads: Int = 0, ioStops: Int = 0, verified: Bool = true, dropped: Int = 0) -> StabilityResult {
        StabilityResult(
            plannedDurationSeconds: 60, durationSeconds: 60, overloadCount: overloads, ioStoppedAbnormallyCount: ioStops,
            incidents: [], truncatedIncidentCount: 0,
            perChannel: [ChannelStabilitySummary(channel: 1, dropoutCount: 0, silenceCount: 0, clickCount: clicks, clipCount: 0, cleanPercentage: 100, verified: verified)],
            droppedRingBufferRecords: dropped, wasInterrupted: false
        )
    }

    private func result(_ frames: UInt32, _ stability: StabilityResult, loaded: [LoadedStabilityResult] = [], latencyMs: Double? = nil) -> BufferSizeResult {
        let latency = latencyMs ?? Double(frames) / 48.0 * 2
        return BufferSizeResult(
            requestedFrames: frames, grantedFrames: frames, sampleRate: 48000,
            halLatency: HALLatencyInfo(inputDeviceLatencyFrames: 0, outputDeviceLatencyFrames: 0, inputSafetyOffsetFrames: 0, outputSafetyOffsetFrames: 0, inputStreamLatencyFrames: 0, outputStreamLatencyFrames: 0, bufferFrames: frames),
            pingResults: [PairLatencyResult(pair: ChannelPair(outputChannel: 1, inputChannel: 1), repetitionsRequested: 10, repetitionsDetected: 10, meanMs: latency, medianMs: latency, minMs: latency, maxMs: latency, stddevMs: 0, ambiguousCount: 0, outlierCount: 0)],
            stability: stability, loadedStability: loaded
        )
    }

    @Test func picksTheSmallestCleanSize() {
        let set = RecommendationEngine.recommend(results: [result(64, stability(clicks: 40)), result(128, stability()), result(256, stability())], sporadicTolerancePerMinute: 0.2)!
        #expect(set.safest.bufferSizeResult.grantedFrames == 128)
        #expect(!set.safest.isFallback)
    }

    /// Regression: the "zero crash" pick ignored the simulated-load passes entirely.
    @Test func safestMustAlsoBeCleanUnderSimulatedLoad() {
        let failsAtLoad = [LoadedStabilityResult(cpuLoadPercent: 75, stability: stability(overloads: 3))]
        let holdsAtLoad = [LoadedStabilityResult(cpuLoadPercent: 75, stability: stability())]
        let set = RecommendationEngine.recommend(results: [result(64, stability(), loaded: failsAtLoad), result(128, stability(), loaded: holdsAtLoad)], sporadicTolerancePerMinute: 0.2)!
        #expect(set.safest.bufferSizeResult.grantedFrames == 128)
    }

    @Test func unverifiedOrIncompletePassesAreNotEvidence() {
        let set = RecommendationEngine.recommend(results: [result(64, stability(verified: false)), result(128, stability(dropped: 5)), result(256, stability())], sporadicTolerancePerMinute: 0.2)!
        #expect(set.safest.bufferSizeResult.grantedFrames == 256)
    }

    /// Regression: the trade-off tolerated any number of overloads as long as no audio incident
    /// was detected.
    @Test func overloadsCountAgainstTheTradeoff() {
        let set = RecommendationEngine.recommend(results: [result(64, stability(overloads: 10)), result(128, stability())], sporadicTolerancePerMinute: 0.2)!
        #expect(set.bestTradeoff.bufferSizeResult.grantedFrames == 128)
        #expect(set.sameAsSafest)
    }

    @Test func tradeoffWithinTolerance() {
        let set = RecommendationEngine.recommend(results: [result(64, stability(clicks: 1)), result(128, stability())], sporadicTolerancePerMinute: 2)!
        #expect(set.safest.bufferSizeResult.grantedFrames == 128)
        #expect(set.bestTradeoff.bufferSizeResult.grantedFrames == 64)
        #expect(!set.sameAsSafest)
    }

    @Test func fallsBackWhenNothingIsClean() {
        let set = RecommendationEngine.recommend(results: [result(64, stability(clicks: 50)), result(128, stability(clicks: 5))], sporadicTolerancePerMinute: 0.2)!
        #expect(set.safest.isFallback)
        #expect(set.safest.bufferSizeResult.grantedFrames == 128)
    }

    @Test func emptyResultsGiveNoRecommendation() {
        #expect(RecommendationEngine.recommend(results: [], sporadicTolerancePerMinute: 0.2) == nil)
    }

    @Test func reportsRenderWithCharsetAndSchemaVersion() throws {
        let results = [result(64, stability()), result(128, stability(clicks: 2))]
        let set = RecommendationEngine.recommend(results: results, sporadicTolerancePerMinute: 0.2)!
        let device = DeviceInfo(audioObjectID: 0, uid: "u", name: "Interface <test>", inputChannelCount: 2, outputChannelCount: 2, nominalSampleRate: 48000, bufferFrameSizeRange: 16...4096, transportType: "USB")
        let plan = LoopbackSimulator.plan(pairs: [ChannelPair(outputChannel: 1, inputChannel: 1)])
        let html = HTMLReportRenderer.render(device: device, plan: plan, results: results, recommendations: set, wasInterrupted: false, sweepError: "boom")
        #expect(html.hasPrefix("<!DOCTYPE html>"))
        #expect(html.contains("<meta charset=\"utf-8\">"))
        #expect(html.contains("Interface &lt;test&gt;"))
        #expect(html.contains("boom"))

        let path = NSTemporaryDirectory() + "cat-report-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try JSONReportExporter.export(device: device, plan: plan, results: results, recommendations: set, wasInterrupted: false, sweepError: nil, to: path)
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let decoded = try JSONDecoder().decode(ReportExport.self, from: data)
        #expect(decoded.schemaVersion == ReportExport.currentSchemaVersion)
        #expect(decoded.bufferSizeResults.count == 2)
    }
}
