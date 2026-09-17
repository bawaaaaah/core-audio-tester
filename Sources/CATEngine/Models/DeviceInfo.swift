import CoreAudio

public struct DeviceInfo: Sendable {
    public let audioObjectID: AudioObjectID
    public let uid: String
    public let name: String
    public let inputChannelCount: Int
    public let outputChannelCount: Int
    public let nominalSampleRate: Double
    public let bufferFrameSizeRange: ClosedRange<UInt32>
    public let transportType: String

    public init(
        audioObjectID: AudioObjectID,
        uid: String,
        name: String,
        inputChannelCount: Int,
        outputChannelCount: Int,
        nominalSampleRate: Double,
        bufferFrameSizeRange: ClosedRange<UInt32>,
        transportType: String
    ) {
        self.audioObjectID = audioObjectID
        self.uid = uid
        self.name = name
        self.inputChannelCount = inputChannelCount
        self.outputChannelCount = outputChannelCount
        self.nominalSampleRate = nominalSampleRate
        self.bufferFrameSizeRange = bufferFrameSizeRange
        self.transportType = transportType
    }
}
