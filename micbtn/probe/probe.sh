#!/bin/bash
# Builds and runs headset-probe.swift:  ./probe.sh media 40   or   ./probe.sh mic 40
# Press each button on the headset a few times, a couple of seconds apart, while it runs.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
bin="${TMPDIR:-/tmp}/headset-probe"
[[ "$bin" -nt "$here/headset-probe.swift" ]] || swiftc -O "$here/headset-probe.swift" -o "$bin" 2>/dev/null
exec "$bin" "${1:-media}" "${2:-40}"
