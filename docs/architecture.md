# Architecture

## The shape of it

```
  phone                          server                     browser
  ─────                          ──────                     ───────
  GPS fix ──► SQLite             raw points on disk         activity list
              (one row per fix)  (gzipped, never edited)    activity detail
                  │                      │                  totals
                  └──── upload ──────────┤                       ▲
                        (raw only)       │                       │
                                    processing ──► summary ──────┘
                                                   (SQLite)
```

One rule holds the whole thing together: **the phone uploads raw points and
nothing else.** Every number a person sees is computed on the server from those
points.

This costs a little work up front. It buys the ability to change how elevation
is smoothed, or how a stopped runner is detected, and then re-run the change
across every run ever recorded. If the phone did the sums, those numbers would
be frozen at whatever the app believed on the day.

## The app

```
app/lib/
  main.dart                     opens the database, starts the app
  data/
    database.dart               schema, pragmas, migrations
    models.dart                 Session, Fix, SessionEvent
    session_repository.dart     every SQL statement lives here
  recording/
    recorder.dart               the recording loop and session state
    geo.dart                    distance maths
    watchdog.dart               talks to the Android alarm
  ui/
    home_screen.dart            three buttons and a distance readout
```

### Four tables

`sessions` holds one row per run. The id is a UUID made on the phone, which is
what lets an upload be retried without creating a second copy. It also carries
the device model, OS version, sample rate and accuracy setting, because the
server reprocesses these points for years and cannot work out afterwards how
they were captured.

`fixes` holds every position the platform hands over, including bad ones. The
key is `(session_id, seq)`. A timestamp will not do, since two fixes can land
in the same millisecond. `seq` is read back from the database when a session
resumes, so recovered runs append to their own history.

Bad fixes are kept on purpose. Dropping a 90-metre fix at write time would bake
today's accuracy threshold into the archive forever. The threshold belongs in
the processing step, where it can be changed and everything re-run.

`session_events` records what happened to a run besides positions arriving:
pause, resume, lifecycle changes, a permission being taken away, an error.

This table exists to answer one question. A person pausing at a shop and the
operating system freezing the app both leave the same hole in the timestamps.
A hole with a `pause` and a `resume` around it was deliberate and should not
count as moving time. A hole with nothing around it was the OS, and is missing
data. Without the events there is no way to tell them apart later.

Each fix stores two clocks: when it arrived and when the platform says it was
taken. If the app is frozen and then thaws, the arrivals bunch up while the GPS
times stay evenly spaced. That difference separates "delivered late" from
"never recorded", and only the second one is data loss.

### Writing

WAL, `synchronous=NORMAL`, one insert per fix, no batching.

Batching would be faster, at the cost of everything since the last commit when
the app is killed. The design holds a kill to one lost fix. WAL means a committed row is already on disk. `synchronous=NORMAL` skips
one disk flush per commit; a killed process is still safe, and only a crashed
operating system or a flat battery can lose recent writes.

### State

`Recorder` is a `ChangeNotifier`. The screen listens and rebuilds. At one fix
per second on a screen with three buttons this is fine. It will not be fine
once there is a map. See [status.md](status.md), open problem 5.

## Distance on the phone

The number on the screen and the number the server publishes will differ
slightly. That is expected and correct.

The phone adds up straight-line distances between fixes, skips anything with
worse than 30 m accuracy, and ignores steps under 2 m so a stationary phone
does not clock up kilometres from GPS jitter. The anchor point does not move
when a step is skipped, so slow walking still accumulates properly.

The server will do something better. Making the two agree would mean sending
the phone's arithmetic along with the points, which is the thing this design
avoids.

## Android background execution

The whole subject has its own file:
[android-background.md](android-background.md).

The short version: recording runs in a foreground service with a location type
declared in the manifest. The app refuses to start a run without the battery
optimisation exemption. An alarm checks every five minutes that recording is
still alive, and raises a notification when it is not.

## Time

Everything is stored as milliseconds since the epoch, UTC. Local time is only
for display. Storing local time means a run at 23:40 lands in the wrong week
the first time the clocks change.

## The server

Not written yet. The plan:

- Plain `node:http`. About six routes and one user.
- `node:sqlite`, which is built into Node 24, so no database driver.
- Raw points gzipped on disk at `data/raw/{id}.json.gz`, written once.
- Summary numbers in indexed columns, with the route stored as an encoded
  polyline for the list view.
- A `pipeline_version` on every activity, so it is clear what has been
  reprocessed and what has not.
- One long-lived token, compared with `crypto.timingSafeEqual`, changed by
  editing a row.
