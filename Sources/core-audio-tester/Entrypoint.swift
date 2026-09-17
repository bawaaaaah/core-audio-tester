import CATAnalysis
import CATEngine
import Foundation

@main
struct Entrypoint {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        var options: RawCLIOptions
        do {
            options = try ArgumentParser.parse(arguments)
        } catch {
            Log.error("\(error)")
            print(ArgumentParser.usageText)
            exit(ExitCodes.usageError)
        }

        if options.help {
            print(ArgumentParser.usageText)
            exit(ExitCodes.success)
        }

        if options.listDevices {
            do {
                let devices = try DeviceDiscovery.allDevices()
                for d in devices {
                    Log.info("\(d.name)")
                    Log.info("  UID: \(d.uid)")
                    Log.info("  Transport: \(d.transportType), Sample rate: \(Int(d.nominalSampleRate)) Hz")
                    Log.info("  Channels: \(d.inputChannelCount) in / \(d.outputChannelCount) out")
                    Log.info("  Buffer size range: \(d.bufferFrameSizeRange.lowerBound)-\(d.bufferFrameSizeRange.upperBound) frames")
                    Log.info("")
                }
            } catch {
                Log.error("\(error)")
                exit(ExitCodes.deviceError)
            }
            exit(ExitCodes.success)
        }

        // No --device given: fall into the interactive wizard when attached to a real terminal,
        // otherwise keep the old hard error (a script/CI run should never sit there waiting on stdin).
        if options.device == nil && options.configPath == nil {
            guard ConsoleUI.isTTY else {
                Log.error("--device is required (or use --list-devices to see available devices).")
                print(ArgumentParser.usageText)
                exit(ExitCodes.usageError)
            }
            do {
                let (_, wizardOptions) = try InteractiveWizard.run()
                options = wizardOptions
            } catch {
                Log.error("\(error)")
                exit(ExitCodes.usageError)
            }
        }

        guard let deviceQuery = options.device else {
            Log.error("--device is required (or use --list-devices to see available devices).")
            print(ArgumentParser.usageText)
            exit(ExitCodes.usageError)
        }

        let device: DeviceInfo
        do {
            device = try DeviceDiscovery.resolve(deviceQuery)
        } catch {
            Log.error("\(error)")
            exit(ExitCodes.deviceError)
        }

        var config: TestConfigFile?
        if let path = options.configPath {
            do {
                config = try TestConfigFile.load(path: path)
            } catch {
                Log.error("Failed to load config file: \(error)")
                exit(ExitCodes.usageError)
            }
        }

        let plan: TestPlan
        do {
            plan = try TestPlanResolver.resolve(cli: options, config: config, device: device)
        } catch {
            Log.error("\(error)")
            exit(ExitCodes.usageError)
        }

        Log.info("Device: \(device.name) (\(device.uid))")
        Log.info("Mode: \(plan.isAutoMode ? "auto (device complet)" : "sélection manuelle")")
        Log.info("Paires testées: \(plan.pairs.count) — sorties \(ChannelSpec.format(plan.outputChannels)) / entrées \(ChannelSpec.format(plan.inputChannels))")
        Log.info("Tailles de buffer: \(plan.bufferSizes.map(String.init).joined(separator: ", "))")
        Log.info("Mode ping: \(plan.pingMode == .parallel ? "parallèle" : "séquentiel") (\(plan.pingRepetitions) répétitions/paire)")
        Log.info("Durée du test de stabilité: \(Int(plan.stabilityDurationSeconds))s par taille de buffer")
        if !plan.cpuLoadLevelsPercent.isEmpty {
            Log.info("Charge CPU simulée: \(plan.cpuLoadLevelsPercent.map { "\($0)%" }.joined(separator: ", ")) (test de stabilité répété à chaque palier)")
        }
        if plan.memoryPressureMB > 0 {
            Log.info("Pression mémoire simulée: \(plan.memoryPressureMB) Mo (en plus de chaque palier de charge CPU)")
        }
        let stabilitySignalDescription: String
        switch plan.stabilitySignalKind {
        case .tone: stabilitySignalDescription = "sinusoïde"
        case .whiteNoise: stabilitySignalDescription = "bruit blanc (comparaison exacte)"
        case .pinkNoise: stabilitySignalDescription = "bruit rose (comparaison exacte)"
        case .wavFile:
            let filename = plan.wavFilePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "?"
            stabilitySignalDescription = "fichier WAV \(filename) (comparaison exacte)"
        }
        Log.info("Signal du test de stabilité: \(stabilitySignalDescription)")

        if !plan.inputChannels.isEmpty {
            let permission = await MicrophonePermission.ensureAccess()
            if permission == .denied {
                Log.error("Microphone access denied for this binary. Enable it via System Settings > Privacy & Security > Microphone, then re-run.")
                exit(ExitCodes.microphonePermissionDenied)
            }
        }

        let pingSeconds = plan.pingMode == .parallel
            ? Double(plan.pingRepetitions) * 0.3
            : Double(plan.pairs.count) * Double(plan.pingRepetitions) * 0.3
        let stabilityPassesPerBufferSize = 1 + plan.cpuLoadLevelsPercent.count
        let estimatedSeconds = Double(plan.bufferSizes.count) * (pingSeconds + Double(stabilityPassesPerBufferSize) * plan.stabilityDurationSeconds + 1.0)
        Log.info(String(format: "Durée totale estimée: ~%.0f minute(s)", estimatedSeconds / 60.0))
        if !plan.skipConfirmation {
            print("Appuyez sur Entrée pour lancer le benchmark (Ctrl-C pour annuler)...")
            _ = readLine()
        }

        CancellationController.shared.install()

        let delegate = AnalysisSweepDelegate()
        let orchestrator = BufferSizeSweepOrchestrator(
            device: device,
            plan: plan,
            delegate: delegate,
            progressHandler: { progress in
                ConsoleUI.endLine()
                let phaseLabel = progress.phase == "ping" ? "ping latence" : "test de stabilité"
                let loadSuffix = progress.cpuLoadPercent.map { " (charge CPU simulée \($0)%)" } ?? ""
                Log.info("[\(progress.bufferSizeIndex + 1)/\(progress.totalBufferSizes)] buffer \(progress.grantedFrames) frames — \(phaseLabel)\(loadSuffix)")
            },
            liveTickHandler: { tick in
                let pct = tick.total > 0 ? min(tick.elapsed / tick.total, 1.0) : 1.0
                let barWidth = 24
                let filled = Int(pct * Double(barWidth))
                let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: max(barWidth - filled, 0))
                let timeText = String(format: "%4.1fs/%.0fs", tick.elapsed, tick.total)
                let loadSuffix = tick.cpuLoadPercent.map { " charge \($0)%" } ?? ""
                if let incidents = tick.liveIncidentCount {
                    let color: ConsoleUI.Color = incidents == 0 ? .green : (incidents < 10 ? .yellow : .red)
                    let incidentText = ConsoleUI.colored("\(incidents) incident(s)", color)
                    ConsoleUI.updateLine("  [\(bar)] \(timeText)\(loadSuffix) — \(incidentText)")
                } else {
                    ConsoleUI.updateLine("  [\(bar)] \(timeText)\(loadSuffix) — ping en cours...")
                }
            }
        )

        let results: [BufferSizeResult]
        let wasInterrupted: Bool
        do {
            (results, wasInterrupted) = try orchestrator.run()
        } catch {
            ConsoleUI.endLine()
            Log.error("\(error)")
            exit(ExitCodes.deviceError)
        }
        ConsoleUI.endLine()

        guard let recommendations = RecommendationEngine.recommend(results: results, sporadicTolerancePerMinute: plan.sporadicToleranceWeightedPerMinute) else {
            Log.error("No buffer size produced results.")
            exit(ExitCodes.deviceError)
        }

        let htmlPath = plan.outputBasePath + ".html"
        let jsonPath = plan.outputBasePath + ".json"
        let html = HTMLReportRenderer.render(device: device, plan: plan, results: results, recommendations: recommendations, wasInterrupted: wasInterrupted)
        do {
            try html.write(toFile: htmlPath, atomically: true, encoding: .utf8)
            try JSONReportExporter.export(device: device, plan: plan, results: results, recommendations: recommendations, wasInterrupted: wasInterrupted, to: jsonPath)
        } catch {
            Log.error("Failed to write report files: \(error)")
        }

        TerminalReportPrinter.printSummary(results: results, recommendations: recommendations, htmlPath: htmlPath, jsonPath: jsonPath)

        if wasInterrupted {
            exit(ExitCodes.interrupted)
        }
        let allClean = results.allSatisfy(\.isFullyClean)
        exit(allClean ? ExitCodes.success : ExitCodes.notFullyClean)
    }
}
