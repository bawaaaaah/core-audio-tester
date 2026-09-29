import CATEngine
import Foundation

public struct Recommendation {
    public let bufferSizeResult: BufferSizeResult
    public let rationale: String
    public let isFallback: Bool
}

public struct RecommendationSet {
    public let safest: Recommendation
    public let bestTradeoff: Recommendation
    public let sameAsSafest: Bool
}

public enum RecommendationEngine {
    /// "Safest": the smallest buffer size that is fully clean and trustworthy at idle *and* under
    /// every simulated load level tested. "Best trade-off": the smallest trustworthy size whose
    /// weighted event rate (overloads and IO stops included) stays within the sporadic tolerance.
    ///
    /// A pass only counts as evidence when it is trustworthy: every channel verified, no captured
    /// audio dropped unchecked, full duration run. A "clean" pass that isn't trustworthy means
    /// nothing was seen, not that nothing happened.
    public static func recommend(results: [BufferSizeResult], sporadicTolerancePerMinute: Double) -> RecommendationSet? {
        guard !results.isEmpty else { return nil }
        let sorted = results.sorted { $0.grantedFrames < $1.grantedFrames }
        let trustworthy = sorted.filter(\.stability.isTrustworthy)
        let hasLoadData = sorted.contains { !$0.loadedStability.isEmpty }

        let safest: Recommendation
        if let best = trustworthy.first(where: { $0.isFullyClean && $0.isCleanUnderLoad }) {
            let loadNote: String
            if let maxLoad = best.loadedStability.map(\.cpuLoadPercent).max() {
                loadNote = " ni sous charge CPU simulée (jusqu'à \(maxLoad) %)"
            } else {
                loadNote = ""
            }
            safest = Recommendation(
                bufferSizeResult: best,
                rationale: "Aucun incident, overload ni arrêt d'E/S au repos\(loadNote) sur toute la durée du test (\(Int(best.stability.durationSeconds)) s) — plus petite taille testée entièrement propre et vérifiée." + pingNote(best),
                isFallback: false
            )
        } else if hasLoadData, let idleClean = trustworthy.first(where: \.isFullyClean) {
            let tolerated = idleClean.highestCleanCPULoadPercent ?? 0
            let toleratedText = tolerated > 0 ? "elle reste propre jusqu'à \(tolerated) % de charge CPU simulée" : "elle décroche dès le premier palier de charge CPU simulée"
            safest = Recommendation(
                bufferSizeResult: idleClean,
                rationale: "Aucune taille testée ne reste propre sous toute la charge CPU simulée. Plus petite taille propre au repos : \(idleClean.grantedFrames) frames ; \(toleratedText). Prévois une taille au-dessus si la machine sera chargée." + pingNote(idleClean),
                isFallback: true
            )
        } else if let fallback = fallbackByEventCount(trustworthy) {
            safest = Recommendation(
                bufferSizeResult: fallback,
                rationale: "Aucune taille testée n'est entièrement propre. Repli sur la taille avec le moins d'événements (\(eventCount(fallback)) : incidents audio + overloads + arrêts d'E/S), puis la latence la plus faible." + pingNote(fallback),
                isFallback: true
            )
        } else {
            let fallback = fallbackByEventCount(sorted)!
            safest = Recommendation(
                bufferSizeResult: fallback,
                rationale: "Aucune passe n'a pu être entièrement vérifiée (canal jamais verrouillé sur son signal de référence, audio capturé perdu faute de temps d'analyse, ou passe interrompue) — ce résultat n'est PAS confirmé. Vérifie le câblage et le routage des canaux testés et relance.",
                isFallback: true
            )
        }

        let tolerable = trustworthy.filter { $0.stability.weightedIncidentRatePerMinute() <= sporadicTolerancePerMinute }
        let tradeoffCandidate = tolerable.min { $0.grantedFrames < $1.grantedFrames }

        let bestTradeoff: Recommendation
        var sameAsSafest = false
        if let candidate = tradeoffCandidate, candidate.grantedFrames < safest.bufferSizeResult.grantedFrames {
            let deltaMs = max(safest.bufferSizeResult.meanLatencyMs - candidate.meanLatencyMs, 0)
            let rationale = String(
                format: "Taille %d : %.1f ms de latence en moins que la plus sûre (%d), au prix de %d événement(s) sur %.0f s de test au repos (taux pondéré %.2f/min, tolérance %.2f/min).",
                candidate.grantedFrames, deltaMs, safest.bufferSizeResult.grantedFrames, eventCount(candidate),
                candidate.stability.durationSeconds, candidate.stability.weightedIncidentRatePerMinute(), sporadicTolerancePerMinute
            ) + pingNote(candidate)
            bestTradeoff = Recommendation(bufferSizeResult: candidate, rationale: rationale, isFallback: false)
        } else {
            sameAsSafest = true
            bestTradeoff = Recommendation(
                bufferSizeResult: safest.bufferSizeResult,
                rationale: "Aucun compromis disponible sous la taille la plus sûre : c'est déjà la plus petite taille testée qui respecte la tolérance aux incidents sporadiques.",
                isFallback: safest.isFallback
            )
        }

        return RecommendationSet(safest: safest, bestTradeoff: bestTradeoff, sameAsSafest: sameAsSafest)
    }

    private static func eventCount(_ result: BufferSizeResult) -> Int {
        result.stability.totalIncidentCount + result.stability.overloadCount + result.stability.ioStoppedAbnormallyCount
    }

    private static func pingNote(_ result: BufferSizeResult) -> String {
        guard result.hasUnreliablePings else { return "" }
        return result.hasLatencyMeasurement
            ? " Attention : la latence de certaines paires n'a pas pu être mesurée de façon fiable."
            : " Attention : aucune latence n'a pu être mesurée pour cette taille."
    }

    private static func fallbackByEventCount(_ candidates: [BufferSizeResult]) -> BufferSizeResult? {
        candidates.min { a, b in
            let eventsA = eventCount(a)
            let eventsB = eventCount(b)
            if eventsA != eventsB { return eventsA < eventsB }
            if a.stability.overloadCount != b.stability.overloadCount {
                return a.stability.overloadCount < b.stability.overloadCount
            }
            return a.meanLatencyMs < b.meanLatencyMs
        }
    }
}
