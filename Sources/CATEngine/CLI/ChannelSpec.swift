import Foundation

public enum ChannelSpecError: Error, CustomStringConvertible {
    case invalidToken(String)
    case rangeTooLarge(String)

    public var description: String {
        switch self {
        case .invalidToken(let token):
            return "Spécification de canaux invalide \"\(token)\" (formes attendues : \"1-7\" ou \"1,3,5\")."
        case .rangeTooLarge(let token):
            return "Plage de canaux trop grande \"\(token)\" (au plus \(ChannelSpec.maxChannelNumber) canaux)."
        }
    }
}

/// Parses channel range specs like "1-7,9,12-14" into a sorted, de-duplicated list of 1-based channels.
public enum ChannelSpec {
    /// No CoreAudio device comes close; the bound keeps a typo like "1-1000000" from allocating
    /// millions of entries before the per-device range check can reject it.
    public static let maxChannelNumber = 1024

    public static func parse(_ spec: String) throws -> [Int] {
        var result: Set<Int> = []
        for rawToken in spec.split(separator: ",") {
            let token = rawToken.trimmingCharacters(in: .whitespaces)
            guard !token.isEmpty else { continue }
            if let dash = token.firstIndex(of: "-"), dash != token.startIndex {
                let lowerStr = token[token.startIndex..<dash].trimmingCharacters(in: .whitespaces)
                let upperStr = token[token.index(after: dash)...].trimmingCharacters(in: .whitespaces)
                guard let lower = Int(lowerStr), let upper = Int(upperStr), lower <= upper else {
                    throw ChannelSpecError.invalidToken(token)
                }
                guard upper <= maxChannelNumber else {
                    throw ChannelSpecError.rangeTooLarge(token)
                }
                result.formUnion(lower...upper)
            } else if let value = Int(token) {
                result.insert(value)
            } else {
                throw ChannelSpecError.invalidToken(token)
            }
        }
        return result.sorted()
    }

    public static func format(_ channels: [Int]) -> String {
        let sorted = channels.sorted()
        guard !sorted.isEmpty else { return "" }
        var parts: [String] = []
        var rangeStart = sorted[0]
        var previous = sorted[0]
        for value in sorted.dropFirst() {
            if value == previous + 1 {
                previous = value
                continue
            }
            parts.append(rangeStart == previous ? "\(rangeStart)" : "\(rangeStart)-\(previous)")
            rangeStart = value
            previous = value
        }
        parts.append(rangeStart == previous ? "\(rangeStart)" : "\(rangeStart)-\(previous)")
        return parts.joined(separator: ",")
    }
}
