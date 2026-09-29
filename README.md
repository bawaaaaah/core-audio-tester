# core-audio-tester

[![CI](https://github.com/bawaaaaah/core-audio-tester/actions/workflows/ci.yml/badge.svg)](https://github.com/bawaaaaah/core-audio-tester/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/bawaaaaah/core-audio-tester?sort=semver)](https://github.com/bawaaaaah/core-audio-tester/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

*English · [Français](README-fr.md)*

A command-line CoreAudio benchmark for macOS: it sweeps your audio interface's buffer
sizes, measures **real round-trip latency** and hunts for **glitches** (dropouts,
discontinuities, overloads) under load, then recommends the lowest buffer size that stays
perfectly stable.

Built for multichannel interfaces (Behringer WING, RME, MOTU, Focusrite…), but it works
with any CoreAudio device that has both inputs and outputs wired in a loopback. To loop
between two separate devices — for example the Mac's built-in output and input, which macOS
exposes as two distinct devices — create an aggregate device in *Audio MIDI Setup* first.

> **Note:** the tool's own console output, help, interactive wizard and reports are in French.

## What it does

For **each requested buffer size** (32, 64, 128… frames):

1. **Ping / latency test** — emits an MLS signal on each output, captures it back on the
   matching input and measures the delay by cross-correlation. Repeated N times to get
   min / median / max / standard deviation, either in parallel across all pairs or
   sequentially.
2. **Stability test** — plays a reference signal continuously for the requested duration
   and compares the captured input against the reference, sample by sample, to detect
   incidents (clicks, silences, dropouts), overloads and abnormal IO stops. Choose the
   signal:
   - **sine** (default) — works on any loopback, analog or digital;
   - **white noise**, **pink noise** or **your own WAV file** — an exact comparison that
     needs a **bit-transparent digital loopback**. Loopback gain and polarity are
     compensated automatically; an analog path (converters, filtering) is reported as
     "unverified" instead of producing false clicks.
3. **Load test** (optional) — replays the stability test at several simulated CPU load
   levels (25%, 50%, 75%, 85%, 90%, 95%) and, if requested, under memory pressure.
   `--io-load` also adds compute load **inside the audio callback itself**, like a real
   DAW's processing — which is what makes buffer sizes that are too low give out in practice.

At the end it generates an **HTML report** and a **JSON export**, plus a terminal summary
with two recommendations:

- **"zero crash"**: the smallest buffer size that is clean at idle **and** at every load
  level tested;
- **"best trade-off"**: the smallest size whose weighted event rate (click 1, silence 2,
  dropout/overload/IO stop 3 per minute) stays within the tolerance.

A pass only counts as evidence when every channel was verified (locked onto its reference
signal), no captured audio was dropped for lack of analysis time, and it ran its full
duration: a muted or misrouted channel reads "unverified", never "clean".

> **Mind the level:** the test plays broadband bursts and a continuous signal on every
> tested output, at **−12 dBFS peak** by default (`--level` to adjust). Mute or turn down
> any PA, speaker or headphones connected to those outputs.

## Installation

### Prebuilt binary (recommended)

Download the latest archive from the
[**Releases**](https://github.com/bawaaaaah/core-audio-tester/releases/latest) page — it's
a **universal** binary (Apple Silicon + Intel), no compilation required.

```bash
tar -xzf core-audio-tester-vX.Y.Z-macos-universal.tar.gz
cd core-audio-tester-vX.Y.Z-macos-universal
xattr -dr com.apple.quarantine core-audio-tester
./core-audio-tester --list-devices
```

The `xattr` call strips the Gatekeeper quarantine flag: the binary is ad-hoc signed, not
notarized by Apple. Verify the archive with the `.sha256` file published alongside it:

```bash
shasum -a 256 -c core-audio-tester-vX.Y.Z-macos-universal.tar.gz.sha256
```

### From source

```bash
git clone https://github.com/bawaaaaah/core-audio-tester.git
cd core-audio-tester
swift build -c release
.build/release/core-audio-tester --list-devices
```

To reproduce the published archive exactly (universal binary + tarball + checksum):

```bash
scripts/package.sh
```

### Requirements

- macOS 15 (Sequoia) or later
- To build: Swift 6.0+ (Xcode 16 or the Command Line Tools)

### Microphone permission

Tests that use inputs need microphone access. macOS grants that permission to the
**terminal that launches the binary**, not to the binary itself: accept the prompt on
first run, or enable it under *System Settings → Privacy & Security → Microphone*. Without
it, the tool exits with code `77`.

## Usage

### Interactive wizard

Launched without `--device`, the tool opens a wizard that walks you through picking the
device, the channels and the parameters:

```bash
core-audio-tester
```

### Command-line examples

```bash
# List the available CoreAudio devices
core-audio-tester --list-devices

# Full automatic benchmark across the whole device
core-audio-tester --device "WING" --auto --yes

# Specific channels, specific buffer sizes, 2 minutes of stability per buffer
core-audio-tester --device "WING" \
  --out 1-8 --in 1-8 \
  --buffer-sizes 32,64,128,256 \
  --duration 2m

# Explicit output:input pairs (cross patch)
core-audio-tester --device "RME" --pairs "1:1,2:2,5:3"

# Demanding test: pink noise + CPU load + memory pressure + incident audio dump
core-audio-tester --device "WING" --auto \
  --stability-signal pink \
  --cpu-load-levels 50,75,90 \
  --mem-pressure-mb 4096 \
  --dump-incident-audio ./incidents \
  --yes

# Verify the device against your own WAV file (digital loopback)
core-audio-tester --device "MOTU" --wav-file ./reference-44100.wav

# Closer to a real session: exclusive access, lower level,
# 40% of every cycle spent inside the audio callback
core-audio-tester --device "WING" --exclusive --level -20 --io-load 40
```

### Options

| Option | Effect |
| --- | --- |
| `--device <name-or-uid>` | Target CoreAudio device (e.g. `"WING"`) |
| `--list-devices` | List devices and exit |
| `--in <spec>` / `--out <spec>` | Channels to test, e.g. `1-7` or `1,3,5` |
| `--pairs <spec>` | Explicit output:input pairs, e.g. `1:1,2:2,5:3` |
| `--auto` | Full-device benchmark (the default when no channel selection is given) |
| `--buffer-sizes <csv>` | Sizes to sweep, e.g. `32,64,128,256,512,1024,2048` |
| `--duration <spec>` | Stability test duration per buffer, e.g. `60s`, `5m` (default `60s`) |
| `--ping-reps <n>` | Repetitions per pair for the latency test (default 20) |
| `--ping-sequential` | Ping one pair at a time instead of the default parallel mode |
| `--stability-signal <kind>` | `sine` (default, any loopback), `noise`, `pink` or `wav` (bit-transparent digital loopback) |
| `--wav-file <path>` | Reference WAV file (implies `--stability-signal wav`) |
| `--cpu-load` | Also replay the stability test under simulated CPU load |
| `--cpu-load-levels <csv>` | Load levels in %, e.g. `25,50,75` (implies `--cpu-load`) |
| `--mem-pressure` / `--mem-pressure-mb <n>` | Add simulated memory pressure |
| `--level <dBFS>` | Peak level of every test signal (default `-12`, from `-60` to `-3`) |
| `--io-load <pct>` | Spend `pct`% of each IO cycle inside the audio callback during stability tests (0-90) |
| `--dump-incident-audio <dir>` | Write a stereo WAV (captured / expected) per incident, at most 5 per channel and pass |
| `--exclusive` | Take exclusive device access (hog mode): CoreAudio's buffer size is a per-process setting, and another application using the same device can skew the test |
| `--config <path>` | JSON config file (CLI flags take precedence) |
| `--out-path <path>` | Base path for the report files (default `./core-audio-tester-report`) |
| `--yes` | Skip the duration-estimate confirmation prompt |
| `--version` | Print the version |
| `--help` | Full help |

### Configuration file

`--config <path>` reads a JSON object whose keys are all optional; command-line options take
precedence. An unknown key (a typo) is an error.

```json
{
  "device": "WING",
  "outputChannels": "1-8",
  "inputChannels": "1-8",
  "bufferSizes": [64, 128, 256],
  "stabilityDurationSeconds": 120,
  "stabilitySignal": "sine",
  "cpuLoadLevelsPercent": [50, 75],
  "outputLevelDBFS": -18,
  "ioLoadPercent": 40,
  "exclusiveAccess": true
}
```

Accepted keys: `device`, `inputChannels`, `outputChannels`, `pairs`
(`[{"output": 1, "input": 1}]`), `bufferSizes`, `pingRepetitions`, `pingMode`
(`parallel`/`sequential`), `stabilityDurationSeconds`, `sporadicToleranceWeightedPerMinute`,
`exclusiveAccess`, `cpuLoadLevelsPercent`, `stabilitySignal`, `memoryPressureMB`, `wavFile`,
`outputLevelDBFS`, `ioLoadPercent`.

### Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success — no incident at any buffer size, idle or under load, and everything verified |
| `1` | Finished, but at least one pass was not perfectly clean or could not be verified |
| `64` | Usage error (unknown flag or invalid value, invalid config…) |
| `65` | Device error (not found, configuration refused, unplugged or sample rate changed mid-run — the partial report is then written) |
| `77` | Microphone access denied |
| `130` | Interrupted (Ctrl-C) — the partial report is still written |

## Generated output

- `core-audio-tester-report.html` — full report: latency tables, incident timeline,
  per-buffer-size comparison, final recommendation
- `core-audio-tester-report.json` — the same data, script-friendly
- `--dump-incident-audio <dir>` — one stereo WAV per incident (left = captured, right =
  expected reference), with ~300 ms of context on each side, so you can hear what actually
  happened. Named `buf<size>_<repos|cpuNN>_chNN_<type>_t<seconds>_<n>.wav`

## Architecture

```
Sources/
  CATEngine/        CoreAudio HAL layer: device discovery and configuration, real-time
                    I/O engine, lock-free ring buffer, overload monitoring, CPU/memory
                    load generators, CLI parsing and test plan
  CATAnalysis/      Offline analysis: MLS ping and cross-correlation, latency statistics,
                    a single glitch detector (GlitchDetector) driven by a sine or
                    noise/WAV reference, recommendation engine, HTML/JSON/terminal rendering
  core-audio-tester/ Executable: entry point, interactive wizard, console UI
Tests/              Unit tests (CLI, configuration, models, WAV, MLS, detectors) and
                    ping/stability session tests over a simulated loopback
```

## Development

```bash
swift build          # debug build
swift test           # unit tests
swift build -c release
scripts/package.sh   # universal binary + tarball + checksum in dist/
```

`scripts/package.sh` stamps the version into the binary (`core-audio-tester --version`, the
JSON report's `toolVersion`); a plain `swift build` reports `dev`.

GitHub Actions CI builds and tests every push and pull request on macOS, and attaches the
packaged universal binary to the run's artifacts. Pushing a `v*` tag triggers the release
workflow, which publishes the archive and its checksum to the Releases page:

```bash
git tag -a v1.0.0 -m "v1.0.0"
git push origin v1.0.0
```

## License

MIT — see [LICENSE](LICENSE).
