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
with any CoreAudio device, including the Mac's built-in input and output.

> **Note:** the tool's own console output and interactive wizard are in French.

## What it does

For **each requested buffer size** (32, 64, 128… frames):

1. **Ping / latency test** — emits an MLS signal on each output, captures it back on the
   matching input and measures the delay by cross-correlation. Repeated N times to get
   min / median / max / standard deviation, either in parallel across all pairs or
   sequentially.
2. **Stability test** — plays a reference signal continuously for the requested duration
   and compares the captured input against the reference, sample by sample, to detect
   incidents. Choose the signal: sine, white noise, pink noise, or **your own WAV file**.
3. **Load test** (optional) — replays the stability test at several simulated CPU load
   levels (25%, 50%, 75%, 85%, 90%, 95%) and, if requested, under memory pressure — this
   is where buffer sizes that are too low give out.

At the end it generates an **HTML report** and a **JSON export**, plus a terminal summary
with the recommended buffer size.

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

# Verify the device against your own WAV file
core-audio-tester --device "MOTU" --wav-file ./reference-44100.wav
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
| `--stability-signal <kind>` | `sine` (default), `noise`, `pink` or `wav` |
| `--wav-file <path>` | Reference WAV file (implies `--stability-signal wav`) |
| `--cpu-load` | Also replay the stability test under simulated CPU load |
| `--cpu-load-levels <csv>` | Load levels in %, e.g. `25,50,75` (implies `--cpu-load`) |
| `--mem-pressure` / `--mem-pressure-mb <n>` | Add simulated memory pressure |
| `--dump-incident-audio <dir>` | Write a stereo WAV (captured / reference) per incident |
| `--exclusive` | Take exclusive device access (hog mode) |
| `--config <path>` | JSON config file (CLI flags take precedence) |
| `--out-path <path>` | Base path for the report files (default `./core-audio-tester-report`) |
| `--yes` | Skip the duration-estimate confirmation prompt |
| `--help` | Full help |

### Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success — no incident at any buffer size |
| `1` | Finished, but at least one buffer size was not perfectly clean |
| `64` | Usage error (unknown flag, invalid config…) |
| `65` | Device error (not found, configuration refused…) |
| `77` | Microphone access denied |
| `130` | Interrupted (Ctrl-C) — the partial report is still written |

## Generated output

- `core-audio-tester-report.html` — full report: latency tables, incident timeline,
  per-buffer-size comparison, final recommendation
- `core-audio-tester-report.json` — the same data, script-friendly
- `--dump-incident-audio <dir>` — one stereo WAV per incident (left = captured, right =
  expected reference), with ~300 ms of context on each side, so you can hear what actually
  happened

## Architecture

```
Sources/
  CATEngine/        CoreAudio HAL layer: device discovery and configuration, real-time
                    I/O engine, lock-free ring buffer, overload monitoring, CPU/memory
                    load generators, CLI parsing and test plan
  CATAnalysis/      Offline analysis: cross-correlation onset detection, latency
                    statistics, glitch detectors (streaming and exact), recommendation
                    engine, HTML/JSON/terminal rendering
  core-audio-tester/ Executable: entry point, interactive wizard, console UI
Tests/              Unit tests for the ring buffer, channel specs and the onset/glitch
                    detectors
```

## Development

```bash
swift build          # debug build
swift test           # unit tests
swift build -c release
scripts/package.sh   # universal binary + tarball + checksum in dist/
```

GitHub Actions CI builds and tests every push and pull request on macOS, and attaches the
packaged universal binary to the run's artifacts. Pushing a `v*` tag triggers the release
workflow, which publishes the archive and its checksum to the Releases page:

```bash
git tag -a v1.0.0 -m "v1.0.0"
git push origin v1.0.0
```

## License

MIT — see [LICENSE](LICENSE).
