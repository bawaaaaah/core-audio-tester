import Testing
@testable import CATAnalysis

@Suite struct CrossCorrelationOnsetDetectorTests {
    @Test func detectsKnownOffset() {
        let template = MLSSignalGenerator.generate(order: 8)
        let offset = 137
        var window = [Float](repeating: 0, count: offset + template.count + 200)
        for (i, v) in template.enumerated() {
            window[offset + i] = v
        }
        let peak = CrossCorrelationOnsetDetector.detect(window: window, template: template)
        #expect(peak != nil)
        #expect(peak!.lag == offset)
        #expect(peak!.normalizedScore > 0.9)
        #expect(peak!.secondaryPeakRatio > 3)
    }

    @Test func lowScoreOnNoise() {
        let template = MLSSignalGenerator.generate(order: 8)
        let noise = (0..<2000).map { _ in Float.random(in: -0.05...0.05) }
        let peak = CrossCorrelationOnsetDetector.detect(window: noise, template: template)
        #expect(peak != nil)
        #expect(peak!.normalizedScore < 0.35)
    }

    @Test func invertedCopyIsOnlyFoundWhenPolarityInsensitive() {
        let template = MLSSignalGenerator.generate(order: 10)
        var window = [Float](repeating: 0, count: 3000)
        for (i, v) in template.enumerated() { window[500 + i] = -0.5 * v }
        let signed = CrossCorrelationOnsetDetector.detect(window: window, template: template)
        #expect(signed!.normalizedScore < 0.35)
        let insensitive = CrossCorrelationOnsetDetector.detect(window: window, template: template, polarityInsensitive: true)
        #expect(insensitive!.lag == 500)
        #expect(insensitive!.normalizedScore > 0.99)
        #expect(insensitive!.isInverted)
    }
}

@Suite struct MLSSignalGeneratorTests {
    @Test func everyTableEntryIsMaximalLength() {
        for (order, mask) in MLSSignalGenerator.primitiveFeedbackMasks {
            #expect(MLSSignalGenerator.period(order: order, feedbackMask: mask) == (1 << order) - 1, "order \(order)")
        }
    }

    @Test func order10ListHoldsSixtyDistinctPrimitivePolynomials() {
        let masks = MLSSignalGenerator.lowCrossCorrelationOrder10Masks
        #expect(masks.count == 60)
        #expect(Set(masks).count == 60)
        for mask in masks {
            #expect(MLSSignalGenerator.period(order: 10, feedbackMask: mask) == 1023, "mask \(mask)")
        }
    }

    /// Regression: the old taps described a non-primitive polynomial; a lone clean burst then had
    /// a secondary correlation peak almost as high as the true one (ratio ≈ 1.03), so the ping
    /// flagged every repetition as ambiguous.
    @Test func cleanBurstHasAnUnambiguousPeak() {
        let template = MLSSignalGenerator.generate(order: MLSSignalGenerator.pingOrder)
        var window = [Float](repeating: 0, count: 4000)
        for (i, v) in template.enumerated() { window[300 + i] = v }
        let peak = CrossCorrelationOnsetDetector.detect(window: window, template: template)!
        #expect(peak.lag == 300)
        #expect(peak.secondaryPeakRatio > 5)
    }

    @Test func balancedLikeAnMLS() {
        let sequence = MLSSignalGenerator.generate(order: 10)
        #expect(sequence.count == 1023)
        #expect(sequence.filter { $0 > 0 }.count == 512)
    }

    /// Parallel ping sequences must not look like each other as isolated bursts (cyclic shifts of
    /// one sequence, the old approach, correlate at ~1.0).
    @Test func parallelSequencesAreMutuallyUncorrelated() {
        let sequences = MLSSignalGenerator.distinctPingSequences(count: 8)
        for a in 0..<sequences.count {
            for b in 0..<sequences.count where a != b {
                var window = [Float](repeating: 0, count: 3 * 1023)
                for (i, v) in sequences[b].enumerated() { window[1023 + i] = v }
                let peak = CrossCorrelationOnsetDetector.detect(window: window, template: sequences[a], polarityInsensitive: true)!
                #expect(peak.normalizedScore < 0.2, "sequences \(a) and \(b)")
            }
        }
    }

    @Test func moreSequencesThanPolynomialsStillProducesTheRequestedCount() {
        #expect(MLSSignalGenerator.distinctPingSequences(count: 70).count == 70)
    }
}

@Suite struct LatencyStatsTests {
    @Test func medianAveragesTheTwoMiddleValues() {
        let summary = LatencyStats.summarize([1, 2, 3, 10])
        #expect(summary.median == 2.5)
        #expect(summary.min == 1 && summary.max == 10)
    }

    @Test func emptyInputIsAllZero() {
        let summary = LatencyStats.summarize([])
        #expect(summary.mean == 0 && summary.median == 0)
    }
}
