#!/bin/bash
# Install micbtn into ~/Applications/MicBtn.app and run it at login under launchd.
# Arguments are passed straight to micbtn:  ./install.sh --double "$PWD/claude-split.sh" --key fn
# Uninstall:  ./install.sh --uninstall
#
# The repo carries a built and signed app (prebuilt/MicBtn.app), so installing needs no Xcode tools. It is
# used whenever it was built from the Swift sources as they stand; with edited sources the app is built
# here instead. After changing the sources, the maintainer refreshes it:  ./install.sh --release
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/MicBtn.app"
BIN="$APP/Contents/MacOS/micbtn"
LABEL="io.github.ishaanzee.micbtn"
DOMAIN="gui/$(id -u)"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/micbtn.log"
TRACE="$HOME/Library/Logs/micbtn.trace"  # every hold's levels, for replaying a misread press
PREBUILT="$HERE/prebuilt"
STAMP="$HOME/Library/Application Support/micbtn/installed"  # which build is in $APP
# A wireless mic's HID button (--click / --triple-click) runs as a second job from the same app, so it and
# the analog mic's job can never stall or restart each other.
BUTTON_LABEL="$LABEL.button"
BUTTON_PLIST="$HOME/Library/LaunchAgents/$BUTTON_LABEL.plist"
BUTTON_LOG="$HOME/Library/Logs/micbtn-button.log"
BUTTON_STATE="$HOME/Library/Application Support/micbtn/button.state"

# macOS ties the Accessibility and Microphone grants to the app's signature. An ad-hoc signature is a
# new one on every build, so every update used to lose the grants and leave the button dead until someone
# noticed. A signing identity kept in the login keychain makes every build the same app to macOS. The
# prebuilt app is signed with the maintainer's; the key never leaves that keychain.
IDENTITY="MicBtn Local Code Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
signing_identity() {
  # Read into a variable, never piped into grep -q: grep exits at the first match, the writer dies of
  # SIGPIPE, and under pipefail a match then reads as "not found".
  local identities
  identities="$(security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null || true)"
  [[ "$identities" == *"\"$IDENTITY\""* ]] && return
  echo "creating the signing identity \"$IDENTITY\" in the login keychain (once)"
  local dir password
  dir="$(mktemp -d)"
  password="$(/usr/bin/openssl rand -hex 24)"
  /usr/bin/openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 3650 -subj "/CN=$IDENTITY/O=MicBtn" \
    -addext "basicConstraints=critical,CA:FALSE" -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" -keyout "$dir/key.pem" -out "$dir/cert.pem" 2>/dev/null
  /usr/bin/openssl pkcs12 -export -name "$IDENTITY" -inkey "$dir/key.pem" -in "$dir/cert.pem" \
    -out "$dir/identity.p12" -passout "pass:$password"
  security import "$dir/identity.p12" -k "$KEYCHAIN" -f pkcs12 -x -P "$password" -T /usr/bin/codesign >/dev/null
  rm -rf "$dir"
}

source_hash() { cat "$HERE"/*.swift | shasum -a 256 | cut -d' ' -f1; }

# What macOS checks a grant against: the identifier and the signing certificate.
requirement() {
  local out
  out="$(codesign -d -r- "$1" 2>/dev/null || true)"
  [[ "$out" == *"designated => "* ]] && echo "${out##*designated => }"
  return 0
}

# Builds, tests and signs the app into the directory $1. Both Mac architectures, macOS 14 and later.
build_app() {
  local app=$1 work arch errors
  command -v swiftc >/dev/null || { echo "swiftc not found: run  xcode-select --install  and re-run this" >&2; exit 1; }
  work="$(mktemp -d)"
  errors="$work/errors"
  for arch in arm64 x86_64; do
    swiftc -O -target "$arch-apple-macos14.0" "$HERE"/*.swift -o "$work/$arch" 2>"$errors" || { grep -A6 "error:" "$errors" >&2; exit 1; }
  done
  lipo -create "$work/arm64" "$work/x86_64" -output "$work/micbtn"
  "$work/micbtn" --self-test || { echo "self-test failed: nothing was replaced" >&2; exit 1; }
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS"
  mv "$work/micbtn" "$app/Contents/MacOS/micbtn"
  rm -rf "$work"
  cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$LABEL</string>
  <key>CFBundleName</key><string>MicBtn</string>
  <key>CFBundleExecutable</key><string>micbtn</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSCameraUsageDescription</key><string>micbtn runs the eye tracker (gaze) that tells it which window you are looking at when you start dictating.</string>
  <key>NSMicrophoneUsageDescription</key><string>micbtn reads the mic's level to tell when its talk button is held.</string>
  <key>NSAppleEventsUsageDescription</key><string>micbtn's --double command drives other apps, such as splitting a Ghostty pane.</string>
</dict></plist>
EOF
  signing_identity
  codesign --force --sign "$IDENTITY" "$app"
}

if [[ "${1:-}" == "--release" ]]; then
  build_app "$PREBUILT/MicBtn.app"
  source_hash > "$PREBUILT/source.sha256"
  echo "prebuilt/MicBtn.app is built from the current sources: commit prebuilt/ with them"
  exit 0
fi

# bootout returns before the job is gone, and a bootstrap that races it fails with "Input/output error".
for label in "$LABEL" "$BUTTON_LABEL"; do
  launchctl bootout "$DOMAIN/$label" 2>/dev/null || true
  while launchctl print "$DOMAIN/$label" >/dev/null 2>&1; do sleep 0.2; done
done

if [[ "${1:-}" == "--uninstall" ]]; then
  rm -rf "$APP" "$PLIST" "$BUTTON_PLIST" "$BUTTON_STATE" "$STAMP"
  tccutil reset All "$LABEL" >/dev/null 2>&1 || true
  echo "micbtn removed"
  exit 0
fi

mkdir -p "$(dirname "$APP")" "$(dirname "$PLIST")" "$(dirname "$LOG")" "$(dirname "$STAMP")"

sources="$(source_hash)"
if [[ -x "$PREBUILT/MicBtn.app/Contents/MacOS/micbtn" && "$(cat "$PREBUILT/source.sha256" 2>/dev/null)" == "$sources" ]]; then
  wanted="prebuilt $sources"
else
  wanted="local $sources"
fi

if [[ ! -x "$BIN" || "$(cat "$STAMP" 2>/dev/null)" != "$wanted" ]]; then
  # Made beside the installed app and swapped in only once it is whole: a broken build never replaces
  # the one that works.
  fresh="$APP.new"
  rm -rf "$fresh"
  if [[ "$wanted" == prebuilt* ]]; then
    echo "installing the prebuilt app"
    ditto "$PREBUILT/MicBtn.app" "$fresh"
    codesign --verify --strict "$fresh" || { echo "the prebuilt app's signature is broken: git status micbtn/prebuilt" >&2; rm -rf "$fresh"; exit 1; }
  else
    echo "the sources differ from the prebuilt app: building"
    build_app "$fresh"
  fi
  # A grant belongs to one signature. When the app about to go carries another (an ad-hoc build, or one
  # signed on this Mac before the prebuilt app existed), its grants are dead: clear them, or Settings
  # keeps showing MicBtn switched on for nothing.
  if [[ -x "$BIN" && "$(requirement "$APP")" != "$(requirement "$fresh")" ]]; then
    tccutil reset All "$LABEL" >/dev/null 2>&1 || true
  fi
  rm -rf "$APP"
  mv "$fresh" "$APP"
  echo "$wanted" > "$STAMP"
fi

# Say which input it will listen on. With the mic unplugged there is none yet, and that is fine:
# micbtn waits for it and starts listening when it is plugged in.
"$BIN" "$@" --inputs | tail -1 || true

# Writes and starts a launchd job: label, plist, log, then the arguments micbtn is started with.
write_job() {
  local label=$1 plist=$2 log=$3 arg
  shift 3
  {
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array>
    <string>$BIN</string>
    <string>--supervise</string>
EOF
    for arg in "$@"; do printf '    <string>%s</string>\n' "$arg"; done
    cat <<EOF
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StartInterval</key><integer>30</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>StandardOutPath</key><string>$log</string>
  <key>StandardErrorPath</key><string>$log</string>
</dict></plist>
EOF
  } > "$plist"
  : > "$log"
  launchctl bootstrap "$DOMAIN" "$plist"
  # macOS 27 leaves a freshly bootstrapped job pending ("pended nondemand spawn") instead of running it.
  launchctl kickstart "$DOMAIN/$label" 2>/dev/null || true
}

# --no-analog: no push-to-talk mic to listen for, only a button (an AirPods stem, a headset's dongle). Without
# it the analog job would take any USB headset's always-live mic for a talk button's line.
analog=1
for arg in "$@"; do [[ "$arg" == --no-analog ]] && analog=0; done
if (( analog )); then
  write_job "$LABEL" "$PLIST" "$LOG" --trace "$TRACE" "$@"
else
  rm -f "$PLIST"
  LOG="$BUTTON_LOG"
fi

# The button job only exists when it has something to do. Each job reads the flags that are its own.
button=0
for arg in "$@"; do [[ "$arg" == --click || "$arg" == --triple-click || "$arg" == --button-source || "$arg" == --button-vendor ]] && button=1; done
if (( button )); then
  write_job "$BUTTON_LABEL" "$BUTTON_PLIST" "$BUTTON_LOG" --button "$@"
else
  rm -f "$BUTTON_PLIST" "$BUTTON_STATE"
fi

# Follow the log until it is listening, so whatever it is waiting on is on screen.
echo "starting (log: $LOG)"
seen=0
opened=0
for _ in $(seq 240); do
  total=$(wc -l < "$LOG")
  if (( total > seen )); then
    tail -n +"$((seen + 1))" "$LOG" | cut -c14-
    seen=$total
  fi
  if (( ! opened )) && grep -q "needs Accessibility" "$LOG"; then
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    opened=1
  fi
  if grep -q "listening on" "$LOG"; then
    echo "micbtn is running. Hold the mic button."
    break
  fi
  # A "waiting" line is only reached once both permissions are granted.
  if grep -q "waiting: " "$LOG"; then
    echo "micbtn is installed and waiting for the mic. Plug it in and hold the button."
    break
  fi
  sleep 0.5
done
if ! grep -q "listening on\|waiting: " "$LOG"; then
  echo "not listening yet: finish the step above and micbtn picks it up within a few seconds" >&2
  exit 1
fi
(( button )) || exit 0

# The same for the button job. It shares the app's grants, and may ask for one more: Input Monitoring.
seen=0
opened=0
for _ in $(seq 240); do
  total=$(wc -l < "$BUTTON_LOG")
  if (( total > seen )); then
    tail -n +"$((seen + 1))" "$BUTTON_LOG" | cut -c14- | sed 's/^/button: /'
    seen=$total
  fi
  if (( ! opened )) && grep -q "needs Input Monitoring" "$BUTTON_LOG"; then
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
    opened=1
  fi
  if grep -q "listening on" "$BUTTON_LOG"; then
    echo "the button is running. Click it."
    exit 0
  fi
  if grep -q "waiting: " "$BUTTON_LOG"; then
    echo "the button is installed and waiting for its receiver. Plug it in and click."
    exit 0
  fi
  sleep 0.5
done
echo "the button is not listening yet: finish the step above and it picks it up within a few seconds (log: $BUTTON_LOG)" >&2
exit 1
