#!/usr/bin/env node

import { createReadStream } from "node:fs";
import { createInterface } from "node:readline";
import { argv, exit } from "node:process";

const path = argv[2];
if (!path) {
  console.error("usage: node tools/analyze-log.mjs <session.jsonl>");
  exit(1);
}

const fixes = [];
const events = [];
let malformed = 0;

const rl = createInterface({
  input: createReadStream(path),
  crlfDelay: Infinity,
});

for await (const line of rl) {
  if (!line.trim()) continue;
  let row;
  try {
    row = JSON.parse(line);
  } catch {
    // A truncated final line is expected if the process was killed mid-write
    malformed++;
    continue;
  }
  if (row.t === "fix") fixes.push(row);
  else events.push(row);
}

if (fixes.length === 0) {
  console.error("No fixes in this log. Events:");
  for (const e of events) console.error(" ", JSON.stringify(e));
  exit(1);
}

const fmtClock = (ms) => new Date(ms).toISOString().slice(11, 19);
const fmtDur = (ms) => {
  const s = Math.round(ms / 1000);
  const m = Math.floor(s / 60);
  return m > 0 ? `${m}m${String(s % 60).padStart(2, "0")}s` : `${s}s`;
};

const first = fixes[0];
const last = fixes[fixes.length - 1];
const spanMs = last.ts - first.ts;

// GPS timestamps are compared separately below
const gaps = [];
for (let i = 1; i < fixes.length; i++) {
  gaps.push({
    ms: fixes[i].ts - fixes[i - 1].ts,
    gpsMs: fixes[i].gpsTs - fixes[i - 1].gpsTs,
    at: fixes[i - 1].ts,
    index: i,
  });
}

const sorted = [...gaps].map((g) => g.ms).sort((a, b) => a - b);
const pct = (p) =>
  sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * p))];

// At the 1 Hz the app requests, a perfect session yields one fix per second.
const expected = Math.round(spanMs / 1000);
const yieldPct = ((fixes.length / expected) * 100).toFixed(1);

const lostMs = gaps.filter((g) => g.ms > 5000).reduce((a, g) => a + g.ms, 0);

console.log(`\n  ${path}\n`);
console.log(
  `  session      ${fmtClock(first.ts)} → ${fmtClock(last.ts)}  (${fmtDur(spanMs)})`,
);
console.log(`  fixes        ${fixes.length} of ~${expected} expected at 1 Hz`);
console.log(`  yield        ${yieldPct}%`);
console.log(`  median gap   ${(pct(0.5) / 1000).toFixed(1)}s`);
console.log(`  p95 gap      ${(pct(0.95) / 1000).toFixed(1)}s`);
console.log(`  max gap      ${(sorted[sorted.length - 1] / 1000).toFixed(1)}s`);
console.log(
  `  time lost    ${fmtDur(lostMs)} across ${gaps.filter((g) => g.ms > 5000).length} gaps over 5s`,
);
if (malformed)
  console.log(`  malformed    ${malformed} line(s) — likely a kill mid-write`);

const accs = fixes.map((f) => f.acc).sort((a, b) => a - b);
console.log(
  `  accuracy     median ${accs[Math.floor(accs.length / 2)].toFixed(0)}m, worst ${accs[accs.length - 1].toFixed(0)}m`,
);
if (fixes.some((f) => f.mocked))
  console.log(`  WARNING      some fixes came from a mock provider`);

// Drain is measured from the first and last fix that carried a battery level,
// not from the session bounds, so a log recorded before battery logging existed
// simply reports nothing rather than dividing by a missing number.
const battery = (() => {
  const withLevel = fixes.filter((f) => typeof f.batt === "number");
  if (withLevel.length < 2) return null;
  const from = withLevel[0];
  const to = withLevel[withLevel.length - 1];
  const hours = (to.ts - from.ts) / 3_600_000;
  if (hours <= 0) return null;
  return { from: from.batt, to: to.batt, hours, rate: (from.batt - to.batt) / hours };
})();

if (battery !== null) {
  console.log(
    `  battery      ${battery.from}% → ${battery.to}% over ${fmtDur(battery.hours * 3_600_000)} = ${battery.rate.toFixed(1)}%/h`,
  );
}

const worst = [...gaps]
  .sort((a, b) => b.ms - a.ms)
  .slice(0, 10)
  .filter((g) => g.ms > 5000);
if (worst.length) {
  console.log(`\n  worst gaps\n`);
  for (const g of worst) {
    // If GPS time advanced as much as wall-clock, the fixes were never taken.
    // If it advanced far less, the service kept sampling and flushed late.
    const drift = Math.abs(g.gpsMs - g.ms);
    const kind = drift > 2000 ? "buffered" : "lost";
    console.log(
      `    ${fmtClock(g.at)}  ${(g.ms / 1000).toFixed(1)}s  (${kind})`,
    );

    // Anything the app logged inside the gap is the likeliest explanation.
    const during = events.filter((e) => e.ts >= g.at && e.ts <= g.at + g.ms);
    for (const e of during) {
      const detail = e.state ?? e.event ?? e.message ?? "";
      console.log(`        └ ${e.t}: ${detail}`);
    }
  }
}

const start = events.find((e) => e.t === "session" && e.event === "start");
if (start?.grants) {
  console.log(`\n  grants at start`);
  for (const [k, v] of Object.entries(start.grants)) {
    console.log(`    ${v ? "✓" : "✗"} ${k}`);
  }
}

// The gate, verbatim from the build plan. Yield and the percentiles above are
// diagnostics; only these decide whether Phase 1 gets written in Dart.
const TARGET_GAP_MS = 30_000;
const HARD_GAP_MS = 120_000;
const MAX_LOST_FIXES = 1;
const MAX_DRAIN_PCT_PER_H = 8;

const maxGapMs = sorted[sorted.length - 1];
const overHard = gaps.filter((g) => g.ms > HARD_GAP_MS).length;

const results = [
  {
    name: "gap discipline",
    pass: maxGapMs <= TARGET_GAP_MS && overHard === 0,
    detail: `max ${(maxGapMs / 1000).toFixed(1)}s (limit ${TARGET_GAP_MS / 1000}s), ${overHard} over ${HARD_GAP_MS / 1000}s`,
  },
  {
    // Fixes are flushed to disk individually, so a force-stop can only ever
    // truncate the write in flight. More than one lost line means something is
    // buffering that should not be.
    name: "kill resilience",
    pass: malformed <= MAX_LOST_FIXES,
    detail: `${malformed} truncated line(s) (limit ${MAX_LOST_FIXES})`,
  },
];

if (battery === null) {
  results.push({
    name: "battery",
    pass: null,
    detail: "not recorded in this log",
  });
} else if (battery.hours < 0.25) {
  // A 4% reading over six minutes extrapolates to 40%/h and means nothing.
  results.push({
    name: "battery",
    pass: null,
    detail: `only ${fmtDur(battery.hours * 3_600_000)} of data — run longer`,
  });
} else {
  results.push({
    name: "battery",
    pass: battery.rate < MAX_DRAIN_PCT_PER_H,
    detail: `${battery.rate.toFixed(1)}%/h (limit ${MAX_DRAIN_PCT_PER_H}%/h)`,
  });
}

results.push({
  name: "interruption",
  pass: null,
  detail: "judge by hand: phone call, camera, Doze",
});

console.log(`\n  gate\n`);
for (const r of results) {
  const mark = r.pass === null ? "?" : r.pass ? "✓" : "✗";
  console.log(`    ${mark} ${r.name.padEnd(16)} ${r.detail}`);
}

const failed = results.filter((r) => r.pass === false);
const unjudged = results.filter((r) => r.pass === null);
console.log(
  failed.length > 0
    ? `\n  FAIL — ${failed.length} criterion/criteria failed: ${failed.map((r) => r.name).join(", ")}.\n` +
        `  If only kill resilience failed, move capture into a native Kotlin\n` +
        `  foreground service. If gaps failed, suspect Doze and OEM killers first.\n`
    : `\n  PASS on everything measurable here${unjudged.length ? `, ${unjudged.length} left to judge by hand` : ""}.\n` +
        `  The Dart-side loop held up — Phase 1 can stay in Flutter.\n`,
);
