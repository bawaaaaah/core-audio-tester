import Foundation

public struct ConfigPairSpec: Codable {
    public let output: Int
    public let input: Int
}

public struct TestConfigFile: Codable {
    public var device: String?
    public var inputChannels: String?
    public var outputChannels: String?
    public var pairs: [ConfigPairSpec]?
    public var bufferSizes: [UInt32]?
    public var pingRepetitions: Int?
    public var pingMode: String?
    public var stabilityDurationSeconds: Double?
    public var sporadicToleranceWeightedPerMinute: Double?
    public var exclusiveAccess: Bool?
    public var cpuLoadLevelsPercent: [Int]?
    public var stabilitySignal: String?
    public var memoryPressureMB: Int?

    public static func load(path: String) throws -> TestConfigFile {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(TestConfigFile.self, from: data)
    }

    public var hasChannelSelection: Bool {
        inputChannels != nil || outputChannels != nil || pairs != nil
    }
}
