/// Generates Maximum Length Sequences (MLS) via a Fibonacci LFSR. MLS bursts are used as the
/// ping test signal: their near-ideal autocorrelation gives strong processing gain against the
/// noise floor and inter-channel bleed, at a low crest factor (safe playback level).
public enum MLSSignalGenerator {
    /// Standard primitive polynomial tap sets (1-indexed bit positions), one of several
    /// well-known tables used for maximal-length sequence generation.
    private static let tapsTable: [Int: [Int]] = [
        4: [4, 3], 5: [5, 3], 6: [6, 5], 7: [7, 6],
        8: [8, 6, 5, 4], 9: [9, 5], 10: [10, 3], 11: [11, 2],
        12: [12, 6, 4, 1], 13: [13, 4, 3, 1], 14: [14, 5, 3, 1],
        15: [15, 1], 16: [16, 5, 3, 2],
    ]

    /// Returns a bipolar (-1/+1) MLS of length 2^order - 1, cyclically shifted by `shift`.
    /// Distinct shifts of the same base sequence are used to keep cross-correlation between
    /// simultaneously-emitted channels low in the default parallel ping mode.
    public static func generate(order: Int, shift: Int = 0) -> [Float] {
        let taps = tapsTable[order] ?? tapsTable[10]!
        let length = (1 << order) - 1
        var state = 1
        var bits = [Int](repeating: 0, count: length)
        for i in 0..<length {
            bits[i] = state & 1
            var feedback = 0
            for tap in taps { feedback ^= (state >> (tap - 1)) & 1 }
            state = (state >> 1) | (feedback << (order - 1))
        }
        let s = ((shift % length) + length) % length
        let rotated = Array(bits[s...] + bits[..<s])
        return rotated.map { $0 == 1 ? 1.0 : -1.0 }
    }
}
