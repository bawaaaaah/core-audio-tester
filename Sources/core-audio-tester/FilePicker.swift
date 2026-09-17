import Foundation

/// Opens a native macOS "choose file" dialog via `osascript`/AppleScript — no AppKit dependency
/// needed for a bare command-line tool, just shelling out to the system's own file-chooser UI.
enum FilePicker {
    /// Returns the selected POSIX path, or `nil` if the user cancelled, no GUI session is
    /// available (e.g. over SSH without a window server), or `osascript` isn't present.
    static func pickFile(prompt: String) -> String? {
        let escapedPrompt = prompt.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "POSIX path of (choose file with prompt \"\(escapedPrompt)\")"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe() // swallow AppleScript's "User canceled." noise

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (path?.isEmpty == false) ? path : nil
        } catch {
            return nil
        }
    }
}
