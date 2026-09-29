import Foundation

/// Writes raw Float32 PCM samples as a WAVE file (IEEE float, no conversion/clamping) — used to
/// dump the exact captured audio around a stability incident for offline inspection. Interleaved
/// multi-channel output (e.g. captured on one channel, the detector's expected reference on
/// another) lets both be compared sample-for-sample in any audio editor.
public enum WAVWriter {
    public static func writeFloat32(interleavedSamples samples: [Float], channelCount: Int, sampleRate: Double, to url: URL) throws {
        let numChannels = UInt16(channelCount)
        let bitsPerSample: UInt16 = 32
        let byteRate = UInt32(sampleRate) * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)
        let dataSize = UInt32(samples.count * MemoryLayout<Float>.size)
        let audioFormat: UInt16 = 3 // WAVE_FORMAT_IEEE_FLOAT

        var data = Data()
        data.append(ascii: "RIFF")
        data.appendLE(UInt32(36) + dataSize)
        data.append(ascii: "WAVE")
        data.append(ascii: "fmt ")
        data.appendLE(UInt32(16))
        data.appendLE(audioFormat)
        data.appendLE(numChannels)
        data.appendLE(UInt32(sampleRate))
        data.appendLE(byteRate)
        data.appendLE(blockAlign)
        data.appendLE(bitsPerSample)
        data.append(ascii: "data")
        data.appendLE(dataSize)
        samples.withUnsafeBufferPointer { buf in
            data.append(UnsafeRawBufferPointer(buf).bindMemory(to: UInt8.self))
        }

        try data.write(to: url)
    }
}

private extension Data {
    mutating func append(ascii string: String) {
        append(contentsOf: string.utf8)
    }

    mutating func appendLE(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
