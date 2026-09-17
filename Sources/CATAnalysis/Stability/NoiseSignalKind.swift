/// Selects which stateless noise reference (`WhiteNoiseReference` or `PinkNoiseReference`)
/// `NoiseStabilityTestSession`/`NoiseGlitchDetector` render and compare against, so that single
/// pair of classes serves every noise-based stability signal instead of one per noise color.
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
