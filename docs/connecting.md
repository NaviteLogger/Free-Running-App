# Connecting the phone

---

## Once per phone: turn on wireless debugging

### Unlock Developer options

**Settings → About phone → tap Build number seven times.** It counts down at
you, then says developer mode is on.

### Find Wireless debugging

On OxygenOS 16:

    Settings → System & update → Developer Options → Wireless debugging

If a system update moves it, search `wireless debugging` in the Settings search
box.

Turn the toggle on, then **tap the label** to open the screen behind it. That
screen holds everything you need:

```
← Wireless debugging                    [ON]

  Device name
  OnePlus 12

  IP address & Port
  AAA.BBB.CCC.DDD:QQQQQ          <- the CONNECT address, used every session

  Pair device with pairing code  <- tap this, once, to pair
  Pair device with QR code
```

---

## Once per phone: pair

Nothing on this page is a working address. Every number you need is on your own
phone screen, and no example here will connect to it.

On the phone, on the Wireless debugging screen, tap
**Pair device with pairing code**. A dialog opens showing two things:

```
Pair with device

  Wi-Fi pairing code
  NNNNNN                      <- six digits

  IP address & Port
  AAA.BBB.CCC.DDD:PPPPP       <- the pairing address
```

Type this in the container, substituting from that dialog:

    adb pair AAA.BBB.CCC.DDD:PPPPP NNNNNN

Three values, all from that one dialog: the IP, the port after the colon, and
the six-digit code. Nothing here is quoted or escaped, so type it exactly as the
phone shows it.

The dialog expires after a minute or two. If it closes, open it again and you
get a fresh code and a fresh port.

Expected:

    Successfully paired to AAA.BBB.CCC.DDD:PPPPP [guid=adb-...]

If you get `protocol fault (couldn't read status message): Success`, nothing
answered at that address. It means one of:

- the numbers were copied from this page
- the dialog expired and the port is no longer listening
- the phone is on a different network from this machine

Close the dialog once pairing succeeds. That port is never used again.

> **The pairing port is not the connect port.** Once paired, the main Wireless
> debugging screen shows a _different_ port under the device name. Everything
> after this uses that one.

---

## Every session: connect and open the tunnel

The connection and the tunnel are both cleared when the phone disconnects, the
phone reboots, or the container restarts. One command does both:

```bash
tools/phone-connect.sh <IP>:<PORT>
```

This address is on the **main Wireless debugging screen**, under the device
name, shown as `IP address & Port`. The port is a different number from the
pairing one.

Expected:

```
0/3  checking AAA.BBB.CCC.DDD:QQQQQ is reachable
1/3  connecting to AAA.BBB.CCC.DDD:QQQQQ
connected to AAA.BBB.CCC.DDD:QQQQQ
2/3  waiting for the device to be ready
3/3  tunnelling phone localhost:8080 to this container
List of devices attached
AAA.BBB.CCC.DDD:QQQQQ	device
reverse tunnels:
AAA.BBB.CCC.DDD:QQQQQ tcp:8080 tcp:8080
```

`QQQQQ` is the connect port, which is not the same number as the pairing port
`PPPPP` used above.

The script checks the address answers before handing it to adb, so a wrong one
says what to check, in place of adb's protocol fault message.

If you would rather run the two commands yourself:

```bash
adb connect <IP>:<PORT>
adb reverse tcp:8080 tcp:8080
```

### Why the tunnel is needed

The container is on a Docker bridge at `172.17.0.2`, inside WSL2, behind NAT.
For the phone to reach it by address you would have to publish a Docker port,
add a WSL port proxy, and open a Windows firewall rule. Three moving parts, and
the address changes when anything restarts.

`adb reverse` goes the other way. The adb connection already runs from the
container to the phone, and this opens a tunnel back along it, so the phone's
own `localhost:8080` arrives at the container. Nothing listens on the network.

---

## Start the server

In a second terminal:

```bash
cd /workspace/server
npm start
```

The first time only, it prints a token:

```
  A new API token was generated. Put it in the phone app:

    uX0e4hIg9OWzjEuiO3HYSKGKrRBz3eyWXYvUM7I19H0

  To revoke it: DELETE FROM settings WHERE key = 'api_token'; then restart.

listening on http://127.0.0.1:8080
data in /workspace/server/data
```

**Copy the token now.** It is not printed again. If you lose it:

```bash
cd /workspace/server
node -e "const {DatabaseSync}=require('node:sqlite');const db=new DatabaseSync('data/tracker.db');console.log(db.prepare(\"SELECT value FROM settings WHERE key='api_token'\").get().value)"
```

Check the server answers before involving the phone:

```bash
curl -s http://127.0.0.1:8080/health
```

Expected: `{"ok":true,"activities":0}`

---

## Install and run the app

### Build a release APK for anything over wifi

Sizes measured on this project:

| Build | Size |
|---|---|
| `flutter build apk --debug` | 182 MB |
| `flutter build apk --release` | 48 MB |

Wireless adb here goes through a Docker bridge and WSL's NAT, and the debug APK
is slow enough over that path to be impractical. Use release for anything you
install over wifi:

```bash
cd /workspace/app
flutter build apk --release
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

Release is also the honest build for a recording test. Debug carries extra
runtime work that shows up in the battery figure.

To make it smaller still, `--split-per-abi` builds one APK per architecture.
This phone is `android-arm64`, so `app-arm64-v8a-release.apk` is the one to
install.

### Hot reload while developing

```bash
cd /workspace/app
flutter run
```

This builds a debug APK, installs it, and attaches. While attached, `r`
hot-reloads a change in about a second, `R` restarts, `q` detaches. The first
install is slow for the size reason above; later reloads are fast because only
the changed Dart is sent.

Detach before any recording test. A debugger holding the process open is exactly
what the test is trying to measure.

---

## Point the app at the server

In the app, tap the **gear** icon:

| Field          | Value                        |
| -------------- | ---------------------------- |
| Server address | `http://localhost:8080`      |
| API token      | the token the server printed |

Tap **Test connection**. It calls `/health`, which needs no token, so a failure
here is the tunnel or the address and not the token.

Expected: `Server answered`.

Tap **Save**.

### Why plain HTTP is allowed here and nowhere else

Android blocks cleartext HTTP by default. Rather than turning that off for the
whole app, `app/android/app/src/main/res/xml/network_security_config.xml`
permits it for `localhost` only. Everything else stays HTTPS, so a mistyped
address cannot quietly send location history in the clear.

---

## Check the whole path

Record a short walk: **Start**, walk for a minute, **Stop**. Stopping uploads
straight away. The title bar shows a count if anything is waiting.

From the container:

```bash
curl -s -H "Authorization: Bearer YOUR_TOKEN" \
  http://127.0.0.1:8080/api/activities
```

Expected: an `activities` array with one entry carrying a distance and a
polyline.

Then the GPX, which should open in any mapping tool:

```bash
curl -s -H "Authorization: Bearer YOUR_TOKEN" \
  http://127.0.0.1:8080/api/activities/THE_ID/gpx -o run.gpx
head -5 run.gpx
```

---

## The real server later

None of the tunnel applies. Caddy terminates TLS and the app points at the real
address:

| Field          | Value                          |
| -------------- | ------------------------------ |
| Server address | `https://run.example.com`      |
| API token      | from that server's first start |

The server binds to `127.0.0.1` and Caddy reaches it over loopback, so the
process is never directly exposed. Set `HOST` to change that.

---

## When something does not work

| Symptom                                         | Cause and fix                                                                                                              |
| ----------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| `adb devices` is empty                          | Re-run `tools/phone-connect.sh`.                                                                                           |
| `failed to connect`                             | Wireless debugging switched itself off. Turn it on and re-run.                                                             |
| `device unauthorized`                           | Pairing was lost. Pair again.                                                                                              |
| Test connection: no answer                      | Tunnel missing or server not running. Check `adb reverse --list` and `curl http://127.0.0.1:8080/health`.                  |
| Uploads give 401                                | Wrong token. Read it back with the command above.                                                                          |
| `CLEARTEXT communication not permitted`         | The address is `http://` and not localhost. Use `https://`.                                                                |
| Pairing code refused                            | The dialog expired. Open it again for a fresh code and port.                                                               |
| `protocol fault (couldn't read status message)` | Nothing answered at that address. Almost always a copied example, or the pairing port used where the connect port belongs. |
| Everything worked yesterday                     | The tunnel is cleared on disconnect. Re-run `tools/phone-connect.sh`.                                                      |
| No `Pair device with pairing code` anywhere     | You are on the Developer options list. Tap the label to open the Wireless debugging screen.                       |
| No Developer options in Settings                | Build number was not tapped seven times, or it is under About phone → Version on this build.                               |
| Cannot find Developer options after enabling it | Search `wireless debugging` in the Settings search box.                                   |
