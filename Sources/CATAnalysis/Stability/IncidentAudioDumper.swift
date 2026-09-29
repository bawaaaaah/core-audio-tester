import CATEngine
import Foundation

/// Diagnostic aid (`--dump-incident-audio <dir>`): writes the audio around a stability incident to
/// a stereo WAV file (left = captured, right = expected reference), so what the detector flagged can
/// be listened to and inspected sample by sample.
///
/// Files are named `<pass>_chNN_<type>_t<seconds>_<n>.wav`, where the pass label identifies the
/// buffer size and load level. Writes happen on a background queue, off the capture drain thread.
public final class IncidentAudioDumper: @unchecked Sendable {
    private let directory: URL
    private let sampleRate: Double
    private let passLabel: String
    private let maxDumpsPerChannel: Int
    private var dumpCountByChannel: [Int: Int] = [:]
    private let writeQueue = DispatchQueue(label: "core-audio-tester.incident-dumps")

    public init(directory: String, sampleRate: Double, passLabel: String, maxDumpsPerChannel: Int = 5) {
        self.directory = URL(fileURLWithPath: directory)
        self.sampleRate = sampleRate
        self.passLabel = passLabel
        self.maxDumpsPerChannel = maxDumpsPerChannel
        do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        } catch {
            Log.warn("impossible de créer le dossier des extraits audio \"\(directory)\" : \(error.localizedDescription)")
        }
    }

    /// Called from the drain thread only.
    public func shouldDump(channel: Int) -> Bool {
        (dumpCountByChannel[channel] ?? 0) < maxDumpsPerChannel
    }

    /// `captured` and `expected` must be sample-aligned. Called from the drain thread only.
    public func dump(channel: Int, incidentType: String, timestampSeconds: Double, captured: [Float], expected: [Float]) {
        let count = dumpCountByChannel[channel, default: 0]
        dumpCountByChannel[channel] = count + 1
        let channelLabel = String(format: "%02d", channel)
        let timeLabel = String(format: "%.3f", max(timestampSeconds, 0))
        let url = directory.appendingPathComponent("\(passLabel)_ch\(channelLabel)_\(incidentType)_t\(timeLabel)_\(count).wav")
        let rate = sampleRate
        writeQueue.async {
            var interleaved = [Float](repeating: 0, count: captured.count * 2)
            for i in 0..<captured.count {
                interleaved[i * 2] = captured[i]
                interleaved[i * 2 + 1] = i < expected.count ? expected[i] : 0
            }
            do {
                try WAVWriter.writeFloat32(interleavedSamples: interleaved, channelCount: 2, sampleRate: rate, to: url)
            } catch {
                Log.warn("échec de l'écriture de \(url.lastPathComponent) : \(error.localizedDescription)")
            }
        }
    }

    /// Blocks until every queued file is on disk.
    public func waitUntilWritten() {
        writeQueue.sync {}
    }
}
