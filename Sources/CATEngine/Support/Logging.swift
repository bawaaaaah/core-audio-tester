import Foundation

/// Simple stdout/stderr logging. Never call this from the realtime IOProc thread.
public enum Log {
    public static func info(_ message: String) {
        print(message)
    }

    public static func warn(_ message: String) {
        FileHandle.standardError.write(Data("Attention : \(message)\n".utf8))
    }

    public static func error(_ message: String) {
        FileHandle.standardError.write(Data("Erreur : \(message)\n".utf8))
    }
}
