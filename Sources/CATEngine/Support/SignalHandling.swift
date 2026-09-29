import Foundation
import Synchronization
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Cooperative cancellation: the signal handler only flips a flag, never does cleanup work
/// itself. The orchestrator polls `isCancelled` between phases and tears down normally.
public final class CancellationController: @unchecked Sendable {
    public static let shared = CancellationController()

    private let cancelled = Atomic<Bool>(false)
    private var sources: [DispatchSourceSignal] = []

    private init() {}

    /// Dedicated background queue — this CLI has no run loop (async `@main` spends all its time
    /// in synchronous, non-suspending calls), so anything scheduled on `.main` would never run.
    private let signalQueue = DispatchQueue(label: "com.core-audio-tester.signals")

    public func install() {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        for sig in [SIGINT, SIGTERM] {
            let source = DispatchSource.makeSignalSource(signal: sig, queue: signalQueue)
            source.setEventHandler { [weak self] in
                self?.requestCancellation()
            }
            source.resume()
            sources.append(source)
        }
    }

    public func requestCancellation() {
        if cancelled.exchange(true, ordering: .relaxed) {
            FileHandle.standardError.write(Data("\nDeuxième interruption : arrêt immédiat (pas de rapport).\n".utf8))
            exit(ExitCodes.interrupted)
        } else {
            FileHandle.standardError.write(Data("\nInterruption reçue : fin de l'étape en cours puis écriture du rapport partiel… (Ctrl-C à nouveau pour quitter immédiatement)\n".utf8))
        }
    }

    public var isCancelled: Bool { cancelled.load(ordering: .relaxed) }
}
