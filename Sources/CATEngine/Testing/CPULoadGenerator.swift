import Foundation
import Synchronization

/// Spins background worker threads through a busy/sleep duty cycle to approximate a target
/// aggregate CPU utilization, so a stability test can be re-run under realistic CPU contention
/// (other apps, background processes) instead of only on an otherwise-idle machine.
///
/// Uses QoS `.default` — this should look like ordinary background-app load, not fight the
/// CoreAudio IOProc thread's real-time scheduling policy for priority.
public final class CPULoadGenerator: @unchecked Sendable {
    private let targetLoadFraction: Double
    private let threadCount: Int
    private let running = Atomic<Bool>(false)
    private let activeWorkers = Atomic<Int>(0)

    public init(targetLoadPercent: Double, threadCount: Int = ProcessInfo.processInfo.activeProcessorCount) {
        self.targetLoadFraction = min(max(targetLoadPercent / 100.0, 0), 1)
        self.threadCount = max(threadCount, 1)
    }

    public func start() {
        running.store(true, ordering: .relaxed)
        for _ in 0..<threadCount {
            activeWorkers.wrappingAdd(1, ordering: .relaxed)
            let thread = Thread { [self] in
                self.runDutyCycle()
                self.activeWorkers.wrappingAdd(-1, ordering: .relaxed)
            }
            thread.qualityOfService = .default
            thread.start()
        }
    }

    /// Signals workers to stop and blocks briefly until they've all actually wound down, so the
    /// caller can be sure no simulated load bleeds into whatever phase runs next.
    public func stop() {
        running.store(false, ordering: .relaxed)
        while activeWorkers.load(ordering: .relaxed) > 0 {
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    private func runDutyCycle() {
        let period: TimeInterval = 0.02
        let busy = period * targetLoadFraction
        let idle = period - busy
        while running.load(ordering: .relaxed) {
            let busyUntil = Date().addingTimeInterval(busy)
            var sink = 1.0
            while Date() < busyUntil {
                sink = sink * 1.0000001 + 1.0
            }
            _ = sink
            if idle > 0 {
                Thread.sleep(forTimeInterval: idle)
            }
        }
    }
}
