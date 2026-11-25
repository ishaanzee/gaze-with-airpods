#!/bin/bash
# micbtn --double / --triple action: split the focused Ghostty pane to the right and run Claude Code on MODEL in
# the new pane, attached to a warm session from `claude-warm` when one is waiting for that directory.
#   --double "claude-split.sh claude-opus-5-5"     tap, then hold
#   --triple "claude-split.sh claude-fable-5-2"    tap, tap, then hold
#
# micbtn starts this the moment the press that may become the gesture goes down, and later writes `go` on
# stdin, or closes it when the press turned out to be a tap. Everything slow happens before `go`: bash and
# osascript start, the script compiles, and Ghostty is asked which directory the current pane is in. After
# `go` only the split is left (~120 ms). By hand:  echo go | ./claude-split.sh claude-opus-5-5
set -uo pipefail
model="${1:?usage: claude-split.sh MODEL}"
[[ "$model" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "bad model name: $model" >&2; exit 2; }
here="$(cd "$(dirname "$0")" && pwd)"

gate="$(mktemp -u "${TMPDIR:-/tmp}/micbtn-split.XXXXXX")"
mkfifo "$gate"
trap 'rm -f "$gate"' EXIT
exec 3<>"$gate"  # held open read-write, so writing the verdict never blocks on osascript

osascript "$here/claude-split.applescript" "$model" "$gate" "$here/claude-warm" &
if read -r verdict && [[ "$verdict" == go ]]; then echo go >&3; else echo off >&3; fi
wait $!
