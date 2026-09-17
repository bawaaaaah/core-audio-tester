import CATEngine

/// A stateless, deterministic reference over a loaded WAV file's samples — the same
/// `sample(channel:frameIndex:)` contract as `WhiteNoiseReference`/`PinkNoiseReference`, so
/// `NoiseStabilityTestSession`/`NoiseGlitchDetector` drive playback and detection from a
/// user-supplied WAV file exactly as they would from synthetic noise, with no changes to either.
///
/// Channel mapping is cyclic by ordinal position among the selected output channels, not raw
/// device channel number: the i-th selected output channel plays file channel `i % fileChannelCount`.
/// This one rule covers every case — mono (always file channel 0), stereo (odd/even alternation
/// once selected channels are 1-indexed), and an N>2-channel file cycling across more output
/// channels than it has tracks.
public struct WAVFileReference: Sendable {
    private let channelSamples: [[Float]]
    private let frameCount: Int
    private let deviceChannelToFileChannel: [Int: Int]

    public init(decoded: WAVReader.DecodedWAV, outputChannelsInOrder: [Int]) {
        self.channelSamples = decoded.channelSamples
        self.frameCount = decoded.frameCount
        let fileChannelCount = max(decoded.channelCount, 1)
        var map: [Int: Int] = [:]
        for (idx, deviceChannel) in outputChannelsInOrder.enumerated() {
            map[deviceChannel] = idx % fileChannelCount
        }
        self.deviceChannelToFileChannel = map
    }

    public func sample(channel: Int, frameIndex: Int64) -> Float {
        guard frameCount > 0, let fileChannel = deviceChannelToFileChannel[channel] else { return 0 }
        let m = Int64(frameCount)
        let idx = Int(((frameIndex % m) + m) % m) // loop the file; safe against a hypothetical negative frameIndex
        return channelSamples[fileChannel][idx]
    }
}
