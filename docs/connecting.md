# Connecting the phone

Every command below is meant to be copied as written. The only things you
substitute are the two addresses the phone shows you, and both are marked.

---

## Once per phone: turn on wireless debugging

On the phone:

1. **Settings → About phone** → tap **Build number** seven times.
2. **Settings → System → Developer options** → turn on **Wireless debugging**.

Leave that screen open. You need two numbers from it and they are different.

---

## Once per phone: pair

On the phone, still on the Wireless debugging screen, tap
**Pair device with pairing code**. A dialog appears with an address and a
six-digit code. It expires after a minute or two, so have the terminal ready.

In the container, using the address **and the code from the pairing dialog**:

```bash
adb pair 192.168.1.42:37831 123456
```

Expected:

```
Successfully paired to 192.168.1.42:37831 [guid=adb-...]
```

Close the dialog. You never need it again unless you reset the phone.

> The port in the pairing dialog is used only by `adb pair`. Everything after
> this uses the port on the main Wireless debugging screen, which is a
> different number.

---

## Every session: connect and open the tunnel

The connection and the tunnel are both cleared when the phone disconnects, the
phone reboots, or the container restarts. One command does both:

```bash
tools/phone-connect.sh 192.168.1.42:5555
```

The address here is from the **main Wireless debugging screen**, not the
pairing dialog.

Expected:

```
1/3  connecting to 192.168.1.42:5555
connected to 192.168.1.42:5555
2/3  waiting for the device to be ready
3/3  tunnelling phone localhost:8080 to this container
List of devices attached
192.168.1.42:5555	device
reverse tunnels:
192.168.1.42:5555 tcp:8080 tcp:8080
```

If you would rather run the two commands yourself:

```bash
adb connect 192.168.1.42:5555
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

In the first terminal:

```bash
cd /workspace/app
flutter run
```

It builds, installs and attaches. While attached, `r` hot-reloads a change in
about a second, `R` restarts, `q` detaches.

Detach before any recording test. A debugger holding the process open is
exactly what the test is trying to measure.

---

## Point the app at the server

In the app, tap the **gear** icon:

| Field | Value |
|---|---|
| Server address | `http://localhost:8080` |
| API token | the token the server printed |

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

| Field | Value |
|---|---|
| Server address | `https://run.example.com` |
| API token | from that server's first start |

The server binds to `127.0.0.1` and Caddy reaches it over loopback, so the
process is never directly exposed. Set `HOST` to change that.

---

## When something does not work

| Symptom | Cause and fix |
|---|---|
| `adb devices` is empty | Re-run `tools/phone-connect.sh`. |
| `failed to connect` | Wireless debugging switched itself off. Turn it on and re-run. |
| `device unauthorized` | Pairing was lost. Pair again. |
| Test connection: no answer | Tunnel missing or server not running. Check `adb reverse --list` and `curl http://127.0.0.1:8080/health`. |
| Uploads give 401 | Wrong token. Read it back with the command above. |
| `CLEARTEXT communication not permitted` | The address is `http://` and not localhost. Use `https://`. |
| Pairing code refused | The dialog expired. Open it again for a fresh code and port. |
| Everything worked yesterday | The tunnel is cleared on disconnect. Re-run `tools/phone-connect.sh`. |
