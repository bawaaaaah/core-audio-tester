#!/usr/bin/env bash
#
# Builds a universal (arm64 + x86_64) release binary and packages it into
# dist/ as a tarball plus a SHA-256 checksum file.
#
# Usage: scripts/package.sh [version]
#   version defaults to the current git tag, else <branch>-<short-sha>, else "dev".

set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
    if VERSION=$(git describe --tags --exact-match 2>/dev/null); then
        :
    elif SHA=$(git rev-parse --short HEAD 2>/dev/null); then
        VERSION="dev-$SHA"
    else
        VERSION="dev"
    fi
fi

NAME="core-audio-tester"
STAGE_DIR="dist/${NAME}-${VERSION}-macos-universal"
TARBALL="dist/${NAME}-${VERSION}-macos-universal.tar.gz"

# Each slice is built in its own scratch path and lipo'd together afterwards, rather than
# via `swift build --arch arm64 --arch x86_64`. Passing both architectures to a single
# invocation routes through the Xcode build system and fails with "Unexpected duplicate
# tasks" / "missing target configuration" on Swift 6.1.x (what the macOS CI runners ship),
# even though it works on newer toolchains. Building one arch at a time works everywhere.
build_slice() {
    local arch="$1"
    local scratch=".build/universal-${arch}"
    echo "==> Building release slice for ${arch}" >&2
    swift build -c release --arch "$arch" --scratch-path "$scratch" >&2
    echo "$(swift build -c release --arch "$arch" --scratch-path "$scratch" --show-bin-path)/${NAME}"
}

ARM64_BIN="$(build_slice arm64)"
X86_64_BIN="$(build_slice x86_64)"

for slice in "$ARM64_BIN" "$X86_64_BIN"; do
    if [[ ! -f "$slice" ]]; then
        echo "error: built binary not found at $slice" >&2
        exit 1
    fi
done

echo "==> Creating universal binary"
BIN_PATH=".build/universal/${NAME}"
mkdir -p "$(dirname "$BIN_PATH")"
lipo -create -output "$BIN_PATH" "$ARM64_BIN" "$X86_64_BIN"

echo "==> Ad-hoc signing"
codesign --force --sign - --timestamp=none "$BIN_PATH"

echo "==> Staging $STAGE_DIR"
rm -rf "$STAGE_DIR" "$TARBALL"
mkdir -p "$STAGE_DIR"
cp "$BIN_PATH" "$STAGE_DIR/"
cp README.md README-fr.md LICENSE "$STAGE_DIR/" 2>/dev/null || true

echo "==> Architectures"
lipo -info "$STAGE_DIR/$NAME"

echo "==> Creating $TARBALL"
tar -czf "$TARBALL" -C dist "$(basename "$STAGE_DIR")"
rm -rf "$STAGE_DIR"

echo "==> Checksum"
( cd dist && shasum -a 256 "$(basename "$TARBALL")" > "$(basename "$TARBALL").sha256" )
cat "${TARBALL}.sha256"

echo "==> Done"
ls -lh dist/
