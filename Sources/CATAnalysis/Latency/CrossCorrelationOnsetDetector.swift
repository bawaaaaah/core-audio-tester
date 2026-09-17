import Accelerate

public struct CorrelationPeak {
    public let lag: Int
    public let fractionalOffset: Double
    public let normalizedScore: Double
    public let secondaryPeakRatio: Double
}

/// Locates a known MLS template inside a captured window via normalized cross-correlation
/// (matched filtering), computed with Accelerate/vDSP for speed.
public enum CrossCorrelationOnsetDetector {
    public static func detect(window: [Float], template: [Float], exclusionRadius: Int = 50) -> CorrelationPeak? {
        let n = window.count
        let p = template.count
        guard n > p, p > 0 else { return nil }
        let outLen = n - p + 1

        // vDSP_conv(A, F) computes a direct sliding dot product C[n] = sum_k A[n+k] * F[k] — no
        // reversal happens internally, so F must be the template as-is. (An earlier version of
        // this code passed the template reversed, which correlates the window against the
        // *reversed* template instead. That went unnoticed for the MLS ping signal because its
        // LFSR structure makes the reversed sequence itself close to a shifted copy of the
        // original — real broadband noise has no such symmetry and the bug is fatal for it.)
        var correlation = [Float](repeating: 0, count: outLen)
        vDSP_conv(window, 1, template, 1, &correlation, 1, vDSP_Length(outLen), vDSP_Length(p))

        var windowSquared = [Float](repeating: 0, count: n)
        vDSP_vsq(window, 1, &windowSquared, 1, vDSP_Length(n))
        let ones = [Float](repeating: 1, count: p)
        var localEnergy = [Float](repeating: 0, count: outLen)
        vDSP_conv(windowSquared, 1, ones, 1, &localEnergy, 1, vDSP_Length(outLen), vDSP_Length(p))

        var templateEnergy: Float = 0
        vDSP_svesq(template, 1, &templateEnergy, vDSP_Length(p))
        guard templateEnergy > 0 else { return nil }

        var normalized = [Float](repeating: 0, count: outLen)
        for i in 0..<outLen {
            let denom = (localEnergy[i] > 0 ? sqrtf(localEnergy[i] * templateEnergy) : 0)
            normalized[i] = denom > 0 ? correlation[i] / denom : 0
        }

        var peakIndex = 0
        var peakValue: Float = -Float.greatestFiniteMagnitude
        for i in 0..<outLen where normalized[i] > peakValue {
            peakValue = normalized[i]
            peakIndex = i
        }

        var secondPeakValue: Float = -Float.greatestFiniteMagnitude
        for i in 0..<outLen where abs(i - peakIndex) > exclusionRadius && normalized[i] > secondPeakValue {
            secondPeakValue = normalized[i]
        }
        if secondPeakValue == -Float.greatestFiniteMagnitude { secondPeakValue = 0 }

        var fractional = 0.0
        if peakIndex > 0, peakIndex < outLen - 1 {
            let y0 = Double(normalized[peakIndex - 1])
            let y1 = Double(normalized[peakIndex])
            let y2 = Double(normalized[peakIndex + 1])
            let denom = y0 - 2 * y1 + y2
            if denom != 0 {
                fractional = 0.5 * (y0 - y2) / denom
            }
        }

        let ratio = secondPeakValue > 0.0001 ? Double(peakValue / secondPeakValue) : Double.infinity
        return CorrelationPeak(lag: peakIndex, fractionalOffset: fractional, normalizedScore: Double(peakValue), secondaryPeakRatio: ratio)
    }
}
