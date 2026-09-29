import Foundation

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

    /// Whether the stability comparison is sample-exact, which needs a bit-transparent loopback.
    public var requiresTransparentLoopback: Bool { self != .tone }
}

public struct TestPlan: Sendable, Codable {
    public static let defaultOutputLevelDBFS: Double = -12

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
    /// Diagnostic-only: when set, the audio around each stability incident is written as a WAV
    /// file in this directory (`--dump-incident-audio <dir>`).
    public var incidentAudioDumpPath: String?
    /// The reference file when `stabilitySignalKind == .wavFile`.
    public var wavFilePath: String?
    /// Peak level of every test signal (ping bursts, sine, noise, WAV), in dBFS.
    public var outputLevelDBFS: Double
    /// Share of each IO cycle spent busy-waiting in the IOProc during stability passes, in percent
    /// — emulates the DSP load of a real audio application's callback.
    public var ioLoadPercent: Int

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
        wavFilePath: String? = nil,
        outputLevelDBFS: Double = TestPlan.defaultOutputLevelDBFS,
        ioLoadPercent: Int = 0
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
        self.outputLevelDBFS = outputLevelDBFS
        self.ioLoadPercent = ioLoadPercent
    }

    public var inputChannels: [Int] { Array(Set(pairs.map(\.inputChannel))).sorted() }
    public var outputChannels: [Int] { Array(Set(pairs.map(\.outputChannel))).sorted() }

    /// Linear peak amplitude matching `outputLevelDBFS`.
    public var outputPeakAmplitude: Float { Float(pow(10.0, outputLevelDBFS / 20.0)) }
}
