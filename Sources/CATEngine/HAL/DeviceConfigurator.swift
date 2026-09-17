import CoreAudio

/// Reads/writes kAudioDevicePropertyBufferFrameSize, with verification, and captures/restores
/// the device's original configuration so a run always leaves the device as it found it.
public final class DeviceConfigurator {
    public let deviceID: AudioObjectID
    public let originalBufferFrameSize: UInt32
    public let originalSampleRate: Float64

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

    public func restoreOriginalSettings() {
        try? AudioObjectProperty.write(deviceID, AudioObjectProperty.address(kAudioDevicePropertyBufferFrameSize), originalBufferFrameSize)
        let currentRate = try? AudioObjectProperty.read(deviceID, AudioObjectProperty.address(kAudioDevicePropertyNominalSampleRate), as: Float64.self)
        if let currentRate, currentRate != originalSampleRate {
            try? AudioObjectProperty.write(deviceID, AudioObjectProperty.address(kAudioDevicePropertyNominalSampleRate), originalSampleRate)
        }
    }

    public func readLatencyInfo(inputStreamIDs: [AudioStreamID], outputStreamIDs: [AudioStreamID], bufferFrames: UInt32) -> HALLatencyInfo {
        func deviceLatency(scope: AudioObjectPropertyScope) -> UInt32 {
            (try? AudioObjectProperty.read(deviceID, AudioObjectProperty.address(kAudioDevicePropertyLatency, scope: scope), as: UInt32.self)) ?? 0
        }
        func safetyOffset(scope: AudioObjectPropertyScope) -> UInt32 {
            (try? AudioObjectProperty.read(deviceID, AudioObjectProperty.address(kAudioDevicePropertySafetyOffset, scope: scope), as: UInt32.self)) ?? 0
        }
        func streamLatency(_ streamIDs: [AudioStreamID]) -> UInt32 {
            streamIDs.reduce(UInt32(0)) { total, streamID in
                let v = (try? AudioObjectProperty.read(streamID, AudioObjectProperty.address(kAudioStreamPropertyLatency), as: UInt32.self)) ?? 0
                return total + v
            }
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
