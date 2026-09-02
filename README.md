# free-running

A running tracker you host yourself. One user, one phone, one small server.

Records a run on an Android phone, uploads the raw GPS points, and does all the
processing on the server so past runs improve when the processing improves.

## Layout

| Directory | What it is |
|---|---|
| `app/` | Flutter app for Android. Records runs to on-device SQLite. |
| `server/` | Node 24 + TypeScript 7. Not started yet. |
| `web/` | Browser UI. Not started yet. |
| `docs/` | Design notes, decisions, and the project status. |
| `tools/` | Scripts that are not part of the app or the server. |

## Where the project is

See [docs/status.md](docs/status.md). Short version: the recorder works and is
tested on a desktop, and has never run on a phone.

## Running the app

The dev container has the Android SDK and Flutter, and no USB. Full steps are in
[docs/connecting.md](docs/connecting.md); the short version:

```bash
# once per phone, using the address and code from the pairing dialog
adb pair 192.168.1.42:37831 123456

# every session, using the address on the main wireless debugging screen
tools/phone-connect.sh 192.168.1.42:5555

cd app && flutter run
```

The phone cannot reach the container by address, because the container is on a
Docker bridge behind WSL2's NAT. `adb reverse` tunnels back along the connection
that already exists, so the app points at `http://localhost:8080` and no ports
are opened anywhere.

```bash
cd app
flutter analyze
flutter test
flutter build apk --debug
```

The tests use SQLite on the host, so they check the real schema and the real
queries without a phone.

## Running the server

Node 24 runs TypeScript with no build step. `tsc` only type-checks.

```bash
cd server
npm run typecheck
npm start
```

## Documents

- [docs/status.md](docs/status.md) — what is done and what is next
- [docs/connecting.md](docs/connecting.md) — getting the phone talking to the server
- [docs/architecture.md](docs/architecture.md) — how the pieces fit
- [docs/decisions.md](docs/decisions.md) — choices that are settled, and why
- [docs/android-background.md](docs/android-background.md) — the OS fights back
- [docs/phase-0.md](docs/phase-0.md) — the original recording experiment
