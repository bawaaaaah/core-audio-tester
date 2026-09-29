import Testing
@testable import CATEngine

@Suite struct RingBufferTests {
    private func produce(_ ring: CaptureRingBuffer, channel: Int32, sampleTime: Int64, frames: [Float]) {
        frames.withUnsafeBufferPointer { buf in
            ring.produce(channel: channel, sampleTime: sampleTime, hostTime: 0, source: buf.baseAddress!, frameCount: frames.count)
        }
    }

    private func drain(_ ring: CaptureRingBuffer) -> [(CaptureRingBuffer.SlotHeader, [Float])] {
        var out: [(CaptureRingBuffer.SlotHeader, [Float])] = []
        while ring.consume({ header, samples in out.append((header, Array(samples))) }) {}
        return out
    }

    @Test func produceConsumeRoundTrip() {
        let ring = CaptureRingBuffer(slotCount: 8, maxFramesPerSlot: 4)
        produce(ring, channel: 3, sampleTime: 100, frames: [1, 2, 3, 4])
        let records = drain(ring)
        #expect(records.count == 1)
        #expect(records[0].1 == [1, 2, 3, 4])
        #expect(records[0].0.channel == 3)
        #expect(records[0].0.sampleTime == 100)
        #expect(records[0].0.framesLostBefore == 0)
    }

    @Test func emptyConsumeReturnsFalse() {
        let ring = CaptureRingBuffer(slotCount: 4, maxFramesPerSlot: 4)
        #expect(!ring.consume { _, _ in })
    }

    @Test func overflowDropsAndReportsLostFramesOnTheNextSlotOfThatChannel() {
        let ring = CaptureRingBuffer(slotCount: 2, maxFramesPerSlot: 4, channelCapacity: 8)
        produce(ring, channel: 1, sampleTime: 0, frames: [1, 1, 1, 1])
        produce(ring, channel: 2, sampleTime: 0, frames: [2, 2, 2, 2])
        produce(ring, channel: 1, sampleTime: 4, frames: [1, 1, 1, 1])   // dropped: ring full
        produce(ring, channel: 1, sampleTime: 8, frames: [1, 1, 1, 1])   // dropped: ring full
        #expect(ring.droppedRecords == 2)
        _ = drain(ring)
        produce(ring, channel: 2, sampleTime: 4, frames: [2, 2, 2, 2])
        produce(ring, channel: 1, sampleTime: 12, frames: [1, 1, 1, 1])
        let records = drain(ring)
        #expect(records.count == 2)
        #expect(records[0].0.channel == 2 && records[0].0.framesLostBefore == 0)
        #expect(records[1].0.channel == 1 && records[1].0.framesLostBefore == 8)
    }

    @Test func truncatedFramesCountAsLostBeforeTheNextSlot() {
        let ring = CaptureRingBuffer(slotCount: 4, maxFramesPerSlot: 2, channelCapacity: 4)
        produce(ring, channel: 1, sampleTime: 0, frames: [1, 2, 3])
        produce(ring, channel: 1, sampleTime: 3, frames: [4, 5])
        let records = drain(ring)
        #expect(records[0].1 == [1, 2])
        #expect(records[1].0.framesLostBefore == 1)
    }

    @Test func resetClearsCountersAndPendingLosses() {
        let ring = CaptureRingBuffer(slotCount: 1, maxFramesPerSlot: 1, channelCapacity: 4)
        produce(ring, channel: 1, sampleTime: 0, frames: [1])
        produce(ring, channel: 1, sampleTime: 1, frames: [1])
        #expect(ring.droppedRecords == 1)
        ring.resetForNewPhase()
        #expect(ring.droppedRecords == 0)
        produce(ring, channel: 1, sampleTime: 0, frames: [1])
        #expect(drain(ring).first?.0.framesLostBefore == 0)
    }
}
