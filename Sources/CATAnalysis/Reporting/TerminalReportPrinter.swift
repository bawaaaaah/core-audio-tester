import CATEngine
import Foundation

public enum TerminalReportPrinter {
    /// Like `String.padding(toLength:)` but never truncates: an incident count can legitimately
    /// run into the millions on a badly-crosstalking channel (unlike latency/percentage columns,
    /// which are always fixed-decimal), so a fixed truncating pad would silently cut off digits
    /// or run straight into the next column with no separating space.
    private static func padCount(_ value: Int, minWidth: Int) -> String {
        let s = "\(value)"
        return s.count >= minWidth ? s + "  " : s.padding(toLength: minWidth, withPad: " ", startingAt: 0)
    }

    public static func printSummary(results: [BufferSizeResult], recommendations: RecommendationSet, htmlPath: String, jsonPath: String) {
        let sorted = results.sorted { $0.grantedFrames < $1.grantedFrames }
        let hasCPULoadData = sorted.contains { !$0.loadedStability.isEmpty }
        Log.info("")
        var header = "Buffer".padding(toLength: 8, withPad: " ", startingAt: 0)
        header += "Latence".padding(toLength: 10, withPad: " ", startingAt: 0)
        header += "Jitter".padding(toLength: 9, withPad: " ", startingAt: 0)
        header += "Overload".padding(toLength: 9, withPad: " ", startingAt: 0)
        header += "Dropout".padding(toLength: 9, withPad: " ", startingAt: 0)
        header += "Silence".padding(toLength: 9, withPad: " ", startingAt: 0)
        header += "Click".padding(toLength: 7, withPad: " ", startingAt: 0)
        header += "Propre".padding(toLength: hasCPULoadData ? 9 : 6, withPad: " ", startingAt: 0)
        if hasCPULoadData { header += "CPU max" }
        Log.info(header)
        for r in sorted {
            var tag = ""
            if r.grantedFrames == recommendations.safest.bufferSizeResult.grantedFrames { tag += " [SAFEST]" }
            if r.grantedFrames == recommendations.bestTradeoff.bufferSizeResult.grantedFrames { tag += " [TRADE-OFF]" }
            if !r.stability.allChannelsVerified { tag += " [NON VÉRIFIÉ]" }
            var line = "\(r.grantedFrames)".padding(toLength: 8, withPad: " ", startingAt: 0)
            line += String(format: "%.2fms", r.meanLatencyMs).padding(toLength: 10, withPad: " ", startingAt: 0)
            let jitter = r.pingResults.map(\.stddevMs).reduce(0, +) / Double(max(r.pingResults.count, 1))
            line += String(format: "±%.2f", jitter).padding(toLength: 9, withPad: " ", startingAt: 0)
            line += padCount(r.stability.overloadCount, minWidth: 9)
            line += padCount(r.stability.perChannel.reduce(0) { $0 + $1.dropoutCount }, minWidth: 9)
            line += padCount(r.stability.perChannel.reduce(0) { $0 + $1.silenceCount }, minWidth: 9)
            line += padCount(r.stability.perChannel.reduce(0) { $0 + $1.clickCount }, minWidth: 7)
            if hasCPULoadData {
                line += String(format: "%.1f%%", r.stability.minCleanPercentage).padding(toLength: 9, withPad: " ", startingAt: 0)
                line += r.highestCleanCPULoadPercent.map { "\($0)%" } ?? "—"
            } else {
                line += String(format: "%.1f%%", r.stability.minCleanPercentage)
            }
            line += tag
            Log.info(line)
        }
        if sorted.contains(where: { !$0.loadedStability.isEmpty }) {
            Log.info("")
            Log.info("Résilience à la charge CPU simulée :")
            for r in sorted where !r.loadedStability.isEmpty {
                Log.info("  Buffer \(r.grantedFrames):")
                for loaded in r.loadedStability.sorted(by: { $0.cpuLoadPercent < $1.cpuLoadPercent }) {
                    let s = loaded.stability
                    let memSuffix = loaded.memoryPressureActive ? " (+ pression mémoire)" : ""
                    Log.info("    \(loaded.cpuLoadPercent)%\(memSuffix) : \(s.totalIncidentCount) incident(s), \(s.overloadCount) overload(s), \(String(format: "%.1f", s.minCleanPercentage))% propre")
                }
            }
        }
        Log.info("")
        Log.info("Recommandation \"zéro crash\" : \(recommendations.safest.bufferSizeResult.grantedFrames) frames")
        Log.info("  \(recommendations.safest.rationale)")
        Log.info("")
        Log.info("Recommandation \"meilleur compromis\" : \(recommendations.bestTradeoff.bufferSizeResult.grantedFrames) frames")
        Log.info("  \(recommendations.bestTradeoff.rationale)")
        Log.info("")
        Log.info("Rapport HTML : \(htmlPath)")
        Log.info("Export JSON  : \(jsonPath)")
    }
}
