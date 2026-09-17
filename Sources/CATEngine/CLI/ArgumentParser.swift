import Foundation

public struct RawCLIOptions {
    public init() {}

    public var listDevices = false
    public var help = false
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

    public var hasExplicitChannelSelection: Bool {
        inputChannels != nil || outputChannels != nil || pairs != nil
    }
}

public enum ArgumentParserError: Error, CustomStringConvertible {
    case unknownFlag(String)
    case missingValue(String)
    case conflictingAutoAndSelection
    case conflictingWavFileAndSignal

    public var description: String {
        switch self {
        case .unknownFlag(let flag):
            return "Unknown flag: \(flag). Use --help to see available options."
        case .missingValue(let flag):
            return "Flag \(flag) requires a value."
        case .conflictingAutoAndSelection:
            return "--auto cannot be combined with --in/--out/--pairs. Omit --auto to test a specific channel selection, or omit the selection flags to run the full auto benchmark."
        case .conflictingWavFileAndSignal:
            return "--wav-file can only be used with --stability-signal wav (or by omitting --stability-signal entirely)."
        }
    }
}

public enum ArgumentParser {
    private static let noValueFlags: Set<String> = ["--list-devices", "--help", "-h", "--auto", "--exclusive", "--yes", "--ping-sequential", "--cpu-load", "--mem-pressure"]

    public static func parse(_ arguments: [String]) throws -> RawCLIOptions {
        var options = RawCLIOptions()
        var iterator = arguments.makeIterator()

        func nextValue(for flag: String) throws -> String {
            guard let value = iterator.next() else { throw ArgumentParserError.missingValue(flag) }
            return value
        }

        while let arg = iterator.next() {
            var flag = arg
            var inlineValue: String?
            if let eq = arg.firstIndex(of: "="), arg.hasPrefix("--") {
                flag = String(arg[arg.startIndex..<eq])
                inlineValue = String(arg[arg.index(after: eq)...])
            }

            func value() throws -> String {
                if let inlineValue { return inlineValue }
                return try nextValue(for: flag)
            }

            switch flag {
            case "--list-devices": options.listDevices = true
            case "--help", "-h": options.help = true
            case "--device": options.device = try value()
            case "--in": options.inputChannels = try value()
            case "--out": options.outputChannels = try value()
            case "--pairs": options.pairs = try value()
            case "--buffer-sizes": options.bufferSizes = try value()
            case "--ping-reps": options.pingRepetitions = Int(try value())
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
            case "--mem-pressure-mb": options.memPressureMB = Int(try value())
            case "--dump-incident-audio": options.dumpIncidentAudioPath = try value()
            case "--wav-file": options.wavFilePath = try value()
            default:
                throw ArgumentParserError.unknownFlag(flag)
            }
        }

        if options.auto && options.hasExplicitChannelSelection {
            throw ArgumentParserError.conflictingAutoAndSelection
        }
        if options.wavFilePath != nil, let signal = options.stabilitySignal,
           !["wav", "wav-file", "file"].contains(signal.lowercased())
        {
            throw ArgumentParserError.conflictingWavFileAndSignal
        }

        return options
    }

    public static let usageText = """
    core-audio-tester — CoreAudio buffer-size benchmark

    USAGE:
      core-audio-tester                          Assistant interactif (si aucun --device n'est donné)
      core-audio-tester --list-devices
      core-audio-tester --device <name-or-uid> [options]

    OPTIONS:
      --device <name-or-uid>     Target CoreAudio device (e.g. "WING")
      --in <spec>                Input channels to test, e.g. "1-7" or "1,3,5" (default: all, see --auto)
      --out <spec>                Output channels to test, e.g. "1-7"
      --pairs <spec>             Explicit output:input pairs, e.g. "1:1,2:2,5:3" (overrides index-aligned pairing)
      --buffer-sizes <csv>       Buffer sizes to sweep, e.g. "32,64,128,256,512,1024,2048"
      --ping-reps <n>            Repetitions per pair for the latency ping test (default 20)
      --ping-sequential          Ping one pair at a time instead of the default parallel mode
      --duration <spec>          Stability test duration per buffer size, e.g. "60s", "5m" (default 60s)
      --config <path>            JSON config file (CLI flags override its fields)
      --auto                     Force full-device benchmark (default when no channel selection is given)
      --exclusive                Take hog mode (exclusive device access) during the run
      --cpu-load                 Also run the stability test under simulated CPU load (default levels 25,50,75,85,90,95%)
      --cpu-load-levels <csv>    Simulated CPU load levels to test, in %, e.g. "25,50,75" (implies --cpu-load)
      --stability-signal <kind>  Stability test signal: "sine" (default), "noise" (white noise), "pink" (pink noise), or "wav" (compare against --wav-file) — noise/wav modes use an exact sample-accurate comparison
      --wav-file <path>          WAV file to play and verify instead of synthetic noise (implies --stability-signal wav). Mono broadcasts to every output channel; stereo alternates odd/even channels; an N-channel file cycles across more output channels than it has tracks. Must match the device's sample rate exactly — resample externally (e.g. afconvert) if it doesn't. Default test duration becomes the file's own length unless --duration overrides it (a longer duration loops the file)
      --mem-pressure             Also simulate memory pressure during each loaded stability pass (implies --cpu-load if no levels given)
      --mem-pressure-mb <n>      Memory pressure target size in MB (implies --mem-pressure) — may slow other apps during the test
      --dump-incident-audio <dir> Noise/wav signal modes only: for each stability incident, write a stereo WAV (L=captured, R=expected reference) with ~300ms of context on each side, for manual listening/inspection (max 5 per channel)
      --yes                      Skip the pre-run time-estimate confirmation prompt
      --out-path <path>          Base path for the generated report files (default: ./core-audio-tester-report)
      --list-devices             List CoreAudio devices and exit
      --help                     Show this help
    """
}
