# core-audio-tester

[![CI](https://github.com/bawaaaaah/core-audio-tester/actions/workflows/ci.yml/badge.svg)](https://github.com/bawaaaaah/core-audio-tester/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/bawaaaaah/core-audio-tester?sort=semver)](https://github.com/bawaaaaah/core-audio-tester/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

*Français · [English](README.md)*

Benchmark CoreAudio en ligne de commande pour macOS : il balaie les tailles de buffer de
votre interface audio, mesure la **latence aller-retour réelle** et traque les **glitches**
(dropouts, discontinuités, overloads) sous charge, puis recommande la taille de buffer la
plus basse qui reste parfaitement stable.

Conçu pour les interfaces multicanales (Behringer WING, RME, MOTU, Focusrite…), mais
fonctionne avec n'importe quel périphérique CoreAudio qui a à la fois des entrées et des
sorties reliées en boucle. Pour boucler entre deux périphériques distincts — par exemple la
sortie et l'entrée intégrées du Mac, que macOS expose comme deux périphériques séparés —
créez d'abord un appareil agrégé dans *Configuration audio et MIDI*.

## Ce que fait l'outil

Pour **chaque taille de buffer** demandée (32, 64, 128… frames) :

1. **Test de ping / latence** — émet un signal MLS sur chaque sortie, le recapture sur
   l'entrée correspondante et mesure le délai par corrélation croisée. Répété N fois pour
   obtenir min / médiane / max / écart-type, en parallèle sur toutes les paires ou en
   séquentiel.
2. **Test de stabilité** — joue un signal de référence en continu pendant la durée
   demandée et compare l'entrée capturée à la référence, échantillon par échantillon, pour
   détecter les incidents (clics, silences, dropouts), les overloads et les arrêts d'E/S.
   Signal au choix :
   - **sinusoïde** (défaut) — fonctionne sur toute boucle, analogique ou numérique ;
   - **bruit blanc**, **bruit rose** ou **votre propre fichier WAV** — comparaison exacte,
     qui exige une boucle **numérique transparente** (bit-exact). Le gain et la polarité de
     la boucle sont compensés automatiquement ; une boucle analogique (convertisseurs,
     filtrage) est signalée « non vérifiée » plutôt que de produire de faux clics.
3. **Test sous charge** (optionnel) — rejoue le test de stabilité à différents paliers de
   charge CPU simulée (25 %, 50 %, 75 %, 85 %, 90 %, 95 %) et, si demandé, sous pression
   mémoire. `--io-load` ajoute en plus une charge de calcul **dans le callback audio
   lui-même**, comme le traitement d'un vrai DAW — c'est ce qui fait lâcher les buffers trop
   bas en conditions réelles.

À la fin, un **rapport HTML** et un **export JSON** sont générés, plus un résumé dans le
terminal avec deux recommandations :

- **« zéro crash »** : la plus petite taille propre au repos **et** à tous les paliers de
  charge testés ;
- **« meilleur compromis »** : la plus petite taille dont le taux d'événements pondéré
  (clic 1, silence 2, dropout/overload/arrêt d'E/S 3 par minute) reste sous la tolérance.

Une passe ne compte comme preuve que si tous ses canaux ont été vérifiés (verrouillés sur
leur signal de référence), qu'aucun audio capturé n'a été perdu faute de temps d'analyse et
qu'elle est allée au bout : un canal muet ou mal routé est « non vérifié », jamais
« propre ».

> **Attention au niveau :** le test envoie des rafales large bande et un signal continu sur
> toutes les sorties testées, à **−12 dBFS crête** par défaut (`--level` pour ajuster).
> Coupez ou baissez toute sono, enceinte ou casque relié à ces sorties.

## Installation

### Binaire précompilé (recommandé)

Téléchargez la dernière archive depuis la page
[**Releases**](https://github.com/bawaaaaah/core-audio-tester/releases/latest) — c'est un
binaire **universel** (Apple Silicon + Intel), aucune compilation nécessaire.

```bash
tar -xzf core-audio-tester-vX.Y.Z-macos-universal.tar.gz
cd core-audio-tester-vX.Y.Z-macos-universal
xattr -dr com.apple.quarantine core-audio-tester
./core-audio-tester --list-devices
```

Le `xattr` retire la mise en quarantaine Gatekeeper : le binaire est signé ad-hoc, pas
notarisé par Apple. Vérifiez l'archive avec le fichier `.sha256` publié à côté :

```bash
shasum -a 256 -c core-audio-tester-vX.Y.Z-macos-universal.tar.gz.sha256
```

### Depuis les sources

```bash
git clone https://github.com/bawaaaaah/core-audio-tester.git
cd core-audio-tester
swift build -c release
.build/release/core-audio-tester --list-devices
```

Pour reproduire exactement l'archive publiée (binaire universel + tarball + checksum) :

```bash
scripts/package.sh
```

### Prérequis

- macOS 15 (Sequoia) ou plus récent
- Pour compiler : Swift 6.0+ (Xcode 16 ou les Command Line Tools)

### Permission micro

Les tests utilisant des entrées ont besoin de l'accès au microphone. macOS attribue cette
permission au **terminal qui lance le binaire**, pas au binaire lui-même : acceptez la
demande au premier lancement, ou activez-la dans *Réglages Système → Confidentialité et
sécurité → Microphone*. Sans elle, l'outil s'arrête avec le code de sortie `77`.

## Utilisation

### Assistant interactif

Lancé sans `--device`, l'outil ouvre un assistant qui vous guide dans le choix du
périphérique, des canaux et des paramètres :

```bash
core-audio-tester
```

### Exemples en ligne de commande

```bash
# Lister les périphériques CoreAudio disponibles
core-audio-tester --list-devices

# Benchmark complet automatique sur tout le périphérique
core-audio-tester --device "WING" --auto --yes

# Canaux précis, buffers précis, 2 minutes de stabilité par buffer
core-audio-tester --device "WING" \
  --out 1-8 --in 1-8 \
  --buffer-sizes 32,64,128,256 \
  --duration 2m

# Paires explicites sortie:entrée (patch croisé)
core-audio-tester --device "RME" --pairs "1:1,2:2,5:3"

# Test exigeant : bruit rose + charge CPU + pression mémoire + dump audio des incidents
core-audio-tester --device "WING" --auto \
  --stability-signal pink \
  --cpu-load-levels 50,75,90 \
  --mem-pressure-mb 4096 \
  --dump-incident-audio ./incidents \
  --yes

# Vérifier le périphérique avec votre propre fichier WAV (boucle numérique)
core-audio-tester --device "MOTU" --wav-file ./reference-44100.wav

# Conditions proches d'une session : accès exclusif, niveau plus bas,
# 40 % de chaque cycle occupé dans le callback audio
core-audio-tester --device "WING" --exclusive --level -20 --io-load 40
```

### Options

| Option | Effet |
| --- | --- |
| `--device <nom-ou-uid>` | Périphérique CoreAudio ciblé (ex. `"WING"`) |
| `--list-devices` | Liste les périphériques et quitte |
| `--in <spec>` / `--out <spec>` | Canaux à tester, ex. `1-7` ou `1,3,5` |
| `--pairs <spec>` | Paires sortie:entrée explicites, ex. `1:1,2:2,5:3` |
| `--auto` | Benchmark complet du périphérique (défaut sans sélection de canaux) |
| `--buffer-sizes <csv>` | Tailles à balayer, ex. `32,64,128,256,512,1024,2048` |
| `--duration <spec>` | Durée du test de stabilité par buffer, ex. `60s`, `5m` (défaut `60s`) |
| `--ping-reps <n>` | Répétitions par paire pour le test de latence (défaut 20) |
| `--ping-sequential` | Ping une paire à la fois au lieu du mode parallèle |
| `--stability-signal <kind>` | `sine` (défaut, toute boucle), `noise`, `pink` ou `wav` (boucle numérique transparente) |
| `--wav-file <path>` | Fichier WAV de référence (implique `--stability-signal wav`) |
| `--cpu-load` | Rejoue le test de stabilité sous charge CPU simulée |
| `--cpu-load-levels <csv>` | Paliers de charge en %, ex. `25,50,75` (implique `--cpu-load`) |
| `--mem-pressure` / `--mem-pressure-mb <n>` | Ajoute une pression mémoire simulée |
| `--level <dBFS>` | Niveau crête de tous les signaux de test (défaut `-12`, de `-60` à `-3`) |
| `--io-load <pct>` | Occupe `pct` % de chaque cycle dans le callback audio pendant les tests de stabilité (0-90) |
| `--dump-incident-audio <dir>` | Écrit un WAV stéréo (capturé / attendu) par incident, 5 max par canal et par passe |
| `--exclusive` | Prend l'accès exclusif au périphérique (hog mode) : la taille de buffer CoreAudio est un réglage par processus, et une autre application ouverte sur le même périphérique peut fausser le test |
| `--config <path>` | Fichier de config JSON (les flags CLI sont prioritaires) |
| `--out-path <path>` | Base des fichiers de rapport (défaut `./core-audio-tester-report`) |
| `--yes` | Passe la confirmation de l'estimation de durée |
| `--version` | Affiche la version |
| `--help` | Aide complète |

### Fichier de configuration

`--config <path>` lit un objet JSON dont toutes les clés sont optionnelles ; les options en
ligne de commande l'emportent. Une clé inconnue (faute de frappe) est une erreur.

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

Clés acceptées : `device`, `inputChannels`, `outputChannels`, `pairs`
(`[{"output": 1, "input": 1}]`), `bufferSizes`, `pingRepetitions`, `pingMode`
(`parallel`/`sequential`), `stabilityDurationSeconds`, `sporadicToleranceWeightedPerMinute`,
`exclusiveAccess`, `cpuLoadLevelsPercent`, `stabilitySignal`, `memoryPressureMB`, `wavFile`,
`outputLevelDBFS`, `ioLoadPercent`.

### Codes de sortie

| Code | Signification |
| --- | --- |
| `0` | Succès — aucun incident sur aucune taille de buffer, au repos comme sous charge, et tout a été vérifié |
| `1` | Terminé, mais au moins une passe n'était pas parfaitement propre ou n'a pas pu être vérifiée |
| `64` | Erreur d'usage (option inconnue ou valeur invalide, config invalide…) |
| `65` | Erreur périphérique (introuvable, configuration refusée, débranché ou fréquence modifiée en cours de test — le rapport partiel est alors écrit) |
| `77` | Accès micro refusé |
| `130` | Interrompu (Ctrl-C) — le rapport partiel est quand même écrit |

## Sorties générées

- `core-audio-tester-report.html` — rapport complet : tableaux de latence, chronologie des
  incidents, comparatif par taille de buffer, recommandation finale
- `core-audio-tester-report.json` — mêmes données, exploitables par script
- `--dump-incident-audio <dir>` — WAV stéréo par incident (gauche = capturé, droite =
  référence attendue), avec ~300 ms de contexte de chaque côté, pour écouter ce qui s'est
  réellement passé. Nom : `buf<taille>_<repos|cpuNN>_chNN_<type>_t<secondes>_<n>.wav`

## Architecture

```
Sources/
  CATEngine/        Couche HAL CoreAudio : découverte et configuration des périphériques,
                    moteur d'I/O temps réel, ring buffer lock-free, monitoring d'overload,
                    générateurs de charge CPU/mémoire, parsing CLI et plan de test
  CATAnalysis/      Analyse hors temps réel : ping MLS et corrélation croisée, statistiques
                    de latence, détecteur de glitch unique (GlitchDetector) piloté par une
                    référence sinus ou bruit/WAV, moteur de recommandation, rendu
                    HTML/JSON/terminal
  core-audio-tester/ Exécutable : point d'entrée, assistant interactif, UI console
Tests/              Tests unitaires (CLI, configuration, modèles, WAV, MLS, détecteurs) et
                    tests des sessions ping/stabilité sur une boucle simulée
```

## Développement

```bash
swift build          # build debug
swift test           # tests unitaires
swift build -c release
scripts/package.sh   # binaire universel + tarball + checksum dans dist/
```

`scripts/package.sh` inscrit la version dans le binaire (`core-audio-tester --version`,
champ `toolVersion` du rapport JSON) ; un simple `swift build` affiche `dev`.

La CI GitHub Actions compile et teste chaque push et chaque pull request sur macOS, et
attache le binaire universel packagé aux artefacts du run. Pousser un tag `v*` déclenche
le workflow de release, qui publie l'archive et son checksum sur la page Releases :

```bash
git tag -a v1.0.0 -m "v1.0.0"
git push origin v1.0.0
```

## Licence

MIT — voir [LICENSE](LICENSE).
