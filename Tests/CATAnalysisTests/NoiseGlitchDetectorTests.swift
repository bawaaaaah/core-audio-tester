import Foundation
import Testing
@testable import CATAnalysis
@testable import CATEngine

@Suite struct NoiseGlitchDetectorTests {
    let sampleRate = 48000.0
    let amplitude: Float = 0.25
    let channel = 1

    private func referenceSignal(frames: Int) -> [Float] {
        (0..<frames).map { NoiseSignalKind.white.sample(channel: channel, frameIndex: Int64($0)) * amplitude }
    }

    @Test func cleanRoundTripLocksAndProducesNoIncidents() {
        let detector = NoiseGlitchDetector(channel: channel, sampleRate: sampleRate, amplitude: amplitude, grantedBufferFrames: 512, noiseKind: .white)
        detector.calibrateNoiseFloor([Float](repeating: 0, count: 4800))
        let samples = referenceSignal(frames: Int(1.0 * sampleRate))
        detector.process(samples, startTimestampSeconds: 0)
        let (incidents, _, summary) = detector.finish(totalDurationSeconds: 1.0)
        #expect(incidents.isEmpty)
        #expect(abs(summary.cleanPercentage - 100.0) < 0.01)
    }

    /// Regression test for a bug where `ChannelStabilitySummary.clickCount` was computed by
    /// filtering the detailed `incidents` array, which is capped (at `maxDetailedIncidents`,
    /// 2000) to bound memory — so a channel with heavy real crosstalk silently plateaued at
    /// exactly 2000 reported clicks instead of its true (much higher) count. Shared logic with
    /// `StreamingGlitchDetectorTests.clickCountIsNotCappedByDetailedIncidentStorageLimit`.
    @Test func clickCountIsNotCappedByDetailedIncidentStorageLimit() {
        let detector = NoiseGlitchDetector(channel: channel, sampleRate: sampleRate, amplitude: amplitude, grantedBufferFrames: 512, noiseKind: .white)
        detector.calibrateNoiseFloor([Float](repeating: 0, count: 4800))

        var samples = referenceSignal(frames: Int(5.0 * sampleRate))
        var injected = 0
        var i = 5000
        while i < samples.count {
            samples[i] = samples[i] > 0 ? -0.9 : 0.9
            injected += 1
            i += 100
        }

        detector.process(samples, startTimestampSeconds: 0)
        let (incidents, _, summary) = detector.finish(totalDurationSeconds: 5.0)
        #expect(injected > 2000)
        #expect(incidents.count <= 2000)
        #expect(summary.clickCount > 2000)
    }
}
