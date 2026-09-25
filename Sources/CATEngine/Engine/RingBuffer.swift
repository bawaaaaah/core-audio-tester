import Synchronization

/// Single-producer/single-consumer lock-free ring buffer that hands captured audio from the
/// realtime IOProc thread to the non-realtime drain thread.
///
/// One slot holds one channel's samples for one IO callback. The producer never allocates or
/// blocks: when the ring is full it drops the record and remembers, per channel, how many frames
/// were lost, so the next stored slot of that channel reports them in `framesLostBefore`. That
/// lets the consumer tell its own backlog apart from a real gap in the device's stream.
public final class CaptureRingBuffer: @unchecked Sendable {
    public struct SlotHeader {
        public var sampleTime: Int64 = 0
        public var hostTime: UInt64 = 0
        public var channel: Int32 = -1
        public var frameCount: Int32 = 0
        public var framesLostBefore: Int32 = 0
    }

    private let slotCount: Int
    private let maxFramesPerSlot: Int
    private let channelCapacity: Int
    private let headers: UnsafeMutablePointer<SlotHeader>
    private let samples: UnsafeMutablePointer<Float>
    /// Producer-owned: frames lost per channel since that channel's last stored slot.
    private let pendingLostFrames: UnsafeMutablePointer<Int>
    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)
    private let droppedRecordCounter = Atomic<Int>(0)

    /// `channelCapacity` must exceed the highest channel number that will be produced; channels
    /// beyond it still flow through but their losses aren't attributed.
    public init(slotCount: Int, maxFramesPerSlot: Int, channelCapacity: Int = 257) {
        self.slotCount = max(slotCount, 1)
        self.maxFramesPerSlot = max(maxFramesPerSlot, 1)
        self.channelCapacity = max(channelCapacity, 1)
        self.headers = .allocate(capacity: self.slotCount)
        self.headers.initialize(repeating: SlotHeader(), count: self.slotCount)
        self.samples = .allocate(capacity: self.slotCount * self.maxFramesPerSlot)
        self.samples.initialize(repeating: 0, count: self.slotCount * self.maxFramesPerSlot)
        self.pendingLostFrames = .allocate(capacity: self.channelCapacity)
        self.pendingLostFrames.initialize(repeating: 0, count: self.channelCapacity)
    }

    deinit {
        headers.deallocate()
        samples.deallocate()
        pendingLostFrames.deallocate()
    }

    /// Realtime-safe. Called only from the IOProc thread. Frames beyond `maxFramesPerSlot` are
    /// truncated and accounted as lost for the channel's next slot.
    @inline(__always)
    public func produce(channel: Int32, sampleTime: Int64, hostTime: UInt64, source: UnsafePointer<Float>, frameCount: Int) {
        let stored = min(max(frameCount, 0), maxFramesPerSlot)
        let channelIndex = Int(channel)
        let tracked = channelIndex >= 0 && channelIndex < channelCapacity
        let w = writeIndex.load(ordering: .relaxed)
        let r = readIndex.load(ordering: .acquiring)
        if w - r >= slotCount {
            droppedRecordCounter.wrappingAdd(1, ordering: .relaxed)
            if tracked { pendingLostFrames[channelIndex] += max(frameCount, 0) }
            return
        }
        var lostBefore = 0
        if tracked {
            lostBefore = pendingLostFrames[channelIndex]
            pendingLostFrames[channelIndex] = max(frameCount, 0) - stored
        }
        let slot = w % slotCount
        headers[slot] = SlotHeader(
            sampleTime: sampleTime, hostTime: hostTime, channel: channel,
            frameCount: Int32(stored), framesLostBefore: Int32(clamping: lostBefore)
        )
        (samples + slot * maxFramesPerSlot).update(from: source, count: stored)
        writeIndex.store(w + 1, ordering: .releasing)
    }

    /// Non-realtime. Called only from the drain thread. Returns false if empty.
    public func consume(_ body: (SlotHeader, UnsafeBufferPointer<Float>) -> Void) -> Bool {
        let r = readIndex.load(ordering: .relaxed)
        let w = writeIndex.load(ordering: .acquiring)
        guard r < w else { return false }
        let slot = r % slotCount
        let header = headers[slot]
        let buf = UnsafeBufferPointer(start: samples + slot * maxFramesPerSlot, count: Int(header.frameCount))
        body(header, buf)
        readIndex.store(r + 1, ordering: .releasing)
        return true
    }

    /// Records dropped because the ring was full, since the last `resetForNewPhase()`.
    public var droppedRecords: Int { droppedRecordCounter.load(ordering: .relaxed) }

    /// Only safe to call while the engine is stopped (no producer/consumer activity in flight).
    public func resetForNewPhase() {
        writeIndex.store(0, ordering: .relaxed)
        readIndex.store(0, ordering: .relaxed)
        droppedRecordCounter.store(0, ordering: .relaxed)
        pendingLostFrames.update(repeating: 0, count: channelCapacity)
    }
}
