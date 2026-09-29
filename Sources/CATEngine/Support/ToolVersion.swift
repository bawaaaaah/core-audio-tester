import Foundation

public enum ToolVersion {
    /// Version stamped into the binary by `scripts/package.sh` (an Info.plist embedded in the
    /// `__TEXT,__info_plist` section); "dev" for a plain `swift build`.
    public static var current: String {
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, !version.isEmpty {
            return version
        }
        return "dev"
    }
}
