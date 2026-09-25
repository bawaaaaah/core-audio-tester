import CATEngine
import Foundation

enum AcquisitionOutcome {
    case locked
    case failed(reason: String)
}

/// Knows what one input channel should be receiving. The detector first asks it to lock onto the
/// captured stream (`acquire`), then compares every captured sample with `expectedSample`.
///
/// Stream indices are frames since the first IO cycle of the pass, on the input timeline. Because
/// the render side is indexed by device sample time too, the mapping from stream index to reference
/// frame stays fixed across skipped cycles and dropped capture records: only a real slip in the
/// device's own stream moves it, and that is what re-acquisition recovers from.
protocol ReferenceTracker: AnyObject {
    /// Contiguous samples needed for one acquisition attempt.
    var acquisitionFrameCount: Int { get }
    /// Samples to skip after a failed attempt before trying again.
    var retryIntervalFrames: Int { get }
    /// Samples after a successful acquisition during which nothing is classified.
    var settleFrameCount: Int { get }
    /// Locks onto the reference from `samples`, whose first element is at `startIndex`.
    func acquire(_ samples: [Float], startIndex: Int64, noiseFloor: Float) -> AcquisitionOutcome
    /// Expected sample at `index`, once locked. Called once per sample, in order; `captured` lets
    /// an adaptive tracker follow slow gain drift.
    func expectedSample(at index: Int64, captured: Float) -> Float
    /// Peak amplitude the channel is currently expected to carry.
    var referencePeakAmplitude: Float { get }
    /// Level a silent input sits at (a DC offset for the sine fit, 0 otherwise).
    var restingLevel: Float { get }
    /// Whether the reference itself carries signal here, so a quiet capture would be abnormal.
    func expectsSignal(expected: Float, silenceThreshold: Float) -> Bool
}

/// Reference for the sine mode. Acquisition is a least-squares fit of `a·sin + b·cos + dc` at the
/// known frequency, which gives the phase, amplitude and DC offset exactly for a clean tone whatever
/// the window length. While tracking, the amplitude follows the captured signal's RMS (so a slowly
/// drifting analog gain doesn't read as an error) — RMS, not mean absolute value, which would settle
/// about 10% low and turn every sine peak into a false click.
final class SineReferenceTracker: ReferenceTracker {
    /// Largest fit residual, relative to the fitted tone's RMS, accepted as "this is our tone".
    static let maxResidualRatio = 0.25

    let acquisitionFrameCount: Int
    let retryIntervalFrames = 0
    let settleFrameCount: Int
    private let phaseIncrement: Double
    private let amplitudeSmoothing = 0.002
    private var phaseOffset = 0.0
    private var dcOffset = 0.0
    private var meanSquare = 0.0

    init(frequency: Double, sampleRate: Double) {
        self.phaseIncrement = 2 * Double.pi * frequency / sampleRate
        self.acquisitionFrameCount = max(Int(sampleRate * 0.1), Int(20 * sampleRate / frequency))
        self.settleFrameCount = Int(sampleRate * 0.01)
    }

    func acquire(_ samples: [Float], startIndex: Int64, noiseFloor: Float) -> AcquisitionOutcome {
        guard !samples.isEmpty else { return .failed(reason: "aucun échantillon") }
        var ss = 0.0, sc = 0.0, cc = 0.0, s1 = 0.0, c1 = 0.0, xs = 0.0, xc = 0.0, x1 = 0.0
        for (k, sample) in samples.enumerated() {
            let theta = phaseIncrement * Double(startIndex + Int64(k))
            let s = sin(theta)
            let c = cos(theta)
            let x = Double(sample)
            ss += s * s; sc += s * c; cc += c * c; s1 += s; c1 += c
            xs += x * s; xc += x * c; x1 += x
        }
        let n = Double(samples.count)
        guard let solution = solve3x3(
            [[ss, sc, s1], [sc, cc, c1], [s1, c1, n]],
            [xs, xc, x1]
        ) else {
            return .failed(reason: "ajustement de la sinusoïde impossible")
        }
        let (a, b, dc) = (solution[0], solution[1], solution[2])
        let amplitude = (a * a + b * b).squareRoot()
        guard amplitude > Double(noiseFloor) * 3 else {
            return .failed(reason: "aucune tonalité reçue (canal muet, mauvais routage ou câble absent)")
        }
        var residual = 0.0
        for (k, sample) in samples.enumerated() {
            let theta = phaseIncrement * Double(startIndex + Int64(k))
            let e = Double(sample) - (a * sin(theta) + b * cos(theta) + dc)
            residual += e * e
        }
        let residualRatio = (residual / n).squareRoot() / (amplitude / 2.0.squareRoot())
        guard residualRatio <= Self.maxResidualRatio else {
            return .failed(reason: String(format: "tonalité attendue noyée dans un autre signal (résidu %.0f %%) : diaphonie, mauvais routage ou forte distorsion", residualRatio * 100))
        }
        phaseOffset = atan2(b, a)
        dcOffset = dc
        meanSquare = amplitude * amplitude / 2
        return .locked
    }

    func expectedSample(at index: Int64, captured: Float) -> Float {
        let centered = Double(captured) - dcOffset
        meanSquare += amplitudeSmoothing * (centered * centered - meanSquare)
        let amplitude = (2 * meanSquare).squareRoot()
        return Float(amplitude * sin(phaseIncrement * Double(index) + phaseOffset) + dcOffset)
    }

    var referencePeakAmplitude: Float { Float((2 * meanSquare).squareRoot()) }
    var restingLevel: Float { Float(dcOffset) }

    func expectsSignal(expected: Float, silenceThreshold: Float) -> Bool {
        referencePeakAmplitude > 2 * silenceThreshold
    }
}

/// Reference for the exact-comparison modes (white/pink noise, WAV file). Acquisition finds the
/// alignment by cross-correlating captured audio against the synthetic reference, then fits the
/// loopback gain (and polarity) by least squares. What's left after that must be essentially
/// nothing: a residual above `maxResidualRatio` means the path isn't bit-transparent (analog
/// converters, filtering, resampling) and a sample-exact comparison would only produce false
/// clicks, so the channel is reported as unverifiable instead.
final class NoiseReferenceTracker: ReferenceTracker {
    /// -30 dB: residual peaks then stay below the click threshold (8% of the peak level).
    static let maxResidualRatio = 0.03

    let acquisitionFrameCount = 2048
    let retryIntervalFrames: Int
    let settleFrameCount = 0
    private let outputChannel: Int
    private let noiseKind: NoiseSignalKind
    private let amplitude: Float
    private let prerollFrames: Int64
    private let maxRoundTripFrames: Int
    /// Reference frame = stream index - referenceOffset.
    private var referenceOffset: Int64 = 0
    private var gain: Float = 1
    private var hasLock = false

    /// `outputChannel` is the device output feeding this input: the reference is generated per
    /// output channel, so cross-patched pairs compare against the right sequence.
    init(outputChannel: Int, noiseKind: NoiseSignalKind, amplitude: Float, prerollFrames: Int, maxRoundTripFrames: Int, sampleRate: Double) {
        self.outputChannel = outputChannel
        self.noiseKind = noiseKind
        self.amplitude = amplitude
        self.prerollFrames = Int64(prerollFrames)
        self.maxRoundTripFrames = maxRoundTripFrames
        self.retryIntervalFrames = Int(sampleRate * 0.25)
    }

    private func reference(frame: Int64) -> Float {
        noiseKind.sample(channel: outputChannel, frameIndex: frame) * amplitude
    }

    func acquire(_ samples: [Float], startIndex: Int64, noiseFloor: Float) -> AcquisitionOutcome {
        let searchBase: Int64
        let searchSpan: Int
        if hasLock {
            // Re-acquisition after a slip: the new alignment is near the old one.
            let expectedFrame = startIndex - referenceOffset
            searchBase = max(expectedFrame - Int64(maxRoundTripFrames), 0)
            searchSpan = 2 * maxRoundTripFrames
        } else {
            // The first captured sample was played at frame startIndex - preroll - roundTrip, with
            // the round trip somewhere up to maxRoundTripFrames (plus a margin).
            searchSpan = maxRoundTripFrames + maxRoundTripFrames / 4
            searchBase = max(startIndex - prerollFrames - Int64(searchSpan), 0)
        }
        let window = (0..<(searchSpan + samples.count)).map { reference(frame: searchBase + Int64($0)) }
        guard let peak = CrossCorrelationOnsetDetector.detect(window: window, template: samples, polarityInsensitive: true),
              peak.normalizedScore >= 0.3
        else {
            return .failed(reason: "signal de référence introuvable (pas de signal, mauvais routage, ou latence hors de la fenêtre de recherche)")
        }

        var cross = 0.0
        var energy = 0.0
        for (k, sample) in samples.enumerated() {
            let r = Double(window[peak.lag + k])
            cross += Double(sample) * r
            energy += r * r
        }
        guard energy > 0 else { return .failed(reason: "référence silencieuse à cet endroit") }
        let fittedGain = cross / energy
        var residual = 0.0
        for (k, sample) in samples.enumerated() {
            let e = Double(sample) - fittedGain * Double(window[peak.lag + k])
            residual += e * e
        }
        let residualRatio = (residual / energy).squareRoot() / abs(fittedGain)
        guard residualRatio <= Self.maxResidualRatio else {
            let residualDB = 20 * log10(max(residualRatio, 1e-9))
            return .failed(reason: String(format: "boucle non transparente (résidu %.0f dB après compensation du gain) : les modes bruit/WAV exigent un loopback numérique bit-exact — utilise --stability-signal sine pour une boucle analogique", residualDB))
        }
        referenceOffset = startIndex - (searchBase + Int64(peak.lag))
        gain = Float(fittedGain)
        hasLock = true
        return .locked
    }

    func expectedSample(at index: Int64, captured: Float) -> Float {
        reference(frame: index - referenceOffset) * gain
    }

    var referencePeakAmplitude: Float { amplitude * abs(gain) }
    var restingLevel: Float { 0 }

    func expectsSignal(expected: Float, silenceThreshold: Float) -> Bool {
        abs(expected) >= silenceThreshold && silenceThreshold * 2 < referencePeakAmplitude
    }
}

/// Solves a 3×3 linear system by Gaussian elimination with partial pivoting; nil if singular.
func solve3x3(_ matrix: [[Double]], _ rhs: [Double]) -> [Double]? {
    var m = matrix
    var v = rhs
    for column in 0..<3 {
        var pivot = column
        for row in (column + 1)..<3 where abs(m[row][column]) > abs(m[pivot][column]) {
            pivot = row
        }
        guard abs(m[pivot][column]) > 1e-12 else { return nil }
        if pivot != column {
            m.swapAt(pivot, column)
            v.swapAt(pivot, column)
        }
        for row in (column + 1)..<3 {
            let factor = m[row][column] / m[column][column]
            for k in column..<3 { m[row][k] -= factor * m[column][k] }
            v[row] -= factor * v[column]
        }
    }
    var x = [0.0, 0.0, 0.0]
    for row in stride(from: 2, through: 0, by: -1) {
        var sum = v[row]
        for k in (row + 1)..<3 { sum -= m[row][k] * x[k] }
        x[row] = sum / m[row][row]
    }
    return x
}
