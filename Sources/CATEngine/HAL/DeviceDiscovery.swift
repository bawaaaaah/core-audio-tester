import CoreAudio
import Foundation

public enum DeviceResolutionError: Error, CustomStringConvertible {
    case notFound(String)
    case ambiguous(String, [String])

    public var description: String {
        switch self {
        case .notFound(let query):
            return "Aucune interface CoreAudio ne correspond à \"\(query)\". Utilise --list-devices pour voir les interfaces disponibles."
        case .ambiguous(let query, let candidates):
            return "\"\(query)\" correspond à plusieurs interfaces : \(candidates.joined(separator: ", ")). Précise le nom ou utilise l'UID exact."
        }
    }
}

public enum DeviceDiscovery {
    public static func allDeviceIDs() throws -> [AudioObjectID] {
        try AudioObjectProperty.readArray(
            AudioObjectID(kAudioObjectSystemObject),
            AudioObjectProperty.address(kAudioHardwarePropertyDevices),
            elementType: AudioObjectID.self
        )
    }

    /// Sums mNumberChannels across all AudioBuffers in the device's StreamConfiguration for the given scope.
    private static func channelCount(_ deviceID: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var total = 0
        let addr = AudioObjectProperty.address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        try? AudioObjectProperty.readRaw(deviceID, addr) { raw, _ in
            let ablPointer = raw.assumingMemoryBound(to: AudioBufferList.self)
            let abl = UnsafeMutableAudioBufferListPointer(ablPointer)
            for buffer in abl {
                total += Int(buffer.mNumberChannels)
            }
        }
        return total
    }

    private static func bufferFrameSizeRange(_ deviceID: AudioObjectID) -> ClosedRange<UInt32> {
        let addr = AudioObjectProperty.address(kAudioDevicePropertyBufferFrameSizeRange)
        if let range = try? AudioObjectProperty.read(deviceID, addr, as: AudioValueRange.self) {
            return UInt32(range.mMinimum)...UInt32(max(range.mMinimum, range.mMaximum))
        }
        return 32...4096
    }

    public static func info(for deviceID: AudioObjectID) throws -> DeviceInfo {
        let uid = try AudioObjectProperty.readCFString(deviceID, AudioObjectProperty.address(kAudioDevicePropertyDeviceUID))
        let name = try AudioObjectProperty.readCFString(deviceID, AudioObjectProperty.address(kAudioObjectPropertyName))
        let sampleRate = try AudioObjectProperty.read(deviceID, AudioObjectProperty.address(kAudioDevicePropertyNominalSampleRate), as: Float64.self)
        let transportCode = (try? AudioObjectProperty.read(deviceID, AudioObjectProperty.address(kAudioDevicePropertyTransportType), as: UInt32.self)) ?? 0
        return DeviceInfo(
            audioObjectID: deviceID,
            uid: uid,
            name: name,
            inputChannelCount: channelCount(deviceID, scope: kAudioObjectPropertyScopeInput),
            outputChannelCount: channelCount(deviceID, scope: kAudioObjectPropertyScopeOutput),
            nominalSampleRate: sampleRate,
            bufferFrameSizeRange: bufferFrameSizeRange(deviceID),
            transportType: transportName(transportCode)
        )
    }

    public static func allDevices() throws -> [DeviceInfo] {
        try allDeviceIDs().compactMap { try? info(for: $0) }
    }

    public static func resolve(_ query: String) throws -> DeviceInfo {
        let devices = try allDevices()
        if let exactUID = devices.first(where: { $0.uid == query }) {
            return exactUID
        }
        let lowered = query.lowercased()
        // An exact (case-insensitive) name wins over substring matches, so "WING" still resolves
        // when another device is called e.g. "WING Aggregate".
        let exactNames = devices.filter { $0.name.lowercased() == lowered }
        if exactNames.count == 1 {
            return exactNames[0]
        }
        let matches = exactNames.isEmpty ? devices.filter { $0.name.lowercased().contains(lowered) } : exactNames
        if matches.count == 1 {
            return matches[0]
        } else if matches.count > 1 {
            throw DeviceResolutionError.ambiguous(query, matches.map(\.name))
        }
        throw DeviceResolutionError.notFound(query)
    }

    private static func transportName(_ code: UInt32) -> String {
        switch code {
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeBuiltIn: return "Built-in"
        case kAudioDeviceTransportTypeAggregate: return "Aggregate"
        case kAudioDeviceTransportTypeVirtual: return "Virtual"
        case kAudioDeviceTransportTypeFireWire: return "FireWire"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        default: return "Unknown"
        }
    }
}
