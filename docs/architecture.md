# How it works

## The shape of it

```
  phone                          server                      browser
  ─────                          ──────                      ───────
  GPS fix ──► SQLite             raw points on disk          activity list
              one row per fix    gzipped, written once       activity detail
                  │                      │                   totals
                  └──── upload ──────────┤                        ▲
                        raw only         │                        │
                                    processing ──► summary ───────┘
                                                   SQLite
```

One rule holds the whole thing together. **The phone sends raw GPS points and
nothing else.** Every number a person sees is worked out on the server.

The payoff comes later. When the way climb is smoothed improves, or the rule
for spotting a runner who has stopped gets better, every run ever recorded can
be worked out again with the new version. Had the phone done the sums, those
numbers would be stuck at whatever the app believed on the day.

## The app

```
app/lib/
  main.dart                     opens the database, starts the app
  data/
    database.dart               tables, settings, migrations
    models.dart                 Session, Fix, SessionEvent
    session_repository.dart     every SQL statement lives here
    settings_repository.dart    server address and token
  recording/
    recorder.dart               the recording loop and session state
    geo.dart                    distance sums
    watchdog.dart               talks to the Android alarm
  sync/
    api_client.dart             one HTTP call, and what its answer means
    sync_service.dart           the upload queue
  ui/
    home_screen.dart            three buttons and a distance readout
    settings_screen.dart        server address and token
```

### Four tables

**`sessions`** holds one row per run. Its id is a UUID made on the phone before
the first position arrives, so an upload can be retried without creating a
second copy of the run.

It also records the phone model, the Android version, the requested sample rate
and the accuracy setting. The server works these points out again years later
and has no other way to know what conditions they were captured under.

**`fixes`** holds every position Android hands over, including the poor ones.
The key is the pair `(session_id, seq)`, where `seq` counts up within a run.
Two positions can arrive in the same millisecond, so a timestamp alone would be
ambiguous. When a run resumes after a crash, `seq` is read back from the
database and carries on from where it stopped.

Poor positions are kept on purpose. Throwing away a 90-metre reading as it
arrives would fix today's accuracy limit into the archive forever. The limit
belongs in the processing step, where it can be adjusted and everything worked
out again.

**`session_events`** records what happened to a run apart from positions
arriving: pause, resume, the app going to the background, a permission being
taken away, an error.

This table answers one question. Somebody pausing at a shop and the phone
freezing the app both leave the same hole in the timestamps. A hole with a
`pause` and a `resume` around it was a choice, and those seconds belong outside
the moving time. A hole with nothing around it means the phone stopped the app,
and those seconds are missing data worth reporting. The events are the only way
to tell the two apart afterwards.

Every position carries two clocks: when it reached the app, and when Android
says the reading was taken. If the app freezes and later wakes, the arrival
times bunch together while the GPS times stay evenly spaced. That difference
separates a delivery that came late from a reading that was never taken. Only
the second one is a real loss.

**`settings`** holds the server address and the API token.

### Writing to disk

WAL journalling, `synchronous=NORMAL`, one insert per position, no batching.

Batching would be quicker and would throw away everything since the last save
whenever the app is killed. Writing one row at a time holds the cost of a kill
to a single position.

WAL means a saved row has already reached the disk. `synchronous=NORMAL` skips
one flush per save, which stays safe through a killed app and risks only the
most recent writes if the whole phone crashes or the battery dies. Being killed
from the task switcher is the case that matters here, and it is the safe one.

### Keeping the screen up to date

`Recorder` is a `ChangeNotifier` and the screen listens to it. With one
position every few seconds and a screen holding three buttons and one number,
this is comfortable. It will want revisiting if a map ever appears. See open
problem 6 in [status.md](status.md).

## Distance on the phone

The number on the phone and the number the server publishes differ slightly,
and that is fine.

The phone adds up straight lines between positions, skips anything less
accurate than 30 metres, and ignores steps under 2 metres so a phone sitting on
a table does not clock up kilometres from GPS drift. When a step is skipped the
anchor point stays where it was, so a slow walk still adds up correctly over
several readings.

The server does something better with the same points. Making the two agree
would mean sending the phone's arithmetic along with the data, which is exactly
what this design sets out to avoid.

## Staying alive in the background

This has a file of its own: [android-background.md](android-background.md).

In short: recording runs inside a foreground service declared for location use,
the app refuses to start without an exemption from battery optimisation, and an
alarm checks every five minutes that recording is still going.

## Time

Everything is stored as milliseconds since 1970, in UTC. Local time is used
only for display. Storing local time puts a run at 23:40 into the wrong week
the first time the clocks change.

## The server

```
server/src/
  main.ts            starts up, prints the token on first run
  server.ts          wires the routes, the token check and the rate limit
  config.ts          port, host, where the data lives
  db.ts              the activities table and the settings row
  raw-store.ts       gzipped raw points on disk
  ingest.ts          upload, and working an activity out again
  gpx.ts             GPX in and out
  routes.ts          six routes
  upload-schema.ts   checks an upload before anything trusts it
  pipeline/          distance, moving time, climb, splits, polyline
  http/              routing, token check, rate limit
```

Plain `node:http`, and `node:sqlite`, which comes with Node 24. No web
framework and no database driver.

Raw points live at `data/raw/{id}.json.gz`, written once and never edited. The
activities table holds the worked-out numbers with the route as an encoded
polyline, so the activity list can be drawn without opening a single raw file.

Every activity records which version of the processing produced its numbers.
Dropping the whole activities table and building it again from the raw files is
a supported operation, and there is a test for it. If that ever stops working,
something is being stored that cannot be recovered.

One long-lived token guards everything, compared in a way that takes the same
time whether it matches or not. Changing it means editing a row.
