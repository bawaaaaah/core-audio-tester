import Foundation
import Testing
@testable import CATAnalysis
@testable import CATEngine

@Suite struct StreamingGlitchDetectorTests {
    let sampleRate = 48000.0
    let frequency = 437.0

    private func cleanSine(seconds: Double, amplitude: Float = 0.25, startPhase: Double = 0) -> [Float] {
        let count = Int(seconds * sampleRate)
        let increment = 2 * Double.pi * frequency / sampleRate
        var phase = startPhase
        var samples = [Float](repeating: 0, count: count)
        for i in 0..<count {
            samples[i] = amplitude * Float(sin(phase))
            phase += increment
        }
        return samples
    }

    @Test func cleanSignalProducesNoIncidents() {
        let detector = StreamingGlitchDetector(channel: 1, frequency: frequency, sampleRate: sampleRate)
        detector.calibrateNoiseFloor([Float](repeating: 0, count: 4800))
        detector.process(cleanSine(seconds: 1.0), startTimestampSeconds: 0)
        let (incidents, _, summary) = detector.finish(totalDurationSeconds: 1.0)
        #expect(incidents.count == 0)
        #expect(abs(summary.cleanPercentage - 100.0) < 0.01)
    }

    @Test func injectedClickIsDetected() {
        let detector = StreamingGlitchDetector(channel: 1, frequency: frequency, sampleRate: sampleRate)
        detector.calibrateNoiseFloor([Float](repeating: 0, count: 4800))
        var samples = cleanSine(seconds: 1.0)
        samples[20000] = 0.9
        samples[20001] = -0.9
        detector.process(samples, startTimestampSeconds: 0)
        let (incidents, _, _) = detector.finish(totalDurationSeconds: 1.0)
        #expect(incidents.contains { $0.type == .click })
    }

    @Test func injectedSilenceGapIsDetected() {
        let detector = StreamingGlitchDetector(channel: 1, frequency: frequency, sampleRate: sampleRate)
        detector.calibrateNoiseFloor([Float](repeating: 0, count: 4800))
        var samples = cleanSine(seconds: 1.0)
        let gapStart = 20000
        let gapLength = Int(0.05 * sampleRate)
        for i in gapStart..<(gapStart + gapLength) { samples[i] = 0 }
        detector.process(samples, startTimestampSeconds: 0)
        let (incidents, _, summary) = detector.finish(totalDurationSeconds: 1.0)
        #expect(incidents.contains { $0.type == .silence })
        #expect(summary.cleanPercentage < 100.0)
    }

    @Test func clippingIsDetectedSeparately() {
        let detector = StreamingGlitchDetector(channel: 1, frequency: frequency, sampleRate: sampleRate)
        detector.calibrateNoiseFloor([Float](repeating: 0, count: 4800))
        var samples = cleanSine(seconds: 1.0, amplitude: 0.25)
        // Past the phase-lock window, so this exercises the steady-state path and proves a
        // clipped sample is classified as `.clip` rather than falling through to `.click`.
        samples[20000] = 1.0
        detector.process(samples, startTimestampSeconds: 0)
        let (incidents, _, summary) = detector.finish(totalDurationSeconds: 1.0)
        #expect(incidents.contains { $0.type == .clip })
        #expect(summary.clipCount == 1)
        #expect(!incidents.contains { $0.type == .click })
    }

    /// Regression test for a blind spot where nothing at all was reported for the first
    /// `phaseLockFrameTarget` frames (100ms at 48kHz): those samples are consumed by the
    /// phase-lock DFT and never reach `processDetection`, so a channel that clipped right at
    /// the start of a stability pass came back perfectly clean. Clipping is a pure amplitude
    /// test and needs no phase reference, so it is now detected during the lock window too.
    @Test func clippingDuringPhaseLockIsDetected() {
        let detector = StreamingGlitchDetector(channel: 1, frequency: frequency, sampleRate: sampleRate)
        detector.calibrateNoiseFloor([Float](repeating: 0, count: 4800))
        var samples = cleanSine(seconds: 1.0, amplitude: 0.25)
        // Index 100 sits well inside the 4800-frame phase-lock window.
        samples[100] = 1.0
        detector.process(samples, startTimestampSeconds: 0)
        let (incidents, _, summary) = detector.finish(totalDurationSeconds: 1.0)
        #expect(incidents.contains { $0.type == .clip })
        #expect(summary.clipCount == 1)
    }

    /// Regression test for a bug where `ChannelStabilitySummary.clickCount` was computed by
    /// filtering the detailed `incidents` array, which is capped (at `maxDetailedIncidents`,
    /// 2000) to bound memory — so a channel with heavy real crosstalk silently plateaued at
    /// exactly 2000 reported clicks instead of its true (much higher) count, observed on
    /// hardware as dozens of channels all showing an identical, suspicious "2000".
    @Test func clickCountIsNotCappedByDetailedIncidentStorageLimit() {
        let detector = StreamingGlitchDetector(channel: 1, frequency: frequency, sampleRate: sampleRate)
        detector.calibrateNoiseFloor([Float](repeating: 0, count: 4800))
        var samples = cleanSine(seconds: 5.0)
        var injected = 0
        var i = 5000
        while i < samples.count {
            samples[i] = 0.9
            injected += 1
            i += 100
        }
        detector.process(samples, startTimestampSeconds: 0)
        let (incidents, _, summary) = detector.finish(totalDurationSeconds: 5.0)
        #expect(injected > 2000)
        #expect(incidents.count <= 2000)
        #expect(summary.clickCount > 2000)
    }

    /// Regression test for a real-hardware finding: on the WING, a brief but genuine deviation
    /// right at the phase-lock boundary (a DFT point estimate's residual inaccuracy against the
    /// real, not perfectly ideal, captured tone — reproduced bit-identically across independent
    /// runs, so not random noise) reliably produced a few borderline clicks on an otherwise
    /// perfectly clean single channel. `phaseLockFrameTarget` for this frequency/sample rate is
    /// exactly 4800 samples, so a deviation placed there stands in for that measured artifact.
    @Test func transientRightAtLockBoundaryIsSuppressed() {
        let detector = StreamingGlitchDetector(channel: 1, frequency: frequency, sampleRate: sampleRate)
        detector.calibrateNoiseFloor([Float](repeating: 0, count: 4800))
        var samples = cleanSine(seconds: 1.0)
        samples[4800] = 0.9
        samples[4801] = -0.9
        detector.process(samples, startTimestampSeconds: 0)
        let (incidents, _, _) = detector.finish(totalDurationSeconds: 1.0)
        #expect(incidents.isEmpty)
    }
}
