#!/bin/sh
#
# Connects to the phone and opens the tunnel the app uses to reach the
# development server. Run it after a reboot, after the container restarts, or
# any time `adb devices` comes up empty.
#
#   tools/phone-connect.sh <IP>:<PORT>
#
# The address is on the phone under Settings, Developer options, Wireless
# debugging, on the main screen. The pairing dialog shows a different port that
# only `adb pair` uses.
#
# POSIX sh, so it behaves the same under sh, zsh and bash.

set -eu

PORT="${SERVER_PORT:-8080}"

if [ $# -ne 1 ]; then
  echo "usage: $0 <IP>:<PORT>" >&2
  echo "  the address on the phone's Wireless debugging screen" >&2
  exit 64
fi

TARGET="$1"

case "$TARGET" in
  *[!0-9.:]*|*:*:*|:*|*:)
    echo "error: '$TARGET' should look like 192.0.2.10:37129" >&2
    exit 64
    ;;
  *.*.*.*:*) ;;
  *)
    echo "error: '$TARGET' should look like 192.0.2.10:37129" >&2
    exit 64
    ;;
esac

HOST="${TARGET%:*}"
PHONE_PORT="${TARGET##*:}"

# adb answers an address that is not listening with "protocol fault (couldn't
# read status message): Success", which describes nothing. Checking the socket
# first means the failure says what to look at.
#
# curl rather than a shell TCP feature: bash has /dev/tcp and zsh does not, and
# curl is here already.
echo "0/3  checking $HOST:$PHONE_PORT answers"
if ! curl -s --connect-timeout 5 "telnet://$HOST:$PHONE_PORT" </dev/null >/dev/null 2>&1; then
  echo >&2
  echo "Nothing is listening on $HOST:$PHONE_PORT." >&2
  echo >&2
  echo "Check that:" >&2
  echo "  - this address came off your phone" >&2
  echo "  - it is the one on the main Wireless debugging screen. The pairing" >&2
  echo "    dialog shows a different port that only 'adb pair' uses" >&2
  echo "  - Wireless debugging is still on. It switches itself off when the" >&2
  echo "    phone leaves the network, and after a reboot" >&2
  echo "  - the phone is on the same wifi as this machine" >&2
  exit 1
fi

echo "1/3  connecting to $TARGET"
if ! timeout 15 adb connect "$TARGET" | tee /dev/stderr | grep -q 'connected to'; then
  echo >&2
  echo "The port answered and adb could not talk to it. Usually one of:" >&2
  echo "  - this phone has never been paired. See docs/connecting.md" >&2
  echo "  - this is the pairing port, which only 'adb pair' can use" >&2
  exit 1
fi

echo "2/3  waiting for the device"
if ! timeout 20 adb wait-for-device; then
  echo "error: connected, and the device never became ready" >&2
  exit 1
fi

# The tunnel is dropped whenever the device disconnects, so set it every time.
echo "3/3  tunnelling phone localhost:$PORT to this machine"
adb reverse --remove-all >/dev/null 2>&1 || true
adb reverse "tcp:$PORT" "tcp:$PORT"

echo
adb devices
echo "reverse tunnels:"
adb reverse --list

cat <<EOF

Done. In the app's settings screen:

  Server address   http://localhost:$PORT
  API token        printed by the server on its first start

Start the server in another terminal:

  cd server && npm start
EOF
