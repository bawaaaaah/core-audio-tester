import Foundation

public enum ChannelSpecError: Error, CustomStringConvertible {
    case invalidToken(String)

    public var description: String {
        switch self {
        case .invalidToken(let token):
            return "Invalid channel specification \"\(token)\" (expected forms like \"1-7\" or \"1,3,5\")"
        }
    }
}

/// Parses channel range specs like "1-7,9,12-14" into a sorted, de-duplicated list of 1-based channels.
public enum ChannelSpec {
    public static func parse(_ spec: String) throws -> [Int] {
        var result: Set<Int> = []
        for rawToken in spec.split(separator: ",") {
            let token = rawToken.trimmingCharacters(in: .whitespaces)
            guard !token.isEmpty else { continue }
            if let dash = token.firstIndex(of: "-"), dash != token.startIndex {
                let lowerStr = token[token.startIndex..<dash]
                let upperStr = token[token.index(after: dash)...]
                guard let lower = Int(lowerStr), let upper = Int(upperStr), lower <= upper else {
                    throw ChannelSpecError.invalidToken(token)
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
