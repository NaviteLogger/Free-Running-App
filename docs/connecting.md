# Connecting the phone

Two separate connections, and they work in opposite directions.

1. **Container to phone**, so `flutter run` can install and debug. This is
   outbound from the container and works over wifi.
2. **Phone to server**, so runs can be uploaded. This is inbound to the
   container, which is the hard one.

## 1. Install the app on the phone

Both devices on the same wifi. On the phone, Android 11 or newer:

1. Settings → About phone → tap **Build number** seven times.
2. Settings → System → Developer options → **Wireless debugging** → on.
3. Tap **Pair device with pairing code**. Leave the dialog open, it expires.

In the container:

```bash
adb pair 192.168.1.42:37831   # IP and port from the pairing dialog
# paste the six-digit code

adb connect 192.168.1.42:5555 # port from the MAIN wireless debugging screen,
                              # which is a different number from the pairing one
adb devices                   # should list one device
```

Pairing survives reboots. The connection does not, so re-run `adb connect`
after a reboot or a container restart.

```bash
cd app
flutter run
```

## 2. Let the phone reach the server

The obvious approach does not work. The container sits on a Docker bridge at
`172.17.0.2`, inside WSL2, behind NAT. For the phone to reach it by address you
would have to publish a Docker port, add a WSL port proxy, and open a Windows
firewall rule. Three moving parts, and the address changes when anything
restarts.

**Use `adb reverse` instead.** The adb connection already exists and already
points from the container to the phone. `adb reverse` opens a tunnel back along
it, so the phone's own `localhost` becomes the container:

```bash
# in the container, with the phone connected
adb reverse tcp:8080 tcp:8080
```

Then start the server, bound to loopback, which is its default:

```bash
cd server
npm start
```

On the first start it prints an API token. Copy it.

In the app, tap the gear icon and enter:

| Field | Value |
|---|---|
| Server address | `http://localhost:8080` |
| API token | the token the server printed |

Tap **Test connection**. It calls `/health`, which needs no token, so a failure
here means the tunnel or the address is wrong and not the token.

`adb reverse` is cleared when the device disconnects. Re-run it after a reboot,
alongside `adb connect`.

### Why plain HTTP works here and nowhere else

Android blocks cleartext HTTP by default. Rather than switching that off for
the whole app, `res/xml/network_security_config.xml` permits it for `localhost`
only. Everything else stays HTTPS-only, so a mistyped server address cannot
quietly send location history in the clear.

### Checking it from the container

```bash
curl -s http://127.0.0.1:8080/health
curl -s -H "Authorization: Bearer YOUR_TOKEN" http://127.0.0.1:8080/api/activities
```

## 3. The real server

For the server on the VPS, none of the above applies. Caddy terminates TLS and
the app points at the real address:

| Field | Value |
|---|---|
| Server address | `https://run.example.com` |
| API token | from the server's first start |

The server binds to `127.0.0.1` by default and Caddy reaches it over loopback,
so the process itself is never exposed. To bind elsewhere, set `HOST`.

## When something does not work

| Symptom | Cause |
|---|---|
| `adb devices` is empty | Connection dropped. Re-run `adb connect`. Re-pair if that fails. |
| Test connection says no answer | `adb reverse` not set, or the server is not running. |
| Uploads give 401 | Wrong token. It is printed only on the server's first start; delete the `api_token` row and restart for a new one. |
| Cleartext error in the logs | An `http://` address that is not localhost. Use `https://` for anything else. |
| Pairing code refused | The dialog expired. Open it again for a fresh code and port. |
