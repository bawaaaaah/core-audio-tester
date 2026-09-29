import CoreAudio
import Foundation

public enum DeviceConfigurationError: Error, CustomStringConvertible {
    case exclusiveAccessUnsupported
    case exclusiveAccessHeldByOtherProcess(pid_t)
    case exclusiveAccessRefused

    public var description: String {
        switch self {
        case .exclusiveAccessUnsupported:
            return "Cette interface ne prend pas en charge l'accès exclusif (hog mode)."
        case .exclusiveAccessHeldByOtherProcess(let pid):
            return "L'interface est déjà en accès exclusif pour un autre processus (pid \(pid)). Ferme l'application qui la monopolise, ou relance sans --exclusive."
        case .exclusiveAccessRefused:
            return "Le driver a refusé l'accès exclusif (hog mode) à l'interface."
        }
    }
}

/// Reads/writes the device's buffer size (with verification), takes and releases hog mode, and
/// captures/restores the original configuration so a run leaves the device as it found it.
///
/// `kAudioDevicePropertyBufferFrameSize` is a per-process setting: other applications using the
/// same device keep their own buffer size, and the device runs at the smallest one requested.
/// Exclusive access (`acquireExclusiveAccess`) is the only way to rule that interference out.
public final class DeviceConfigurator {
    public let deviceID: AudioObjectID
    public let originalBufferFrameSize: UInt32
    public let originalSampleRate: Float64
    public private(set) var ownsExclusiveAccess = false

    public init(deviceID: AudioObjectID) throws {
        self.deviceID = deviceID
        self.originalBufferFrameSize = try AudioObjectProperty.read(
            deviceID, AudioObjectProperty.address(kAudioDevicePropertyBufferFrameSize), as: UInt32.self
        )
        self.originalSampleRate = try AudioObjectProperty.read(
            deviceID, AudioObjectProperty.address(kAudioDevicePropertyNominalSampleRate), as: Float64.self
        )
    }

    /// Sets the requested buffer size and returns the size actually granted by the driver
    /// (USB devices frequently clamp/quantize the requested value).
    @discardableResult
    public func setBufferFrameSize(_ requested: UInt32) throws -> UInt32 {
        try AudioObjectProperty.write(deviceID, AudioObjectProperty.address(kAudioDevicePropertyBufferFrameSize), requested)
        return try AudioObjectProperty.read(deviceID, AudioObjectProperty.address(kAudioDevicePropertyBufferFrameSize), as: UInt32.self)
    }

    /// Takes hog mode for this process. Writing `kAudioDevicePropertyHogMode` toggles ownership
    /// (the written value is ignored), so the current owner is checked first and the result
    /// verified afterwards.
    public func acquireExclusiveAccess() throws {
        let address = AudioObjectProperty.address(kAudioDevicePropertyHogMode)
        guard AudioObjectProperty.exists(deviceID, address) else {
            throw DeviceConfigurationError.exclusiveAccessUnsupported
        }
        let me = getpid()
        let owner = try AudioObjectProperty.read(deviceID, address, as: pid_t.self)
        if owner == me {
            ownsExclusiveAccess = true
            return
        }
        guard owner == -1 else {
            throw DeviceConfigurationError.exclusiveAccessHeldByOtherProcess(owner)
        }
        try AudioObjectProperty.write(deviceID, address, me)
        guard (try AudioObjectProperty.read(deviceID, address, as: pid_t.self)) == me else {
            throw DeviceConfigurationError.exclusiveAccessRefused
        }
        ownsExclusiveAccess = true
    }

    public func releaseExclusiveAccess() {
        guard ownsExclusiveAccess else { return }
        let address = AudioObjectProperty.address(kAudioDevicePropertyHogMode)
        let me = getpid()
        if (try? AudioObjectProperty.read(deviceID, address, as: pid_t.self)) == me {
            try? AudioObjectProperty.write(deviceID, address, me)
        }
        ownsExclusiveAccess = false
    }

    public func restoreOriginalSettings() {
        try? AudioObjectProperty.write(deviceID, AudioObjectProperty.address(kAudioDevicePropertyBufferFrameSize), originalBufferFrameSize)
        let currentRate = try? AudioObjectProperty.read(deviceID, AudioObjectProperty.address(kAudioDevicePropertyNominalSampleRate), as: Float64.self)
        if let currentRate, currentRate != originalSampleRate {
            try? AudioObjectProperty.write(deviceID, AudioObjectProperty.address(kAudioDevicePropertyNominalSampleRate), originalSampleRate)
        }
        releaseExclusiveAccess()
    }

    /// Stream latency is per stream: the selected channels are bounded by the slowest of the
    /// streams they live on, so the maximum is reported rather than the sum.
    public func readLatencyInfo(inputStreamIDs: [AudioStreamID], outputStreamIDs: [AudioStreamID], bufferFrames: UInt32) -> HALLatencyInfo {
        func deviceLatency(scope: AudioObjectPropertyScope) -> UInt32 {
            (try? AudioObjectProperty.read(deviceID, AudioObjectProperty.address(kAudioDevicePropertyLatency, scope: scope), as: UInt32.self)) ?? 0
        }
        func safetyOffset(scope: AudioObjectPropertyScope) -> UInt32 {
            (try? AudioObjectProperty.read(deviceID, AudioObjectProperty.address(kAudioDevicePropertySafetyOffset, scope: scope), as: UInt32.self)) ?? 0
        }
        func streamLatency(_ streamIDs: [AudioStreamID]) -> UInt32 {
            streamIDs.map { streamID in
                (try? AudioObjectProperty.read(streamID, AudioObjectProperty.address(kAudioStreamPropertyLatency), as: UInt32.self)) ?? 0
            }.max() ?? 0
        }
        return HALLatencyInfo(
            inputDeviceLatencyFrames: deviceLatency(scope: kAudioObjectPropertyScopeInput),
            outputDeviceLatencyFrames: deviceLatency(scope: kAudioObjectPropertyScopeOutput),
            inputSafetyOffsetFrames: safetyOffset(scope: kAudioObjectPropertyScopeInput),
            outputSafetyOffsetFrames: safetyOffset(scope: kAudioObjectPropertyScopeOutput),
            inputStreamLatencyFrames: streamLatency(inputStreamIDs),
            outputStreamLatencyFrames: streamLatency(outputStreamIDs),
            bufferFrames: bufferFrames
        )
    }
}
