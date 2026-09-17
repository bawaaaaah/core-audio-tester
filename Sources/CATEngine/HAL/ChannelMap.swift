import CoreAudio

public struct ChannelLocation: Sendable {
    /// Index into the AudioBufferList delivered to the IOProc for this direction.
    public let bufferIndex: Int
    /// Offset of this channel within that buffer (0 if the buffer is mono/non-interleaved).
    public let channelOffsetWithinBuffer: Int
    /// Number of interleaved channels in that buffer (1 for non-interleaved mono streams).
    public let channelsInBuffer: Int
}

public enum ChannelMapError: Error, CustomStringConvertible {
    case unsupportedFormat(String)
    case channelOutOfRange(Int, Int)

    public var description: String {
        switch self {
        case .unsupportedFormat(let detail):
            return "Unsupported stream format: \(detail)"
        case .channelOutOfRange(let requested, let available):
            return "Channel \(requested) is out of range (device exposes \(available) channels on this side)"
        }
    }
}

/// Maps 1-based device channel numbers to their position within the AudioBufferList
/// the IOProc receives, for one direction (input or output).
public struct ChannelMap {
    public let scope: AudioObjectPropertyScope
    public let streamIDs: [AudioStreamID]
    private let locations: [Int: ChannelLocation]
    public let totalChannels: Int

    public init(deviceID: AudioObjectID, scope: AudioObjectPropertyScope) throws {
        self.scope = scope
        self.streamIDs = try AudioObjectProperty.readArray(
            deviceID, AudioObjectProperty.address(kAudioDevicePropertyStreams, scope: scope), elementType: AudioStreamID.self
        )

        var startingChannels: [Int] = []
        var bufferChannelCounts: [Int] = []
        for streamID in streamIDs {
            let start = try AudioObjectProperty.read(streamID, AudioObjectProperty.address(kAudioStreamPropertyStartingChannel), as: UInt32.self)
            startingChannels.append(Int(start))

            let format = try AudioObjectProperty.read(streamID, AudioObjectProperty.address(kAudioStreamPropertyVirtualFormat), as: AudioStreamBasicDescription.self)
            guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0 else {
                throw ChannelMapError.unsupportedFormat("stream \(streamID) is not linear PCM float (formatID=\(format.mFormatID), flags=\(format.mFormatFlags))")
            }
            bufferChannelCounts.append(Int(format.mChannelsPerFrame))
        }

        var built: [Int: ChannelLocation] = [:]
        for (bufferIndex, (start, channelsInBuffer)) in zip(startingChannels, bufferChannelCounts).enumerated() {
            for offset in 0..<channelsInBuffer {
                built[start + offset] = ChannelLocation(bufferIndex: bufferIndex, channelOffsetWithinBuffer: offset, channelsInBuffer: channelsInBuffer)
            }
        }
        self.locations = built
        self.totalChannels = bufferChannelCounts.reduce(0, +)
    }

    public func location(forDeviceChannel channel: Int) throws -> ChannelLocation {
        guard let loc = locations[channel] else {
            throw ChannelMapError.channelOutOfRange(channel, totalChannels)
        }
        return loc
    }

    public func streamID(forDeviceChannel channel: Int) throws -> AudioStreamID {
        let loc = try location(forDeviceChannel: channel)
        return streamIDs[loc.bufferIndex]
    }

    public func streamIDs(forDeviceChannels channels: [Int]) -> [AudioStreamID] {
        let indices = Set(channels.compactMap { try? location(forDeviceChannel: $0).bufferIndex })
        return indices.map { streamIDs[$0] }
    }
}
