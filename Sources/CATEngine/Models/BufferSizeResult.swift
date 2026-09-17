public struct HALLatencyInfo: Sendable, Codable {
    public var inputDeviceLatencyFrames: UInt32
    public var outputDeviceLatencyFrames: UInt32
    public var inputSafetyOffsetFrames: UInt32
    public var outputSafetyOffsetFrames: UInt32
    public var inputStreamLatencyFrames: UInt32
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

    /// True when too few repetitions correlated cleanly to trust this pair's numbers.
    public var isUnreliable: Bool {
        repetitionsDetected == 0 || Double(ambiguousCount) > Double(repetitionsRequested) * 0.5
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
    /// False when this channel never locked onto its reference signal (noise/WAV modes only —
    /// sine mode has no comparable lock-confidence gate and is always `true`): with nothing ever
    /// compared, `cleanPercentage` reads 100% by construction even though nothing was verified.
    /// Downstream code must treat an unverified channel as untrusted, not as confirmed-clean.
    public var verified: Bool

    public init(channel: Int, dropoutCount: Int, silenceCount: Int, clickCount: Int, clipCount: Int, cleanPercentage: Double, verified: Bool = true) {
        self.channel = channel
        self.dropoutCount = dropoutCount
        self.silenceCount = silenceCount
        self.clickCount = clickCount
        self.clipCount = clipCount
        self.cleanPercentage = cleanPercentage
        self.verified = verified
    }
}

public struct StabilityResult: Sendable, Codable {
    public var durationSeconds: Double
    public var overloadCount: Int
    public var incidents: [Incident]
    public var truncatedIncidentCount: Int
    public var perChannel: [ChannelStabilitySummary]
    public var correlatedCount: Int
    public var silentOverloadCount: Int
    public var unexplainedGlitchCount: Int
    public var droppedRingBufferRecords: Int

    public init(
        durationSeconds: Double,
        overloadCount: Int,
        incidents: [Incident],
        truncatedIncidentCount: Int,
        perChannel: [ChannelStabilitySummary],
        correlatedCount: Int,
        silentOverloadCount: Int,
        unexplainedGlitchCount: Int,
        droppedRingBufferRecords: Int
    ) {
        self.durationSeconds = durationSeconds
        self.overloadCount = overloadCount
        self.incidents = incidents
        self.truncatedIncidentCount = truncatedIncidentCount
        self.perChannel = perChannel
        self.correlatedCount = correlatedCount
        self.silentOverloadCount = silentOverloadCount
        self.unexplainedGlitchCount = unexplainedGlitchCount
        self.droppedRingBufferRecords = droppedRingBufferRecords
    }

    public var totalIncidentCount: Int {
        incidents.filter { $0.type != .clip }.count + truncatedIncidentCount
    }

    public var minCleanPercentage: Double {
        perChannel.map(\.cleanPercentage).min() ?? 100.0
    }

    /// False if any channel never locked onto its reference signal — see `ChannelStabilitySummary.verified`.
    public var allChannelsVerified: Bool {
        perChannel.allSatisfy(\.verified)
    }

    public var meanCleanPercentage: Double {
        guard !perChannel.isEmpty else { return 100.0 }
        return perChannel.map(\.cleanPercentage).reduce(0, +) / Double(perChannel.count)
    }

    /// Severity-weighted incidents per minute (click=1, silence=2, dropout=3; clips excluded).
    public func weightedIncidentRatePerMinute(minutes: Double) -> Double {
        guard minutes > 0 else { return 0 }
        let weighted = incidents.reduce(0.0) { total, incident in
            switch incident.type {
            case .click: return total + 1.0
            case .silence: return total + 2.0
            case .dropout: return total + 3.0
            case .clip: return total
            }
        }
        return (weighted + Double(truncatedIncidentCount) * 1.0) / minutes
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

    public var meanLatencyMs: Double {
        guard !pingResults.isEmpty else { return 0 }
        return pingResults.map(\.meanMs).reduce(0, +) / Double(pingResults.count)
    }

    public var worstLatencyMs: Double {
        pingResults.map(\.maxMs).max() ?? 0
    }

    public var isFullyClean: Bool {
        stability.overloadCount == 0 && stability.totalIncidentCount == 0 && stability.allChannelsVerified
    }

    public var hasAmbiguousPairs: Bool {
        pingResults.contains { $0.isUnreliable }
    }

    /// Highest simulated CPU load level (among those tested, 0 meaning the idle baseline) that
    /// stayed fully clean, in ascending order of confidence — `nil` if even the idle baseline had
    /// incidents (in which case CPU load isn't the relevant variable at all).
    public var highestCleanCPULoadPercent: Int? {
        guard isFullyClean else { return nil }
        var best = 0
        for loaded in loadedStability.sorted(by: { $0.cpuLoadPercent < $1.cpuLoadPercent }) {
            guard loaded.stability.overloadCount == 0 && loaded.stability.totalIncidentCount == 0 && loaded.stability.allChannelsVerified else { break }
            best = loaded.cpuLoadPercent
        }
        return best
    }
}
