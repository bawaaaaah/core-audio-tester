import CATEngine
import Foundation

public enum HTMLReportRenderer {
    public static func render(
        device: DeviceInfo,
        plan: TestPlan,
        results: [BufferSizeResult],
        recommendations: RecommendationSet,
        wasInterrupted: Bool,
        sweepError: String? = nil
    ) -> String {
        let sorted = results.sorted { $0.grantedFrames < $1.grantedFrames }
        let hasCPULoadData = sorted.contains { !$0.loadedStability.isEmpty }
        let chart = renderChart(sorted: sorted, safest: recommendations.safest.bufferSizeResult, tradeoff: recommendations.bestTradeoff.bufferSizeResult)
        let cpuLoadChart = renderCPULoadChart(sorted: sorted)
        let table = renderTable(sorted: sorted, safest: recommendations.safest.bufferSizeResult, tradeoff: recommendations.bestTradeoff.bufferSizeResult, hasCPULoadData: hasCPULoadData)
        let details = sorted.map { renderDetail(result: $0) }.joined(separator: "\n")
        var notes: [String] = []
        if wasInterrupted {
            notes.append("<p class=\"warn\">Test interrompu (Ctrl-C) — ce rapport ne couvre que ce qui a été mesuré avant l'interruption.</p>")
        }
        if let sweepError {
            notes.append("<p class=\"warn\">Test arrêté sur une erreur : \(escape(sweepError)) — rapport partiel.</p>")
        }
        if plan.stabilitySignalKind.requiresTransparentLoopback {
            notes.append("<p class=\"meta\">Mode à comparaison exacte : valable uniquement sur une boucle numérique transparente (gain compensé automatiquement). Une boucle analogique est signalée « non vérifiée ».</p>")
        }
        let interruptedNote = notes.joined(separator: "\n")
        let cpuLoadSectionHTML = hasCPULoadData
            ? """
              <h2>Performance en fonction de la charge CPU simulée</h2>
              <div class="overflow">\(cpuLoadChart)</div>
              """
            : ""
        let stabilitySignalDescription: String
        switch plan.stabilitySignalKind {
        case .tone: stabilitySignalDescription = "sinusoïde continue par canal (phase, amplitude et offset ajustés par moindres carrés, amplitude suivie en RMS)"
        case .whiteNoise: stabilitySignalDescription = "bruit blanc à comparaison exacte (échantillon par échantillon, après verrouillage par corrélation croisée et compensation du gain)"
        case .pinkNoise: stabilitySignalDescription = "bruit rose à comparaison exacte (échantillon par échantillon, après verrouillage par corrélation croisée et compensation du gain)"
        case .wavFile:
            let filename = plan.wavFilePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "?"
            stabilitySignalDescription = "fichier WAV \(escape(filename)) à comparaison exacte (échantillon par échantillon, après verrouillage par corrélation croisée et compensation du gain)"
        }

        return """
        <!DOCTYPE html>
        <html lang="fr">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>core-audio-tester — \(escape(device.name))</title>
        <style>
          :root {
            --bg: #ffffff; --fg: #1a1a1a; --muted: #666666; --border: #dddddd;
            --accent: #2563eb; --safe: #16a34a; --warn: #d97706; --danger: #dc2626;
            --card-bg: #f7f7f8;
          }
          @media (prefers-color-scheme: dark) {
            :root:not([data-theme="light"]) {
              --bg: #14161a; --fg: #e8e8e8; --muted: #9a9a9a; --border: #333333;
              --accent: #60a5fa; --safe: #4ade80; --warn: #fbbf24; --danger: #f87171;
              --card-bg: #1c1f26;
            }
          }
          :root[data-theme="dark"] {
            --bg: #14161a; --fg: #e8e8e8; --muted: #9a9a9a; --border: #333333;
            --accent: #60a5fa; --safe: #4ade80; --warn: #fbbf24; --danger: #f87171;
            --card-bg: #1c1f26;
          }
          body { background: var(--bg); color: var(--fg); font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 0; padding: 2rem; line-height: 1.5; }
          h1 { font-size: 1.4rem; margin-bottom: 0.25rem; }
          h2 { font-size: 1.1rem; margin-top: 2rem; }
          .meta { color: var(--muted); font-size: 0.9rem; margin-bottom: 1.5rem; }
          .cards { display: flex; gap: 1rem; flex-wrap: wrap; margin: 1rem 0 2rem; }
          .card { background: var(--card-bg); border: 1px solid var(--border); border-radius: 10px; padding: 1rem 1.25rem; flex: 1; min-width: 260px; }
          .card h3 { margin: 0 0 0.5rem; font-size: 0.95rem; }
          .card .big { font-size: 1.6rem; font-weight: 600; }
          .card.safe .big { color: var(--safe); }
          .card.tradeoff .big { color: var(--accent); }
          .card p { margin: 0.5rem 0 0; font-size: 0.9rem; color: var(--muted); }
          .warn { color: var(--warn); font-weight: 600; }
          table { border-collapse: collapse; width: 100%; margin: 1rem 0; font-size: 0.85rem; }
          th, td { border: 1px solid var(--border); padding: 0.4rem 0.6rem; text-align: right; }
          th:first-child, td:first-child { text-align: left; }
          th { background: var(--card-bg); }
          tr.tag-safe td:first-child { border-left: 3px solid var(--safe); }
          tr.tag-tradeoff td:first-child { border-left: 3px solid var(--accent); }
          .tag { display: inline-block; font-size: 0.7rem; padding: 0.1rem 0.4rem; border-radius: 4px; margin-left: 0.3rem; }
          .tag.safe { background: var(--safe); color: #032b13; }
          .tag.tradeoff { background: var(--accent); color: #05204d; }
          .tag.warn { background: var(--warn); color: #3a2100; }
          .overflow { overflow-x: auto; }
          details { margin: 0.5rem 0; border: 1px solid var(--border); border-radius: 8px; padding: 0.5rem 1rem; background: var(--card-bg); }
          summary { cursor: pointer; font-weight: 600; }
          svg text { fill: var(--fg); font-family: -apple-system, sans-serif; }
          footer { margin-top: 3rem; color: var(--muted); font-size: 0.8rem; }
          @media (max-width: 600px) { body { padding: 1rem; } }
        </style>
        </head>
        <body>
        <h1>core-audio-tester — \(escape(device.name))</h1>
        <p class="meta">
          UID: \(escape(device.uid)) · \(Int(device.nominalSampleRate)) Hz · \(device.inputChannelCount) entrées / \(device.outputChannelCount) sorties ·
          Canaux testés : \(plan.pairs.count) paire(s) · Mode ping : \(plan.pingMode == .parallel ? "parallèle" : "séquentiel") ·
          Niveau : \(String(format: "%.0f", plan.outputLevelDBFS)) dBFS crête\(plan.ioLoadPercent > 0 ? " · Charge DSP simulée dans le callback : \(plan.ioLoadPercent) %" : "")\(plan.exclusiveAccess ? " · Accès exclusif (hog mode)" : "")
        </p>
        \(interruptedNote)
        <div class="cards">
          \(renderCard(title: "Recommandation : zéro crash", result: recommendations.safest.bufferSizeResult, rationale: recommendations.safest.rationale, cssClass: "safe"))
          \(renderCard(title: "Recommandation : meilleur compromis", result: recommendations.bestTradeoff.bufferSizeResult, rationale: recommendations.bestTradeoff.rationale, cssClass: "tradeoff"))
        </div>
        <h2>Latence &amp; incidents par taille de buffer</h2>
        <div class="overflow">\(chart)</div>
        \(cpuLoadSectionHTML)
        <h2>Tableau complet</h2>
        <div class="overflow">\(table)</div>
        <h2>Détail par taille de buffer</h2>
        \(details)
        <footer>
          Méthodologie : rafales MLS (ordre 10, 1023 échantillons, une séquence distincte par sortie en mode parallèle) pour la latence, \(stabilitySignalDescription) pour la stabilité, seuils de détection relatifs au niveau reçu et au bruit de fond mesuré. \(plan.pingRepetitions) répétitions/paire, tolérance sporadique \(String(format: "%.2f", plan.sporadicToleranceWeightedPerMinute))/min (clic 1, silence 2, dropout/overload/arrêt d'E/S 3). core-audio-tester \(escape(ToolVersion.current)).
        </footer>
        </body>
        </html>
        """
    }

    private static func renderCard(title: String, result: BufferSizeResult, rationale: String, cssClass: String) -> String {
        """
        <div class="card \(cssClass)">
          <h3>\(escape(title))</h3>
          <div class="big">\(result.grantedFrames) frames</div>
          <p>Latence moyenne : \(latencyText(result.meanLatencyMs, measured: result.hasLatencyMeasurement)) · Incidents : \(result.stability.totalIncidentCount) · Overloads : \(result.stability.overloadCount)</p>
          <p>\(escape(rationale))</p>
        </div>
        """
    }

    private static func renderTable(sorted: [BufferSizeResult], safest: BufferSizeResult, tradeoff: BufferSizeResult, hasCPULoadData: Bool) -> String {
        var rows = ""
        for r in sorted {
            var tags = ""
            var rowClass = ""
            if r.grantedFrames == safest.grantedFrames { tags += "<span class=\"tag safe\">SAFEST</span>"; rowClass = "tag-safe" }
            if r.grantedFrames == tradeoff.grantedFrames { tags += "<span class=\"tag tradeoff\">TRADE-OFF</span>"; rowClass = rowClass.isEmpty ? "tag-tradeoff" : rowClass }
            if !r.stability.allChannelsVerified { tags += "<span class=\"tag warn\">NON VÉRIFIÉ</span>" }
            if r.wasInterrupted { tags += "<span class=\"tag warn\">INTERROMPU</span>" }
            if r.stability.droppedRingBufferRecords > 0 { tags += "<span class=\"tag warn\">CAPTURE INCOMPLÈTE</span>" }
            if r.hasUnreliablePings { tags += "<span class=\"tag warn\">PING ?</span>" }
            let theoreticalMs = r.halLatency.theoreticalRoundTripMs(sampleRate: r.sampleRate)
            let cpuLoadCell: String
            if hasCPULoadData {
                if let best = r.highestCleanCPULoadPercent {
                    cpuLoadCell = "<td>\(best)%</td>"
                } else {
                    cpuLoadCell = "<td>—</td>"
                }
            } else {
                cpuLoadCell = ""
            }
            rows += """
            <tr class="\(rowClass)">
              <td>\(r.grantedFrames)\(tags)</td>
              <td>\(Int(r.sampleRate))</td>
              <td>\(r.hasLatencyMeasurement ? String(format: "%.2f", r.meanLatencyMs) : "—")</td>
              <td>\(r.hasLatencyMeasurement ? String(format: "%.2f", r.worstLatencyMs) : "—")</td>
              <td>\(String(format: "%.2f", theoreticalMs))</td>
              <td>\(r.stability.overloadCount)</td>
              <td>\(r.stability.ioStoppedAbnormallyCount)</td>
              <td>\(r.stability.dropoutCount)</td>
              <td>\(r.stability.silenceCount)</td>
              <td>\(r.stability.clickCount)</td>
              <td>\(r.stability.clipCount)</td>
              <td>\(r.stability.droppedRingBufferRecords)</td>
              <td>\(String(format: "%.1f", r.stability.minCleanPercentage))%</td>
              \(cpuLoadCell)
            </tr>
            """
        }
        let cpuLoadHeader = hasCPULoadData ? "<th>Propre jusqu'à (charge CPU)</th>" : ""
        return """
        <table>
          <thead><tr>
            <th>Buffer (frames)</th><th>Sample rate</th><th>Latence moy. (ms)</th><th>Latence max (ms)</th>
            <th>Latence théorique (ms)</th><th>Overloads</th><th>Arrêts E/S</th><th>Dropouts</th><th>Silences</th><th>Clics</th><th>Clips</th><th>Captures perdues</th><th>Propre (min)</th>\(cpuLoadHeader)
          </tr></thead>
          <tbody>\(rows)</tbody>
        </table>
        """
    }

    private static func renderDetail(result: BufferSizeResult) -> String {
        var pairRows = ""
        for p in result.pingResults {
            let flag = !p.hasMeasurement ? " ⚠️ non détectée" : (p.isUnreliable ? " ⚠️ ambiguë" : "")
            pairRows += """
            <tr>
              <td>Out \(p.pair.outputChannel) → In \(p.pair.inputChannel)</td>
              <td>\(p.repetitionsDetected)/\(p.repetitionsRequested)</td>
              <td>\(p.hasMeasurement ? String(format: "%.2f", p.meanMs) : "—")</td>
              <td>\(p.hasMeasurement ? String(format: "%.2f", p.medianMs) : "—")</td>
              <td>\(p.hasMeasurement ? "\(String(format: "%.2f", p.minMs))–\(String(format: "%.2f", p.maxMs))" : "—")</td>
              <td>\(p.hasMeasurement ? String(format: "%.2f", p.stddevMs) : "—")</td>
              <td>\(p.ambiguousCount)\(flag)</td>
            </tr>
            """
        }
        var channelRows = ""
        for c in result.stability.perChannel.sorted(by: { $0.channel < $1.channel }) {
            let cleanCell = c.verified
                ? "\(String(format: "%.1f", c.cleanPercentage))%"
                : "<span class=\"tag warn\" title=\"\(escape(c.unverifiedReason ?? ""))\">NON VÉRIFIÉ</span>"
            let note = c.verified ? (c.reacquisitionCount > 0 ? "référence perdue puis retrouvée \(c.reacquisitionCount) fois" : "") : (c.unverifiedReason ?? "")
            channelRows += """
            <tr>
              <td>Entrée \(c.channel)</td><td>\(c.dropoutCount)</td><td>\(c.silenceCount)</td><td>\(c.clickCount)</td><td>\(c.clipCount)</td><td>\(cleanCell)</td><td style="text-align:left">\(escape(note))</td>
            </tr>
            """
        }
        let cpuLoadSection = renderCPULoadSection(result: result)
        return """
        <details>
          <summary>Taille \(result.grantedFrames) frames — \(latencyText(result.meanLatencyMs, measured: result.hasLatencyMeasurement)) moy., \(result.stability.totalIncidentCount) incident(s)</summary>
          <h4>Latence par paire</h4>
          <div class="overflow"><table>
            <thead><tr><th>Paire</th><th>Détections</th><th>Moy (ms)</th><th>Médiane (ms)</th><th>Min–Max (ms)</th><th>Jitter (σ)</th><th>Ambiguës</th></tr></thead>
            <tbody>\(pairRows)</tbody>
          </table></div>
          <h4>Stabilité par canal</h4>
          <div class="overflow"><table>
            <thead><tr><th>Canal</th><th>Dropouts</th><th>Silences</th><th>Clics</th><th>Clips</th><th>Propre</th><th>Remarque</th></tr></thead>
            <tbody>\(channelRows)</tbody>
          </table></div>
          \(cpuLoadSection)
        </details>
        """
    }

    private static func renderCPULoadSection(result: BufferSizeResult) -> String {
        guard !result.loadedStability.isEmpty else { return "" }
        var rows = ""
        for loaded in result.loadedStability.sorted(by: { $0.cpuLoadPercent < $1.cpuLoadPercent }) {
            let s = loaded.stability
            let memSuffix = loaded.memoryPressureActive ? " <span class=\"tag warn\">+ mémoire</span>" : ""
            rows += """
            <tr>
              <td>\(loaded.cpuLoadPercent)%\(memSuffix)</td><td>\(s.overloadCount)</td><td>\(s.ioStoppedAbnormallyCount)</td><td>\(s.totalIncidentCount)</td><td>\(String(format: "%.1f", s.minCleanPercentage))%\(s.isTrustworthy ? "" : " <span class=\"tag warn\">NON VÉRIFIÉ</span>")</td>
            </tr>
            """
        }
        return """
        <h4>Résilience à la charge CPU simulée</h4>
        <div class="overflow"><table>
          <thead><tr><th>Charge CPU</th><th>Overloads</th><th>Arrêts E/S</th><th>Incidents</th><th>Propre</th></tr></thead>
          <tbody>\(rows)</tbody>
        </table></div>
        """
    }

    private static func renderChart(sorted: [BufferSizeResult], safest: BufferSizeResult, tradeoff: BufferSizeResult) -> String {
        guard !sorted.isEmpty else { return "<p>Pas de données.</p>" }
        let width = 900.0
        let height = 420.0
        let marginLeft = 60.0
        let marginRight = 60.0
        let marginTop = 30.0
        let marginBottom = 60.0
        let plotWidth = width - marginLeft - marginRight
        let plotHeight = height - marginTop - marginBottom
        let n = sorted.count
        let step = n > 1 ? plotWidth / Double(n - 1) : 0
        let maxLatency = max(sorted.map(\.worstLatencyMs).max() ?? 1, 1) * 1.2
        let maxIncidents = max(sorted.map { Double($0.stability.totalIncidentCount + $0.stability.overloadCount) }.max() ?? 1, 1) * 1.2

        func x(_ i: Int) -> Double { marginLeft + Double(i) * step }
        func yLatency(_ ms: Double) -> Double { marginTop + plotHeight - (ms / maxLatency) * plotHeight }
        func yIncidents(_ count: Double) -> Double { marginTop + plotHeight - (count / maxIncidents) * plotHeight }

        var svg = "<svg viewBox=\"0 0 \(width) \(height)\" width=\"100%\" style=\"max-width:900px\">"
        svg += "<line x1=\"\(marginLeft)\" y1=\"\(marginTop)\" x2=\"\(marginLeft)\" y2=\"\(marginTop + plotHeight)\" stroke=\"var(--border)\"/>"
        svg += "<line x1=\"\(marginLeft)\" y1=\"\(marginTop + plotHeight)\" x2=\"\(marginLeft + plotWidth)\" y2=\"\(marginTop + plotHeight)\" stroke=\"var(--border)\"/>"

        // Incident bars (dropout/silence/click stacked) + overload marker
        let barWidth = min(step * 0.5, 30)
        for (i, r) in sorted.enumerated() {
            let cx = x(i)
            var yTop = marginTop + plotHeight
            let counts: [(Double, String)] = [
                (Double(r.stability.dropoutCount), "var(--danger)"),
                (Double(r.stability.silenceCount), "var(--warn)"),
                (Double(r.stability.clickCount), "#eab308"),
            ]
            for (count, color) in counts where count > 0 {
                let barHeight = (marginTop + plotHeight) - yIncidents(count)
                let barY = yTop - barHeight
                svg += "<rect x=\"\(cx - barWidth/2)\" y=\"\(barY)\" width=\"\(barWidth)\" height=\"\(barHeight)\" fill=\"\(color)\"><title>\(r.grantedFrames)f: \(Int(count))</title></rect>"
                yTop = barY
            }
            if r.stability.overloadCount > 0 {
                let oy = yIncidents(Double(r.stability.overloadCount))
                svg += "<circle cx=\"\(cx)\" cy=\"\(oy)\" r=\"4\" fill=\"none\" stroke=\"var(--danger)\" stroke-width=\"2\"><title>Overloads: \(r.stability.overloadCount)</title></circle>"
            }
        }

        // Theoretical latency dashed line
        var theoPoints = ""
        for (i, r) in sorted.enumerated() {
            let px = x(i); let py = yLatency(r.halLatency.theoreticalRoundTripMs(sampleRate: r.sampleRate))
            theoPoints += "\(px),\(py) "
        }
        svg += "<polyline points=\"\(theoPoints)\" fill=\"none\" stroke=\"var(--muted)\" stroke-width=\"1.5\" stroke-dasharray=\"4,3\"/>"

        // Measured mean latency line + min/max band
        var meanPoints = ""
        var bandPathTop = ""
        var bandPathBottom = ""
        for (i, r) in sorted.enumerated() {
            let px = x(i)
            meanPoints += "\(px),\(yLatency(r.meanLatencyMs)) "
            bandPathTop += "\(px),\(yLatency(r.worstLatencyMs)) "
            let minMs = r.hasLatencyMeasurement ? r.bestLatencyMs : r.meanLatencyMs
            bandPathBottom = "\(px),\(yLatency(minMs)) " + bandPathBottom
        }
        svg += "<polygon points=\"\(bandPathTop)\(bandPathBottom)\" fill=\"var(--accent)\" opacity=\"0.12\"/>"
        svg += "<polyline points=\"\(meanPoints)\" fill=\"none\" stroke=\"var(--accent)\" stroke-width=\"2.5\"/>"
        for (i, r) in sorted.enumerated() {
            svg += "<circle cx=\"\(x(i))\" cy=\"\(yLatency(r.meanLatencyMs))\" r=\"3.5\" fill=\"var(--accent)\"><title>\(r.grantedFrames)f: \(String(format: "%.2f", r.meanLatencyMs)) ms</title></circle>"
        }

        // Highlight safest / tradeoff
        for (i, r) in sorted.enumerated() {
            let isSafe = r.grantedFrames == safest.grantedFrames
            let isTradeoff = r.grantedFrames == tradeoff.grantedFrames
            guard isSafe || isTradeoff else { continue }
            let color = isSafe ? "var(--safe)" : "var(--accent)"
            let label = isSafe && isTradeoff ? "SAFEST + TRADE-OFF" : (isSafe ? "SAFEST" : "TRADE-OFF")
            svg += "<line x1=\"\(x(i))\" y1=\"\(marginTop)\" x2=\"\(x(i))\" y2=\"\(marginTop + plotHeight)\" stroke=\"\(color)\" stroke-width=\"1.5\" stroke-dasharray=\"2,2\"/>"
            svg += "<text x=\"\(x(i))\" y=\"\(marginTop - 10)\" font-size=\"10\" text-anchor=\"middle\" fill=\"\(color)\">\(label)</text>"
        }

        // X axis labels
        for (i, r) in sorted.enumerated() {
            svg += "<text x=\"\(x(i))\" y=\"\(marginTop + plotHeight + 20)\" font-size=\"11\" text-anchor=\"middle\">\(r.grantedFrames)</text>"
        }
        svg += "<text x=\"\(marginLeft + plotWidth/2)\" y=\"\(height - 8)\" font-size=\"11\" text-anchor=\"middle\">Taille de buffer (frames)</text>"
        svg += "<text x=\"15\" y=\"\(marginTop + plotHeight/2)\" font-size=\"11\" text-anchor=\"middle\" transform=\"rotate(-90 15 \(marginTop + plotHeight/2))\">Latence (ms, ligne)</text>"
        svg += "<text x=\"\(width - 12)\" y=\"\(marginTop + plotHeight/2)\" font-size=\"11\" text-anchor=\"middle\" transform=\"rotate(-90 \(width - 12) \(marginTop + plotHeight/2))\">Incidents (barres)</text>"
        svg += "</svg>"
        return svg
    }

    /// One line per buffer size that has simulated-load data, plotting min per-channel clean %
    /// against the CPU load level (idle baseline included as the 0% category) — shows at a
    /// glance how much CPU contention each buffer size actually tolerates.
    private static func renderCPULoadChart(sorted: [BufferSizeResult]) -> String {
        let withLoad = sorted.filter { !$0.loadedStability.isEmpty }
        guard !withLoad.isEmpty else { return "" }

        let levels = Array(Set(withLoad.flatMap { $0.loadedStability.map(\.cpuLoadPercent) })).sorted()
        let categories = [0] + levels

        let width = 900.0
        let height = 380.0
        let marginLeft = 60.0
        let marginRight = 150.0
        let marginTop = 30.0
        let marginBottom = 50.0
        let plotWidth = width - marginLeft - marginRight
        let plotHeight = height - marginTop - marginBottom
        let n = categories.count
        let step = n > 1 ? plotWidth / Double(n - 1) : 0
        let palette = ["#2563eb", "#dc2626", "#16a34a", "#d97706", "#7c3aed", "#0891b2", "#db2777", "#65a30d"]

        func x(_ i: Int) -> Double { marginLeft + Double(i) * step }
        func y(_ percent: Double) -> Double { marginTop + plotHeight - (percent / 100.0) * plotHeight }

        var svg = "<svg viewBox=\"0 0 \(width) \(height)\" width=\"100%\" style=\"max-width:900px\">"
        svg += "<line x1=\"\(marginLeft)\" y1=\"\(marginTop)\" x2=\"\(marginLeft)\" y2=\"\(marginTop + plotHeight)\" stroke=\"var(--border)\"/>"
        svg += "<line x1=\"\(marginLeft)\" y1=\"\(marginTop + plotHeight)\" x2=\"\(marginLeft + plotWidth)\" y2=\"\(marginTop + plotHeight)\" stroke=\"var(--border)\"/>"

        for gridPct in [0.0, 25.0, 50.0, 75.0, 100.0] {
            let py = y(gridPct)
            svg += "<line x1=\"\(marginLeft)\" y1=\"\(py)\" x2=\"\(marginLeft + plotWidth)\" y2=\"\(py)\" stroke=\"var(--border)\" stroke-dasharray=\"2,3\"/>"
            svg += "<text x=\"\(marginLeft - 8)\" y=\"\(py + 3)\" font-size=\"10\" text-anchor=\"end\">\(Int(gridPct))%</text>"
        }

        for (bufferIndex, r) in withLoad.enumerated() {
            let color = palette[bufferIndex % palette.count]
            var points: [(x: Double, y: Double, tooltip: String)] = []
            points.append((
                x(0), y(r.stability.minCleanPercentage),
                "\(r.grantedFrames)f idle: \(String(format: "%.1f", r.stability.minCleanPercentage))% propre, \(r.stability.totalIncidentCount) incident(s)"
            ))
            for level in levels {
                guard let loaded = r.loadedStability.first(where: { $0.cpuLoadPercent == level }),
                      let idx = categories.firstIndex(of: level) else { continue }
                let s = loaded.stability
                let memSuffix = loaded.memoryPressureActive ? " + mémoire" : ""
                points.append((
                    x(idx), y(s.minCleanPercentage),
                    "\(r.grantedFrames)f @\(level)%\(memSuffix): \(String(format: "%.1f", s.minCleanPercentage))% propre, \(s.totalIncidentCount) incident(s), \(s.overloadCount) overload(s)"
                ))
            }
            let polyline = points.map { "\($0.x),\($0.y)" }.joined(separator: " ")
            svg += "<polyline points=\"\(polyline)\" fill=\"none\" stroke=\"\(color)\" stroke-width=\"2.5\"/>"
            for p in points {
                svg += "<circle cx=\"\(p.x)\" cy=\"\(p.y)\" r=\"3.5\" fill=\"\(color)\"><title>\(escape(p.tooltip))</title></circle>"
            }
        }

        for (i, level) in categories.enumerated() {
            let label = level == 0 ? "idle" : "\(level)%"
            svg += "<text x=\"\(x(i))\" y=\"\(marginTop + plotHeight + 20)\" font-size=\"11\" text-anchor=\"middle\">\(label)</text>"
        }
        svg += "<text x=\"\(marginLeft + plotWidth/2)\" y=\"\(height - 8)\" font-size=\"11\" text-anchor=\"middle\">Charge CPU simulée</text>"
        svg += "<text x=\"15\" y=\"\(marginTop + plotHeight/2)\" font-size=\"11\" text-anchor=\"middle\" transform=\"rotate(-90 15 \(marginTop + plotHeight/2))\">% propre (canal le pire)</text>"

        var legendY = marginTop + 6
        for (bufferIndex, r) in withLoad.enumerated() {
            let color = palette[bufferIndex % palette.count]
            let lx = marginLeft + plotWidth + 20
            svg += "<rect x=\"\(lx)\" y=\"\(legendY - 8)\" width=\"10\" height=\"10\" fill=\"\(color)\"/>"
            svg += "<text x=\"\(lx + 16)\" y=\"\(legendY + 1)\" font-size=\"11\">\(r.grantedFrames) frames</text>"
            legendY += 18
        }

        svg += "</svg>"
        return svg
    }

    private static func latencyText(_ ms: Double, measured: Bool) -> String {
        measured ? String(format: "%.2f ms", ms) : "non mesurée"
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
