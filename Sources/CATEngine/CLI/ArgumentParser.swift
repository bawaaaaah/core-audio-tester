import Foundation

public struct RawCLIOptions {
    public init() {}

    public var listDevices = false
    public var help = false
    public var version = false
    public var device: String?
    public var inputChannels: String?
    public var outputChannels: String?
    public var pairs: String?
    public var bufferSizes: String?
    public var pingRepetitions: Int?
    public var pingSequential = false
    public var duration: String?
    public var configPath: String?
    public var auto = false
    public var exclusive = false
    public var skipConfirmation = false
    public var outputBasePath: String?
    public var cpuLoad = false
    public var cpuLoadLevels: String?
    public var stabilitySignal: String?
    public var memPressure = false
    public var memPressureMB: Int?
    public var dumpIncidentAudioPath: String?
    public var wavFilePath: String?
    public var outputLevelDBFS: Double?
    public var ioLoadPercent: Int?

    public var hasExplicitChannelSelection: Bool {
        inputChannels != nil || outputChannels != nil || pairs != nil
    }
}

public enum ArgumentParserError: Error, CustomStringConvertible {
    case unknownFlag(String)
    case unexpectedArgument(String)
    case missingValue(String)
    case invalidNumber(flag: String, value: String)
    case conflictingAutoAndSelection
    case conflictingWavFileAndSignal

    public var description: String {
        switch self {
        case .unknownFlag(let flag):
            return "Option inconnue : \(flag). Utilise --help pour la liste des options."
        case .unexpectedArgument(let argument):
            return "Argument inattendu : \"\(argument)\". Les options s'écrivent --nom valeur (voir --help)."
        case .missingValue(let flag):
            return "L'option \(flag) attend une valeur."
        case .invalidNumber(let flag, let value):
            return "Valeur invalide pour \(flag) : \"\(value)\" (nombre attendu)."
        case .conflictingAutoAndSelection:
            return "--auto ne se combine pas avec --in/--out/--pairs : retire --auto pour tester une sélection, ou retire la sélection pour le benchmark complet."
        case .conflictingWavFileAndSignal:
            return "--wav-file ne s'utilise qu'avec --stability-signal wav (ou sans --stability-signal)."
        }
    }
}

public enum ArgumentParser {
    public static func parse(_ arguments: [String]) throws -> RawCLIOptions {
        var options = RawCLIOptions()
        var index = 0

        while index < arguments.count {
            let arg = arguments[index]
            index += 1
            guard arg.hasPrefix("-") else {
                throw ArgumentParserError.unexpectedArgument(arg)
            }
            var flag = arg
            var inlineValue: String?
            if arg.hasPrefix("--"), let eq = arg.firstIndex(of: "=") {
                flag = String(arg[arg.startIndex..<eq])
                inlineValue = String(arg[arg.index(after: eq)...])
            }

            func value() throws -> String {
                if let inlineValue { return inlineValue }
                // A following "--flag" means this one's value was forgotten, not that the value
                // is literally "--flag".
                guard index < arguments.count, !arguments[index].hasPrefix("--") else {
                    throw ArgumentParserError.missingValue(flag)
                }
                defer { index += 1 }
                return arguments[index]
            }
            func intValue() throws -> Int {
                let raw = try value()
                guard let parsed = Int(raw.trimmingCharacters(in: .whitespaces)) else {
                    throw ArgumentParserError.invalidNumber(flag: flag, value: raw)
                }
                return parsed
            }
            func levelValue() throws -> Double {
                let raw = try value()
                var text = raw.trimmingCharacters(in: .whitespaces).lowercased()
                for suffix in ["dbfs", "db"] where text.hasSuffix(suffix) {
                    text = String(text.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
                    break
                }
                guard let parsed = Double(text), parsed.isFinite else {
                    throw ArgumentParserError.invalidNumber(flag: flag, value: raw)
                }
                return parsed
            }

            switch flag {
            case "--list-devices": options.listDevices = true
            case "--help", "-h": options.help = true
            case "--version": options.version = true
            case "--device": options.device = try value()
            case "--in": options.inputChannels = try value()
            case "--out": options.outputChannels = try value()
            case "--pairs": options.pairs = try value()
            case "--buffer-sizes": options.bufferSizes = try value()
            case "--ping-reps": options.pingRepetitions = try intValue()
            case "--ping-sequential": options.pingSequential = true
            case "--duration": options.duration = try value()
            case "--config": options.configPath = try value()
            case "--auto": options.auto = true
            case "--exclusive": options.exclusive = true
            case "--yes": options.skipConfirmation = true
            case "--out-path": options.outputBasePath = try value()
            case "--cpu-load": options.cpuLoad = true
            case "--cpu-load-levels": options.cpuLoadLevels = try value()
            case "--stability-signal": options.stabilitySignal = try value()
            case "--mem-pressure": options.memPressure = true
            case "--mem-pressure-mb": options.memPressureMB = try intValue()
            case "--dump-incident-audio": options.dumpIncidentAudioPath = try value()
            case "--wav-file": options.wavFilePath = try value()
            case "--level": options.outputLevelDBFS = try levelValue()
            case "--io-load": options.ioLoadPercent = try intValue()
            default:
                throw ArgumentParserError.unknownFlag(flag)
            }
        }

        if options.auto && options.hasExplicitChannelSelection {
            throw ArgumentParserError.conflictingAutoAndSelection
        }
        if options.wavFilePath != nil, let signal = options.stabilitySignal,
           !TestPlanResolver.wavSignalAliases.contains(signal.lowercased())
        {
            throw ArgumentParserError.conflictingWavFileAndSignal
        }

        return options
    }

    public static let usageText = """
    core-audio-tester — benchmark CoreAudio des tailles de buffer

    UTILISATION :
      core-audio-tester                          Assistant interactif (sans --device)
      core-audio-tester --list-devices
      core-audio-tester --device <nom-ou-uid> [options]

    OPTIONS :
      --device <nom-ou-uid>       Interface CoreAudio à tester (ex. "WING")
      --in <spec>                 Entrées à tester, ex. "1-7" ou "1,3,5" (par défaut : toutes, voir --auto)
      --out <spec>                Sorties à tester, ex. "1-7" (appariées aux entrées dans l'ordre)
      --pairs <spec>              Paires sortie:entrée explicites, ex. "1:1,2:2,5:3" (patch croisé)
      --buffer-sizes <csv>        Tailles à balayer, ex. "32,64,128,256,512,1024,2048"
      --ping-reps <n>             Répétitions du ping de latence par paire (défaut 20)
      --ping-sequential           Un ping à la fois au lieu du mode parallèle par défaut
      --duration <spec>           Durée du test de stabilité par taille, ex. "60s", "5m" (défaut 60s)
      --level <dBFS>              Niveau crête de tous les signaux de test (défaut -12 dBFS, de -60 à -3)
      --stability-signal <type>   Signal de stabilité : "sine" (défaut), "noise" (bruit blanc), "pink"
                                  (bruit rose) ou "wav" (fichier, voir --wav-file). Les modes bruit/wav
                                  comparent échantillon par échantillon : ils exigent une boucle
                                  numérique transparente (bit-exact, gain compensé automatiquement).
                                  Pour une boucle analogique, garde "sine".
      --wav-file <chemin>         Fichier WAV de référence (implique --stability-signal wav). Mono :
                                  diffusé sur toutes les sorties ; stéréo : alterne canaux impairs/pairs ;
                                  N canaux : répartis en boucle. Doit être à la fréquence de l'interface
                                  (rééchantillonne avant avec afconvert si besoin). Durée par défaut : celle
                                  du fichier, sauf --duration (le fichier boucle alors).
      --cpu-load                  Rejoue le test de stabilité sous charge CPU simulée
                                  (paliers par défaut 25,50,75,85,90,95 %)
      --cpu-load-levels <csv>     Paliers de charge CPU en %, ex. "25,50,75" (implique --cpu-load)
      --mem-pressure              Ajoute une pression mémoire simulée pendant ces passes chargées
      --mem-pressure-mb <n>       Taille de la pression mémoire en Mo (implique --mem-pressure)
      --io-load <pct>             Occupe <pct> % de chaque cycle d'E/S dans le callback audio pendant les
                                  tests de stabilité (0-90), pour émuler la charge DSP d'une vraie appli
      --exclusive                 Prend l'accès exclusif à l'interface (hog mode) pendant le test
      --dump-incident-audio <dir> Écrit un WAV stéréo par incident (G = capturé, D = attendu),
                                  ~300 ms de contexte de chaque côté (5 max par canal et par passe)
      --config <chemin>           Fichier de configuration JSON (les options CLI l'emportent)
      --out-path <chemin>         Base des fichiers de rapport (défaut ./core-audio-tester-report)
      --yes                       Pas de confirmation avant le lancement
      --list-devices              Liste les interfaces CoreAudio et quitte
      --version                   Affiche la version et quitte
      --help                      Affiche cette aide
    """
}
