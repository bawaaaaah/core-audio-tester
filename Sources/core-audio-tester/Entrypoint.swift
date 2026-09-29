import CATAnalysis
import CATEngine
import Foundation

@main
struct Entrypoint {
    static func main() async {
        var options: RawCLIOptions
        do {
            options = try ArgumentParser.parse(Array(CommandLine.arguments.dropFirst()))
        } catch {
            Log.error("\(error)")
            print(ArgumentParser.usageText)
            exit(ExitCodes.usageError)
        }

        if options.help {
            print(ArgumentParser.usageText)
            exit(ExitCodes.success)
        }
        if options.version {
            print("core-audio-tester \(ToolVersion.current)")
            exit(ExitCodes.success)
        }
        if options.listDevices {
            listDevices()
        }

        var config: TestConfigFile?
        if let path = options.configPath {
            do {
                config = try TestConfigFile.load(path: path)
            } catch {
                Log.error("\(error)")
                exit(ExitCodes.usageError)
            }
        }

        // No device on the command line or in the config: run the wizard when attached to a real
        // terminal, otherwise fail (a script or CI run must never sit waiting on stdin).
        if options.device == nil && config?.device == nil {
            guard ConsoleUI.isTTY else {
                Log.error("--device est obligatoire hors terminal interactif (voir --list-devices).")
                print(ArgumentParser.usageText)
                exit(ExitCodes.usageError)
            }
            do {
                options = try InteractiveWizard.run(base: options)
            } catch {
                Log.error("\(error)")
                exit(ExitCodes.usageError)
            }
        }

        guard let deviceQuery = options.device ?? config?.device else {
            Log.error("--device est obligatoire (voir --list-devices).")
            exit(ExitCodes.usageError)
        }

        let device: DeviceInfo
        do {
            device = try DeviceDiscovery.resolve(deviceQuery)
        } catch {
            Log.error("\(error)")
            exit(ExitCodes.deviceError)
        }

        let plan: TestPlan
        do {
            plan = try TestPlanResolver.resolve(cli: options, config: config, device: device)
        } catch {
            Log.error("\(error)")
            exit(ExitCodes.usageError)
        }

        let delegate: AnalysisSweepDelegate
        do {
            delegate = try AnalysisSweepDelegate(plan: plan)
        } catch {
            Log.error("\(error)")
            exit(ExitCodes.usageError)
        }

        printPlan(plan, device: device)

        if !plan.inputChannels.isEmpty {
            let permission = await MicrophonePermission.ensureAccess()
            if permission == .denied {
                Log.error("Accès au micro refusé. macOS l'accorde au terminal qui lance l'outil : active-le dans Réglages Système > Confidentialité et sécurité > Microphone, puis relance.")
                exit(ExitCodes.microphonePermissionDenied)
            }
        }

        Log.info(String(format: "Durée totale estimée : ~%.0f minute(s)", estimatedDurationSeconds(plan: plan, sampleRate: device.nominalSampleRate) / 60.0))
        if !plan.skipConfirmation {
            print("Appuie sur Entrée pour lancer le benchmark (Ctrl-C pour annuler)…")
            _ = readLine()
        }

        CancellationController.shared.install()

        let orchestrator = BufferSizeSweepOrchestrator(
            device: device,
            plan: plan,
            delegate: delegate,
            progressHandler: { progress in
                ConsoleUI.endLine()
                let phaseLabel = progress.phase == .ping ? "ping latence" : "test de stabilité"
                let loadSuffix = progress.cpuLoadPercent.map { " (charge CPU simulée \($0) %)" } ?? ""
                Log.info("[\(progress.bufferSizeIndex + 1)/\(progress.totalBufferSizes)] buffer \(progress.grantedFrames) frames — \(phaseLabel)\(loadSuffix)")
            },
            liveTickHandler: { tick in
                let pct = tick.total > 0 ? min(tick.elapsed / tick.total, 1.0) : 1.0
                let barWidth = 24
                let filled = Int(pct * Double(barWidth))
                let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: max(barWidth - filled, 0))
                let timeText = String(format: "%4.1fs/%.0fs", tick.elapsed, tick.total)
                let loadSuffix = tick.cpuLoadPercent.map { " charge \($0) %" } ?? ""
                if let incidents = tick.liveIncidentCount {
                    let color: ConsoleUI.Color = incidents == 0 ? .green : (incidents < 10 ? .yellow : .red)
                    let incidentText = ConsoleUI.colored("\(incidents) incident(s)", color)
                    ConsoleUI.updateLine("  [\(bar)] \(timeText)\(loadSuffix) — \(incidentText)")
                } else {
                    ConsoleUI.updateLine("  [\(bar)] \(timeText)\(loadSuffix) — ping en cours…")
                }
            },
            noticeHandler: { notice in
                ConsoleUI.endLine()
                Log.warn(notice)
            }
        )

        let outcome = orchestrator.run()
        ConsoleUI.endLine()
        let sweepErrorText = outcome.error.map { "\($0)" }

        guard let recommendations = RecommendationEngine.recommend(results: outcome.results, sporadicTolerancePerMinute: plan.sporadicToleranceWeightedPerMinute) else {
            if let sweepErrorText {
                Log.error(sweepErrorText)
                exit(ExitCodes.deviceError)
            }
            if outcome.wasInterrupted {
                Log.error("Interrompu avant la fin du premier test : aucun résultat à rapporter.")
                exit(ExitCodes.interrupted)
            }
            Log.error("Aucune taille de buffer n'a produit de résultat.")
            exit(ExitCodes.deviceError)
        }

        let htmlPath = plan.outputBasePath + ".html"
        let jsonPath = plan.outputBasePath + ".json"
        let html = HTMLReportRenderer.render(
            device: device, plan: plan, results: outcome.results, recommendations: recommendations,
            wasInterrupted: outcome.wasInterrupted, sweepError: sweepErrorText
        )
        var reportWritten = true
        do {
            try html.write(toFile: htmlPath, atomically: true, encoding: .utf8)
            try JSONReportExporter.export(
                device: device, plan: plan, results: outcome.results, recommendations: recommendations,
                wasInterrupted: outcome.wasInterrupted, sweepError: sweepErrorText, to: jsonPath
            )
        } catch {
            reportWritten = false
            Log.error("Échec de l'écriture du rapport : \(error)")
        }

        TerminalReportPrinter.printSummary(results: outcome.results, recommendations: recommendations, htmlPath: htmlPath, jsonPath: jsonPath)

        if let sweepErrorText {
            Log.error("Test arrêté avant la fin : \(sweepErrorText) (rapport partiel\(reportWritten ? " écrit" : " non écrit")).")
            exit(ExitCodes.deviceError)
        }
        if outcome.wasInterrupted {
            exit(ExitCodes.interrupted)
        }
        let allClean = outcome.results.allSatisfy { $0.isFullyClean && $0.isCleanUnderLoad }
        exit(allClean ? ExitCodes.success : ExitCodes.notFullyClean)
    }

    private static func listDevices() -> Never {
        do {
            for d in try DeviceDiscovery.allDevices() {
                Log.info("\(d.name)")
                Log.info("  UID : \(d.uid)")
                Log.info("  Transport : \(d.transportType), fréquence : \(Int(d.nominalSampleRate)) Hz")
                Log.info("  Canaux : \(d.inputChannelCount) entrée(s) / \(d.outputChannelCount) sortie(s)")
                Log.info("  Tailles de buffer : \(d.bufferFrameSizeRange.lowerBound)-\(d.bufferFrameSizeRange.upperBound) frames")
                Log.info("")
            }
        } catch {
            Log.error("\(error)")
            exit(ExitCodes.deviceError)
        }
        exit(ExitCodes.success)
    }

    private static func printPlan(_ plan: TestPlan, device: DeviceInfo) {
        Log.info("Interface : \(device.name) (\(device.uid))")
        Log.info("Mode : \(plan.isAutoMode ? "auto (interface complète)" : "sélection manuelle")")
        Log.info("Paires testées : \(plan.pairs.count) — sorties \(ChannelSpec.format(plan.outputChannels)) / entrées \(ChannelSpec.format(plan.inputChannels))")
        Log.info("Tailles de buffer : \(plan.bufferSizes.map(String.init).joined(separator: ", "))")
        Log.info("Mode ping : \(plan.pingMode == .parallel ? "parallèle" : "séquentiel") (\(plan.pingRepetitions) répétitions/paire)")
        Log.info("Durée du test de stabilité : \(formatSeconds(plan.stabilityDurationSeconds)) par passe")
        if !plan.cpuLoadLevelsPercent.isEmpty {
            Log.info("Charge CPU simulée : \(plan.cpuLoadLevelsPercent.map { "\($0) %" }.joined(separator: ", ")) (une passe de stabilité par palier)")
        }
        if plan.memoryPressureMB > 0 {
            Log.info("Pression mémoire simulée : \(plan.memoryPressureMB) Mo (pendant chaque palier de charge CPU)")
        }
        if plan.ioLoadPercent > 0 {
            Log.info("Charge DSP simulée dans le callback audio : \(plan.ioLoadPercent) % de chaque cycle")
        }
        if plan.exclusiveAccess {
            Log.info("Accès exclusif à l'interface (hog mode) : oui")
        }
        let signalDescription: String
        switch plan.stabilitySignalKind {
        case .tone: signalDescription = "sinusoïde"
        case .whiteNoise: signalDescription = "bruit blanc (comparaison exacte)"
        case .pinkNoise: signalDescription = "bruit rose (comparaison exacte)"
        case .wavFile:
            let filename = plan.wavFilePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "?"
            signalDescription = "fichier WAV \(filename) (comparaison exacte)"
        }
        Log.info("Signal du test de stabilité : \(signalDescription)")
        if plan.stabilitySignalKind.requiresTransparentLoopback {
            Log.info("  → exige une boucle numérique transparente ; sur une boucle analogique, les canaux seront signalés « non vérifiés » (utilise alors le signal sinus).")
        }
        let level = String(format: "%.0f", plan.outputLevelDBFS)
        Log.warn("le test joue des rafales large bande et un signal continu sur \(plan.outputChannels.count) sortie(s) à \(level) dBFS crête. Coupe ou baisse toute sono, enceinte ou casque relié à ces sorties (--level pour ajuster).")
    }

    private static func formatSeconds(_ seconds: Double) -> String {
        seconds >= 1 && seconds == seconds.rounded() ? "\(Int(seconds)) s" : String(format: "%.2f s", seconds)
    }

    /// Mirrors PingTestSession's track layout, so the estimate follows the buffer sizes.
    private static func estimatedDurationSeconds(plan: TestPlan, sampleRate: Double) -> Double {
        let burst = Double((1 << MLSSignalGenerator.pingOrder) - 1)
        let slots = Double(plan.pingMode == .parallel ? plan.pingRepetitions : plan.pairs.count * plan.pingRepetitions)
        let passes = Double(1 + plan.cpuLoadLevelsPercent.count)
        return plan.bufferSizes.reduce(0.0) { total, size in
            let margin = max(sampleRate * 0.05, Double(size) * 8)
            let gap = burst + margin + sampleRate * 0.05
            let ping = (slots * gap + burst + sampleRate * 0.5) / sampleRate + 0.5
            return total + ping + passes * plan.stabilityDurationSeconds + 1.0
        }
    }
}
