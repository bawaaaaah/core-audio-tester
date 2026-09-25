import CATEngine

/// Per-channel incident bookkeeping: a detailed (capped) list for the report, true per-type
/// counts, and the share of the pass covered by incidents.
final class IncidentLog {
    static let maxDetailedIncidents = 2000

    let channel: Int
    private let sampleRate: Double
    private(set) var incidents: [Incident] = []
    private(set) var truncatedCount = 0
    private(set) var dropoutCount = 0
    private(set) var silenceCount = 0
    private(set) var clickCount = 0
    private(set) var clipCount = 0
    /// Frames covered by at least one non-clip incident. Overlapping incidents (a silence gap is
    /// usually also a dropout) are counted once, using a high-water mark — exact as long as
    /// incidents are recorded roughly in start order, which is how the detector emits them.
    private(set) var affectedFrames: Int64 = 0
    private var coveredUntil = Int64.min
    /// Called after each record with the incident's type and start timestamp.
    var onRecord: ((IncidentType, Double) -> Void)?

    init(channel: Int, sampleRate: Double) {
        self.channel = channel
        self.sampleRate = sampleRate
    }

    /// Audio incidents so far (clips excluded, matching `StabilityResult.totalIncidentCount`).
    var incidentCount: Int { dropoutCount + silenceCount + clickCount }

    /// `startIndex` is in frames since the start of the pass's input timeline.
    func record(_ type: IncidentType, startIndex: Int64, frameCount: Int64, severity: Double) {
        let timestamp = max(Double(startIndex) / sampleRate, 0)
        let frames = max(frameCount, 0)
        if incidents.count < Self.maxDetailedIncidents {
            incidents.append(Incident(
                type: type,
                channel: channel,
                timestampSeconds: timestamp,
                durationMs: Double(frames) / sampleRate * 1000.0,
                severity: severity
            ))
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
            let end = startIndex + frames
            let from = max(startIndex, coveredUntil)
            if end > from { affectedFrames += end - from }
            coveredUntil = max(coveredUntil, end)
        }
        onRecord?(type, timestamp)
    }

    func cleanPercentage(totalDurationSeconds: Double) -> Double {
        guard totalDurationSeconds > 0 else { return 100.0 }
        let affectedSeconds = Double(affectedFrames) / sampleRate
        return max(0, (totalDurationSeconds - affectedSeconds) / totalDurationSeconds * 100.0)
    }
}
