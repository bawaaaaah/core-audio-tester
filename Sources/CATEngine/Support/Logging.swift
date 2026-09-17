import Foundation

/// Simple stderr/stdout logging. Never call this from the realtime IOProc thread.
public enum Log {
    public static func info(_ message: String) {
        print(message)
    }

    public static func warn(_ message: String) {
        FileHandle.standardError.write(Data("Warning: \(message)\n".utf8))
    }

    public static func error(_ message: String) {
        FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
    }
}
