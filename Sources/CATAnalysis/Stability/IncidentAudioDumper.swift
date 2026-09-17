import Foundation

/// Diagnostic aid, opt-in via `--dump-incident-audio <dir>`: writes the raw captured audio
/// surrounding a stability incident to a WAV file, so the exact samples the detector flagged can
/// be inspected/listened to directly instead of trusting the incident classification alone.
public final class IncidentAudioDumper {
    private let directory: URL
    private let sampleRate: Double
    private let maxDumpsPerChannel: Int
    private var dumpCountByChannel: [Int: Int] = [:]

    public init(directory: String, sampleRate: Double, maxDumpsPerChannel: Int = 5) {
        self.directory = URL(fileURLWithPath: directory)
        self.sampleRate = sampleRate
        self.maxDumpsPerChannel = maxDumpsPerChannel
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    public func shouldDump(channel: Int) -> Bool {
        (dumpCountByChannel[channel] ?? 0) < maxDumpsPerChannel
    }

    /// `captured` and `expected` must be the same length and sample-aligned: written as a stereo
    /// WAV (L=captured, R=expected) so both can be compared sample-for-sample in any audio editor.
    public func dump(channel: Int, incidentType: String, timestampSeconds: Double, captured: [Float], expected: [Float]) {
        let count = dumpCountByChannel[channel, default: 0]
        dumpCountByChannel[channel] = count + 1
        let filename = String(format: "ch%02d_%@_t%.3f_%d.wav", channel, incidentType, max(timestampSeconds, 0), count)
        let url = directory.appendingPathComponent(filename)
        var interleaved = [Float](repeating: 0, count: captured.count * 2)
        for i in 0..<captured.count {
            interleaved[i * 2] = captured[i]
            interleaved[i * 2 + 1] = i < expected.count ? expected[i] : 0
        }
        try? WAVWriter.writeFloat32(interleavedSamples: interleaved, channelCount: 2, sampleRate: sampleRate, to: url)
    }
}
