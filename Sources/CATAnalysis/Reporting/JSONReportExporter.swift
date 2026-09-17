import CATEngine
import Foundation

public struct RecommendationExport: Codable {
    public let grantedFrames: UInt32
    public let rationale: String
    public let isFallback: Bool
}

public struct ReportExport: Codable {
    public let schemaVersion: Int
    public let toolVersion: String
    public let device: DeviceExport
    public let config: TestPlan
    public let bufferSizeResults: [BufferSizeResult]
    public let safestRecommendation: RecommendationExport
    public let bestTradeoffRecommendation: RecommendationExport
    public let sameAsSafest: Bool
    public let wasInterrupted: Bool

    public struct DeviceExport: Codable {
        public let uid: String
        public let name: String
        public let inputChannelCount: Int
        public let outputChannelCount: Int
        public let nominalSampleRate: Double
    }
}

public enum JSONReportExporter {
    public static func export(
        device: DeviceInfo,
        plan: TestPlan,
        results: [BufferSizeResult],
        recommendations: RecommendationSet,
        wasInterrupted: Bool,
        to path: String
    ) throws {
        let report = ReportExport(
            schemaVersion: 1,
            toolVersion: "0.1.0",
            device: .init(
                uid: device.uid, name: device.name,
                inputChannelCount: device.inputChannelCount, outputChannelCount: device.outputChannelCount,
                nominalSampleRate: device.nominalSampleRate
            ),
            config: plan,
            bufferSizeResults: results.sorted { $0.grantedFrames < $1.grantedFrames },
            safestRecommendation: .init(grantedFrames: recommendations.safest.bufferSizeResult.grantedFrames, rationale: recommendations.safest.rationale, isFallback: recommendations.safest.isFallback),
            bestTradeoffRecommendation: .init(grantedFrames: recommendations.bestTradeoff.bufferSizeResult.grantedFrames, rationale: recommendations.bestTradeoff.rationale, isFallback: recommendations.bestTradeoff.isFallback),
            sameAsSafest: recommendations.sameAsSafest,
            wasInterrupted: wasInterrupted
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        try data.write(to: URL(fileURLWithPath: path))
    }
}
