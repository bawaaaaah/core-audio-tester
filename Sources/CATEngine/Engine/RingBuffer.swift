import Synchronization

/// Single-producer/single-consumer lock-free ring buffer used to hand captured audio
/// from the realtime IOProc thread to a non-realtime drain thread.
///
/// One slot == one channel's captured samples for one IO callback. The producer (the
/// IOProc) never allocates and never blocks: on overflow it drops the newest record and
/// increments `droppedRecords` instead of overwriting data the consumer hasn't read yet
/// (that would corrupt in-flight reads) or blocking (which would risk a deadline miss).
public final class CaptureRingBuffer: @unchecked Sendable {
    public struct SlotHeader {
        public var sampleTime: Int64 = 0
        public var hostTime: UInt64 = 0
        public var channel: Int32 = -1
        public var frameCount: Int32 = 0
    }

    private let slotCount: Int
    private let maxFramesPerSlot: Int
    private let headers: UnsafeMutablePointer<SlotHeader>
    private let samples: UnsafeMutablePointer<Float>
    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)
    public private(set) var droppedRecordsPointer: UnsafeMutablePointer<Int>

    public init(slotCount: Int, maxFramesPerSlot: Int) {
        self.slotCount = slotCount
        self.maxFramesPerSlot = maxFramesPerSlot
        self.headers = .allocate(capacity: slotCount)
        self.headers.initialize(repeating: SlotHeader(), count: slotCount)
        self.samples = .allocate(capacity: slotCount * maxFramesPerSlot)
        self.samples.initialize(repeating: 0, count: slotCount * maxFramesPerSlot)
        self.droppedRecordsPointer = .allocate(capacity: 1)
        self.droppedRecordsPointer.initialize(to: 0)
    }

    deinit {
        headers.deallocate()
        samples.deallocate()
        droppedRecordsPointer.deallocate()
    }

    /// Realtime-safe. Called only from the IOProc thread.
    @inline(__always)
    public func produce(channel: Int32, sampleTime: Int64, hostTime: UInt64, source: UnsafePointer<Float>, frameCount: Int) {
        let w = writeIndex.load(ordering: .relaxed)
        let r = readIndex.load(ordering: .acquiring)
        if w - r >= slotCount {
            droppedRecordsPointer.pointee += 1
            return
        }
        let slot = w % slotCount
        let clamped = min(frameCount, maxFramesPerSlot)
        headers[slot] = SlotHeader(sampleTime: sampleTime, hostTime: hostTime, channel: channel, frameCount: Int32(clamped))
        (samples + slot * maxFramesPerSlot).update(from: source, count: clamped)
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

    public var droppedRecords: Int { droppedRecordsPointer.pointee }

    /// Only safe to call while the engine is stopped (no producer/consumer activity in flight).
    public func resetForNewPhase() {
        writeIndex.store(0, ordering: .relaxed)
        readIndex.store(0, ordering: .relaxed)
        droppedRecordsPointer.pointee = 0
    }
}
