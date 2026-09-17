import CATEngine
import Foundation

enum InteractiveWizardError: Error, CustomStringConvertible {
    case cancelled
    case noDevices

    var description: String {
        switch self {
        case .cancelled: return "Cancelled."
        case .noDevices: return "No CoreAudio device found."
        }
    }
}

/// A guided console setup, used when the tool is launched with no `--device` (and stdout is a
/// TTY) — picks the device, channel selection, buffer sizes, and durations interactively instead
/// of requiring the user to already know the CLI flag syntax.
enum InteractiveWizard {
    static func run() throws -> (device: DeviceInfo, options: RawCLIOptions) {
        print(ConsoleUI.bold("core-audio-tester") + " — assistant interactif")
        print(ConsoleUI.colored("(passe --device et les autres flags pour sauter cet assistant)", .dim))
        print("")

        let devices = try DeviceDiscovery.allDevices()
        guard !devices.isEmpty else { throw InteractiveWizardError.noDevices }

        print(ConsoleUI.bold("Devices CoreAudio disponibles :"))
        for (i, d) in devices.enumerated() {
            print("  [\(i + 1)] \(d.name)  (\(d.inputChannelCount) in / \(d.outputChannelCount) out, \(Int(d.nominalSampleRate)) Hz, \(d.transportType))")
        }
        let deviceChoice = ConsoleUI.promptWithDefault("Choisis un device (numéro)", default: "1")
        guard let deviceIndex = Int(deviceChoice), devices.indices.contains(deviceIndex - 1) else {
            throw InteractiveWizardError.cancelled
        }
        let device = devices[deviceIndex - 1]
        print(ConsoleUI.colored("→ \(device.name) sélectionné.", .green))
        print("")

        var options = RawCLIOptions()
        options.device = device.uid

        var selectionMode = ""
        while true {
            let answer = ConsoleUI.promptWithDefault(
                "Tester [a]tous les \(min(device.inputChannelCount, device.outputChannelCount)) canaux ou une [s]élection ?",
                default: "a"
            ).lowercased()
            if answer.hasPrefix("a") || answer.hasPrefix("s") {
                selectionMode = answer
                break
            }
            // A silent fallback here (e.g. defaulting to "all channels" for any unrecognized
            // input) previously let a mistyped answer — someone reading "[a]...ou une
            // [s]élection ?" and typing a channel count like "2" instead of a letter — silently
            // run the full-device benchmark with zero indication anything was misunderstood.
            print(ConsoleUI.colored("Réponse non reconnue (\"\(answer)\") — tape \"a\" (tous) ou \"s\" (sélection).", .yellow))
        }

        if selectionMode.hasPrefix("s") {
            let outSpec = ConsoleUI.promptWithDefault("Canaux de sortie à tester (ex: 1-7 ou 1,3,5)", default: "1-\(device.outputChannelCount)")
            let inSpec = ConsoleUI.promptWithDefault("Canaux d'entrée à tester (ex: 1-7)", default: "1-\(device.inputChannelCount)")
            options.outputChannels = outSpec
            options.inputChannels = inSpec
            print(ConsoleUI.colored("→ Sélection personnalisée : sorties \(outSpec), entrées \(inSpec).", .green))
        } else {
            options.auto = true
            print(ConsoleUI.colored("→ Tous les canaux (auto).", .green))
        }
        print("")

        let bufferSizesDefault = TestPlanResolver.defaultBufferSizes.map(String.init).joined(separator: ",")
        let bufferSizesAnswer = ConsoleUI.promptWithDefault("Tailles de buffer à tester (CSV)", default: bufferSizesDefault)
        options.bufferSizes = bufferSizesAnswer

        let durationAnswer = ConsoleUI.promptWithDefault("Durée du test de stabilité par taille (ex: 60s, 5m)", default: "60s")
        options.duration = durationAnswer

        let pingRepsAnswer = ConsoleUI.promptWithDefault("Répétitions du ping par paire", default: "\(TestPlanResolver.defaultPingRepetitions)")
        options.pingRepetitions = Int(pingRepsAnswer)

        let pingModeAnswer = ConsoleUI.promptWithDefault("Mode du ping — [p]arallèle (rapide) ou [s]équentiel (isolation max)", default: "p").lowercased()
        options.pingSequential = pingModeAnswer.hasPrefix("s")

        let cpuLoadDefault = TestPlanResolver.defaultCPULoadLevelsPercent.map(String.init).joined(separator: ",")
        let cpuLoadAnswer = ConsoleUI.promptWithDefault(
            "Répéter le test de stabilité sous charge CPU simulée ? CSV de %, ex. \(cpuLoadDefault) (vide = désactivé)",
            default: ""
        )
        if !cpuLoadAnswer.trimmingCharacters(in: .whitespaces).isEmpty {
            options.cpuLoadLevels = cpuLoadAnswer
        }

        let memPressureAnswer = ConsoleUI.promptWithDefault(
            "Ajouter une pression mémoire simulée pendant ces passes chargées ? [o]ui / [n]on",
            default: "n"
        ).lowercased()
        if memPressureAnswer.hasPrefix("o") {
            options.memPressure = true
        }

        let signalAnswer = ConsoleUI.promptWithDefault(
            "Signal du test de stabilité — [s]inusoïde (défaut), bruit [b]lanc, bruit [r]ose ou [f]ichier WAV (comparaison exacte)",
            default: "s"
        ).lowercased()
        if signalAnswer.hasPrefix("r") {
            options.stabilitySignal = "pink"
        } else if signalAnswer.hasPrefix("b") {
            options.stabilitySignal = "noise"
        } else if signalAnswer.hasPrefix("f") {
            options.stabilitySignal = "wav"
            let typedPath = ConsoleUI.promptWithDefault("Chemin du fichier WAV (laisse vide pour ouvrir un sélecteur de fichier)", default: "")
            if typedPath.isEmpty {
                if let picked = FilePicker.pickFile(prompt: "Sélectionne le fichier WAV de référence") {
                    print(ConsoleUI.colored("→ \(picked)", .green))
                    options.wavFilePath = picked
                } else {
                    print(ConsoleUI.colored("Aucun fichier sélectionné.", .dim))
                }
            } else {
                options.wavFilePath = typedPath
            }
        } else {
            options.stabilitySignal = "sine"
        }

        print("")
        return (device, options)
    }
}
