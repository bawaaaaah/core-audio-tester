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
    }

    @Test func lowScoreOnNoise() {
        let template = MLSSignalGenerator.generate(order: 8)
        let noise = (0..<2000).map { _ in Float.random(in: -0.05...0.05) }
        let peak = CrossCorrelationOnsetDetector.detect(window: noise, template: template)
        #expect(peak != nil)
        #expect(peak!.normalizedScore < 0.35)
    }
}
