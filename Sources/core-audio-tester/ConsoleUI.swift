import Darwin
import Foundation

/// Minimal ANSI console helpers — no external dependency, degrades to plain text when stdout
/// isn't a TTY (piped/redirected output, CI logs) so scripted usage never sees escape codes.
enum ConsoleUI {
    static let isTTY: Bool = isatty(STDOUT_FILENO) != 0

    enum Color: String {
        case reset = "\u{1B}[0m"
        case bold = "\u{1B}[1m"
        case dim = "\u{1B}[2m"
        case red = "\u{1B}[31m"
        case green = "\u{1B}[32m"
        case yellow = "\u{1B}[33m"
        case blue = "\u{1B}[34m"
        case magenta = "\u{1B}[35m"
        case cyan = "\u{1B}[36m"
    }

    static func colored(_ text: String, _ color: Color) -> String {
        guard isTTY else { return text }
        return color.rawValue + text + Color.reset.rawValue
    }

    static func bold(_ text: String) -> String {
        guard isTTY else { return text }
        return Color.bold.rawValue + text + Color.reset.rawValue
    }

    /// Redraws a single status line in place (carriage return + pad + no newline). Falls back
    /// to doing nothing when not a TTY — the caller should print a normal line at phase end.
    static func updateLine(_ text: String) {
        guard isTTY else { return }
        let padded = text.count < 100 ? text + String(repeating: " ", count: 100 - text.count) : text
        FileHandle.standardOutput.write(Data("\r\(padded)".utf8))
    }

    static func endLine() {
        guard isTTY else { return }
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    static func prompt(_ text: String) -> String? {
        print(text, terminator: "")
        return readLine()
    }

    static func promptWithDefault(_ text: String, default defaultValue: String) -> String {
        let value = prompt("\(text) [\(defaultValue)]: ")
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return defaultValue }
        return value.trimmingCharacters(in: .whitespaces)
    }
}
