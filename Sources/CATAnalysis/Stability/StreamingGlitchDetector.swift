import CATEngine
import Foundation

/// Streaming (bounded-memory) glitch detector for one channel's continuous-phase sine test
/// signal. Tracks an expected-phase accumulator and a slow amplitude envelope, self-calibrated
/// against a short silent pre-roll, and classifies deviations into clicks, silence gaps,
/// dropouts (persistent phase/energy error), and clipping.
public final class StreamingGlitchDetector {
    public let channel: Int
    private let frequency: Double
    private let sampleRate: Double
    private var expectedPhase: Double = 0
    private let phaseIncrement: Double

    private var noiseFloor: Float = 0.0005
    private var amplitudeEstimate: Float = 0
    private let amplitudeEmaAlpha: Float = 0.002

    private var totalSamples: Int64 = 0
    private var incidentAffectedSamples: Int64 = 0

    private var incidents: [Incident] = []
    private var truncatedCount = 0
    private let maxDetailedIncidents = 2000

    // True per-type incident counts, incremented unconditionally regardless of whether the
    // detailed `Incident` itself got stored: `maxDetailedIncidents` only bounds memory for the
    // full per-incident record list, so filtering that (possibly-truncated) list for a per-type
    // count would silently plateau at whatever the cap let through — observed on hardware as
    // every heavily-affected channel reporting an identical, suspicious "2000 clicks" instead of
    // its real (much higher) count.
    private var dropoutCount = 0
    private var silenceCount = 0
    private var clickCount = 0
    private var clipCount = 0

    private var inClick = false
    private var clickRunLength = 0
    private var clickPeakDeviation: Float = 0
    private var clickStartSample: Int64 = 0

    private var inSilence = false
    private var silenceRunLength = 0
    private var silenceStartSample: Int64 = 0

    private var errorWindowSumSq: Double = 0
    private var errorWindowCount = 0
    private let errorWindowSize = 32
    private var consecutiveElevatedWindows = 0
    private var inDropout = false
    private var dropoutStartSample: Int64 = 0

    // A round-trip through the device/console adds an unknown (but roughly constant) delay,
    // which is an unknown *phase offset* at the tested frequency — not just a time shift.
    // Starting expectedPhase at 0 assumes zero delay, so the mismatch (and false click/dropout
    // rate) grows with frequency for the exact same physical latency. Instead we estimate the
    // actual phase/amplitude from a short window of real audio right after calibration (a
    // single-frequency DFT / phase-locking step) before turning on detection.
    private var phaseLockBuffer: [Float] = []
    private let phaseLockFrameTarget: Int
    private var phaseLocked = false

    // Confirmed on real hardware (WING, bit-identical across independent runs): the first ~1
    // cycle right after `lockPhase()` reliably produces a few borderline-threshold clicks even
    // on a single, otherwise perfectly clean channel — a DFT point estimate's small residual
    // inaccuracy against the real (not perfectly ideal) captured tone, not a real audio glitch.
    // Classification is suppressed for a short window immediately after lock while phase/
    // amplitude tracking keeps running, mirroring the calibration/dead-zone/detection masking
    // already used at the session level for the render-side boundary. The window can extend
    // itself a little if a violation lands right at its edge (the exact tail length varies a bit
    // by channel) — but ONLY up to `maxSettleFrameCount` total: an unbounded extension would let
    // a channel with a genuine, sustained problem (e.g. real multi-channel crosstalk, confirmed
    // separately on hardware to produce continuous closely-spaced clicks) "re-trigger" the grace
    // period forever and never actually get measured — which would silently hide exactly the
    // kind of real fault this detector exists to catch. Even with the cap, a real channel can
    // very occasionally still surface exactly one borderline click right at the cap boundary
    // (measured on hardware: the residual transient sometimes runs a little longer than the cap)
    // — accepted as a known, negligible (sub-millisecond, threshold-adjacent) residual rather
    // than raising the cap indefinitely chasing a guaranteed zero, since the existing
    // `sporadicToleranceWeightedPerMinute` mechanism already exists precisely to not penalize a
    // buffer size over one negligible blip in an otherwise clean multi-second/minute run.
    private var settleSamplesRemaining = 0
    private var settleSamplesUsed = 0
    private let settleFrameCount: Int
    private let graceExtensionFrames: Int
    private let maxSettleFrameCount: Int

    /// `expectedAmplitude` seeds the envelope tracker with the amplitude we know we sent —
    /// starting the estimate at 0 and letting it climb via EMA created a "cold start" window
    /// at the tone's onset where predicted ≈ 0 while the actual signal was already at full
    /// amplitude, making the normalized error blow up and firing spurious dropout/click
    /// incidents for the first few dozen milliseconds of every run.
    public init(channel: Int, frequency: Double, sampleRate: Double, expectedAmplitude: Float = 0.25) {
        self.channel = channel
        self.frequency = frequency
        self.sampleRate = sampleRate
        self.phaseIncrement = 2 * Double.pi * frequency / sampleRate
        self.amplitudeEstimate = expectedAmplitude
        // Enough samples for several cycles even at the lowest test frequencies (~200 Hz).
        self.phaseLockFrameTarget = max(Int(sampleRate * 0.1), Int(20 * sampleRate / frequency))
        // Measured on real hardware (WING): the transient actually lands ~17-22ms after lock,
        // not immediately at it, so this is a fixed time budget rather than a cycle count — its
        // tail is then covered by the self-extending grace period below, not a larger fixed value.
        self.settleFrameCount = Int(sampleRate * 0.02)
        self.graceExtensionFrames = Int(sampleRate * 0.01)
        self.maxSettleFrameCount = Int(sampleRate * 0.3)
    }

    public func calibrateNoiseFloor(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        var sumSq: Float = 0
        for s in samples { sumSq += s * s }
        let rms = sqrtf(sumSq / Float(samples.count))
        noiseFloor = max(rms, 0.0002)
    }

    public func process(_ samples: [Float], startTimestampSeconds: Double) {
        guard phaseLocked else {
            let needed = phaseLockFrameTarget - phaseLockBuffer.count
            let takeCount = max(min(needed, samples.count), 0)
            phaseLockBuffer.append(contentsOf: samples.prefix(takeCount))

            // Clipping is a pure amplitude test — it needs no phase reference, so it stays
            // detectable while we're still locking. Without this, anything that clipped inside
            // the phase-lock window (the first 100ms at 48kHz) went completely unreported: those
            // samples feed the lock DFT and are never handed to `processDetection`.
            for (i, sample) in samples.prefix(takeCount).enumerated() where abs(sample) > 0.99 {
                recordIncident(
                    type: .clip,
                    timestamp: startTimestampSeconds + Double(i) / sampleRate,
                    durationMs: 1000.0 / sampleRate,
                    severity: Double(abs(sample))
                )
            }

            totalSamples += Int64(takeCount)
            if phaseLockBuffer.count >= phaseLockFrameTarget {
                lockPhase()
                phaseLocked = true
                settleSamplesRemaining = settleFrameCount
                settleSamplesUsed = settleFrameCount
                if takeCount < samples.count {
                    let remainder = Array(samples[takeCount...])
                    processDetection(remainder, startTimestampSeconds: startTimestampSeconds + Double(takeCount) / sampleRate)
                }
            }
            return
        }
        processDetection(samples, startTimestampSeconds: startTimestampSeconds)
    }

    /// Single-frequency DFT over the phase-lock window to estimate the actual received
    /// amplitude and phase, so `expectedPhase` starts aligned with reality instead of assuming
    /// zero round-trip delay.
    private func lockPhase() {
        let n = phaseLockBuffer.count
        var phase = 0.0
        var sumSin = 0.0
        var sumCos = 0.0
        for sample in phaseLockBuffer {
            let s = Double(sample)
            sumSin += s * sin(phase)
            sumCos += s * cos(phase)
            phase += phaseIncrement
        }
        let sinCoeff = 2.0 / Double(n) * sumSin
        let cosCoeff = 2.0 / Double(n) * sumCos
        let amplitude = (sinCoeff * sinCoeff + cosCoeff * cosCoeff).squareRoot()
        let phi = atan2(cosCoeff, sinCoeff)

        if amplitude > Double(noiseFloor) * 3 {
            amplitudeEstimate = Float(amplitude)
        }
        var startPhase = (phi + phaseIncrement * Double(n)).truncatingRemainder(dividingBy: 2 * Double.pi)
        if startPhase < 0 { startPhase += 2 * Double.pi }
        expectedPhase = startPhase
        phaseLockBuffer = []
    }

    private func processDetection(_ samples: [Float], startTimestampSeconds: Double) {
        let clickThreshold = max(noiseFloor * 9, 0.02)
        let silenceThreshold = max(noiseFloor * 4, powf(10, -40.0 / 20.0))
        let dropoutErrorRatioThreshold = 0.35

        for (i, sample) in samples.enumerated() {
            let expectedUnit = Float(sin(expectedPhase))
            amplitudeEstimate += amplitudeEmaAlpha * (abs(sample) * 1.4142 - amplitudeEstimate)
            let predicted = amplitudeEstimate * expectedUnit
            let error = sample - predicted

            let sampleIndex = totalSamples + Int64(i)
            let t = startTimestampSeconds + Double(i) / sampleRate

            let isSettling: Bool
            if settleSamplesRemaining > 0 {
                settleSamplesRemaining -= 1
                isSettling = true
            } else if abs(sample) <= 0.99 && abs(error) > clickThreshold && settleSamplesUsed < maxSettleFrameCount {
                // The fixed timer expired but this sample would still read as a click: measured
                // on real hardware, pushing the timer later just relocates the same edge case to
                // wherever the new deadline lands, rather than eliminating it — the residual
                // transient's exact length varies a little by channel. Extend the grace period
                // instead of flagging it, so settling only ends once a sample is actually clean —
                // but capped by `maxSettleFrameCount` (checked via the cumulative `settleSamplesUsed`,
                // not just this extension) so a channel with a genuine, sustained problem can't
                // keep re-triggering this forever and go completely unmeasured.
                let grantedExtension = min(graceExtensionFrames, maxSettleFrameCount - settleSamplesUsed)
                settleSamplesRemaining = grantedExtension
                settleSamplesUsed += grantedExtension
                isSettling = true
            } else {
                isSettling = false
            }

            if abs(sample) > 0.99 {
                recordIncident(type: .clip, timestamp: t, durationMs: 1000.0 / sampleRate, severity: Double(abs(sample)))
            } else if !isSettling {
                if abs(error) > clickThreshold {
                    if !inClick {
                        inClick = true
                        clickRunLength = 0
                        clickPeakDeviation = 0
                        clickStartSample = sampleIndex
                    }
                    clickRunLength += 1
                    clickPeakDeviation = max(clickPeakDeviation, abs(error))
                } else if inClick {
                    if clickRunLength <= 20 {
                        let durationMs = Double(clickRunLength) / sampleRate * 1000.0
                        let severityDb = 20 * log10(Double(max(clickPeakDeviation, 1e-6)) / Double(max(noiseFloor, 1e-6)))
                        let ts = startTimestampSeconds + Double(clickStartSample - totalSamples) / sampleRate
                        recordIncident(type: .click, timestamp: ts, durationMs: durationMs, severity: severityDb)
                    }
                    inClick = false
                }

                let isQuiet = abs(sample) < silenceThreshold && amplitudeEstimate > silenceThreshold * 2
                if isQuiet {
                    if !inSilence {
                        inSilence = true
                        silenceRunLength = 0
                        silenceStartSample = sampleIndex
                    }
                    silenceRunLength += 1
                } else if inSilence {
                    let durationMs = Double(silenceRunLength) / sampleRate * 1000.0
                    if durationMs >= 3.0 {
                        let ts = startTimestampSeconds + Double(silenceStartSample - totalSamples) / sampleRate
                        recordIncident(type: .silence, timestamp: ts, durationMs: durationMs, severity: durationMs)
                    }
                    inSilence = false
                }
            }

            if !isSettling {
                errorWindowSumSq += Double(error * error)
                errorWindowCount += 1
                if errorWindowCount >= errorWindowSize {
                    let rmsError = sqrt(errorWindowSumSq / Double(errorWindowCount))
                    let normalized = Double(amplitudeEstimate) > 0.0001 ? rmsError / Double(amplitudeEstimate) : 0
                    if normalized > dropoutErrorRatioThreshold {
                        consecutiveElevatedWindows += 1
                        if !inDropout && consecutiveElevatedWindows >= 3 {
                            inDropout = true
                            dropoutStartSample = sampleIndex - Int64(errorWindowSize * 2)
                        }
                    } else {
                        if inDropout {
                            let skippedSamples = Double(max(sampleIndex - dropoutStartSample, 0))
                            let durationMs = skippedSamples / sampleRate * 1000.0
                            let ts = startTimestampSeconds + Double(dropoutStartSample - totalSamples) / sampleRate
                            recordIncident(type: .dropout, timestamp: ts, durationMs: durationMs, severity: skippedSamples)
                            inDropout = false
                        }
                        consecutiveElevatedWindows = 0
                    }
                    errorWindowSumSq = 0
                    errorWindowCount = 0
                }
            }

            expectedPhase += phaseIncrement
            if expectedPhase > 2 * Double.pi { expectedPhase -= 2 * Double.pi }
        }
        totalSamples += Int64(samples.count)
    }

    private func recordIncident(type: IncidentType, timestamp: Double, durationMs: Double, severity: Double) {
        if incidents.count < maxDetailedIncidents {
            incidents.append(Incident(type: type, channel: channel, timestampSeconds: max(timestamp, 0), durationMs: durationMs, severity: severity))
        } else {
            truncatedCount += 1
        }
        switch type {
        case .dropout: dropoutCount += 1
        case .silence: silenceCount += 1
        case .click: clickCount += 1
        case .clip: clipCount += 1
        }
        if type != .clip {
            incidentAffectedSamples += Int64(durationMs / 1000.0 * sampleRate)
        }
    }

    /// Records a dropout detected directly from a HAL `sampleTime` discontinuity between two
    /// captured chunks — a ground-truth fact from CoreAudio's own frame counter, independent of
    /// (and much cheaper than) the statistical content-based detection above. Complements it:
    /// this catches frames genuinely lost by the driver/transport; it can't catch a callback that
    /// arrives on schedule but with corrupted content, which is what the rest of this type is for.
    public func recordHardDropout(timestampSeconds: Double, missingFrames: Int64) {
        guard missingFrames > 0 else { return }
        let durationMs = Double(missingFrames) / sampleRate * 1000.0
        recordIncident(type: .dropout, timestamp: timestampSeconds, durationMs: durationMs, severity: Double(missingFrames))
    }

    /// Non-mutating snapshot, safe to call concurrently with `process` under the caller's own lock.
    public var liveIncidentCount: Int { incidents.count + truncatedCount }

    public func finish(totalDurationSeconds: Double) -> (incidents: [Incident], truncated: Int, channelSummary: ChannelStabilitySummary) {
        let affectedSeconds = Double(incidentAffectedSamples) / sampleRate
        let clean = totalDurationSeconds > 0 ? max(0, (totalDurationSeconds - affectedSeconds) / totalDurationSeconds * 100.0) : 100.0
        // Sine mode's phase-lock always proceeds after its warm-up window regardless of the
        // estimated amplitude's confidence (unlike the noise/WAV lock's confidence-gated
        // cross-correlation, which can give up) — so there's no failure mode to report here.
        let channelSummary = ChannelStabilitySummary(channel: channel, dropoutCount: dropoutCount, silenceCount: silenceCount, clickCount: clickCount, clipCount: clipCount, cleanPercentage: clean, verified: true)
        return (incidents, truncatedCount, channelSummary)
    }
}
