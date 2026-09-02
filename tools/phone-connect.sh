#!/usr/bin/env bash
#
# Connects to the phone and opens the tunnel the app uses to reach the dev
# server. Run this after a reboot, after the container restarts, or any time
# `adb devices` comes up empty.
#
#   tools/phone-connect.sh <IP>:<PORT>
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

HOST="${TARGET%%:*}"
PHONE_PORT="${TARGET##*:}"

# adb's own message for an address that is not answering is "protocol fault
# (couldn't read status message): Success", which describes nothing. Checking
# the socket first means the failure says what is actually wrong.
echo "0/3  checking $HOST:$PHONE_PORT is reachable"
if ! timeout 5 bash -c "exec 3<>/dev/tcp/$HOST/$PHONE_PORT" 2>/dev/null; then
  echo >&2
  echo "Nothing is listening on $HOST:$PHONE_PORT." >&2
  echo >&2
  echo "Check that:" >&2
  echo "  - this is a real address off your phone, not an example from the docs" >&2
  echo "  - it is the IP and port on the main Wireless debugging screen," >&2
  echo "    not the one in the pairing dialog, which is a different port" >&2
  echo "  - Wireless debugging is still switched on (it turns itself off" >&2
  echo "    when the phone leaves the network, and after a reboot)" >&2
  echo "  - the phone is on the same wifi as this machine" >&2
  exit 1
fi

echo "1/3  connecting to $TARGET"
if ! timeout 15 adb connect "$TARGET" | tee /dev/stderr | grep -qE 'connected to|already connected'; then
  echo >&2
  echo "The port answered but adb could not talk to it. Usually one of:" >&2
  echo "  - this phone has never been paired: see docs/connecting.md" >&2
  echo "  - this is the pairing port, which only 'adb pair' can use" >&2
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
