/// Selects the deterministic reference (white noise, pink noise or a WAV file) that the stability
/// session renders and `NoiseReferenceTracker` compares against — one code path for every
/// exact-comparison signal.
public enum NoiseSignalKind: Sendable {
    case white
    case pink
    case wavFile(WAVFileReference)

    @inline(__always)
    public func sample(channel: Int, frameIndex: Int64) -> Float {
        switch self {
        case .white: return WhiteNoiseReference.sample(channel: channel, frameIndex: frameIndex)
        case .pink: return PinkNoiseReference.sample(channel: channel, frameIndex: frameIndex)
        case .wavFile(let reference): return reference.sample(channel: channel, frameIndex: frameIndex)
        }
    }
}
