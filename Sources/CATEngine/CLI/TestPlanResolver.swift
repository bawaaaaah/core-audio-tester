import Foundation

public enum TestPlanResolverError: Error, CustomStringConvertible {
    case noBufferSizesInRange(ClosedRange<UInt32>)
    case invalidDuration(String)
    case invalidPairSpec(String)
    case channelOutOfRange(Int, String, Int)
    case noChannelsSelected
    case wavFilePathMissing
    case wavFileInvalid(String)
    case wavSampleRateMismatch(path: String, fileSampleRate: Double, deviceSampleRate: Double)

    public var description: String {
        switch self {
        case .noBufferSizesInRange(let range):
            return "None of the requested buffer sizes fall within the device's supported range (\(range.lowerBound)-\(range.upperBound))."
        case .invalidDuration(let value):
            return "Invalid duration \"\(value)\" (expected forms like \"10s\", \"5m\")."
        case .invalidPairSpec(let value):
            return "Invalid --pairs specification \"\(value)\" (expected forms like \"1:1,2:2\")."
        case .channelOutOfRange(let channel, let direction, let available):
            return "\(direction) channel \(channel) is out of range (device exposes \(available))."
        case .noChannelsSelected:
            return "No channels selected for testing."
        case .wavFilePathMissing:
            return "--stability-signal wav requires --wav-file <path>."
        case .wavFileInvalid(let reason):
            return reason
        case .wavSampleRateMismatch(let path, let fileSampleRate, let deviceSampleRate):
            return "WAV file \"\(path)\" is at \(Int(fileSampleRate)) Hz but the device runs at \(Int(deviceSampleRate)) Hz — resample the file externally first (e.g. \"afconvert -r \(Int(deviceSampleRate)) '\(path)' out.wav\"); this tool won't resample internally since that would color the sample-accurate comparison it exists to perform."
        }
    }
}

public enum TestPlanResolver {
    public static let defaultBufferSizes: [UInt32] = [32, 64, 128, 256, 512, 1024, 2048]
    public static let defaultPingRepetitions = 20
    public static let defaultStabilityDuration: Double = 60.0
    public static let defaultSporadicTolerance: Double = 0.2
    public static let defaultCPULoadLevelsPercent: [Int] = [25, 50, 75, 85, 90, 95]

    /// Conservative and capped: enough to create real pressure on typical machines without
    /// risking a serious slowdown of whatever else the user has running, on lower-RAM Macs.
    public static var defaultMemoryPressureMB: Int {
        let physicalMB = Int(ProcessInfo.processInfo.physicalMemory / 1_048_576)
        return min(2048, physicalMB / 4)
    }

    public static func parseDuration(_ text: String) throws -> Double {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { throw TestPlanResolverError.invalidDuration(text) }
        if trimmed.hasSuffix("ms"), let v = Double(trimmed.dropLast(2)) { return v / 1000.0 }
        if trimmed.hasSuffix("s"), let v = Double(trimmed.dropLast(1)) { return v }
        if trimmed.hasSuffix("m"), let v = Double(trimmed.dropLast(1)) { return v * 60.0 }
        if trimmed.hasSuffix("h"), let v = Double(trimmed.dropLast(1)) { return v * 3600.0 }
        if let v = Double(trimmed) { return v }
        throw TestPlanResolverError.invalidDuration(text)
    }

    public static func parseBufferSizes(_ csv: String) -> [UInt32] {
        csv.split(separator: ",").compactMap { UInt32($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Parses a CSV of CPU load percentages, clamped to 1-100, deduplicated, sorted ascending.
    public static func parseCPULoadLevels(_ csv: String) -> [Int] {
        let values = csv.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        var seen = Set<Int>()
        return values.map { min(max($0, 1), 100) }.filter { seen.insert($0).inserted }.sorted()
    }

    public static func parsePairs(_ spec: String) throws -> [ChannelPair] {
        var pairs: [ChannelPair] = []
        for token in spec.split(separator: ",") {
            let parts = token.split(separator: ":")
            guard parts.count == 2, let out = Int(parts[0]), let inp = Int(parts[1]) else {
                throw TestPlanResolverError.invalidPairSpec(String(token))
            }
            pairs.append(ChannelPair(outputChannel: out, inputChannel: inp))
        }
        return pairs
    }

    public static func resolve(cli: RawCLIOptions, config: TestConfigFile?, device: DeviceInfo) throws -> TestPlan {
        // 1. Determine channel selection precedence: CLI > config > (none => auto)
        let explicitInputSpec = cli.inputChannels ?? config?.inputChannels
        let explicitOutputSpec = cli.outputChannels ?? config?.outputChannels
        let explicitPairsSpec = cli.pairs
        let configPairs = config?.pairs

        let hasExplicitSelection = cli.auto ? false : (
            explicitInputSpec != nil || explicitOutputSpec != nil || explicitPairsSpec != nil || configPairs != nil
        )
        let isAutoMode = cli.auto || !hasExplicitSelection

        var pairs: [ChannelPair]
        if isAutoMode {
            let count = min(device.inputChannelCount, device.outputChannelCount)
            guard count > 0 else { throw TestPlanResolverError.noChannelsSelected }
            pairs = (1...count).map { ChannelPair(outputChannel: $0, inputChannel: $0) }
        } else if let explicitPairsSpec {
            pairs = try parsePairs(explicitPairsSpec)
        } else if let configPairs {
            pairs = configPairs.map { ChannelPair(outputChannel: $0.output, inputChannel: $0.input) }
        } else {
            let outs = try (explicitOutputSpec.map(ChannelSpec.parse)) ?? []
            let ins = try (explicitInputSpec.map(ChannelSpec.parse)) ?? []
            let effectiveOuts = outs.isEmpty ? ins : outs
            let effectiveIns = ins.isEmpty ? outs : ins
            guard !effectiveOuts.isEmpty, effectiveOuts.count == effectiveIns.count else {
                throw TestPlanResolverError.noChannelsSelected
            }
            pairs = zip(effectiveOuts, effectiveIns).map { ChannelPair(outputChannel: $0.0, inputChannel: $0.1) }
        }

        for pair in pairs {
            guard pair.outputChannel >= 1, pair.outputChannel <= device.outputChannelCount else {
                throw TestPlanResolverError.channelOutOfRange(pair.outputChannel, "Output", device.outputChannelCount)
            }
            guard pair.inputChannel >= 1, pair.inputChannel <= device.inputChannelCount else {
                throw TestPlanResolverError.channelOutOfRange(pair.inputChannel, "Input", device.inputChannelCount)
            }
        }

        // 2. Buffer sizes: CLI > config > default, clamped+deduplicated to device range.
        let requestedSizes: [UInt32]
        if let cliSizes = cli.bufferSizes {
            requestedSizes = parseBufferSizes(cliSizes)
        } else if let configSizes = config?.bufferSizes {
            requestedSizes = configSizes
        } else {
            requestedSizes = defaultBufferSizes
        }
        var seen = Set<UInt32>()
        let clamped = requestedSizes.filter { device.bufferFrameSizeRange.contains($0) }.filter { seen.insert($0).inserted }.sorted()
        guard !clamped.isEmpty else { throw TestPlanResolverError.noBufferSizesInRange(device.bufferFrameSizeRange) }

        // 3. Stability test signal: sine (default, unchanged behavior), white noise, pink noise,
        // or a user-supplied WAV file — the latter three use an exact sample-accurate comparison.
        // Resolved before duration (below) since WAV mode's default duration comes from the file
        // itself, and before ping/tolerance only because there's no dependency either way.
        let stabilitySignalRaw = (cli.stabilitySignal ?? config?.stabilitySignal ?? "sine").lowercased()
        let wavSignalAliases: Set<String> = ["wav", "wav-file", "file"]
        let stabilitySignalKind: StabilitySignalKind
        var wavFilePath: String?
        var wavOwnDurationSeconds: Double?
        if cli.wavFilePath != nil || wavSignalAliases.contains(stabilitySignalRaw) {
            guard let path = cli.wavFilePath else {
                throw TestPlanResolverError.wavFilePathMissing
            }
            let decoded: WAVReader.DecodedWAV
            do {
                decoded = try WAVReader.read(url: URL(fileURLWithPath: path))
            } catch let error as WAVReader.WAVReaderError {
                throw TestPlanResolverError.wavFileInvalid(error.description)
            }
            guard decoded.sampleRate == device.nominalSampleRate else {
                throw TestPlanResolverError.wavSampleRateMismatch(path: path, fileSampleRate: decoded.sampleRate, deviceSampleRate: device.nominalSampleRate)
            }
            stabilitySignalKind = .wavFile
            wavFilePath = path
            wavOwnDurationSeconds = Double(decoded.frameCount) / decoded.sampleRate
        } else {
            switch stabilitySignalRaw {
            case "pink", "pink-noise", "pinknoise":
                stabilitySignalKind = .pinkNoise
            case "noise", "white", "white-noise", "whitenoise":
                stabilitySignalKind = .whiteNoise
            default:
                stabilitySignalKind = .tone
            }
        }

        // 4. Ping repetitions, mode, duration, tolerance.
        let pingRepetitions = cli.pingRepetitions ?? config?.pingRepetitions ?? defaultPingRepetitions
        let pingMode: PingMode = cli.pingSequential ? .sequential : (config?.pingMode.flatMap(PingMode.init(rawValue:)) ?? .parallel)
        let stabilityDuration: Double
        if let cliDuration = cli.duration {
            stabilityDuration = try parseDuration(cliDuration)
        } else if let configDuration = config?.stabilityDurationSeconds {
            stabilityDuration = configDuration
        } else if let wavOwnDurationSeconds {
            stabilityDuration = wavOwnDurationSeconds
        } else {
            stabilityDuration = defaultStabilityDuration
        }
        let sporadicTolerance = config?.sporadicToleranceWeightedPerMinute ?? defaultSporadicTolerance
        let exclusive = cli.exclusive || (config?.exclusiveAccess ?? false)
        let outputBasePath = cli.outputBasePath ?? "./core-audio-tester-report"

        // 4. Simulated CPU load levels: opt-in, off by default. An explicit CLI level list wins,
        // then a plain --cpu-load flag (or a config-file list) turns it on with the default levels.
        var cpuLoadLevelsPercent: [Int]
        if let cliLevels = cli.cpuLoadLevels {
            cpuLoadLevelsPercent = parseCPULoadLevels(cliLevels)
        } else if cli.cpuLoad {
            cpuLoadLevelsPercent = config?.cpuLoadLevelsPercent ?? defaultCPULoadLevelsPercent
        } else if let configLevels = config?.cpuLoadLevelsPercent {
            cpuLoadLevelsPercent = configLevels
        } else {
            cpuLoadLevelsPercent = []
        }

        // 5. Simulated memory pressure: layered on top of each configured CPU-load pass rather
        // than a separate axis, to avoid multiplying the number of stability passes. Enabling it
        // alone (with no CPU load levels configured) still falls back to the default CPU levels,
        // so the flag isn't a silent no-op.
        let memoryPressureMB: Int
        if let explicitMB = cli.memPressureMB {
            memoryPressureMB = max(explicitMB, 0)
        } else if cli.memPressure {
            memoryPressureMB = config?.memoryPressureMB ?? defaultMemoryPressureMB
        } else if let configMB = config?.memoryPressureMB {
            memoryPressureMB = configMB
        } else {
            memoryPressureMB = 0
        }
        if memoryPressureMB > 0 && cpuLoadLevelsPercent.isEmpty {
            cpuLoadLevelsPercent = defaultCPULoadLevelsPercent
        }

        return TestPlan(
            deviceUID: device.uid,
            deviceName: device.name,
            pairs: pairs,
            bufferSizes: clamped,
            pingRepetitions: pingRepetitions,
            pingMode: pingMode,
            stabilityDurationSeconds: stabilityDuration,
            sporadicToleranceWeightedPerMinute: sporadicTolerance,
            isAutoMode: isAutoMode,
            exclusiveAccess: exclusive,
            outputBasePath: outputBasePath,
            skipConfirmation: cli.skipConfirmation,
            cpuLoadLevelsPercent: cpuLoadLevelsPercent,
            stabilitySignalKind: stabilitySignalKind,
            memoryPressureMB: memoryPressureMB,
            incidentAudioDumpPath: cli.dumpIncidentAudioPath,
            wavFilePath: wavFilePath
        )
    }
}
