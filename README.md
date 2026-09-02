# free-running

A running tracker you host yourself.

Your phone records a run and sends the raw GPS points to a small server you
own. The server works out distance, climb, pace and splits, and a web page
shows them back to you. One person, one phone, one machine.

Location history is the most personal data most people carry. It is your home
address, your workplace and your daily routine. This keeps all of it on
hardware you control.

## What it does

- Records a run on Android, writing every position straight to the phone's own
  database
- Survives being killed mid-run and offers to carry on where it stopped
- Uploads finished runs when there is a network, and holds on to them when
  there isn't
- Works out distance, moving time, climb and kilometre splits on the server
- Imports and exports GPX, so your history from elsewhere comes with you and
  yours can leave whenever you like

## What it will never do

Accounts, following people, sharing, leaderboards, segments, kudos. One person
uses this. Adding any of that would mean building the thing it exists to
replace.

## Where the project is

The recorder works and has run on a phone. The server accepts uploads and
serves activities back. The web page has not been written yet.

Full detail in [docs/status.md](docs/status.md).

## What you need

- An Android phone, version 11 or later
- Flutter, to build the app
- Node 24 or later, for the server
- Somewhere to run the server. A small virtual machine is plenty.

## Running the server

Node 24 runs TypeScript directly, so there is no build step. `tsc` is there to
check types.

```bash
cd server
npm install
npm start
```

The first start prints an API token. Copy it somewhere safe, since it is shown
only once. To issue a new one, delete the `api_token` row from the `settings`
table and restart.

```bash
npm run typecheck
npm test
```

## Running the app

```bash
cd app
flutter pub get
flutter run
```

Then open the settings screen in the app and enter the server address and the
token.

Getting a phone connected to a development machine takes a few steps, and they
are all in [docs/connecting.md](docs/connecting.md).

The tests run against real SQLite on your computer, so they exercise the actual
schema and queries with no phone attached.

## Checking everything

```sh
tools/verify.sh
```

Formatting, types and tests for both halves. It runs each check unpiped and
exits non-zero if any of them fail, so it works in a script or a hook. The same
checks run in CI on every push.

## How it is put together

The phone sends raw GPS points and nothing else. Every number you see is worked
out on the server.

This costs a little effort up front and buys something valuable. When the way
climb is smoothed improves next year, every run you have ever recorded can be
worked out again with the better version. Had the phone done the sums, those
numbers would be stuck at whatever the app believed on the day.

[docs/architecture.md](docs/architecture.md) has the rest.

## A warning about Android

Keeping an app alive with the screen off is the hardest part of building this,
and it has little to do with your code. Android limits background work, and
phone makers add their own limits on top that are stricter and barely
documented. Strava has the same problem and answers it with a support article
per manufacturer.

[docs/android-background.md](docs/android-background.md) covers what helps,
with measurements from a OnePlus 12.

## Documentation

- [docs/status.md](docs/status.md) · what is done, what is next, what is broken
- [docs/connecting.md](docs/connecting.md) · getting a phone talking to a
  development server
- [docs/architecture.md](docs/architecture.md) · how the pieces fit together
- [docs/decisions.md](docs/decisions.md) · settled choices and the reasoning
- [docs/android-background.md](docs/android-background.md) · staying alive in
  the background
- [docs/testing-the-recorder.md](docs/testing-the-recorder.md) · the four tests
  that need a real walk
