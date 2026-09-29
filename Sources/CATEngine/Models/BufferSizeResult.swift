public struct HALLatencyInfo: Sendable, Codable {
    public var inputDeviceLatencyFrames: UInt32
    public var outputDeviceLatencyFrames: UInt32
    public var inputSafetyOffsetFrames: UInt32
    public var outputSafetyOffsetFrames: UInt32
    /// Largest stream latency among the streams carrying the selected input channels.
    public var inputStreamLatencyFrames: UInt32
    /// Largest stream latency among the streams carrying the selected output channels.
    public var outputStreamLatencyFrames: UInt32
    public var bufferFrames: UInt32

    public init(
        inputDeviceLatencyFrames: UInt32,
        outputDeviceLatencyFrames: UInt32,
        inputSafetyOffsetFrames: UInt32,
        outputSafetyOffsetFrames: UInt32,
        inputStreamLatencyFrames: UInt32,
        outputStreamLatencyFrames: UInt32,
        bufferFrames: UInt32
    ) {
        self.inputDeviceLatencyFrames = inputDeviceLatencyFrames
        self.outputDeviceLatencyFrames = outputDeviceLatencyFrames
        self.inputSafetyOffsetFrames = inputSafetyOffsetFrames
        self.outputSafetyOffsetFrames = outputSafetyOffsetFrames
        self.inputStreamLatencyFrames = inputStreamLatencyFrames
        self.outputStreamLatencyFrames = outputStreamLatencyFrames
        self.bufferFrames = bufferFrames
    }

    /// Theoretical round-trip: two buffer periods (in+out) plus the fixed device/stream/safety-offset terms.
    public var theoreticalRoundTripFrames: UInt32 {
        outputDeviceLatencyFrames + outputStreamLatencyFrames + outputSafetyOffsetFrames + bufferFrames
            + inputDeviceLatencyFrames + inputStreamLatencyFrames + inputSafetyOffsetFrames + bufferFrames
    }

    public func theoreticalRoundTripMs(sampleRate: Double) -> Double {
        Double(theoreticalRoundTripFrames) / sampleRate * 1000.0
    }
}

public struct PairLatencyResult: Sendable, Codable {
    public var pair: ChannelPair
    public var repetitionsRequested: Int
    public var repetitionsDetected: Int
    public var meanMs: Double
    public var medianMs: Double
    public var minMs: Double
    public var maxMs: Double
    public var stddevMs: Double
    public var ambiguousCount: Int
    public var outlierCount: Int

    public init(
        pair: ChannelPair,
        repetitionsRequested: Int,
        repetitionsDetected: Int,
        meanMs: Double,
        medianMs: Double,
        minMs: Double,
        maxMs: Double,
        stddevMs: Double,
        ambiguousCount: Int,
        outlierCount: Int
    ) {
        self.pair = pair
        self.repetitionsRequested = repetitionsRequested
        self.repetitionsDetected = repetitionsDetected
        self.meanMs = meanMs
        self.medianMs = medianMs
        self.minMs = minMs
        self.maxMs = maxMs
        self.stddevMs = stddevMs
        self.ambiguousCount = ambiguousCount
        self.outlierCount = outlierCount
    }

    /// True when no repetition was detected at all — the statistics above are then meaningless.
    public var hasMeasurement: Bool { repetitionsDetected > 0 }

    /// True when too few repetitions correlated cleanly to trust this pair's numbers.
    public var isUnreliable: Bool {
        !hasMeasurement || Double(ambiguousCount) > Double(repetitionsRequested) * 0.5
    }
}

public enum IncidentType: String, Sendable, Codable {
    case dropout
    case silence
    case click
    case clip
}

public struct Incident: Sendable, Codable {
    public var type: IncidentType
    public var channel: Int
    public var timestampSeconds: Double
    public var durationMs: Double
    public var severity: Double

    public init(type: IncidentType, channel: Int, timestampSeconds: Double, durationMs: Double, severity: Double) {
        self.type = type
        self.channel = channel
        self.timestampSeconds = timestampSeconds
        self.durationMs = durationMs
        self.severity = severity
    }
}

public struct ChannelStabilitySummary: Sendable, Codable {
    public var channel: Int
    public var dropoutCount: Int
    public var silenceCount: Int
    public var clickCount: Int
    public var clipCount: Int
    public var cleanPercentage: Double
    /// False when the channel never locked onto its reference signal (no signal, wrong routing, or
    /// a loopback that isn't transparent enough for an exact comparison). Nothing was compared,
    /// so `cleanPercentage` then says nothing about the channel's health.
    public var verified: Bool
    /// Why the channel couldn't be verified, when `verified` is false.
    public var unverifiedReason: String?
    /// Times the detector lost the reference mid-pass (after a slip or a long dropout) and had to
    /// lock onto it again.
    public var reacquisitionCount: Int

    public init(
        channel: Int,
        dropoutCount: Int,
        silenceCount: Int,
        clickCount: Int,
        clipCount: Int,
        cleanPercentage: Double,
        verified: Bool = true,
        unverifiedReason: String? = nil,
        reacquisitionCount: Int = 0
    ) {
        self.channel = channel
        self.dropoutCount = dropoutCount
        self.silenceCount = silenceCount
        self.clickCount = clickCount
        self.clipCount = clipCount
        self.cleanPercentage = cleanPercentage
        self.verified = verified
        self.unverifiedReason = unverifiedReason
        self.reacquisitionCount = reacquisitionCount
    }

    /// Clips are reported but not counted as incidents: they mean the level is too hot, not that
    /// the buffer size is too small.
    public var incidentCount: Int { dropoutCount + silenceCount + clickCount }
}

public struct StabilityResult: Sendable, Codable {
    public var plannedDurationSeconds: Double
    public var durationSeconds: Double
    public var overloadCount: Int
    public var ioStoppedAbnormallyCount: Int
    /// Detailed incidents, capped per channel; per-type counts live in `perChannel`.
    public var incidents: [Incident]
    public var truncatedIncidentCount: Int
    public var perChannel: [ChannelStabilitySummary]
    /// Capture records the ring buffer dropped because analysis fell behind — audio that was
    /// delivered by the device but never checked.
    public var droppedRingBufferRecords: Int
    /// The pass was cut short (Ctrl-C).
    public var wasInterrupted: Bool

    public init(
        plannedDurationSeconds: Double,
        durationSeconds: Double,
        overloadCount: Int,
        ioStoppedAbnormallyCount: Int,
        incidents: [Incident],
        truncatedIncidentCount: Int,
        perChannel: [ChannelStabilitySummary],
        droppedRingBufferRecords: Int,
        wasInterrupted: Bool
    ) {
        self.plannedDurationSeconds = plannedDurationSeconds
        self.durationSeconds = durationSeconds
        self.overloadCount = overloadCount
        self.ioStoppedAbnormallyCount = ioStoppedAbnormallyCount
        self.incidents = incidents
        self.truncatedIncidentCount = truncatedIncidentCount
        self.perChannel = perChannel
        self.droppedRingBufferRecords = droppedRingBufferRecords
        self.wasInterrupted = wasInterrupted
    }

    public var dropoutCount: Int { perChannel.reduce(0) { $0 + $1.dropoutCount } }
    public var silenceCount: Int { perChannel.reduce(0) { $0 + $1.silenceCount } }
    public var clickCount: Int { perChannel.reduce(0) { $0 + $1.clickCount } }
    public var clipCount: Int { perChannel.reduce(0) { $0 + $1.clipCount } }

    /// Audio incidents (dropouts, silences, clicks) across all channels — clips excluded.
    public var totalIncidentCount: Int { dropoutCount + silenceCount + clickCount }

    public var minCleanPercentage: Double {
        perChannel.map(\.cleanPercentage).min() ?? 100.0
    }

    public var meanCleanPercentage: Double {
        guard !perChannel.isEmpty else { return 100.0 }
        return perChannel.map(\.cleanPercentage).reduce(0, +) / Double(perChannel.count)
    }

    /// False if any channel never locked onto its reference signal — see `ChannelStabilitySummary.verified`.
    public var allChannelsVerified: Bool {
        perChannel.allSatisfy(\.verified)
    }

    public var completedPlannedDuration: Bool {
        !wasInterrupted && durationSeconds + 0.25 >= plannedDurationSeconds
    }

    /// No overload, no abnormal IO stop and no audio incident.
    public var isClean: Bool {
        overloadCount == 0 && ioStoppedAbnormallyCount == 0 && totalIncidentCount == 0
    }

    /// Every channel was verified, no captured audio went unchecked and the pass ran its full
    /// duration — without this, "clean" only means "nothing was seen".
    public var isTrustworthy: Bool {
        allChannelsVerified && droppedRingBufferRecords == 0 && completedPlannedDuration
    }

    public var isFullyClean: Bool { isClean && isTrustworthy }

    /// Severity-weighted events per minute: click 1, silence 2, dropout 3, overload 3, abnormal IO stop 3.
    public func weightedIncidentRatePerMinute() -> Double {
        let minutes = max(durationSeconds / 60.0, 1.0 / 60.0)
        let weighted = Double(clickCount)
            + 2.0 * Double(silenceCount)
            + 3.0 * Double(dropoutCount)
            + 3.0 * Double(overloadCount)
            + 3.0 * Double(ioStoppedAbnormallyCount)
        return weighted / minutes
    }
}

/// One stability pass repeated under a simulated aggregate CPU load, so a buffer size that's
/// clean at idle can be checked for how much CPU contention it actually tolerates.
public struct LoadedStabilityResult: Sendable, Codable {
    public var cpuLoadPercent: Int
    public var memoryPressureActive: Bool
    public var stability: StabilityResult

    public init(cpuLoadPercent: Int, memoryPressureActive: Bool = false, stability: StabilityResult) {
        self.cpuLoadPercent = cpuLoadPercent
        self.memoryPressureActive = memoryPressureActive
        self.stability = stability
    }
}

public struct BufferSizeResult: Sendable, Codable {
    public var requestedFrames: UInt32
    public var grantedFrames: UInt32
    public var sampleRate: Double
    public var halLatency: HALLatencyInfo
    public var pingResults: [PairLatencyResult]
    public var stability: StabilityResult
    public var loadedStability: [LoadedStabilityResult]
    /// Some pass of this buffer size was cut short (Ctrl-C).
    public var wasInterrupted: Bool

    public init(
        requestedFrames: UInt32,
        grantedFrames: UInt32,
        sampleRate: Double,
        halLatency: HALLatencyInfo,
        pingResults: [PairLatencyResult],
        stability: StabilityResult,
        loadedStability: [LoadedStabilityResult] = [],
        wasInterrupted: Bool = false
    ) {
        self.requestedFrames = requestedFrames
        self.grantedFrames = grantedFrames
        self.sampleRate = sampleRate
        self.halLatency = halLatency
        self.pingResults = pingResults
        self.stability = stability
        self.loadedStability = loadedStability
        self.wasInterrupted = wasInterrupted
    }

    /// Pairs whose latency was actually measured; pairs with no detection would otherwise drag
    /// the averages toward zero.
    public var measuredPingResults: [PairLatencyResult] { pingResults.filter(\.hasMeasurement) }

    public var hasLatencyMeasurement: Bool { !measuredPingResults.isEmpty }

    public var meanLatencyMs: Double {
        let measured = measuredPingResults
        guard !measured.isEmpty else { return 0 }
        return measured.map(\.meanMs).reduce(0, +) / Double(measured.count)
    }

    public var worstLatencyMs: Double {
        measuredPingResults.map(\.maxMs).max() ?? 0
    }

    public var bestLatencyMs: Double {
        measuredPingResults.map(\.minMs).min() ?? 0
    }

    public var meanJitterMs: Double {
        let measured = measuredPingResults
        guard !measured.isEmpty else { return 0 }
        return measured.map(\.stddevMs).reduce(0, +) / Double(measured.count)
    }

    public var hasUnreliablePings: Bool {
        pingResults.contains { $0.isUnreliable }
    }

    /// Clean and trustworthy at idle.
    public var isFullyClean: Bool { stability.isFullyClean }

    /// Clean and trustworthy under every simulated load level tested (vacuously true if none).
    public var isCleanUnderLoad: Bool {
        loadedStability.allSatisfy { $0.stability.isFullyClean }
    }

    /// Highest simulated CPU load level (0 meaning the idle baseline) up to which every tested
    /// level stayed fully clean — `nil` if even the idle baseline wasn't.
    public var highestCleanCPULoadPercent: Int? {
        guard isFullyClean else { return nil }
        var best = 0
        for loaded in loadedStability.sorted(by: { $0.cpuLoadPercent < $1.cpuLoadPercent }) {
            guard loaded.stability.isFullyClean else { break }
            best = loaded.cpuLoadPercent
        }
        return best
    }
}
