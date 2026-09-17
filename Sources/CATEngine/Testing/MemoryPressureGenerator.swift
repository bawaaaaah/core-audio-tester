import Foundation
import Synchronization
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Continuously allocates and rewrites a block of memory to simulate a memory-hungry background
/// application. Unlike `CPULoadGenerator`'s pure busy-loop (which QoS scheduling shields the real
/// audio thread and our own capture thread from), memory pressure — cache/TLB contention, page
/// reclaim — affects every thread regardless of QoS, making it a genuinely different contention
/// vector worth testing separately.
public final class MemoryPressureGenerator: @unchecked Sendable {
    private let targetBytes: Int
    private let running = Atomic<Bool>(false)
    private let workerDone = Atomic<Bool>(true)

    public init(targetMB: Int) {
        self.targetBytes = max(targetMB, 0) * 1_048_576
    }

    public func start() {
        guard targetBytes > 0 else { return }
        running.store(true, ordering: .relaxed)
        workerDone.store(false, ordering: .relaxed)
        let thread = Thread { [self] in
            self.runChurnLoop()
            self.workerDone.store(true, ordering: .relaxed)
        }
        thread.qualityOfService = .default
        thread.start()
    }

    /// Signals the worker to stop and blocks briefly until the allocation has actually been
    /// released, so pressure doesn't bleed into whatever phase runs next.
    public func stop() {
        running.store(false, ordering: .relaxed)
        while !workerDone.load(ordering: .relaxed) {
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    private func runChurnLoop() {
        let pageSize = 4096
        // `UnsafeMutableRawPointer.allocate` traps on failure; a too-large request on a
        // resource-constrained machine should fail soft (no simulated pressure) rather than
        // crash the whole benchmark run, so this goes through raw `posix_memalign` instead.
        var rawPointer: UnsafeMutableRawPointer?
        let result = posix_memalign(&rawPointer, pageSize, targetBytes)
        guard result == 0, let buffer = rawPointer else { return }
        defer { free(buffer) }

        var counter: UInt8 = 1
        while running.load(ordering: .relaxed) {
            var offset = 0
            while offset < targetBytes {
                buffer.storeBytes(of: counter, toByteOffset: offset, as: UInt8.self)
                offset += pageSize
                if offset % (pageSize * 256) == 0 && !running.load(ordering: .relaxed) { break }
            }
            counter &+= 1
        }
    }
}
