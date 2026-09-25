import Foundation

public struct ConfigPairSpec: Codable {
    public let output: Int
    public let input: Int

    public init(output: Int, input: Int) {
        self.output = output
        self.input = input
    }
}

public enum TestConfigFileError: Error, CustomStringConvertible {
    case unreadable(path: String, reason: String)
    case notAnObject(path: String)
    case unknownKeys(path: String, keys: [String])
    case invalid(path: String, reason: String)

    public var description: String {
        switch self {
        case .unreadable(let path, let reason):
            return "Impossible de lire le fichier de configuration \"\(path)\" : \(reason)"
        case .notAnObject(let path):
            return "Le fichier de configuration \"\(path)\" doit contenir un objet JSON."
        case .unknownKeys(let path, let keys):
            let known = TestConfigFile.CodingKeys.allCases.map(\.rawValue).joined(separator: ", ")
            return "Clé(s) inconnue(s) dans \"\(path)\" : \(keys.joined(separator: ", ")). Clés acceptées : \(known)."
        case .invalid(let path, let reason):
            return "Fichier de configuration \"\(path)\" invalide : \(reason)"
        }
    }
}

/// JSON configuration file (`--config`). Every field is optional; command-line options win.
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
    public var wavFile: String?
    public var outputLevelDBFS: Double?
    public var ioLoadPercent: Int?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case device, inputChannels, outputChannels, pairs, bufferSizes, pingRepetitions, pingMode
        case stabilityDurationSeconds, sporadicToleranceWeightedPerMinute, exclusiveAccess
        case cpuLoadLevelsPercent, stabilitySignal, memoryPressureMB, wavFile, outputLevelDBFS, ioLoadPercent
    }

    public init() {}

    public static func load(path: String) throws -> TestConfigFile {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw TestConfigFileError.unreadable(path: path, reason: error.localizedDescription)
        }
        return try decode(data, path: path)
    }

    /// Rejects unknown keys: JSONDecoder would otherwise silently ignore a typo like
    /// "bufferSize", and the run would quietly use the default instead.
    public static func decode(_ data: Data, path: String) throws -> TestConfigFile {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw TestConfigFileError.invalid(path: path, reason: error.localizedDescription)
        }
        guard let dictionary = object as? [String: Any] else {
            throw TestConfigFileError.notAnObject(path: path)
        }
        let known = Set(CodingKeys.allCases.map(\.rawValue))
        let unknown = dictionary.keys.filter { !known.contains($0) }.sorted()
        guard unknown.isEmpty else {
            throw TestConfigFileError.unknownKeys(path: path, keys: unknown)
        }
        do {
            return try JSONDecoder().decode(TestConfigFile.self, from: data)
        } catch {
            throw TestConfigFileError.invalid(path: path, reason: "\(error)")
        }
    }

    public var hasChannelSelection: Bool {
        inputChannels != nil || outputChannels != nil || pairs != nil
    }
}
