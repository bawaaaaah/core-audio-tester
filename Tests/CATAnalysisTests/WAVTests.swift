import Foundation
import Testing
@testable import CATAnalysis
@testable import CATEngine

@Suite struct WAVTests {
    private func temporaryURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cat-\(UUID().uuidString).wav")
    }

    @Test func float32RoundTrip() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let interleaved: [Float] = [0.5, -0.5, 0.25, -0.25, 1, -1]
        try WAVWriter.writeFloat32(interleavedSamples: interleaved, channelCount: 2, sampleRate: 44100, to: url)
        let decoded = try WAVReader.read(url: url)
        #expect(decoded.sampleRate == 44100)
        #expect(decoded.channelCount == 2)
        #expect(decoded.frameCount == 3)
        #expect(decoded.channelSamples[0] == [0.5, 0.25, 1])
        #expect(decoded.channelSamples[1] == [-0.5, -0.25, -1])
    }

    @Test func pcm16And24AreNormalized() throws {
        func header(format: UInt16, channels: UInt16, bits: UInt16, dataSize: Int) -> [UInt8] {
            func le32(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian, Array.init) }
            func le16(_ v: UInt16) -> [UInt8] { withUnsafeBytes(of: v.littleEndian, Array.init) }
            let blockAlign = channels * bits / 8
            return Array("RIFF".utf8) + le32(UInt32(36 + dataSize)) + Array("WAVE".utf8)
                + Array("fmt ".utf8) + le32(16) + le16(format) + le16(channels) + le32(48000)
                + le32(48000 * UInt32(blockAlign)) + le16(blockAlign) + le16(bits)
                + Array("data".utf8) + le32(UInt32(dataSize))
        }
        let url16 = temporaryURL()
        let url24 = temporaryURL()
        defer {
            try? FileManager.default.removeItem(at: url16)
            try? FileManager.default.removeItem(at: url24)
        }
        // 16-bit: 16384 = 0.5, -32768 = -1.
        let pcm16: [UInt8] = [0x00, 0x40, 0x00, 0x80]
        try Data(header(format: 1, channels: 1, bits: 16, dataSize: pcm16.count) + pcm16).write(to: url16)
        #expect(try WAVReader.read(url: url16).channelSamples[0] == [0.5, -1])
        // 24-bit: 0x400000 = 0.5, 0xC00000 = -0.5.
        let pcm24: [UInt8] = [0x00, 0x00, 0x40, 0x00, 0x00, 0xC0]
        try Data(header(format: 1, channels: 1, bits: 24, dataSize: pcm24.count) + pcm24).write(to: url24)
        #expect(try WAVReader.read(url: url24).channelSamples[0] == [0.5, -0.5])
    }

    @Test func missingDataChunkIsRejected() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(Array("RIFF".utf8) + [4, 0, 0, 0] + Array("WAVE".utf8)).write(to: url)
        #expect(throws: WAVReader.WAVReaderError.self) { try WAVReader.read(url: url) }
    }

    @Test func fileReferenceMapsChannelsCyclicallyAndLoops() {
        let decoded = WAVReader.DecodedWAV(sampleRate: 48000, channelCount: 2, frameCount: 3, channelSamples: [[1, 2, 3], [-1, -2, -3]])
        let reference = WAVFileReference(decoded: decoded, outputChannelsInOrder: [1, 2, 5])
        #expect(reference.sample(channel: 1, frameIndex: 0) == 1)
        #expect(reference.sample(channel: 2, frameIndex: 1) == -2)
        #expect(reference.sample(channel: 5, frameIndex: 2) == 3)     // third output wraps to file channel 0
        #expect(reference.sample(channel: 1, frameIndex: 4) == 2)     // loops
        #expect(reference.sample(channel: 3, frameIndex: 0) == 0)     // not routed
        #expect(reference.sample(channel: 99, frameIndex: 0) == 0)
    }
}
