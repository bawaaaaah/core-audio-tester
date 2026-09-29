import CATEngine
import Foundation

public struct RecommendationExport: Codable {
    public let grantedFrames: UInt32
    public let rationale: String
    public let isFallback: Bool
}

public struct ReportExport: Codable {
    /// 2: stability results carry planned duration, abnormal IO stops, interruption and
    /// per-channel verification details; the always-zero overload cross-reference fields are gone.
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let toolVersion: String
    public let device: DeviceExport
    public let config: TestPlan
    public let bufferSizeResults: [BufferSizeResult]
    public let safestRecommendation: RecommendationExport
    public let bestTradeoffRecommendation: RecommendationExport
    public let sameAsSafest: Bool
    public let wasInterrupted: Bool
    /// Why the sweep stopped early, when it did (the results above are then partial).
    public let error: String?

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
        sweepError: String? = nil,
        to path: String
    ) throws {
        let report = ReportExport(
            schemaVersion: ReportExport.currentSchemaVersion,
            toolVersion: ToolVersion.current,
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
            wasInterrupted: wasInterrupted,
            error: sweepError
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        try data.write(to: URL(fileURLWithPath: path))
    }
}
