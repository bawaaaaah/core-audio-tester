import Foundation
import Testing
@testable import CATAnalysis
@testable import CATEngine

@Suite struct SineGlitchDetectorTests {
    let sampleRate = 48000.0

    private func sine(frequency: Double, seconds: Double, amplitude: Float = 0.25, phase: Double = 0.3, dc: Float = 0) -> [Float] {
        let increment = 2 * Double.pi * frequency / sampleRate
        return (0..<Int(seconds * sampleRate)).map { amplitude * Float(sin(phase + increment * Double($0))) + dc }
    }

    private func detect(_ samples: [Float], frequency: Double, chunk: Int = 256) -> ChannelDetectionOutcome {
        let detector = GlitchDetector(channel: 1, sampleRate: sampleRate, tracker: SineReferenceTracker(frequency: frequency, sampleRate: sampleRate))
        detector.calibrateNoiseFloor([Float](repeating: 0, count: 4800))
        var start = 0
        while start < samples.count {
            let end = min(start + chunk, samples.count)
            detector.process(Array(samples[start..<end]), startIndex: Int64(start))
            start = end
        }
        return detector.finish(totalDurationSeconds: Double(samples.count) / sampleRate)
    }

    /// Regression: the amplitude tracker used to settle ~10% low (mean |x|·√2 instead of the RMS),
    /// so from the 3rd pair's frequency upward a perfectly clean tone produced hundreds of clicks
    /// per second. Every pair frequency and a spread of levels must now come back clean.
    @Test(arguments: [0, 1, 2, 3, 5, 8, 13, 21, 34, 47])
    func cleanToneIsCleanAtEveryPairFrequency(pairIndex: Int) {
        let frequency = 300.0 + Double(pairIndex) * 137.0
        for amplitude: Float in [0.02, 0.1, 0.25, 0.5, 0.7] {
            let outcome = detect(sine(frequency: frequency, seconds: 0.6, amplitude: amplitude), frequency: frequency)
            #expect(outcome.summary.verified)
            #expect(outcome.summary.incidentCount == 0, "f=\(frequency) Hz, A=\(amplitude)")
        }
    }

    @Test func dcOffsetIsTolerated() {
        let outcome = detect(sine(frequency: 574, seconds: 0.6, dc: 0.03), frequency: 574)
        #expect(outcome.summary.incidentCount == 0)
    }

    @Test func injectedClickIsDetected() {
        var samples = sine(frequency: 437, seconds: 1)
        samples[20000] = 0.9
        samples[20001] = -0.9
        #expect(detect(samples, frequency: 437).summary.clickCount >= 1)
    }

    /// Regression: error runs longer than 20 samples were dropped as "not a click" yet too short
    /// to open a dropout, so a 30-sample burst of garbage went unreported.
    @Test func mediumLengthBurstIsReported() {
        var samples = sine(frequency: 437, seconds: 1)
        for i in 30000..<30030 { samples[i] = i % 2 == 0 ? 0.2 : -0.2 }
        #expect(detect(samples, frequency: 437).summary.incidentCount >= 1)
    }

    @Test func silenceGapIsDetected() {
        var samples = sine(frequency: 437, seconds: 1)
        for i in 20000..<(20000 + 2400) { samples[i] = 0 }
        let outcome = detect(samples, frequency: 437)
        #expect(outcome.summary.silenceCount >= 1)
        #expect(outcome.summary.cleanPercentage < 100)
    }

    /// Regression: after a slip the old detector stayed out of phase for the rest of the pass —
    /// the dropout it opened was never closed or reported, and later glitches were invisible.
    @Test func phaseSlipIsReportedAndLaterIncidentsStillDetected() {
        let increment = 2 * Double.pi * 437 / sampleRate
        var samples = (0..<Int(2 * sampleRate)).map { i -> Float in
            let slip = i >= 24000 ? 24.0 : 0.0
            return 0.25 * Float(sin(increment * (Double(i) + slip)))
        }
        samples[72000] = 0.9
        samples[72001] = -0.9
        let outcome = detect(samples, frequency: 437)
        #expect(outcome.summary.dropoutCount >= 1)
        #expect(outcome.summary.reacquisitionCount >= 1)
        #expect(outcome.incidents.contains { $0.type == .click && $0.timestampSeconds > 1.4 })
        #expect(outcome.summary.verified)
    }

    /// Regression: an incident still open when the pass ended was silently discarded.
    @Test func dropoutStillOpenAtTheEndIsReported() {
        var samples = sine(frequency: 437, seconds: 1)
        for i in 36000..<samples.count { samples[i] = 0 }
        let outcome = detect(samples, frequency: 437)
        #expect(outcome.summary.dropoutCount >= 1)
        #expect(outcome.summary.cleanPercentage < 80)
    }

    @Test func deadChannelIsUnverified() {
        let outcome = detect([Float](repeating: 0, count: Int(sampleRate)), frequency: 437)
        #expect(!outcome.summary.verified)
        #expect(outcome.summary.unverifiedReason != nil)
    }

    @Test func wrongToneIsUnverified() {
        let outcome = detect(sine(frequency: 1000, seconds: 1), frequency: 437)
        #expect(!outcome.summary.verified)
    }

    @Test func clippingDuringAcquisitionIsCounted() {
        var samples = sine(frequency: 437, seconds: 1)
        samples[100] = 1.0
        #expect(detect(samples, frequency: 437).summary.clipCount == 1)
    }

    @Test func clipIsCountedSeparatelyFromIncidents() {
        var samples = sine(frequency: 437, seconds: 1)
        samples[20000] = 1.0
        let outcome = detect(samples, frequency: 437)
        #expect(outcome.summary.clipCount == 1)
    }
}

@Suite struct NoiseGlitchDetectorTests {
    let sampleRate = 48000.0
    let amplitude: Float = 0.25
    let preroll = 9600
    let margin = 4800
    let roundTrip = 137

    private func reference(_ frame: Int, channel: Int = 1) -> Float {
        NoiseSignalKind.white.sample(channel: channel, frameIndex: Int64(frame)) * amplitude
    }

    /// Captured stream from the detection start, as the session would deliver it.
    private func captured(seconds: Double, gain: Float = 1, fractionalDelay: Float = 0, slipAt: Int? = nil, slip: Int = 0, channel: Int = 1) -> [Float] {
        let start = preroll + margin
        return (0..<Int(seconds * sampleRate)).map { k in
            let index = start + k
            var frame = index - preroll - roundTrip
            if let slipAt, k >= slipAt { frame += slip }
            let now = reference(frame, channel: channel)
            let previous = reference(frame - 1, channel: channel)
            return gain * ((1 - fractionalDelay) * now + fractionalDelay * previous)
        }
    }

    private func detect(_ samples: [Float], outputChannel: Int = 1) -> ChannelDetectionOutcome {
        let tracker = NoiseReferenceTracker(outputChannel: outputChannel, noiseKind: .white, amplitude: amplitude, prerollFrames: preroll, maxRoundTripFrames: margin, sampleRate: sampleRate)
        let detector = GlitchDetector(channel: 1, sampleRate: sampleRate, tracker: tracker)
        detector.calibrateNoiseFloor([Float](repeating: 0, count: 4800))
        let start = preroll + margin
        var offset = 0
        while offset < samples.count {
            let end = min(offset + 512, samples.count)
            detector.process(Array(samples[offset..<end]), startIndex: Int64(start + offset))
            offset = end
        }
        return detector.finish(totalDurationSeconds: Double(samples.count) / sampleRate)
    }

    @Test func bitExactLoopbackIsClean() {
        let outcome = detect(captured(seconds: 0.6))
        #expect(outcome.summary.verified)
        #expect(outcome.summary.incidentCount == 0)
    }

    /// Regression: the exact comparison assumed unity gain — 1 dB of attenuation produced
    /// thousands of false clicks per second.
    @Test func gainIsCompensated() {
        #expect(detect(captured(seconds: 0.6, gain: 0.89)).summary.incidentCount == 0)
        let inverted = detect(captured(seconds: 0.6, gain: -0.25))
        #expect(inverted.summary.verified)
        #expect(inverted.summary.incidentCount == 0)
    }

    /// An analog path (here a 0.1-sample delay) can't be compared sample-exactly: the channel must
    /// be reported as unverifiable, not flooded with false clicks.
    @Test func nonTransparentPathIsUnverified() {
        let outcome = detect(captured(seconds: 0.6, fractionalDelay: 0.1))
        #expect(!outcome.summary.verified)
        #expect(outcome.summary.unverifiedReason?.contains("transparente") == true)
        #expect(outcome.summary.incidentCount == 0)
    }

    @Test func slipIsReportedThenTrackingResumes() {
        var samples = captured(seconds: 1.2, slipAt: 14400, slip: 7)
        samples[40000] = 0.9
        let outcome = detect(samples)
        #expect(outcome.summary.dropoutCount >= 1)
        #expect(outcome.summary.reacquisitionCount >= 1)
        #expect(outcome.incidents.contains { $0.type == .click && $0.timestampSeconds > 1.0 })
    }

    @Test func wrongOutputSequenceIsUnverified() {
        #expect(!detect(captured(seconds: 0.6, channel: 5), outputChannel: 1).summary.verified)
    }

    /// Per-type counts are true counts even beyond the detailed-incident storage cap.
    @Test func clickCountIsNotCappedByDetailedIncidentStorage() {
        var samples = captured(seconds: 5)
        var injected = 0
        var i = 5000
        while i < samples.count {
            samples[i] = samples[i] > 0 ? -0.9 : 0.9
            injected += 1
            i += 100
        }
        let outcome = detect(samples)
        #expect(injected > IncidentLog.maxDetailedIncidents)
        #expect(outcome.incidents.count <= IncidentLog.maxDetailedIncidents)
        #expect(outcome.summary.clickCount > IncidentLog.maxDetailedIncidents)
    }
}
