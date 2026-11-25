#!/bin/bash
# A short recording window (about 3 minutes): spoken cues, a few presses of each kind, scored at the end.
# micbtn is stopped while this runs, so nothing is typed or opened, and started again afterwards.
# The recording is audio of your voice: it stays in ~/Library/Application Support/micbtn/corpus.
# Name cues to run only those:  ./window.sh long-talk tap-hold
# A different build can record and score:  BIN=/path/to/micbtn ./window.sh
set -euo pipefail
BIN="${BIN:-$HOME/Applications/MicBtn.app/Contents/MacOS/micbtn}"
DIR="$HOME/Library/Application Support/micbtn/corpus/$(date +%Y%m%d-%H%M)-window"
DOMAIN="gui/$(id -u)"
PLIST="$HOME/Library/LaunchAgents/io.github.bhaktatejas922.micbtn.plist"
ONLY=" $* "
[[ -x "$BIN" ]] || { echo "micbtn is not installed: run install.sh first" >&2; exit 1; }
mkdir -p "$DIR"
launchctl bootout "$DOMAIN/io.github.bhaktatejas922.micbtn" 2>/dev/null || true
trap 'launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null || true' EXIT

# step NAME SECONDS PRESSES DOUBLES LONGEST SHORTEST CUE...   ("-" for no limit)
# The cue is spoken with the button up, so the mic is dead and the first second of every file is idle
# line, which is what the decoder measures its floor from.
step() {
  local name=$1 seconds=$2
  [[ "$ONLY" == "  " || "$ONLY" == *" $name "* ]] || return 0
  echo "$name $3 $4 $5 $6" >> "$DIR/expect"
  shift 6
  "$BIN" --record "$DIR/$name.raw" >/dev/null &
  local recorder=$!
  sleep 1.5
  echo "$*"
  say "$*"
  sleep "$seconds"
  afplay /System/Library/Sounds/Glass.aiff
  sleep 1
  kill "$recorder" 2>/dev/null || true
  wait "$recorder" 2>/dev/null || true
}

say "Recording window. Wait for each cue, and stop at the chime."
step idle 8 0 0 - - "Hands off the mic."
step talk 15 5 0 - 0.4 "Five holds. Press, say a word, let go."
step silent-hold 20 5 0 - 0.9 "Five silent holds, two seconds each."
step tap-hold 22 10 5 - - "Five doubles. Tap, then hold two seconds. Normal speed."
step tap-hold-slow 24 10 5 - - "Five lazy doubles. Slow and soft, the way it fails."
step tap 12 5 0 0.6 - "Five quick single taps."
step long-talk 24 1 0 - 12 "One long hold. Press, and keep talking for twenty seconds. Use words with P and B."
say "Done."

"$BIN" --eval "$DIR" || true
echo "corpus: $DIR"
