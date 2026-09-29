import CATEngine
import Foundation

enum InteractiveWizardError: Error, CustomStringConvertible {
    case cancelled
    case noDevices

    var description: String {
        switch self {
        case .cancelled: return "Annulé."
        case .noDevices: return "Aucune interface CoreAudio trouvée."
        }
    }
}

/// Guided console setup, used when the tool is launched without a device (and stdout is a TTY).
/// Options already given on the command line (`--out-path`, `--yes`, `--exclusive`…) are kept;
/// the wizard only fills in what it asks about.
enum InteractiveWizard {
    static func run(base: RawCLIOptions) throws -> RawCLIOptions {
        print(ConsoleUI.bold("core-audio-tester") + " — assistant interactif")
        print(ConsoleUI.colored("(passe --device et les autres options pour sauter cet assistant)", .dim))
        print("")

        let devices = try DeviceDiscovery.allDevices()
        guard !devices.isEmpty else { throw InteractiveWizardError.noDevices }

        print(ConsoleUI.bold("Interfaces CoreAudio disponibles :"))
        for (i, d) in devices.enumerated() {
            print("  [\(i + 1)] \(d.name)  (\(d.inputChannelCount) entrée(s) / \(d.outputChannelCount) sortie(s), \(Int(d.nominalSampleRate)) Hz, \(d.transportType))")
        }
        let deviceChoice = ConsoleUI.promptWithDefault("Choisis une interface (numéro)", default: "1")
        guard let deviceIndex = Int(deviceChoice), devices.indices.contains(deviceIndex - 1) else {
            throw InteractiveWizardError.cancelled
        }
        let device = devices[deviceIndex - 1]
        print(ConsoleUI.colored("→ \(device.name) sélectionnée.", .green))
        if device.inputChannelCount == 0 || device.outputChannelCount == 0 {
            print(ConsoleUI.colored("Cette interface n'a pas à la fois des entrées et des sorties : pour tester une boucle entre deux interfaces (ex. entrée et sortie intégrées du Mac), crée d'abord un appareil agrégé dans Configuration audio et MIDI.", .yellow))
        }
        print("")

        var options = base
        options.device = device.uid

        var selectionMode = ""
        while true {
            let answer = ConsoleUI.promptWithDefault(
                "Tester [a] tous les \(min(device.inputChannelCount, device.outputChannelCount)) canaux ou une [s]élection ?",
                default: "a"
            ).lowercased()
            if answer.hasPrefix("a") || answer.hasPrefix("s") {
                selectionMode = answer
                break
            }
            // A mistyped answer (a channel count instead of a letter) must not silently fall
            // back to the full-device benchmark.
            print(ConsoleUI.colored("Réponse non reconnue (\"\(answer)\") — tape \"a\" (tous) ou \"s\" (sélection).", .yellow))
        }

        if selectionMode.hasPrefix("s") {
            let common = min(device.inputChannelCount, device.outputChannelCount)
            let outSpec = ConsoleUI.promptWithDefault("Sorties à tester (ex. 1-7 ou 1,3,5)", default: "1-\(common)")
            let inSpec = ConsoleUI.promptWithDefault("Entrées à tester, dans le même ordre (ex. 1-7)", default: outSpec)
            options.outputChannels = outSpec
            options.inputChannels = inSpec
            options.auto = false
            print(ConsoleUI.colored("→ Sélection : sorties \(outSpec), entrées \(inSpec).", .green))
        } else {
            options.auto = true
            options.outputChannels = nil
            options.inputChannels = nil
            options.pairs = nil
            print(ConsoleUI.colored("→ Tous les canaux (auto).", .green))
        }
        print("")

        let bufferSizesDefault = options.bufferSizes ?? TestPlanResolver.defaultBufferSizes.map(String.init).joined(separator: ",")
        options.bufferSizes = ConsoleUI.promptWithDefault("Tailles de buffer à tester (CSV)", default: bufferSizesDefault)
        options.duration = ConsoleUI.promptWithDefault("Durée du test de stabilité par taille (ex. 60s, 5m)", default: options.duration ?? "60s")

        let pingRepsAnswer = ConsoleUI.promptWithDefault("Répétitions du ping par paire", default: "\(options.pingRepetitions ?? TestPlanResolver.defaultPingRepetitions)")
        guard let pingReps = Int(pingRepsAnswer) else {
            throw ArgumentParserError.invalidNumber(flag: "répétitions du ping", value: pingRepsAnswer)
        }
        options.pingRepetitions = pingReps

        let pingModeAnswer = ConsoleUI.promptWithDefault("Mode du ping — [p]arallèle (rapide) ou [s]équentiel (isolation max)", default: options.pingSequential ? "s" : "p").lowercased()
        options.pingSequential = pingModeAnswer.hasPrefix("s")

        let levelDefault = String(format: "%.0f", options.outputLevelDBFS ?? TestPlan.defaultOutputLevelDBFS)
        let levelAnswer = ConsoleUI.promptWithDefault("Niveau crête des signaux de test en dBFS (de -60 à -3)", default: levelDefault)
        guard let level = Double(levelAnswer.replacingOccurrences(of: ",", with: ".")) else {
            throw ArgumentParserError.invalidNumber(flag: "niveau", value: levelAnswer)
        }
        options.outputLevelDBFS = level

        let cpuLoadDefault = TestPlanResolver.defaultCPULoadLevelsPercent.map(String.init).joined(separator: ",")
        let cpuLoadAnswer = ConsoleUI.promptWithDefault(
            "Répéter le test de stabilité sous charge CPU simulée ? CSV de %, ex. \(cpuLoadDefault) (vide = non)",
            default: options.cpuLoadLevels ?? ""
        )
        options.cpuLoadLevels = cpuLoadAnswer.trimmingCharacters(in: .whitespaces).isEmpty ? nil : cpuLoadAnswer

        let memPressureAnswer = ConsoleUI.promptWithDefault(
            "Ajouter une pression mémoire simulée pendant ces passes chargées ? [o]ui / [n]on",
            default: options.memPressure ? "o" : "n"
        ).lowercased()
        options.memPressure = memPressureAnswer.hasPrefix("o")

        let signalAnswer = ConsoleUI.promptWithDefault(
            "Signal du test de stabilité — [s]inusoïde (défaut, toute boucle), bruit [b]lanc, bruit [r]ose ou [f]ichier WAV (boucle numérique transparente uniquement)",
            default: "s"
        ).lowercased()
        if signalAnswer.hasPrefix("r") {
            options.stabilitySignal = "pink"
        } else if signalAnswer.hasPrefix("b") {
            options.stabilitySignal = "noise"
        } else if signalAnswer.hasPrefix("f") {
            options.stabilitySignal = "wav"
            let typedPath = ConsoleUI.promptWithDefault("Chemin du fichier WAV (vide pour ouvrir un sélecteur de fichier)", default: "")
            if typedPath.isEmpty {
                if let picked = FilePicker.pickFile(prompt: "Sélectionne le fichier WAV de référence") {
                    print(ConsoleUI.colored("→ \(picked)", .green))
                    options.wavFilePath = picked
                } else {
                    print(ConsoleUI.colored("Aucun fichier sélectionné.", .dim))
                }
            } else {
                options.wavFilePath = unescapeDroppedPath(typedPath)
            }
        } else {
            options.stabilitySignal = "sine"
            options.wavFilePath = nil
        }

        print("")
        return options
    }

    /// A path dragged into Terminal arrives shell-escaped ("My\ File.wav") or quoted.
    private static func unescapeDroppedPath(_ path: String) -> String {
        var trimmed = path.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 2, let first = trimmed.first, first == trimmed.last, first == "'" || first == "\"" {
            trimmed = String(trimmed.dropFirst().dropLast())
        }
        var result = ""
        var escaping = false
        for character in trimmed {
            if escaping {
                result.append(character)
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                result.append(character)
            }
        }
        return result
    }
}
