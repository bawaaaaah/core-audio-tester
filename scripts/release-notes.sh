#!/usr/bin/env bash
#
# Generates release-notes.md for a tag, based on what scripts/package.sh put in dist/.
# Usage: scripts/release-notes.sh <tag>

set -euo pipefail

cd "$(dirname "$0")/.."

TAG="${1:?usage: scripts/release-notes.sh <tag>}"

TARBALL=$(basename dist/*.tar.gz)
CHECKSUM=$(awk '{print $1}' dist/*.tar.gz.sha256)
DIRNAME="${TARBALL%.tar.gz}"

cat > release-notes.md <<NOTES
Binaire **macOS universel** (Apple Silicon + Intel), prêt à l'emploi — aucune compilation nécessaire.

## Installation

\`\`\`bash
tar -xzf ${TARBALL}
cd ${DIRNAME}
xattr -dr com.apple.quarantine core-audio-tester
./core-audio-tester --list-devices
\`\`\`

Le \`xattr\` retire la mise en quarantaine Gatekeeper : le binaire est signé ad-hoc, pas notarisé.
Au premier test utilisant des entrées, macOS demande l'accès au micro **pour votre terminal**
(Réglages Système → Confidentialité et sécurité → Microphone).

## Prérequis

- macOS 15 (Sequoia) ou plus récent

## Vérification de l'archive

\`\`\`
${CHECKSUM}  ${TARBALL}
\`\`\`
NOTES

echo "--- release-notes.md ---"
cat release-notes.md
