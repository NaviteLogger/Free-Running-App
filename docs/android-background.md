# Android background execution

The hardest part of a run tracker is not recording GPS. It is staying alive
while the screen is off. Android throttles background work, and phone makers
add their own layer on top that is more aggressive and less documented.

Target phone: OnePlus 12 (CPH2581), OxygenOS 16, Android 16.

## How bad it is on this phone

[dontkillmyapp.com](https://dontkillmyapp.com/oneplus) scores OnePlus 5 out of
5 for killing background apps, its worst score, level with Xiaomi and Huawei.

The DontKillMyApp benchmark runs a foreground service with a wake lock, some
repeating work, and alarms, then reports how much of that work actually ran.

| Run | Setup | Total | Work | Main thread | Alarms |
|---|---|---|---|---|---|
| 1 | Nothing changed | 63% | 27% | 27% | **100%** |
| 2 | OS settings applied, app locked in recents | **87%** | 73% | 73% | **100%** |

Two things came out of this.

**The settings work.** In-process work went from 27% to 73%. This ruled out the
worry that the settings exist but do nothing on OxygenOS 16.

**Alarms always fire.** 100% in both runs, including the crippled one. Alarms
are the one mechanism OxygenOS leaves alone, so they are the only reliable way
to watch a recorder that may have been frozen. This is why the watchdog is
built on `AlarmManager` and not on a timer inside the app.

There is also a hint about the failure mode. Alarms can only fire into a live
process, so the app was being frozen and not killed. A frozen app thaws and
receives the positions it missed in a burst. That is survivable. A killed app
never sampled them at all.

## Phone settings

OnePlus renames and moves these between releases. Each row says what the
setting does. If a path is wrong, search for the term in the Settings search
box.

| What it does | Path | Set to | Search |
|---|---|---|---|
| Deep optimization / Adaptive battery. The main app killer. | Settings → Battery → ⋮ → Advanced optimization | off | `optimization` |
| Sleep standby optimization. Cuts the network on a sleep schedule. | Same screen | off | `sleep` |
| Per-app battery exemption | Settings → Apps → ⚙ → Special access → Battery optimization → All apps | Don't optimize | `battery optimization` |
| Background activity and auto-launch | Settings → Battery → More settings → App battery management | both allowed | `background activity` |

Then open the app, go to the recents screen, long-press its card, and tap the
padlock. On a OnePlus this is the single most useful thing you can do, and it
only has to be done once.

**These settings do not stay put.** OnePlus is documented to switch the battery
exemption back on by itself, days later, without telling you. This is why the
app checks the exemption before every run and refuses to start without it. A
recorder that trusts a setting granted once will quietly lose a run weeks
later.

## What the app does about it

**A foreground service with `foregroundServiceType="location"`.** Required from
Android 14. Without it in the manifest the service refuses to start.

**Refuses to record without the battery exemption.** Checked at the start of
every run, and again every thirty seconds while running. Losing it mid-run is
written into `session_events`, so a hole in the data can be explained
afterwards.

**Writes every fix straight to disk.** Nothing is held in memory waiting to be
saved. Being killed costs one fix.

**Offers to resume on the next launch.** A run still marked `recording` means
the app died. Everything up to that point is already saved, and the session can
be continued or closed.

**An alarm watchdog.** Every five minutes an alarm checks a heartbeat that the
recorder writes every thirty seconds. If the heartbeat is more than four
minutes old, it raises a notification. Tapping it opens the app, which offers
to resume.

It uses `setAndAllowWhileIdle` and not the exact version. The exact one needs
`SCHEDULE_EXACT_ALARM`, which is a permission the user grants and can take
away on Android 13 and later. The inexact one still fires during Doze, with
looser timing. For noticing a dead recorder that is good enough, and it costs
no permission.

The watchdog does not restart recording. The location stream belongs to the
Dart side of the app, so when that process is gone there is nothing left to do
the restarting. Restarting on its own would mean moving the recording loop into
a native Android service, which is held in reserve.

## What other apps do

Strava does not solve this either. Its help centre has separate instructions
per phone maker, including OnePlus, telling people which battery settings to
turn off. That is the industry answer: documentation.

Part of why big apps seem to work better is that phone makers keep internal
lists of popular apps they treat gently. That option is not open here.

This project has one advantage Strava does not: one phone, one owner, and an
owner who will actually change the settings.
