#!/usr/bin/env bash
#
# Generates release-notes.md for a tag, based on what scripts/package.sh put in dist/.
# The notes are bilingual: an English section, then a French one, then the checksum
# (language-neutral, so it is published once rather than duplicated per language).
#
# Usage: scripts/release-notes.sh <tag>

set -euo pipefail

cd "$(dirname "$0")/.."

TAG="${1:?usage: scripts/release-notes.sh <tag>}"

# Relative links don't resolve in a GitHub release body, so the README links are absolute
# and pinned to this tag — a reader following them gets the docs as of this release, not
# whatever main happens to say later.
# Derived with basename/dirname rather than a regex: it handles both the SSH
# (git@github.com:owner/repo.git) and HTTPS (https://github.com/owner/repo.git) remote
# forms, and BSD sed has no non-greedy operator to do it cleanly in one expression.
REPO="${GITHUB_REPOSITORY:-}"
if [[ -z "$REPO" ]]; then
    REMOTE_URL="$(git config --get remote.origin.url)"
    REMOTE_URL="${REMOTE_URL%.git}"
    REMOTE_URL="${REMOTE_URL#*://}"   # drop an https:// scheme, if present
    REMOTE_URL="${REMOTE_URL#*@}"     # drop a git@ user, if present
    REMOTE_URL="${REMOTE_URL/:/\/}"   # host:owner/repo -> host/owner/repo
    REPO="$(basename "$(dirname "$REMOTE_URL")")/$(basename "$REMOTE_URL")"
fi
DOCS_BASE="https://github.com/${REPO}/blob/${TAG}"

TARBALL=$(basename dist/*.tar.gz)
CHECKSUM=$(awk '{print $1}' dist/*.tar.gz.sha256)
DIRNAME="${TARBALL%.tar.gz}"

cat > release-notes.md <<NOTES
## English

**macOS universal binary** (Apple Silicon + Intel), ready to run — no compilation required.

### Installation

\`\`\`bash
tar -xzf ${TARBALL}
cd ${DIRNAME}
xattr -dr com.apple.quarantine core-audio-tester
./core-audio-tester --list-devices
\`\`\`

The \`xattr\` call strips the Gatekeeper quarantine flag: the binary is ad-hoc signed, not
notarized by Apple. On the first test that uses inputs, macOS asks for microphone access
**for your terminal**, not for the binary itself
(System Settings → Privacy & Security → Microphone).

Requires **macOS 15 (Sequoia) or later**. Full documentation: [README.md](${DOCS_BASE}/README.md).

---

## Français

Binaire **macOS universel** (Apple Silicon + Intel), prêt à l'emploi — aucune compilation
nécessaire.

### Installation

\`\`\`bash
tar -xzf ${TARBALL}
cd ${DIRNAME}
xattr -dr com.apple.quarantine core-audio-tester
./core-audio-tester --list-devices
\`\`\`

Le \`xattr\` retire la mise en quarantaine Gatekeeper : le binaire est signé ad-hoc, pas
notarisé par Apple. Au premier test utilisant des entrées, macOS demande l'accès au micro
**pour votre terminal**, pas pour le binaire lui-même
(Réglages Système → Confidentialité et sécurité → Microphone).

Nécessite **macOS 15 (Sequoia) ou plus récent**. Documentation complète :
[README-fr.md](${DOCS_BASE}/README-fr.md).

---

## Checksum · Somme de contrôle

\`\`\`
${CHECKSUM}  ${TARBALL}
\`\`\`
NOTES

echo "--- release-notes.md ---"
cat release-notes.md
