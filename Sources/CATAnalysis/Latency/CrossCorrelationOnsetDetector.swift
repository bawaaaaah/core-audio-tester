import Accelerate

public struct CorrelationPeak {
    public let lag: Int
    public let fractionalOffset: Double
    /// Normalized correlation at the peak (its magnitude when polarity-insensitive).
    public let normalizedScore: Double
    /// Peak score divided by the best score farther than the exclusion radius.
    public let secondaryPeakRatio: Double
    /// The template matched with inverted polarity (only possible when polarity-insensitive).
    public let isInverted: Bool
}

/// Locates a known template inside a captured window via normalized cross-correlation
/// (matched filtering), computed with Accelerate/vDSP.
public enum CrossCorrelationOnsetDetector {
    /// `polarityInsensitive` also accepts an inverted copy of the template (a loopback wired or
    /// configured with reversed polarity): peaks are then searched on the correlation magnitude.
    public static func detect(window: [Float], template: [Float], exclusionRadius: Int = 50, polarityInsensitive: Bool = false) -> CorrelationPeak? {
        let n = window.count
        let p = template.count
        guard n > p, p > 0 else { return nil }
        let outLen = n - p + 1

        // vDSP_conv(A, F) computes the sliding dot product C[n] = sum_k A[n+k] * F[k] with a
        // positive filter stride — a correlation, so the template is passed as-is.
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
            let denom = localEnergy[i] > 0 ? sqrtf(localEnergy[i] * templateEnergy) : 0
            let value = denom > 0 ? correlation[i] / denom : 0
            normalized[i] = polarityInsensitive ? abs(value) : value
        }

        var peakIndex = 0
        var peakValue = -Float.greatestFiniteMagnitude
        for i in 0..<outLen where normalized[i] > peakValue {
            peakValue = normalized[i]
            peakIndex = i
        }

        var secondPeakValue = -Float.greatestFiniteMagnitude
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

        let isInverted: Bool
        if polarityInsensitive {
            let denom = localEnergy[peakIndex] > 0 ? sqrtf(localEnergy[peakIndex] * templateEnergy) : 0
            isInverted = denom > 0 && correlation[peakIndex] < 0
        } else {
            isInverted = false
        }
        let ratio = secondPeakValue > 0.0001 ? Double(peakValue / secondPeakValue) : Double.infinity
        return CorrelationPeak(
            lag: peakIndex,
            fractionalOffset: fractional,
            normalizedScore: Double(peakValue),
            secondaryPeakRatio: ratio,
            isInverted: isInverted
        )
    }
}
