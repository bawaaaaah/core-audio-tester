import CoreAudio
import Foundation

public enum CoreAudioError: Error, CustomStringConvertible {
    case osStatus(OSStatus, String)

    public var description: String {
        switch self {
        case .osStatus(let status, let context):
            return "\(context) failed with OSStatus \(status)"
        }
    }
}

func caCheck(_ status: OSStatus, _ context: String) throws {
    guard status == noErr else {
        throw CoreAudioError.osStatus(status, context)
    }
}

/// Generic helpers around AudioObjectGetPropertyData / AudioObjectSetPropertyData.
public enum AudioObjectProperty {
    public static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    public static func exists(_ objectID: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var addr = address
        return AudioObjectHasProperty(objectID, &addr)
    }

    public static func read<T>(_ objectID: AudioObjectID, _ address: AudioObjectPropertyAddress, as type: T.Type = T.self) throws -> T {
        var addr = address
        var size: UInt32 = 0
        try caCheck(AudioObjectGetPropertyDataSize(objectID, &addr, 0, nil, &size), "GetPropertyDataSize(\(address.mSelector))")
        let value = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { value.deallocate() }
        try caCheck(AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, value), "GetPropertyData(\(address.mSelector))")
        return value.load(as: T.self)
    }

    public static func readArray<T>(_ objectID: AudioObjectID, _ address: AudioObjectPropertyAddress, elementType: T.Type = T.self) throws -> [T] {
        var addr = address
        var size: UInt32 = 0
        try caCheck(AudioObjectGetPropertyDataSize(objectID, &addr, 0, nil, &size), "GetPropertyDataSize(\(address.mSelector))")
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { raw.deallocate() }
        try caCheck(AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, raw), "GetPropertyData(\(address.mSelector))")
        let typed = raw.assumingMemoryBound(to: T.self)
        return Array(UnsafeBufferPointer(start: typed, count: count))
    }

    /// Reads a variable-size property (e.g. an AudioBufferList) into a raw buffer and hands it to `body`.
    public static func readRaw(_ objectID: AudioObjectID, _ address: AudioObjectPropertyAddress, _ body: (UnsafeMutableRawPointer, Int) throws -> Void) throws {
        var addr = address
        var size: UInt32 = 0
        try caCheck(AudioObjectGetPropertyDataSize(objectID, &addr, 0, nil, &size), "GetPropertyDataSize(\(address.mSelector))")
        guard size > 0 else { return }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 8)
        defer { raw.deallocate() }
        try caCheck(AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, raw), "GetPropertyData(\(address.mSelector))")
        try body(raw, Int(size))
    }

    public static func readCFString(_ objectID: AudioObjectID, _ address: AudioObjectPropertyAddress) throws -> String {
        var addr = address
        var size = UInt32(MemoryLayout<CFString?>.size)
        var cfStr: CFString? = nil
        let status = withUnsafeMutablePointer(to: &cfStr) { ptr -> OSStatus in
            AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, ptr)
        }
        try caCheck(status, "GetPropertyData(CFString \(address.mSelector))")
        return (cfStr as String?) ?? ""
    }

    public static func write<T>(_ objectID: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: T) throws {
        var addr = address
        var v = value
        let status = withUnsafeBytes(of: &v) { raw -> OSStatus in
            guard let base = raw.baseAddress else { return kAudioHardwareUnspecifiedError }
            return AudioObjectSetPropertyData(objectID, &addr, 0, nil, UInt32(MemoryLayout<T>.size), base)
        }
        try caCheck(status, "SetPropertyData(\(address.mSelector))")
    }
}
