#!/usr/bin/env bash
# Launch the Streakwise mobile app (React Native via Expo Go) in the iOS Simulator.
# Run `jac run` in another terminal first: the app talks to that server.
#
#   ./scripts/mobile-ios.sh            # then press  i  in this terminal
#   ./scripts/mobile-ios.sh --phone    # real iPhone: scan the QR code with the Camera app (needs Expo Go)
set -euo pipefail
cd "$(dirname "$0")/.."

if ! curl -s -o /dev/null -m 3 http://127.0.0.1:8000/; then
    echo "streakwise: start the server first:  jac run" >&2
    exit 1
fi

if [[ "${1:-}" == "--phone" ]]; then
    host="$(ipconfig getifaddr en0 2>/dev/null || true)"
    echo "Phone mode: in the app, connect to http://${host:-YOUR-MAC-IP}:8000"
else
    host=127.0.0.1
    # Boot the first available iPhone simulator so pressing `i` opens instantly.
    device="$(xcrun simctl list devices available | grep -m1 -oE 'iPhone[^(]*\(([0-9A-F-]{36})\) \((Shutdown|Booted)\)' | grep -oE '[0-9A-F-]{36}' || true)"
    if [[ -n "$device" ]]; then
        xcrun simctl boot "$device" 2>/dev/null || true
        open -a Simulator
    fi
    echo "When you see 'Waiting on http://localhost:8081', press  i  to open Streakwise in the simulator."
    echo "In the app, keep the server address http://127.0.0.1:8000 and tap Connect."
fi

# JAC_RN_DEV_HOST / REACT_NATIVE_PACKAGER_HOSTNAME: address the device uses to reach Metro.
# JAC_MOBILE_PLATFORM=web: jac's dev mode also spawns a helper "backend" for the mobile
# entry, which otherwise tries a full Android build; the real API is the `jac run` server.
export JAC_RN_DEV_HOST="$host" REACT_NATIVE_PACKAGER_HOSTNAME="$host" JAC_MOBILE_PLATFORM=web
exec jac run --dev mobile
