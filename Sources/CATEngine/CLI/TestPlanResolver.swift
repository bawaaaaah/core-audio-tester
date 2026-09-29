import Foundation

public enum TestPlanResolverError: Error, CustomStringConvertible {
    case noBufferSizesInRange(ClosedRange<UInt32>)
    case invalidBufferSizes(String)
    case invalidDuration(String)
    case durationNotPositive(Double)
    case invalidPairSpec(String)
    case channelOutOfRange(Int, String, Int)
    case noChannelsSelected
    case channelCountMismatch(outputs: Int, inputs: Int)
    case duplicateInputChannel(Int)
    case wavFilePathMissing
    case wavFileInvalid(String)
    case wavSampleRateMismatch(path: String, fileSampleRate: Double, deviceSampleRate: Double)
    case unknownStabilitySignal(String)
    case unknownPingMode(String)
    case invalidPingRepetitions(Int)
    case invalidCPULoadLevels(String)
    case invalidMemoryPressure(Int)
    case invalidOutputLevel(Double)
    case invalidIOLoad(Int)
    case invalidSporadicTolerance(Double)

    public var description: String {
        switch self {
        case .noBufferSizesInRange(let range):
            return "Aucune des tailles de buffer demandées n'est dans la plage de l'interface (\(range.lowerBound)-\(range.upperBound))."
        case .invalidBufferSizes(let value):
            return "Liste de tailles de buffer invalide \"\(value)\" (forme attendue : \"64,128,256\")."
        case .invalidDuration(let value):
            return "Durée invalide \"\(value)\" (formes attendues : \"10s\", \"5m\", \"1h\")."
        case .durationNotPositive(let value):
            return "La durée du test de stabilité doit être strictement positive (reçu : \(value) s)."
        case .invalidPairSpec(let value):
            return "Spécification --pairs invalide \"\(value)\" (forme attendue : \"1:1,2:2\")."
        case .channelOutOfRange(let channel, let direction, let available):
            return "\(direction) \(channel) hors limites (l'interface en expose \(available))."
        case .noChannelsSelected:
            return "Aucun canal sélectionné pour le test."
        case .channelCountMismatch(let outputs, let inputs):
            return "\(outputs) sortie(s) pour \(inputs) entrée(s) : --in et --out doivent désigner autant de canaux (ils sont appariés dans l'ordre). Pour un appariement libre, utilise --pairs."
        case .duplicateInputChannel(let channel):
            return "L'entrée \(channel) apparaît dans plusieurs paires : chaque entrée ne peut recevoir qu'une sortie testée."
        case .wavFilePathMissing:
            return "--stability-signal wav nécessite --wav-file <chemin> (ou \"wavFile\" dans le fichier de configuration)."
        case .wavFileInvalid(let reason):
            return reason
        case .wavSampleRateMismatch(let path, let fileSampleRate, let deviceSampleRate):
            return "Le fichier WAV \"\(path)\" est à \(Int(fileSampleRate)) Hz mais l'interface tourne à \(Int(deviceSampleRate)) Hz — rééchantillonne-le d'abord (ex. \"afconvert -r \(Int(deviceSampleRate)) '\(path)' sortie.wav\") : l'outil ne rééchantillonne pas lui-même, cela fausserait la comparaison échantillon par échantillon."
        case .unknownStabilitySignal(let value):
            return "Signal de stabilité inconnu \"\(value)\" (valeurs possibles : sine, noise, pink, wav)."
        case .unknownPingMode(let value):
            return "Mode de ping inconnu \"\(value)\" (valeurs possibles : parallel, sequential)."
        case .invalidPingRepetitions(let value):
            return "Nombre de répétitions du ping invalide (\(value)) : il faut entre 1 et 1000."
        case .invalidCPULoadLevels(let value):
            return "Paliers de charge CPU invalides \"\(value)\" : il faut des entiers entre 1 et 100, ex. \"25,50,75\"."
        case .invalidMemoryPressure(let value):
            return "Pression mémoire invalide (\(value) Mo) : la valeur doit être positive ou nulle."
        case .invalidOutputLevel(let value):
            return "Niveau de sortie invalide (\(value) dBFS) : il faut entre \(Int(TestPlanResolver.outputLevelRange.lowerBound)) et \(Int(TestPlanResolver.outputLevelRange.upperBound)) dBFS."
        case .invalidIOLoad(let value):
            return "Charge du callback invalide (\(value) %) : il faut entre 0 et \(TestPlanResolver.maxIOLoadPercent) %."
        case .invalidSporadicTolerance(let value):
            return "Tolérance sporadique invalide (\(value)) : la valeur doit être positive ou nulle."
        }
    }
}

public enum TestPlanResolver {
    public static let defaultBufferSizes: [UInt32] = [32, 64, 128, 256, 512, 1024, 2048]
    public static let defaultPingRepetitions = 20
    public static let defaultStabilityDuration: Double = 60.0
    public static let defaultSporadicTolerance: Double = 0.2
    public static let defaultCPULoadLevelsPercent: [Int] = [25, 50, 75, 85, 90, 95]
    public static let outputLevelRange: ClosedRange<Double> = -60 ... -3
    public static let maxIOLoadPercent = 90
    public static let wavSignalAliases: Set<String> = ["wav", "wav-file", "file"]

    /// Conservative and capped: enough to create real pressure on typical machines without
    /// risking a serious slowdown of whatever else the user has running on lower-RAM Macs.
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

    public static func parseBufferSizes(_ csv: String) throws -> [UInt32] {
        var sizes: [UInt32] = []
        for token in csv.split(separator: ",") {
            let trimmed = token.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let size = UInt32(trimmed), size > 0 else {
                throw TestPlanResolverError.invalidBufferSizes(csv)
            }
            sizes.append(size)
        }
        guard !sizes.isEmpty else { throw TestPlanResolverError.invalidBufferSizes(csv) }
        return sizes
    }

    /// Parses a CSV of CPU load percentages (1-100), deduplicated and sorted ascending.
    public static func parseCPULoadLevels(_ csv: String) throws -> [Int] {
        var levels: [Int] = []
        for token in csv.split(separator: ",") {
            let trimmed = token.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let level = Int(trimmed) else { throw TestPlanResolverError.invalidCPULoadLevels(csv) }
            levels.append(level)
        }
        guard !levels.isEmpty else { throw TestPlanResolverError.invalidCPULoadLevels(csv) }
        return try validateCPULoadLevels(levels, source: csv)
    }

    static func validateCPULoadLevels(_ levels: [Int], source: String) throws -> [Int] {
        guard levels.allSatisfy({ (1...100).contains($0) }) else {
            throw TestPlanResolverError.invalidCPULoadLevels(source)
        }
        return Array(Set(levels)).sorted()
    }

    public static func parsePairs(_ spec: String) throws -> [ChannelPair] {
        var pairs: [ChannelPair] = []
        for token in spec.split(separator: ",") {
            let parts = token.split(separator: ":")
            guard parts.count == 2,
                  let out = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                  let inp = Int(parts[1].trimmingCharacters(in: .whitespaces))
            else {
                throw TestPlanResolverError.invalidPairSpec(String(token))
            }
            pairs.append(ChannelPair(outputChannel: out, inputChannel: inp))
        }
        guard !pairs.isEmpty else { throw TestPlanResolverError.invalidPairSpec(spec) }
        return pairs
    }

    public static func parseStabilitySignal(_ raw: String) throws -> StabilitySignalKind {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "sine", "sinus", "tone":
            return .tone
        case "noise", "white", "white-noise", "whitenoise":
            return .whiteNoise
        case "pink", "pink-noise", "pinknoise":
            return .pinkNoise
        case let value where wavSignalAliases.contains(value):
            return .wavFile
        default:
            throw TestPlanResolverError.unknownStabilitySignal(raw)
        }
    }

    public static func parsePingMode(_ raw: String) throws -> PingMode {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "parallel", "parallele", "parallèle": return .parallel
        case "sequential", "sequentiel", "séquentiel": return .sequential
        default: throw TestPlanResolverError.unknownPingMode(raw)
        }
    }

    /// Channel selection precedence, highest first: `--auto`, `--pairs`, `--in`/`--out` (a side not
    /// given on the command line may come from the config file), config `pairs`, config
    /// `inputChannels`/`outputChannels`, and finally the full-device auto mode.
    static func resolvePairs(cli: RawCLIOptions, config: TestConfigFile?, device: DeviceInfo) throws -> (pairs: [ChannelPair], isAuto: Bool) {
        if cli.auto {
            return (try autoPairs(device: device), true)
        }
        if let spec = cli.pairs {
            return (try parsePairs(spec), false)
        }
        if cli.inputChannels != nil || cli.outputChannels != nil {
            return (try pairsFromSpecs(output: cli.outputChannels ?? config?.outputChannels, input: cli.inputChannels ?? config?.inputChannels), false)
        }
        if let configPairs = config?.pairs {
            let pairs = configPairs.map { ChannelPair(outputChannel: $0.output, inputChannel: $0.input) }
            guard !pairs.isEmpty else { throw TestPlanResolverError.noChannelsSelected }
            return (pairs, false)
        }
        if config?.inputChannels != nil || config?.outputChannels != nil {
            return (try pairsFromSpecs(output: config?.outputChannels, input: config?.inputChannels), false)
        }
        return (try autoPairs(device: device), true)
    }

    private static func autoPairs(device: DeviceInfo) throws -> [ChannelPair] {
        let count = min(device.inputChannelCount, device.outputChannelCount)
        guard count > 0 else { throw TestPlanResolverError.noChannelsSelected }
        return (1...count).map { ChannelPair(outputChannel: $0, inputChannel: $0) }
    }

    private static func pairsFromSpecs(output: String?, input: String?) throws -> [ChannelPair] {
        let outs = try output.map(ChannelSpec.parse) ?? []
        let ins = try input.map(ChannelSpec.parse) ?? []
        let effectiveOuts = outs.isEmpty ? ins : outs
        let effectiveIns = ins.isEmpty ? outs : ins
        guard !effectiveOuts.isEmpty else { throw TestPlanResolverError.noChannelsSelected }
        guard effectiveOuts.count == effectiveIns.count else {
            throw TestPlanResolverError.channelCountMismatch(outputs: effectiveOuts.count, inputs: effectiveIns.count)
        }
        return zip(effectiveOuts, effectiveIns).map { ChannelPair(outputChannel: $0.0, inputChannel: $0.1) }
    }

    /// `warn` receives non-fatal notices (e.g. requested buffer sizes outside the device's range).
    public static func resolve(
        cli: RawCLIOptions,
        config: TestConfigFile?,
        device: DeviceInfo,
        warn: (String) -> Void = { Log.warn($0) }
    ) throws -> TestPlan {
        // 1. Channels.
        let (pairs, isAutoMode) = try resolvePairs(cli: cli, config: config, device: device)
        var seenInputs = Set<Int>()
        for pair in pairs {
            guard pair.outputChannel >= 1, pair.outputChannel <= device.outputChannelCount else {
                throw TestPlanResolverError.channelOutOfRange(pair.outputChannel, "Sortie", device.outputChannelCount)
            }
            guard pair.inputChannel >= 1, pair.inputChannel <= device.inputChannelCount else {
                throw TestPlanResolverError.channelOutOfRange(pair.inputChannel, "Entrée", device.inputChannelCount)
            }
            guard seenInputs.insert(pair.inputChannel).inserted else {
                throw TestPlanResolverError.duplicateInputChannel(pair.inputChannel)
            }
        }

        // 2. Buffer sizes: CLI > config > default, restricted to the device's range.
        let requestedSizes: [UInt32]
        if let cliSizes = cli.bufferSizes {
            requestedSizes = try parseBufferSizes(cliSizes)
        } else if let configSizes = config?.bufferSizes {
            guard !configSizes.isEmpty, configSizes.allSatisfy({ $0 > 0 }) else {
                throw TestPlanResolverError.invalidBufferSizes(configSizes.map(String.init).joined(separator: ","))
            }
            requestedSizes = configSizes
        } else {
            requestedSizes = defaultBufferSizes
        }
        let range = device.bufferFrameSizeRange
        let outOfRange = requestedSizes.filter { !range.contains($0) }
        let inRange = Array(Set(requestedSizes.filter { range.contains($0) })).sorted()
        guard !inRange.isEmpty else { throw TestPlanResolverError.noBufferSizesInRange(range) }
        if !outOfRange.isEmpty {
            warn("taille(s) de buffer hors de la plage de l'interface (\(range.lowerBound)-\(range.upperBound)) ignorée(s) : \(outOfRange.map(String.init).joined(separator: ", ")).")
        }

        // 3. Stability signal. Resolved before the duration, since WAV mode's default duration is
        // the file's own length.
        let signalSource = cli.stabilitySignal
            ?? (cli.wavFilePath != nil ? "wav" : nil)
            ?? config?.stabilitySignal
            ?? (config?.wavFile != nil ? "wav" : nil)
            ?? "sine"
        let stabilitySignalKind = try parseStabilitySignal(signalSource)
        var wavFilePath: String?
        var wavOwnDurationSeconds: Double?
        if stabilitySignalKind == .wavFile {
            guard let path = cli.wavFilePath ?? config?.wavFile else {
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
            wavFilePath = path
            wavOwnDurationSeconds = Double(decoded.frameCount) / decoded.sampleRate
        }

        // 4. Ping, duration, tolerance, output.
        let pingRepetitions = cli.pingRepetitions ?? config?.pingRepetitions ?? defaultPingRepetitions
        guard (1...1000).contains(pingRepetitions) else {
            throw TestPlanResolverError.invalidPingRepetitions(pingRepetitions)
        }
        let pingMode: PingMode
        if cli.pingSequential {
            pingMode = .sequential
        } else if let configMode = config?.pingMode {
            pingMode = try parsePingMode(configMode)
        } else {
            pingMode = .parallel
        }

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
        guard stabilityDuration > 0, stabilityDuration.isFinite else {
            throw TestPlanResolverError.durationNotPositive(stabilityDuration)
        }

        let sporadicTolerance = config?.sporadicToleranceWeightedPerMinute ?? defaultSporadicTolerance
        guard sporadicTolerance >= 0 else { throw TestPlanResolverError.invalidSporadicTolerance(sporadicTolerance) }
        let exclusive = cli.exclusive || (config?.exclusiveAccess ?? false)
        let outputBasePath = cli.outputBasePath ?? "./core-audio-tester-report"

        let outputLevel = cli.outputLevelDBFS ?? config?.outputLevelDBFS ?? TestPlan.defaultOutputLevelDBFS
        guard outputLevelRange.contains(outputLevel) else { throw TestPlanResolverError.invalidOutputLevel(outputLevel) }
        let ioLoad = cli.ioLoadPercent ?? config?.ioLoadPercent ?? 0
        guard (0...maxIOLoadPercent).contains(ioLoad) else { throw TestPlanResolverError.invalidIOLoad(ioLoad) }

        // 5. Simulated CPU load levels: opt-in. An explicit CLI list wins, then a plain --cpu-load
        // (config list or defaults), then a config list on its own.
        var cpuLoadLevelsPercent: [Int]
        if let cliLevels = cli.cpuLoadLevels {
            cpuLoadLevelsPercent = try parseCPULoadLevels(cliLevels)
        } else if let configLevels = config?.cpuLoadLevelsPercent {
            cpuLoadLevelsPercent = try validateCPULoadLevels(configLevels, source: configLevels.map(String.init).joined(separator: ","))
        } else if cli.cpuLoad {
            cpuLoadLevelsPercent = defaultCPULoadLevelsPercent
        } else {
            cpuLoadLevelsPercent = []
        }

        // 6. Simulated memory pressure, layered on top of each CPU-load pass rather than a separate
        // axis. Enabling it alone falls back to the default CPU levels so it isn't a silent no-op.
        let memoryPressureMB: Int
        if let explicitMB = cli.memPressureMB {
            memoryPressureMB = explicitMB
        } else if let configMB = config?.memoryPressureMB {
            memoryPressureMB = configMB
        } else if cli.memPressure {
            memoryPressureMB = defaultMemoryPressureMB
        } else {
            memoryPressureMB = 0
        }
        guard memoryPressureMB >= 0 else { throw TestPlanResolverError.invalidMemoryPressure(memoryPressureMB) }
        if memoryPressureMB > 0 && cpuLoadLevelsPercent.isEmpty {
            cpuLoadLevelsPercent = defaultCPULoadLevelsPercent
        }

        return TestPlan(
            deviceUID: device.uid,
            deviceName: device.name,
            pairs: pairs,
            bufferSizes: inRange,
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
            wavFilePath: wavFilePath,
            outputLevelDBFS: outputLevel,
            ioLoadPercent: ioLoad
        )
    }
}
