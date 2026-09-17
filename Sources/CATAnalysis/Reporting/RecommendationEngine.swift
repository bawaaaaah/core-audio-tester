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
    public static func recommend(results: [BufferSizeResult], sporadicTolerancePerMinute: Double) -> RecommendationSet? {
        guard !results.isEmpty else { return nil }
        let sorted = results.sorted { $0.grantedFrames < $1.grantedFrames }

        // A result where some channel never locked onto its reference signal reads as "0
        // incidents, 100% clean" by construction — nothing was ever compared, so that's not
        // evidence of health, it's an absence of evidence. Recommending it as safe would be
        // exactly the silent-failure-looks-like-success trap this tool exists to avoid, so it's
        // excluded from consideration entirely unless literally nothing verified.
        let verifiable = sorted.filter(\.stability.allChannelsVerified)

        let clean = verifiable.filter(\.isFullyClean)
        let safest: Recommendation
        if let best = clean.first {
            safest = Recommendation(
                bufferSizeResult: best,
                rationale: "Aucun incident (overload ou glitch audio) détecté sur toute la durée du test de stabilité (\(Int(best.stability.durationSeconds))s) — plus petite taille testée qui soit 100% propre.",
                isFallback: false
            )
        } else if let fallback = fallbackByIncidentCount(verifiable) {
            safest = Recommendation(
                bufferSizeResult: fallback,
                rationale: "Aucune taille de buffer testée n'est 100% propre sur toute la durée du test. Repli sur la taille avec le moins d'incidents au total (\(fallback.stability.totalIncidentCount)), puis le moins d'overloads (\(fallback.stability.overloadCount)), puis la latence la plus faible.",
                isFallback: true
            )
        } else {
            // Every single result had at least one channel that never locked — there's nothing
            // verified to recommend from at all. Still return something (a fallback of last
            // resort) rather than crashing the report, but say plainly that it's unconfirmed.
            let fallback = fallbackByIncidentCount(sorted)!
            safest = Recommendation(
                bufferSizeResult: fallback,
                rationale: "Aucun canal n'a pu être vérifié sur aucune taille de buffer testée (le verrouillage sur le signal de référence n'a jamais été acquis) — ce résultat n'est PAS confirmé, retenu seulement à défaut d'alternative. Vérifie le câblage/routage des canaux testés, ou que le signal de référence (ex: début du fichier WAV) contient assez de contenu pour être verrouillé.",
                isFallback: true
            )
        }

        let tolerable = verifiable.filter { result in
            let minutes = max(result.stability.durationSeconds / 60.0, 1.0 / 60.0)
            return result.stability.weightedIncidentRatePerMinute(minutes: minutes) <= sporadicTolerancePerMinute
        }
        let tradeoffCandidate = tolerable.min { $0.grantedFrames < $1.grantedFrames }

        let bestTradeoff: Recommendation
        var sameAsSafest = false
        if let candidate = tradeoffCandidate, candidate.grantedFrames < safest.bufferSizeResult.grantedFrames {
            let deltaMs = max(safest.bufferSizeResult.meanLatencyMs - candidate.meanLatencyMs, 0)
            let incidents = candidate.stability.totalIncidentCount
            let minutes = max(candidate.stability.durationSeconds / 60.0, 1.0 / 60.0)
            let rate = candidate.stability.weightedIncidentRatePerMinute(minutes: minutes)
            let rationale = String(
                format: "Taille %d : %.1f ms de latence en moins que la taille la plus sûre (%d), au prix de %d incident(s) sur %.0fs de test (taux pondéré %.2f/min, tolérance %.2f/min).",
                candidate.grantedFrames, deltaMs, safest.bufferSizeResult.grantedFrames, incidents, candidate.stability.durationSeconds, rate, sporadicTolerancePerMinute
            )
            bestTradeoff = Recommendation(bufferSizeResult: candidate, rationale: rationale, isFallback: false)
        } else {
            sameAsSafest = true
            bestTradeoff = Recommendation(
                bufferSizeResult: safest.bufferSizeResult,
                rationale: "Aucun compromis disponible sous la taille la plus sûre : c'est déjà la plus petite taille testée respectant la tolérance aux incidents sporadiques.",
                isFallback: safest.isFallback
            )
        }

        return RecommendationSet(safest: safest, bestTradeoff: bestTradeoff, sameAsSafest: sameAsSafest)
    }

    private static func fallbackByIncidentCount(_ candidates: [BufferSizeResult]) -> BufferSizeResult? {
        candidates.min { a, b in
            if a.stability.totalIncidentCount != b.stability.totalIncidentCount {
                return a.stability.totalIncidentCount < b.stability.totalIncidentCount
            }
            if a.stability.overloadCount != b.stability.overloadCount {
                return a.stability.overloadCount < b.stability.overloadCount
            }
            return a.meanLatencyMs < b.meanLatencyMs
        }
    }
}
