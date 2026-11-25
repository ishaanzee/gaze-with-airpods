#!/bin/bash
# Record a labelled session of real presses (guided, about 5 minutes) and score the decoder against it.
# micbtn is stopped while this runs, so nothing is typed or opened, and started again afterwards.
# The recording is audio of your voice: it stays in ~/Library/Application Support/micbtn/corpus.
set -euo pipefail
BIN="$HOME/Applications/MicBtn.app/Contents/MacOS/micbtn"
DIR="$HOME/Library/Application Support/micbtn/corpus/$(date +%Y%m%d-%H%M)"
DOMAIN="gui/$(id -u)"
PLIST="$HOME/Library/LaunchAgents/io.github.ishaanzee.micbtn.plist"
[[ -x "$BIN" ]] || { echo "micbtn is not installed: run install.sh first" >&2; exit 1; }
launchctl bootout "$DOMAIN/io.github.ishaanzee.micbtn" 2>/dev/null || true
trap 'launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null || true' EXIT
"$BIN" --capture "$DIR"
"$BIN" --eval "$DIR" || true
echo "corpus: $DIR"
