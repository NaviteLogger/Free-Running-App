#!/usr/bin/env bash
#
# Connects to the phone and opens the tunnel the app uses to reach the dev
# server. Run this after a reboot, after the container restarts, or any time
# `adb devices` comes up empty.
#
#   tools/phone-connect.sh 192.168.1.42:5555
#
# The address is on the phone under Settings -> System -> Developer options ->
# Wireless debugging, on the main screen. It is NOT the one in the pairing
# dialog; that port is different and only used once, by `adb pair`.

set -euo pipefail

PORT="${SERVER_PORT:-8080}"

if [ $# -ne 1 ]; then
  echo "usage: $0 <phone-ip:port>" >&2
  echo "  the IP and port on the phone's Wireless debugging screen" >&2
  exit 64
fi

TARGET="$1"

if ! [[ "$TARGET" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}:[0-9]{1,5}$ ]]; then
  echo "error: '$TARGET' is not an ip:port" >&2
  exit 64
fi

echo "1/3  connecting to $TARGET"
# adb connect has no timeout of its own and will sit there for a long time
# against an address that is not answering.
if ! timeout 15 adb connect "$TARGET" | tee /dev/stderr | grep -qE 'connected to|already connected'; then
  echo >&2
  echo "Could not connect. Usually one of:" >&2
  echo "  - Wireless debugging was switched off, or the phone rebooted" >&2
  echo "  - the phone is on a different network" >&2
  echo "  - this phone has never been paired: see docs/connecting.md step 2" >&2
  exit 1
fi

echo "2/3  waiting for the device to be ready"
if ! timeout 20 adb wait-for-device; then
  echo "error: connected, but the device never became ready" >&2
  exit 1
fi

echo "3/3  tunnelling phone localhost:$PORT to this container"
# Cleared whenever the device disconnects, so it is set every time rather than
# only when it is missing.
adb reverse --remove-all >/dev/null 2>&1 || true
adb reverse "tcp:$PORT" "tcp:$PORT"

echo
adb devices
echo "reverse tunnels:"
adb reverse --list

cat <<EOF

Done. In the app's settings screen use:

  Server address   http://localhost:$PORT
  API token        printed by the server on its first start

Start the server in another terminal:

  cd server && npm start
EOF
