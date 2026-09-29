import CATEngine

/// A deterministic reference over a loaded WAV file — the same `sample(channel:frameIndex:)`
/// contract as `WhiteNoiseReference`/`PinkNoiseReference`, so the stability session plays and
/// verifies a user-supplied file exactly like synthetic noise.
///
/// Channel mapping is cyclic by position among the selected output channels, not by raw device
/// channel number: the i-th selected output plays file channel `i % fileChannelCount` — mono goes
/// to every output, stereo alternates, an N-channel file cycles across more outputs than it has
/// tracks. The file loops.
public struct WAVFileReference: Sendable {
    /// Planar: file channel `c` occupies `[c * frameCount, (c + 1) * frameCount)`.
    private let samples: [Float]
    private let frameCount: Int
    /// Indexed by device channel; -1 for channels the file isn't routed to. An array rather than a
    /// dictionary because this is read on the realtime thread.
    private let fileChannelByDeviceChannel: [Int]

    public init(decoded: WAVReader.DecodedWAV, outputChannelsInOrder: [Int]) {
        self.samples = decoded.channelSamples.flatMap { $0 }
        self.frameCount = decoded.frameCount
        let fileChannelCount = max(decoded.channelCount, 1)
        var map = [Int](repeating: -1, count: (outputChannelsInOrder.max() ?? 0) + 1)
        for (index, deviceChannel) in outputChannelsInOrder.enumerated() where deviceChannel >= 0 {
            map[deviceChannel] = index % fileChannelCount
        }
        self.fileChannelByDeviceChannel = map
    }

    @inline(__always)
    public func sample(channel: Int, frameIndex: Int64) -> Float {
        guard frameCount > 0, channel >= 0, channel < fileChannelByDeviceChannel.count else { return 0 }
        let fileChannel = fileChannelByDeviceChannel[channel]
        guard fileChannel >= 0 else { return 0 }
        let length = Int64(frameCount)
        let index = Int(((frameIndex % length) + length) % length)
        return samples[fileChannel * frameCount + index]
    }
}
