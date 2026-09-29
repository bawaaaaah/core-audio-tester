import CATEngine
import Foundation

public enum TerminalReportPrinter {
    /// Like `String.padding(toLength:)` but never truncates: an incident count can run into the
    /// millions, and a truncating pad would cut digits or glue the value to the next column.
    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text + "  " : text.padding(toLength: width, withPad: " ", startingAt: 0)
    }

    public static func printSummary(results: [BufferSizeResult], recommendations: RecommendationSet, htmlPath: String, jsonPath: String) {
        let sorted = results.sorted { $0.grantedFrames < $1.grantedFrames }
        let hasCPULoadData = sorted.contains { !$0.loadedStability.isEmpty }
        Log.info("")
        var header = pad("Buffer", 8) + pad("Latence", 11) + pad("Jitter", 9) + pad("Overload", 9) + pad("Arrêt E/S", 10)
        header += pad("Dropout", 9) + pad("Silence", 9) + pad("Clic", 7) + pad("Propre", hasCPULoadData ? 9 : 8)
        if hasCPULoadData { header += pad("CPU max", 9) }
        Log.info(header)
        for r in sorted {
            var tags = ""
            if r.grantedFrames == recommendations.safest.bufferSizeResult.grantedFrames { tags += " [PLUS SÛR]" }
            if r.grantedFrames == recommendations.bestTradeoff.bufferSizeResult.grantedFrames { tags += " [COMPROMIS]" }
            if !r.stability.allChannelsVerified { tags += " [NON VÉRIFIÉ]" }
            if r.stability.droppedRingBufferRecords > 0 { tags += " [CAPTURE INCOMPLÈTE]" }
            if r.wasInterrupted { tags += " [INTERROMPU]" }
            if r.hasUnreliablePings { tags += " [PING ?]" }
            var line = pad("\(r.grantedFrames)", 8)
            line += pad(r.hasLatencyMeasurement ? String(format: "%.2fms", r.meanLatencyMs) : "—", 11)
            line += pad(r.hasLatencyMeasurement ? String(format: "±%.2f", r.meanJitterMs) : "—", 9)
            line += pad("\(r.stability.overloadCount)", 9)
            line += pad("\(r.stability.ioStoppedAbnormallyCount)", 10)
            line += pad("\(r.stability.dropoutCount)", 9)
            line += pad("\(r.stability.silenceCount)", 9)
            line += pad("\(r.stability.clickCount)", 7)
            line += pad(String(format: "%.1f%%", r.stability.minCleanPercentage), hasCPULoadData ? 9 : 8)
            if hasCPULoadData {
                line += pad(r.highestCleanCPULoadPercent.map { "\($0)%" } ?? "—", 9)
            }
            Log.info(line + tags)
        }
        if hasCPULoadData {
            Log.info("")
            Log.info("Résilience à la charge CPU simulée :")
            for r in sorted where !r.loadedStability.isEmpty {
                Log.info("  Buffer \(r.grantedFrames) :")
                for loaded in r.loadedStability.sorted(by: { $0.cpuLoadPercent < $1.cpuLoadPercent }) {
                    let s = loaded.stability
                    let memSuffix = loaded.memoryPressureActive ? " (+ pression mémoire)" : ""
                    let trustSuffix = s.isTrustworthy ? "" : " [NON VÉRIFIÉ]"
                    Log.info("    \(loaded.cpuLoadPercent) %\(memSuffix) : \(s.totalIncidentCount) incident(s), \(s.overloadCount) overload(s), \(s.ioStoppedAbnormallyCount) arrêt(s) d'E/S, \(String(format: "%.1f", s.minCleanPercentage)) % propre\(trustSuffix)")
                }
            }
        }
        Log.info("")
        Log.info("Recommandation « zéro crash » : \(recommendations.safest.bufferSizeResult.grantedFrames) frames")
        Log.info("  \(recommendations.safest.rationale)")
        Log.info("")
        Log.info("Recommandation « meilleur compromis » : \(recommendations.bestTradeoff.bufferSizeResult.grantedFrames) frames")
        Log.info("  \(recommendations.bestTradeoff.rationale)")
        Log.info("")
        Log.info("Rapport HTML : \(htmlPath)")
        Log.info("Export JSON  : \(jsonPath)")
    }
}
