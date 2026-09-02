# Status

Updated 2 September 2026.

## Now

Phase 1 is code-complete and tested on a desktop. Nothing has run on a phone.
The next real step is installing the app and recording a walk.

## Phases

### Phase 0 — measure the phone · done, with a gap

| Item | State |
|---|---|
| Throwaway recorder that logs GPS to a file | Built, then replaced by Phase 1 |
| Device benchmark, before and after OS settings | Done. 63% → 87% |
| 45-minute walk with the screen off | **Never run** |
| Battery cost over an hour | **Never measured** |

The four field tests were never run. This stopped being a blocker when the
decision was made to finish the project either way, but it still means the
Dart recording loop has never been tested against a real walk.

`tools/analyze-log.mjs` reads the file format the old experiment produced.
Nothing produces that format now. See Open problems.

### Phase 1 — the recorder · code complete, untested on hardware

| Item | State |
|---|---|
| SQLite schema, WAL, one row per fix | Done, 18 tests |
| Session state, resume and salvage after a kill | Done, tested |
| Start, pause, stop, distance readout | Done |
| Refuses to start without the battery exemption | Done |
| Alarm watchdog that notices a dead recorder | Done, native Kotlin |
| Runs on a phone | **Not yet** |
| Recording accuracy against a known route | **Not yet** |

### Phase 2 — sync and the server · started

| Item | State |
|---|---|
| Processing: distance, moving time, elevation, splits | Done |
| Encoded polyline for the list view | Done |
| Raw points stored gzipped and never edited | Done |
| Upload keyed on the session id, safe to retry | Done |
| Summary table rebuildable from raw points alone | Done, tested |
| Server database and token | Done |
| Server: routes, token check, rate limit | Done |
| Upload from the phone, with a retry queue | Done |
| GPX import and export | Done |
| Elevation from a height map | Not started |
| Running against the real server from a phone | **Not yet** |

82 server tests, 37 app tests. Both run in CI on every push.

Processing rules that are checked by tests:

- A flat loop with several metres of altitude noise reports under 10 m of
  climb. Adding up every rise gives over 200 m, which is the mistake this
  guards against.
- A 100 m hill with the same noise on top reports within 15%.
- A 60-second stop comes out of moving time. A 5-second wait at a crossing
  stays in.
- A gap with a pause around it counts as paused. The same gap with no pause
  counts as lost.
- The same input processed twice gives byte-identical output, and the answer
  does not change if the points arrive in a different order.
- Uploading the same id twice leaves one activity, and the second upload cannot
  change the points the first one stored.
- Deleting every summary row and reprocessing the raw files reproduces the
  numbers exactly.
- An id containing `../` is refused before it reaches the filesystem.

Phone upload queue:

- A finished run is sent, then marked uploaded only after the server confirms.
- A temporary failure keeps the run queued and stops after the first one,
  instead of retrying twenty runs against a network that is down.
- A rejected run is reported and not retried forever.
- The payload field names are asserted against the server's schema, so renaming
  a field breaks a test instead of failing on a phone.
- GPX exports are read back by @tmcw/togeojson, a parser we did not write.
- Importing the same GPX file twice makes one activity, because the id comes
  from the bytes of the file.

Server behaviour checked against a real listening server, not mocks:

- A missing token, a wrong token of the same length, and a wrong token of a
  different length all give 401. The right one gives 200.
- A gzipped body is accepted, which is how the phone sends it. A body that
  claims to be gzip and is not gives 400.
- An invalid upload gives 422 and says which field is wrong.
- An unknown path gives 404; a known path with the wrong method gives 405.
- Every answer carries HSTS and nosniff.
- The rate limiter allows a burst, refills over time, counts each address
  separately, and leaves other routes alone.

### Phase 3 — web UI · not started

Activity list, activity detail with a map, weekly and monthly totals, calendar
heatmap.

### Phase 4 — whatever is missing after a month of use

Deliberately empty until the app has been used for a month.

## Test recordings still needed

Phase 2 cannot be checked without these, and they take weeks of calendar time
to collect. Record them while using the app in Phase 1.

- [ ] A flat park loop. Should report under 10 m of climb.
- [ ] A hill with a known height. Should land within 15%.
- [ ] Twelve laps of a 400 m track. Should land within 1% of 4,800 m.
- [ ] A run with a deliberate 60-second stop and a 5-second pause at a light.

## Open problems

1. **`tools/analyze-log.mjs` has nothing to read.** It parses the log format
   from the Phase 0 experiment. The Phase 1 database holds everything that log
   held and more, so the tool can be pointed at a copy of the database pulled
   off the phone with `adb`. Not done.
2. **`docs/phase-0.md` describes an app that no longer exists.** The device
   settings and the benchmark numbers in it are still correct and still matter.
   The instructions for the app are out of date.
3. **Drift is still open.** sqflite works and has tests. Drift would add typed
   queries and a code generation step. Not urgent; the query count is small.
4. **The `Recorder` class has no tests.** The database, the schema and the
   distance maths are covered. The recording loop itself is not, because it
   needs the location plugin faked.
5. **The watchdog notices but cannot restart.** It raises a notification and
   the app offers to resume. Restarting on its own needs the recording loop
   moved into a native Android service.
6. **The screen rebuilds twice a second.** Once from a clock timer, once from
   the recorder. Nothing drops frames at this size, and it will matter when the
   screen has a map on it.

## Log

| Date | What happened |
|---|---|
| 2026-08-25 | Dev container: Flutter, JDK 21, Android SDK |
| 2026-08-26 | Phase 0 experiment built. Strict TypeScript set up for the server. |
| 2026-09-02 | Device benchmark run. OS settings raised it from 63% to 87%. |
| 2026-09-02 | Phase 1 built: schema, recorder, UI, watchdog, 18 tests. |
| 2026-09-02 | Audit. Dead dependencies removed, timer leak fixed. |
| 2026-09-02 | `.gitignore` was hiding `app/lib/data/`. Fixed. |
| 2026-09-02 | Reviewed a proposal for Riverpod, isolates, in-app maps and Isar. Kept the current design; reasons in decisions.md. |
| 2026-09-02 | Docs written: README, status, architecture, decisions, android-background. |
| 2026-09-02 | Phase 2 started: processing pipeline and 18 tests. A test found a real bug in how pauses were attributed. |
| 2026-09-02 | Audit of the pipeline. Standing still was being reported as data lost to the OS; fixed. |
| 2026-09-02 | Raw point storage, server database, idempotent ingest. 37 server tests. |
| 2026-09-02 | HTTP layer: routes on the built-in URLPattern, bearer token, rate limit. |
| 2026-09-02 | Hand-written upload validation replaced with zod. |
| 2026-09-02 | CI added. Formatting, type check, tests, and an APK build. |
| 2026-09-02 | GPX import and export, checked against a third-party parser. |
| 2026-09-02 | Phone upload queue, settings screen, and a schema v2 migration. |
