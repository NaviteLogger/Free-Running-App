# Phase 0 — the recording gate

> **Historical.** The app this describes was replaced by the Phase 1 recorder,
> so the instructions for pressing Start and sharing a log no longer match
> anything. Kept because the four field tests were never run and are still
> worth running, and because the working notes below record how the numbers
> were arrived at.
>
> The phone settings and the benchmark results have moved to
> [android-background.md](android-background.md), which is the current
> document. Read that one.


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

### OnePlus 12 / OxygenOS 16 — read this part

[dontkillmyapp.com](https://dontkillmyapp.com/oneplus) rates OnePlus **5 out of 5
💩**, its worst tier, alongside Xiaomi and Huawei. OxygenOS will kill a
foreground service that Android itself considers protected. None of the
following is optional on this phone:

OnePlus renames and moves these between releases, so each row lists what the
setting *does* alongside its likely path. If a path is wrong on OxygenOS 16, use
the **search box at the top of Settings** with the term in the last column —
that survives menu reshuffles.

| What it does | Likely path | Set to | Search for |
|---|---|---|---|
| **Deep optimization** / Adaptive battery — the main app killer | Settings → Battery → **⋮** (top right) → Advanced optimization | **off** | `optimization` |
| **Sleep standby optimization** — cuts the network on a sleep schedule | same screen | **off** | `sleep` |
| Per-app battery exemption for tracker | Settings → Apps → ⚙ → Special access → Battery optimization → All apps | **Don't optimize** | `battery optimization` |
| Background activity + auto-launch for tracker | Settings → Battery → More settings → App battery management → tracker | both **allowed** | `background activity` |

OxygenOS 15 also introduced a feature called **Sleep Capsule** under Settings →
Battery → More settings. If it exists on 16, turn it off too.

Deep optimization is described by dontkillmyapp as "the main app killer". If you
change one thing, change that.

**Verify it took.** The app's own `no-doze` chip reads the exemption directly
from Android, so it is ground truth for that one setting — it should be green
before you start a test. For the rest, run 2 of the benchmark is the check: if
WORK and MAIN do not climb well above 27 %, the settings are decorative on this
build and the native Kotlin path stops being optional.

**Then lock the app in recents.** Open the app, go to the recents screen,
long-press its card, and tap the padlock. This is the single highest-leverage
action on a OnePlus and it persists — you only do it once.

**The setting does not stay put.** OnePlus is documented as randomly reverting
the battery-optimisation exemption for arbitrary apps, days later, with no
notice. That is why the app shows permission chips on its main screen: check
that `no-doze` is still green **before every run**, not just once during setup.
The recents lock is reported to reduce these reversions, which is the other
reason to do it.

This is a fight with the OS, not a bug in our code. Budget for the gate failing
on this phone and needing a second pass with these settings corrected before you
conclude anything about Flutter.

### Baseline the phone first with DontKillMyApp

Before touching our app, measure the phone itself. [DontKillMyApp](https://f-droid.org/en/packages/com.urbandroid.dontkillmyapp/)
runs the same trio our recorder depends on — a foreground service with a wake
lock, repeating work on a thread executor, and `AlarmManager` alarms scheduled
with `setExactAndAllowWhileIdle` — and reports executed-vs-expected as a
percentage. It gives a verdict about the *device*, independent of our code, so a
Phase 0 failure can be attributed rather than guessed at.

Run it **three times**:

1. **Before changing any settings.** This is the baseline.
2. **After applying the OxygenOS settings above and locking the app in recents.**
   The delta is the only proof that those settings do anything on OxygenOS 16.
3. **A few days later, changing nothing.** This directly tests the documented
   claim that OnePlus silently reverts the exemption. If run 3 is worse than run
   2, the reversion is real on your device, and Phase 1 must treat the grant as
   untrustworthy rather than checked-once.

Conditions that decide whether the number means anything:

- **Unplugged.** Charging disables Doze outright and relaxes OEM killers. A
  plugged-in benchmark reports a near-perfect score that tells you nothing.
- **Screen off, phone left alone.** Touching it resets the idle timers.
- **Stationary**, and ideally **overnight.** Doze escalates in stages and its
  maintenance windows grow further apart over hours; a ten-minute test barely
  reaches the first stage.

#### Results

| Run | Conditions | TOTAL | WORK | MAIN | ALARM |
|---|---|---|---|---|---|
| 1 — baseline | unplugged, no settings changed, Android 16 / CPH2581 | **63 %** | 27 % | 27 % | **100 %** |
| 2 — configured | after OxygenOS settings + recents lock | **87 %** | 73 % | 73 % | **100 %** |
| 3 — days later | nothing changed since run 2 | | | | |

Run 1 reading: alarms scheduled with `setExactAndAllowWhileIdle` fired **every
single time**, while in-process work ran only 27 % of the time. Alarms firing
means the process was still alive — so OxygenOS is *freezing* the app, not
killing it. That is a materially better failure mode than a kill, and it is the
one our dual-clock log can identify: a frozen process that thaws receives its
buffered fixes in a burst, which the analyser reports as `buffered` rather than
`lost`.

It also means an `AlarmManager` watchdog is viable on this device. 100 % is as
strong a signal as this benchmark can give.

Run 2 reading: the OxygenOS settings are real — in-process work went from 27 %
to 73 %. Alarms held at 100 % for a second time, which settles the watchdog
question.

The residual 27 % is not uniform: the chart shows one contiguous suppressed
window with dense execution either side, which is the signature of entering Doze
and then coming back out. That distinction matters, because contiguous
suppression is what produces a *gap* in a track rather than a thinner sampling
rate.

It is also probably not our failure mode. Doze requires the device to be
**stationary**, and this benchmark was run on a phone sitting still. During an
actual run the phone is moving, so the deepest states should not engage at all.
Expect the real recording test to land better than 73 % — and treat that as a
hypothesis Phase 0 tests, not a conclusion.

**Reading it against our actual use case:** a stationary overnight test is
*harsher* than a run. Doze needs the device to be still, so during an actual run
the motion keeps the phone out of the deepest states. OEM killers like Deep
optimization are not Doze, though, and will happily kill a moving phone. So a
bad score is not a prediction that recording fails — but a bad score *after*
step 2 means the settings did not take, and that is worth knowing before you
spend 45 minutes walking.

## 4. The four tests

Run each one, then press **Stop**, then **Log** to share the file to yourself
(email, Drive, whatever). Save it into `logs/` here — that directory is
gitignored, because these files are your actual movements.

Then:

```bash
node tools/analyze-log.mjs logs/phase0-2026-08-26T....jsonl
```

**Test 1 — screen off, in pocket.** Start, lock the phone, put it in a pocket,
walk for **45 minutes**. This is the baseline and the headline criterion: no
gap longer than 30s, and zero gaps over 120s. If this fails nothing else
matters.

**Test 2 — backgrounded.** Start, press home, use other apps normally for 20
minutes, including something heavy like a camera or a map.

**Test 3 — swiped from recents.** Start, then swipe the app out of the recent
apps list, and walk for 10 minutes. This is the one that most often fails. The
bar is that at most **one** fix is lost — fixes are flushed to disk one at a
time, so a force-stop can only truncate the write in flight. If more than one
line is missing, something is buffering that shouldn't be. If it fails, that's
the finding, and it points straight at the Kotlin service.

**Test 4 — battery.** Run for a full hour. The app now records the battery level
on every fix, so the analyser computes the drain rate itself — you don't need to
note anything. The bar is **under 8 %/hour** at 1 Hz. Much above that and you are
probably holding a wake lock or the screen on. Under 15 minutes of data, the
analyser refuses to judge rather than extrapolating from noise.

## 5. Reading the result

The analyser prints a verdict, but the numbers behind it are what to look at:

- **yield** — fixes received against fixes expected at 1 Hz. A diagnostic, not a
  criterion.
- **max gap** — the longest silence. Must be under 30s, and nothing over 120s.
  A 15-minute gap is Doze.
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
