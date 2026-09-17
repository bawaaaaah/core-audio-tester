/// A stateless, counter-mode noise source: `sample(channel:frameIndex:)` is a pure function of
/// its inputs, so the output-render side and the detector can each independently compute the
/// exact same value for any `(channel, frameIndex)` pair with zero shared state and zero
/// allocation — no sequential PRNG to keep in sync between two different threads.
public enum WhiteNoiseReference {
    public static func sample(channel: Int, frameIndex: Int64) -> Float {
        var x = UInt64(bitPattern: frameIndex) &+ (UInt64(truncatingIfNeeded: channel) &* 0x9E3779B97F4A7C15)
        x = (x ^ (x >> 30)) &* 0xBF58476D1CE4E5B9
        x = (x ^ (x >> 27)) &* 0x94D049BB133111EB
        x ^= (x >> 31)
        let unit = Float(x >> 40) / Float(1 << 24) * 2 - 1 // uniform in [-1, 1)
        return unit
    }
}
