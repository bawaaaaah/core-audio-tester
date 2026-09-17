/// A stateless pink-noise (1/f power spectrum) reference: a counter-mode reinterpretation of the
/// Voss-McCartney algorithm. Row `i` normally holds a random value that is redrawn every `2^i`
/// samples, and the output is the sum of all rows; since a row's current value depends only on
/// `frameIndex >> i` and never on prior samples, `sample(channel:frameIndex:)` stays a pure
/// function of its inputs — matching `WhiteNoiseReference`'s zero-shared-state, zero-allocation
/// contract so the render side and the detector can independently reproduce the exact same value.
///
/// Each row is computed fresh every call rather than cached across samples: the 16 row hashes are
/// independent (no data dependency between them), so the compiler auto-vectorizes this loop: a
/// hand-rolled cache that reuses unchanged rows measured ~2x *slower* in practice, since it forces
/// a sequential dependency (a running cache + a per-row "did this change" branch) onto arithmetic
/// that's otherwise cheap and parallel — the branches and boxed storage cost more than the hashing.
public enum PinkNoiseReference {
    private static let rowCount = 16

    public static func sample(channel: Int, frameIndex: Int64) -> Float {
        let index = UInt64(bitPattern: frameIndex)
        var sum: Float = 0
        for row in 0..<rowCount {
            sum += rowValue(channel: channel, row: row, index: index >> UInt64(row))
        }
        // rowCount independent uniforms summed, not averaged: dividing by rowCount (rather than
        // sqrt(rowCount)) would keep the result within [-1, 1) but make its RMS ~4x quieter than
        // WhiteNoiseReference's — and NoiseGlitchDetector's silence/click thresholds are absolute
        // levels tuned for that white-noise RMS, so a quieter reference reads as constant silence.
        // Dividing by sqrt(rowCount) instead matches variance with a single uniform(-1, 1) term
        // (measured empirically), keeping both noise colors comparable on the same thresholds; the
        // clamp guards the CLT-thinned tail that can now exceed [-1, 1) instead of narrowing to it.
        let normalized = sum / Float(rowCount).squareRoot()
        return max(-1, min(normalized, 1))
    }

    private static func rowValue(channel: Int, row: Int, index: UInt64) -> Float {
        var x = index &+ (UInt64(truncatingIfNeeded: channel) &* 0x9E3779B97F4A7C15) &+ (UInt64(truncatingIfNeeded: row) &* 0xC2B2AE3D27D4EB4F)
        x = (x ^ (x >> 30)) &* 0xBF58476D1CE4E5B9
        x = (x ^ (x >> 27)) &* 0x94D049BB133111EB
        x ^= (x >> 31)
        return Float(x >> 40) / Float(1 << 24) * 2 - 1
    }
}
