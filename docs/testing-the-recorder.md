# Testing the recorder

Everything else can be checked on a computer. Whether a phone will keep
recording for an hour with the screen off can only be found out by carrying it
around.

These four tests have not been run yet. Until they have, nobody knows whether
the recording loop can stay in Dart or has to move into native Android code.

## Before you start

Work through [android-background.md](android-background.md) first and get the
phone's battery settings sorted out. Running these against a phone that is
still allowed to freeze the app just measures the phone's settings.

Build a release version. A debug build carries extra work that shows up in the
battery figure, and it is ten times the size to install.

```bash
cd app
flutter build apk --release --split-per-abi
adb install -r build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

Detach any debugger before you walk. A debugger holds the app open, which is
the exact thing these tests are trying to measure.

## The four tests

**One: screen off, in a pocket.** Start recording, lock the phone, put it away,
walk for 45 minutes. This is the headline test. Everything else assumes it
passes.

Target: no gap longer than 30 seconds, and nothing above 120 seconds.

**Two: interrupted.** Start recording, then use the phone normally for 20
minutes. Take a call. Open the camera. Switch between a few apps.

Target: recording survives all three.

**Three: swiped away.** Start recording, then swipe the app out of the recent
apps list, and walk for 10 minutes.

Target: at most one position is lost. Positions are written to disk one at a
time, so being killed can only ever interrupt the write in progress. Losing
more than one means something is holding data in memory that should not be.

**Four: battery.** Run for a full hour. The app records the battery level with
every position, so the drain works itself out from the data.

Target: under 8% an hour.

## What to do with the results

Stop the recording, which uploads it. Then look at the numbers the server
worked out:

```bash
curl -s -H "Authorization: Bearer YOUR_TOKEN" \
  http://127.0.0.1:8080/api/activities
```

The three that matter are `movingS`, `pausedS` and `droppedS`.

`droppedS` counts seconds where positions stopped arriving with no pause to
explain it. That is the number these tests exist to drive down.

For a closer look, fetch the raw points and compare the two clocks on each one:

```bash
curl -s -H "Authorization: Bearer YOUR_TOKEN" \
  http://127.0.0.1:8080/api/activities/THE_ID/raw
```

If the arrival times bunch up while the GPS times stay evenly spaced, the app
was frozen and later woke up with a backlog. The track survives that. If both
clocks show the same gap, those positions were never taken, and that time is
gone.

## Reading the outcome

| Result | What it means |
|---|---|
| All four pass | The recording loop stays in Dart. |
| Only test three fails | Move recording into a native Android service and let Flutter draw the screen over the same database. |
| Tests one or two fail | Check the battery settings again before blaming the code. Nearly always the phone. |
| Test four fails | Ask for positions less often and add a distance filter, then run one to three again. |

## One thing to check while you are there

On a stationary phone indoors, this OnePlus delivered a position every 7.1
seconds while the app was asking for one per second. Everything written so far
assumes one per second: the yield figure, the gap limits, the log analyser.

Watch the interval during test one. A phone that is actually moving may behave
completely differently, and there is no point adjusting any limits until
somebody has looked.
