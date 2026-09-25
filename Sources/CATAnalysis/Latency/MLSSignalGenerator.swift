/// Generates maximum length sequences (MLS) with a right-shifting Fibonacci LFSR. MLS bursts are
/// the ping test signal: their near-ideal autocorrelation gives strong processing gain against the
/// noise floor and inter-channel bleed at a low crest factor.
///
/// Register convention: each step outputs `state & 1`, then shifts right and inserts the parity of
/// `state & feedbackMask` at bit `order - 1`. Bit `i` of the mask is the coefficient of `x^i` in the
/// characteristic polynomial `x^order + … + 1`, so bit 0 is always set.
public enum MLSSignalGenerator {
    /// Burst order used by the ping test: 1023-sample bursts.
    public static let pingOrder = 10

    /// One primitive polynomial per order, as feedback masks in the convention above.
    static let primitiveFeedbackMasks: [Int: Int] = [
        4: 0b11,             // x^4 + x + 1
        5: 0b101,            // x^5 + x^2 + 1
        6: 0b11,             // x^6 + x + 1
        7: 0b11,             // x^7 + x + 1
        8: 0b11101,          // x^8 + x^4 + x^3 + x^2 + 1
        9: 0b10001,          // x^9 + x^4 + 1
        10: 0b1001,          // x^10 + x^3 + 1
        11: 0b101,           // x^11 + x^2 + 1
        12: 0b1010011,       // x^12 + x^6 + x^4 + x + 1
        13: 0b11011,         // x^13 + x^4 + x^3 + x + 1
        14: 0b101011,        // x^14 + x^5 + x^3 + x + 1
        15: 0b11,            // x^15 + x + 1
        16: 0b101101,        // x^16 + x^5 + x^3 + x^2 + 1
    ]

    /// All 60 primitive polynomials of order 10, ordered so that each prefix keeps the pairwise
    /// cross-correlation of their bursts low: the first 30 stay at or below ~0.16 (normalized, over
    /// every lag), the full set at or below ~0.38. Cyclic shifts of one sequence would not do —
    /// as isolated bursts they overlap almost entirely (≈1.0).
    static let lowCrossCorrelationOrder10Masks: [Int] = [
        9, 255, 853, 801, 633, 893, 197, 987, 591, 579, 705, 639, 549, 101, 839, 129, 915, 139, 867, 45,
        291, 945, 845, 603, 735, 567, 215, 693, 281, 111, 791, 765, 343, 507, 857, 455, 797, 417, 363, 243,
        723, 1017, 407, 27, 39, 649, 503, 305, 531, 1011, 317, 231, 825, 485, 269, 389, 399, 909, 533, 323,
    ]

    /// Bipolar (-1/+1) MLS of length 2^order - 1 from the reference polynomial of that order,
    /// cyclically shifted by `shift`.
    public static func generate(order: Int, shift: Int = 0) -> [Float] {
        let resolvedOrder = primitiveFeedbackMasks[order] == nil ? pingOrder : order
        return generate(order: resolvedOrder, feedbackMask: primitiveFeedbackMasks[resolvedOrder]!, shift: shift)
    }

    public static func generate(order: Int, feedbackMask: Int, shift: Int = 0) -> [Float] {
        let length = (1 << order) - 1
        var state = 1
        var bits = [Float](repeating: 0, count: length)
        for i in 0..<length {
            bits[i] = (state & 1) == 1 ? 1 : -1
            let feedback = (state & feedbackMask).nonzeroBitCount & 1
            state = (state >> 1) | (feedback << (order - 1))
        }
        let s = ((shift % length) + length) % length
        guard s != 0 else { return bits }
        return Array(bits[s...] + bits[..<s])
    }

    /// Number of steps before the register returns to its initial state; equals 2^order - 1
    /// exactly when `feedbackMask` describes a primitive polynomial.
    public static func period(order: Int, feedbackMask: Int) -> Int {
        let limit = 1 << order
        var state = 1
        for step in 1...limit {
            let feedback = (state & feedbackMask).nonzeroBitCount & 1
            state = (state >> 1) | (feedback << (order - 1))
            if state == 1 { return step }
        }
        return -1
    }

    /// `count` order-10 sequences for pinging several outputs at once, as mutually uncorrelated as
    /// possible. Beyond the 60 distinct polynomials, sequences are reused with a cyclic shift.
    public static func distinctPingSequences(count: Int) -> [[Float]] {
        let masks = lowCrossCorrelationOrder10Masks
        let length = (1 << pingOrder) - 1
        let reuseRounds = max((count + masks.count - 1) / masks.count, 1)
        return (0..<max(count, 0)).map { index in
            let round = index / masks.count
            return generate(order: pingOrder, feedbackMask: masks[index % masks.count], shift: round * (length / reuseRounds))
        }
    }
}
