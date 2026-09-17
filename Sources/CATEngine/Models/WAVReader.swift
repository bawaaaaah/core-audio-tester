import Foundation

/// Reads a WAVE (RIFF/WAVE) file into de-interleaved Float32 samples normalized to [-1, 1].
/// Supports PCM (8/16/24/32-bit) and IEEE float (32/64-bit) `fmt ` chunks, including
/// WAVE_FORMAT_EXTENSIBLE (common from DAW exports for >2 channels or >16-bit) — everything
/// downstream only ever sees normalized Float32, regardless of the file's native bit depth.
public enum WAVReader {
    public struct DecodedWAV: Sendable {
        public let sampleRate: Double
        public let channelCount: Int
        public let frameCount: Int
        /// De-interleaved: `channelSamples[channel][frame]`.
        public let channelSamples: [[Float]]
    }

    public enum WAVReaderError: Error, CustomStringConvertible {
        case unreadable(path: String, reason: String)
        case malformed(path: String, reason: String)
        case unsupportedFormat(path: String, reason: String)
        case empty(path: String)

        public var description: String {
            switch self {
            case .unreadable(let path, let reason):
                return "Could not read WAV file \"\(path)\": \(reason)"
            case .malformed(let path, let reason):
                return "WAV file \"\(path)\" is invalid: \(reason)"
            case .unsupportedFormat(let path, let reason):
                return "WAV file \"\(path)\" uses an unsupported format: \(reason)"
            case .empty(let path):
                return "WAV file \"\(path)\" contains no samples."
            }
        }
    }

    public static func read(url: URL) throws -> DecodedWAV {
        let path = url.path
        let bytes: [UInt8]
        do {
            bytes = [UInt8](try Data(contentsOf: url))
        } catch {
            throw WAVReaderError.unreadable(path: path, reason: error.localizedDescription)
        }
        guard bytes.count >= 12,
              bytes[0..<4].elementsEqual(Array("RIFF".utf8)),
              bytes[8..<12].elementsEqual(Array("WAVE".utf8))
        else {
            throw WAVReaderError.malformed(path: path, reason: "missing RIFF/WAVE header")
        }

        func readU16(_ at: Int) -> UInt16 {
            UInt16(bytes[at]) | (UInt16(bytes[at + 1]) << 8)
        }
        func readU32(_ at: Int) -> UInt32 {
            UInt32(bytes[at]) | (UInt32(bytes[at + 1]) << 8) | (UInt32(bytes[at + 2]) << 16) | (UInt32(bytes[at + 3]) << 24)
        }

        var offset = 12
        var audioFormat: UInt16?
        var numChannels: Int?
        var sampleRate: Double?
        var bitsPerSample: Int?
        var dataRange: Range<Int>?

        // RIFF chunks: 4-byte ASCII tag, 4-byte little-endian size, then the body — padded to an
        // even byte count, so an odd-sized chunk is followed by one skipped pad byte. Any chunk
        // besides "fmt " and "data" (LIST, fact, bext, JUNK, ...) is skipped by size alone.
        while offset + 8 <= bytes.count {
            let tag = String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
            let chunkSize = Int(readU32(offset + 4))
            let bodyStart = offset + 8
            guard bodyStart + chunkSize <= bytes.count else { break }

            if tag == "fmt " {
                guard chunkSize >= 16 else {
                    throw WAVReaderError.malformed(path: path, reason: "\"fmt \" chunk too short")
                }
                let format = readU16(bodyStart)
                if format == 0xFFFE {
                    // WAVE_FORMAT_EXTENSIBLE: the real codec is the first 2 bytes of the 16-byte
                    // SubFormat GUID living at offset 24 within the extended fmt chunk.
                    guard chunkSize >= 40 else {
                        throw WAVReaderError.malformed(path: path, reason: "extended (EXTENSIBLE) \"fmt \" chunk too short")
                    }
                    audioFormat = readU16(bodyStart + 24)
                } else {
                    audioFormat = format
                }
                numChannels = Int(readU16(bodyStart + 2))
                sampleRate = Double(readU32(bodyStart + 4))
                bitsPerSample = Int(readU16(bodyStart + 14))
            } else if tag == "data" {
                dataRange = bodyStart..<(bodyStart + chunkSize)
            }

            offset = bodyStart + chunkSize + (chunkSize % 2)
        }

        guard let audioFormat, let numChannels, numChannels > 0, let sampleRate, let bitsPerSample, bitsPerSample > 0 else {
            throw WAVReaderError.malformed(path: path, reason: "missing or incomplete \"fmt \" chunk")
        }
        guard let dataRange else {
            throw WAVReaderError.malformed(path: path, reason: "missing \"data\" chunk")
        }

        let bytesPerSample = bitsPerSample / 8
        let blockAlign = bytesPerSample * numChannels
        guard blockAlign > 0 else {
            throw WAVReaderError.unsupportedFormat(path: path, reason: "invalid block alignment")
        }
        let frameCount = dataRange.count / blockAlign
        guard frameCount > 0 else {
            throw WAVReaderError.empty(path: path)
        }

        func decodeSample(byteOffset: Int) throws -> Float {
            switch (audioFormat, bitsPerSample) {
            case (1, 8):
                return (Float(bytes[byteOffset]) - 128) / 128.0
            case (1, 16):
                return Float(Int16(bitPattern: readU16(byteOffset))) / 32_768.0
            case (1, 24):
                let b0 = Int32(bytes[byteOffset])
                let b1 = Int32(bytes[byteOffset + 1])
                let b2 = Int32(bytes[byteOffset + 2])
                var v = b0 | (b1 << 8) | (b2 << 16)
                if v & 0x0080_0000 != 0 { v |= Int32(bitPattern: 0xFF00_0000) }
                return Float(v) / 8_388_608.0
            case (1, 32):
                return Float(Int32(bitPattern: readU32(byteOffset))) / 2_147_483_648.0
            case (3, 32):
                return Float(bitPattern: readU32(byteOffset))
            case (3, 64):
                let bits = UInt64(readU32(byteOffset)) | (UInt64(readU32(byteOffset + 4)) << 32)
                return Float(Double(bitPattern: bits))
            default:
                throw WAVReaderError.unsupportedFormat(path: path, reason: "codec \(audioFormat) at \(bitsPerSample) bits is not supported")
            }
        }

        var channelSamples = [[Float]](repeating: [Float](repeating: 0, count: frameCount), count: numChannels)
        let base = dataRange.lowerBound
        for frame in 0..<frameCount {
            let frameStart = base + frame * blockAlign
            for ch in 0..<numChannels {
                channelSamples[ch][frame] = try decodeSample(byteOffset: frameStart + ch * bytesPerSample)
            }
        }

        return DecodedWAV(sampleRate: sampleRate, channelCount: numChannels, frameCount: frameCount, channelSamples: channelSamples)
    }
}
