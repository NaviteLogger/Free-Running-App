# Decisions

Choices that are settled, and why. Revisit one only with a reason that is
written down here.

## Scope

**One user.** No accounts, no sharing, no public pages, no social features, no
segments. One person, one phone.

**Android only.** No iOS build, no iOS testing, no Cupertino widgets.

**Ceiling of 3,000 activities.** Ten years of running most days. Around 300 MB
of compressed raw points. This is small, and the design is allowed to assume
it.

## Client

**Flutter.** The choice that matters is not Dart against Kotlin, it is where
the recording loop lives. It starts in Dart. If a phone kill loses more than
one fix, capture and the database writes move into a native Kotlin foreground
service and Flutter stays as the screen on top of the same database.

**sqflite for storage on the phone.** Plain SQLite with plain SQL. The database
file has to stay readable by anything, since the project's own rules say the
whole system state moves with one `rsync` and nothing is stored in a format
only this app understands.

Isar was considered and rejected. It stores data in its own binary format,
which breaks that rule, and the original package has not had a stable release
in a long time.

Drift is a reasonable alternative and stays compatible, since it generates code
over ordinary SQLite. It adds a code generation step. Open for discussion; see
[status.md](status.md).

**No maps in the app.** The app records. The browser draws maps. This is why
the app screen is three buttons and a distance readout.

**State on the phone is a `ChangeNotifier`.** Reviewed on 2 September 2026
against a proposal to move to Riverpod with `select` for isolated rebuilds.
Kept, because the screen shows one number and three buttons and updates once a
second. Nothing drops frames, so the rewrite would be churn. Revisit if the app
ever gets a map or a live chart.

**No isolates on the phone.** There is no heavy work to move off the main
thread. Smoothing routes, averaging pace and parsing large payloads all happen
on the server. Revisit alongside the state question if maps arrive.

## Server

**One €5 machine, one process, one file.** No containers, no orchestration.

**Plain `node:http`.** About six routes and one user, so a framework would be
more machinery than the problem needs.

Paths are matched with **`URLPattern`**, which Node 24 provides. There is no
hand-written path parser: `/api/activities/:id` is given to the platform and it
does the matching.

**Uploads are validated with zod.** This is the only place untrusted input
crosses into the system, and hand-written checks are where the field somebody
forgot to check lives. The schema is also the source of the wire type, and a
compile-time assertion fails the build if it drifts from the domain type.

**`node:sqlite`.** Built into Node 24. No database driver, no native build.

**No build step.** Node 24 runs TypeScript directly. `tsc` only type-checks.
`erasableSyntaxOnly` in the TypeScript config blocks the syntax Node cannot
strip, so anything that type-checks will run.

**The phone uploads raw points and nothing else.** All processing is on the
server. This is what makes it possible to improve the processing and re-run it
across the whole archive.

**Raw points are written once and never edited.** Every published number has to
be rebuildable from them alone. If the summary table cannot be dropped and
rebuilt, something is being stored that should not be.

## Data

**Milliseconds since the epoch, UTC, everywhere.** Local time is for display
only.

**Session ids are made on the phone.** A UUID, generated before the first fix.
Uploading the same id twice produces one activity, so a retry after a dropped
connection is free.

**Every fix is stored, including bad ones.** Filtering at write time would fix
today's accuracy threshold in place forever.

## Security

**One long-lived token.** No sessions, no OAuth, no password reset. To revoke
it, change a row in the database.

**HTTPS with HSTS**, handled by Caddy.

**No analytics and no crash reporting.** Location history is a home address, a
workplace and a daily schedule. Nothing that could carry coordinates leaves the
machine.

**Trim roughly 200 m from the start and end of a route before drawing it.** A
screenshot should not show the front door.

## Operations

**Litestream to object storage.** Losing the machine should cost under a
minute of data.

**Restore has to be practised once, on a fresh machine.** A backup that has
never been restored is a guess.

**No alerting and no uptime target.** One user. If it is down you will find out
when you open it, and the phone keeps its uploads queued.

## Tooling

**Everything runs in CI on every push.** Formatting, type checking and tests
for both packages, plus a debug APK build. A check that only runs when somebody
remembers is not a check.

**Formatters decide layout.** `dart format` and Prettier, both enforced in CI.
No arguments about indentation.

**The analyzer is set to fail on anything, including hints**
(`--fatal-infos --fatal-warnings`). A warning nobody has to fix is a warning
nobody reads.

**No suppressions.** No `@ts-ignore`, no `@ts-expect-error`, no
`eslint-disable`, no `// ignore:` in Dart, no `any`. If the type checker
complains, the code changes. The one deliberate exception is
`server/tripwire/`, which exists to fail on purpose and is checked by
`npm run typecheck:config`.

## Rejected

| Idea | Why not |
|---|---|
| Isar | Own binary format, breaks the portability rule |
| Riverpod or BLoC on the phone | Nothing to optimise on a screen this small |
| Maps and history in the app | The browser already does this, once |
| iOS and Cupertino widgets | One owner, one Android phone |
| Heart rate | No sensor, never asked for |
| Fastify or Hono | More machinery than six routes need |
| A single-page app framework for the web UI | Four read-only screens |
| Containers | One user, one process |
| Sending computed distance to the server | Freezes every past run at today's maths |
