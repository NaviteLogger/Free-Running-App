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

The dev container has the Android SDK and Flutter. It has no USB, so the phone
connects over wifi:

```bash
adb pair 192.168.1.x:PORT      # port from the pairing dialog
adb connect 192.168.1.x:5555   # port from the main wireless debugging screen
cd app && flutter run
```

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
- [docs/architecture.md](docs/architecture.md) — how the pieces fit
- [docs/decisions.md](docs/decisions.md) — choices that are settled, and why
- [docs/android-background.md](docs/android-background.md) — the OS fights back
- [docs/phase-0.md](docs/phase-0.md) — the original recording experiment
