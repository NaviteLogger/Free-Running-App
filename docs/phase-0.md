# Phase 0 — the recording gate

Before any of the rest of this project is worth building, one question has to be
answered on **your** phone, not on a phone in general: can a Flutter app keep a
location stream alive for an hour with the screen off?

If yes, Phase 1 is written in Dart. If no, the recording loop moves into a native
Kotlin foreground service and Flutter becomes the UI over the same database.
Either way we find out now, not in week six with a half-built app.

Everything in `app/` is disposable except this answer.

---

## 1. Pair the phone (once)

The dev container has no USB access, so the phone connects over wifi. Both
devices must be on the same network.

**On the phone** (Android 11 or newer):

1. Settings → About phone → tap **Build number** seven times to unlock
   Developer options.
2. Settings → System → Developer options → **Wireless debugging** → on.
3. Tap **Pair device with pairing code**. You get an IP, a port, and a six-digit
   code. Leave this dialog open — it expires.

**In this container:**

```bash
adb pair 192.168.1.42:37831     # the IP:port from the pairing dialog
# paste the six-digit code when prompted
```

Then connect using the port on the *main* Wireless debugging screen, which is a
**different port** from the pairing one — this trips up nearly everyone:

```bash
adb connect 192.168.1.42:5555
adb devices                      # should list one device
```

The pairing survives reboots; the connection does not. After a reboot, or after
the container restarts, just re-run `adb connect`.

## 2. Install and run

```bash
cd app
flutter run
```

This builds, installs, and attaches. Leave it attached while you're iterating —
press `r` to hot-reload a code change onto the running app in about a second,
`R` for a full restart, `q` to detach.

For the actual field tests, detach first (`q`). A test that measures whether
Android kills the app should not have a debugger holding it open.

## 3. Grant the permissions

Press **Start**. You'll get a sequence of system prompts. What you pick matters,
so:

| Prompt | Answer | Why |
|---|---|---|
| Location access | **While using the app** first | Android won't offer "always" until the app has asked once |
| Notifications | Allow | A foreground service with no visible notification is one Android feels entitled to kill |
| "Allow all the time" | Allow | Often opens Settings rather than showing a dialog — go to Permissions → Location → Allow all the time |
| Battery optimisation | Allow | This is the Doze exemption; without it Android throttles you to a handful of fixes an hour |

The four chips under the stats should all be green before you start a real test.
If `no-doze` stays red, find it manually: Settings → Apps → tracker → Battery →
**Unrestricted**.

Samsung and Xiaomi need more than this. Samsung: Settings → Battery → Background
usage limits → make sure tracker is not in "Sleeping" or "Deep sleeping apps".
Xiaomi/MIUI: Settings → Apps → tracker → Autostart on, and Battery saver → No
restrictions. [dontkillmyapp.com](https://dontkillmyapp.com) has the current
steps per vendor — this is a genuine, ongoing fight with the OS, not something
we've configured wrong.

## 4. The four tests

Run each one, then press **Stop**, then **Log** to share the file to yourself
(email, Drive, whatever). Save it into `logs/` here — that directory is
gitignored, because these files are your actual movements.

Then:

```bash
node tools/analyze-log.mjs logs/phase0-2026-08-26T....jsonl
```

**Test 1 — screen off, in pocket.** Start, lock the phone, put it in a pocket,
walk for 20 minutes. This is the baseline; if this fails nothing else matters.

**Test 2 — backgrounded.** Start, press home, use other apps normally for 20
minutes, including something heavy like a camera or a map.

**Test 3 — swiped from recents.** Start, then swipe the app out of the recent
apps list, and walk for 10 minutes. This is the one that most often fails. If it
does, that's the finding, and it points straight at the Kotlin service.

**Test 4 — battery.** Note the battery percentage, run for a full hour, note it
again. Under 10%/hour is livable for a run tracker. Over 20% means the 1 Hz
sampling rate has to come down.

## 5. Reading the result

The analyser prints a verdict, but the numbers behind it are what to look at:

- **yield** — fixes received against fixes expected at 1 Hz. Above 90% is fine.
- **max gap** — the longest silence. Under 15s is fine; a 15-minute gap is Doze.
- **lost vs buffered** — for each big gap, whether GPS timestamps advanced as
  much as the wall clock. `lost` means those seconds were never sampled.
  `buffered` means the service kept sampling and delivered late, which is
  survivable: the track is intact, it just arrived in a burst.

A `buffered` gap is a very different result from a `lost` one, and it changes
what Phase 1 has to do. That distinction is the main reason this log records
both clocks.

## 6. What we do with each outcome

| Result | Next |
|---|---|
| All four pass | Phase 1 in Dart. Keep `geolocator`, swap the JSONL log for SQLite. |
| Test 3 fails only | Native Kotlin foreground service for capture and writes; Flutter reads the same DB. |
| Tests 1–2 fail | Doze or an OEM killer. Re-check the exemptions and re-run before concluding anything about Flutter. |
| Test 4 fails | Drop the sample rate and add a distance filter, then re-run 1–3. |
