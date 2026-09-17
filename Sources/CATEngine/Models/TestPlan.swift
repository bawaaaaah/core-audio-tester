public struct ChannelPair: Sendable, Hashable, Codable {
    /// 1-based device channel numbers.
    public let outputChannel: Int
    public let inputChannel: Int

    public init(outputChannel: Int, inputChannel: Int) {
        self.outputChannel = outputChannel
        self.inputChannel = inputChannel
    }
}

public enum PingMode: String, Sendable, Codable {
    case parallel
    case sequential
}

public enum StabilitySignalKind: String, Sendable, Codable {
    case tone
    case whiteNoise
    case pinkNoise
    case wavFile
}

public struct TestPlan: Sendable, Codable {
    public var deviceUID: String
    public var deviceName: String
    public var pairs: [ChannelPair]
    public var bufferSizes: [UInt32]
    public var pingRepetitions: Int
    public var pingMode: PingMode
    public var stabilityDurationSeconds: Double
    public var sporadicToleranceWeightedPerMinute: Double
    public var isAutoMode: Bool
    public var exclusiveAccess: Bool
    public var outputBasePath: String
    public var skipConfirmation: Bool
    public var cpuLoadLevelsPercent: [Int]
    public var stabilitySignalKind: StabilitySignalKind
    public var memoryPressureMB: Int
    /// Diagnostic-only: when set, dumps the captured audio around each stability incident to a
    /// WAV file in this directory. Off by default; enabled via `--dump-incident-audio <dir>`.
    public var incidentAudioDumpPath: String?
    /// The reference file when `stabilitySignalKind == .wavFile`; set via `--wav-file <path>`.
    public var wavFilePath: String?

    public init(
        deviceUID: String,
        deviceName: String,
        pairs: [ChannelPair],
        bufferSizes: [UInt32],
        pingRepetitions: Int,
        pingMode: PingMode,
        stabilityDurationSeconds: Double,
        sporadicToleranceWeightedPerMinute: Double,
        isAutoMode: Bool,
        exclusiveAccess: Bool,
        outputBasePath: String,
        skipConfirmation: Bool,
        cpuLoadLevelsPercent: [Int] = [],
        stabilitySignalKind: StabilitySignalKind = .tone,
        memoryPressureMB: Int = 0,
        incidentAudioDumpPath: String? = nil,
        wavFilePath: String? = nil
    ) {
        self.deviceUID = deviceUID
        self.deviceName = deviceName
        self.pairs = pairs
        self.bufferSizes = bufferSizes
        self.pingRepetitions = pingRepetitions
        self.pingMode = pingMode
        self.stabilityDurationSeconds = stabilityDurationSeconds
        self.sporadicToleranceWeightedPerMinute = sporadicToleranceWeightedPerMinute
        self.isAutoMode = isAutoMode
        self.exclusiveAccess = exclusiveAccess
        self.outputBasePath = outputBasePath
        self.skipConfirmation = skipConfirmation
        self.cpuLoadLevelsPercent = cpuLoadLevelsPercent
        self.stabilitySignalKind = stabilitySignalKind
        self.memoryPressureMB = memoryPressureMB
        self.incidentAudioDumpPath = incidentAudioDumpPath
        self.wavFilePath = wavFilePath
    }

    public var inputChannels: [Int] { Array(Set(pairs.map(\.inputChannel))).sorted() }
    public var outputChannels: [Int] { Array(Set(pairs.map(\.outputChannel))).sorted() }
}
