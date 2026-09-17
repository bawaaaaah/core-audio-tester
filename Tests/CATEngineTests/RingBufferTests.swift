import Testing
@testable import CATEngine

@Suite struct RingBufferTests {
    @Test func produceConsumeRoundTrip() {
        let ring = CaptureRingBuffer(slotCount: 8, maxFramesPerSlot: 4)
        let samples: [Float] = [1, 2, 3, 4]
        samples.withUnsafeBufferPointer { buf in
            ring.produce(channel: 3, sampleTime: 100, hostTime: 200, source: buf.baseAddress!, frameCount: 4)
        }
        var received: [Float] = []
        var header: CaptureRingBuffer.SlotHeader?
        let did = ring.consume { h, buf in
            header = h
            received = Array(buf)
        }
        #expect(did)
        #expect(received == samples)
        #expect(header?.channel == 3)
        #expect(header?.sampleTime == 100)
    }

    @Test func emptyConsumeReturnsFalse() {
        let ring = CaptureRingBuffer(slotCount: 4, maxFramesPerSlot: 4)
        let did = ring.consume { _, _ in }
        #expect(!did)
    }

    @Test func overflowDropsInsteadOfBlocking() {
        let ring = CaptureRingBuffer(slotCount: 2, maxFramesPerSlot: 1)
        var value: Float = 1
        for _ in 0..<5 {
            withUnsafePointer(to: &value) { ptr in
                ring.produce(channel: 0, sampleTime: 0, hostTime: 0, source: ptr, frameCount: 1)
            }
        }
        #expect(ring.droppedRecords > 0)
    }
}
