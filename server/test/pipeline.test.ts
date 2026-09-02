import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import { decodePolyline, encodePolyline, haversineM } from '../src/pipeline/geo.ts';
import { PIPELINE_VERSION, processActivity } from '../src/pipeline/run.ts';
import type { RawActivity, RawEvent, RawPoint } from '../src/pipeline/types.ts';

const START = Date.UTC(2026, 8, 1, 7, 0, 0);

function point(seq: number, over: Partial<RawPoint> = {}): RawPoint {
  return {
    seq,
    ts: START + seq * 1000,
    gpsTs: START + seq * 1000,
    lat: 52.2,
    lon: 21.0,
    accuracy: 5,
    altitude: 110,
    altitudeAccuracy: 3,
    speed: null,
    speedAccuracy: null,
    heading: null,
    isMocked: false,
    battery: 90,
    ...over,
  };
}

function activity(points: RawPoint[], events: RawEvent[] = []): RawActivity {
  const last = points[points.length - 1];
  return {
    id: 'a1',
    startedAt: START,
    endedAt: last === undefined ? START : last.gpsTs,
    device: 'OnePlus CPH2581',
    osVersion: 'Android 16',
    appVersion: '1.0.0+1',
    sampleIntervalMs: 1000,
    accuracyProfile: 'best',
    points,
    events,
  };
}

/** Straight north at a steady pace, one fix a second. */
function straightRun(
  seconds: number,
  metresPerSecond: number,
  altitudeAt?: (s: number) => number,
) {
  const degPerMetre = 1 / 111_195;
  const points: RawPoint[] = [];
  for (let s = 0; s < seconds; s++) {
    points.push(
      point(s, {
        lat: 52.2 + s * metresPerSecond * degPerMetre,
        altitude: altitudeAt ? altitudeAt(s) : 110,
      }),
    );
  }
  return points;
}

describe('geo', () => {
  it('measures a known separation', () => {
    assert.ok(Math.abs(haversineM(52, 21, 53, 21) - 111_195) < 200);
  });

  it('round-trips a polyline within its precision', () => {
    const original = [
      { lat: 52.22967, lon: 21.01222 },
      { lat: 52.23001, lon: 21.01301 },
      { lat: 52.23044, lon: 21.01377 },
    ];
    const decoded = decodePolyline(encodePolyline(original));
    assert.equal(decoded.length, original.length);
    decoded.forEach((p, i) => {
      const want = original[i];
      assert.ok(want !== undefined);
      assert.ok(Math.abs(p.lat - want.lat) < 1e-5);
      assert.ok(Math.abs(p.lon - want.lon) < 1e-5);
    });
  });

  it('encodes the same input to the same bytes every time', () => {
    const pts = [
      { lat: 52.2, lon: 21.0 },
      { lat: 52.3, lon: 21.1 },
    ];
    assert.equal(encodePolyline(pts), encodePolyline(pts));
  });
});

describe('distance', () => {
  it('measures a straight run', () => {
    // 600 seconds at 3 m/s is 1,800 m.
    const summary = processActivity(activity(straightRun(600, 3)));
    assert.ok(Math.abs(summary.distanceM - 1800) < 20, `got ${summary.distanceM}`);
  });

  it('adds nothing while the phone sits still', () => {
    const points: RawPoint[] = [];
    for (let s = 0; s < 600; s++) {
      // A metre of drift back and forth, which is what a stationary phone gives.
      points.push(point(s, { lat: 52.2 + (s % 2) * 0.000009 }));
    }
    assert.equal(processActivity(activity(points)).distanceM, 0);
  });

  it('ignores fixes outside the accuracy gate', () => {
    const points = [
      point(0, { lat: 52.2, accuracy: 5 }),
      point(1, { lat: 52.3, accuracy: 90 }), // an 11 km jump, from a bad fix
      point(2, { lat: 52.2, accuracy: 5 }),
    ];
    assert.equal(processActivity(activity(points)).distanceM, 0);
  });

  it('still accumulates at walking pace', () => {
    // 1.4 m/s is below the 2 m step filter, so this checks the anchor does not
    // move when a step is skipped.
    const summary = processActivity(activity(straightRun(600, 1.4)));
    assert.ok(Math.abs(summary.distanceM - 840) < 20, `got ${summary.distanceM}`);
  });
});

describe('elevation', () => {
  it('reports under 10 m of climb on a flat loop', () => {
    // Flat ground, altitude wandering by a few metres, which is what GPS does.
    // Adding up every rise here gives well over 200 m.
    const noise = [0, 2.1, -1.4, 3.2, -2.8, 1.1, -0.6, 2.5, -3.1, 0.9];
    const summary = processActivity(
      activity(straightRun(600, 3, (s) => 110 + (noise[s % noise.length] ?? 0))),
    );
    assert.ok(summary.ascentM < 10, `flat loop reported ${summary.ascentM} m of climb`);
  });

  it('keeps a real hill', () => {
    // 100 m of climb over 600 m, with the same noise on top.
    const noise = [0, 1.6, -1.2, 2.1, -1.8];
    const summary = processActivity(
      activity(
        straightRun(
          600,
          3,
          (s) => 110 + s * (100 / 600) + (noise[s % noise.length] ?? 0),
        ),
      ),
    );
    assert.ok(
      summary.ascentM > 85 && summary.ascentM < 115,
      `hill reported ${summary.ascentM} m, wanted about 100`,
    );
  });
});

describe('moving time', () => {
  /** Runs, stands still, runs again. All fixes keep arriving throughout. */
  function runRestRun(restSeconds: number) {
    const degPerMetre = 1 / 111_195;
    const points: RawPoint[] = [];
    for (let s = 0; s < 60; s++)
      points.push(point(s, { lat: 52.2 + s * 3 * degPerMetre }));
    const restLat = 52.2 + 59 * 3 * degPerMetre;
    for (let s = 60; s < 60 + restSeconds; s++) points.push(point(s, { lat: restLat }));
    for (let s = 0; s < 60; s++) {
      points.push(point(60 + restSeconds + s, { lat: restLat + s * 3 * degPerMetre }));
    }
    return points;
  }

  it('keeps a five-second wait at a crossing', () => {
    const summary = processActivity(activity(runRestRun(5)));
    // 125 seconds elapsed, none of it taken out.
    assert.ok(
      summary.movingS >= 120,
      `moving ${summary.movingS} of ${summary.elapsedS}, the short wait was removed`,
    );
    assert.equal(summary.droppedS, 0);
  });

  it('takes out a sixty-second stop, and only once', () => {
    const summary = processActivity(activity(runRestRun(60)));
    // 180 elapsed, 60 standing still, so about 120 of movement. An earlier
    // version subtracted the stop again on every sample and drove this to zero,
    // which an "is it less than elapsed" check happily accepted.
    assert.ok(
      summary.movingS > 110 && summary.movingS < 130,
      `moving ${summary.movingS}, wanted about 120`,
    );
  });

  it('does not call standing still a data loss', () => {
    // Fixes kept arriving the whole time. Nothing was lost, the runner stopped.
    const summary = processActivity(activity(runRestRun(60)));
    assert.equal(summary.droppedS, 0);
    assert.equal(summary.usedPointCount, summary.pointCount);
  });
});

describe('pauses and lost time', () => {
  it('counts a deliberate pause as paused, not lost', () => {
    const first = straightRun(60, 3);
    const lat = first[59]?.lat ?? 52.2;
    const points = [...first];
    // Nothing recorded for two minutes, with pause and resume around it.
    for (let s = 180; s < 240; s++) {
      points.push(point(s, { lat: lat + (s - 180) * 3 * (1 / 111_195) }));
    }
    const events: RawEvent[] = [
      { seq: 0, ts: START + 60_000, kind: 'pause', detail: null },
      { seq: 1, ts: START + 180_000, kind: 'resume', detail: null },
    ];
    const summary = processActivity(activity(points, events));
    assert.ok(summary.pausedS > 100, `paused ${summary.pausedS}`);
    assert.equal(summary.droppedS, 0);
  });

  it('counts an unexplained hole as lost', () => {
    const first = straightRun(60, 3);
    const lat = first[59]?.lat ?? 52.2;
    const points = [...first];
    for (let s = 180; s < 240; s++) {
      points.push(point(s, { lat: lat + (s - 180) * 3 * (1 / 111_195) }));
    }
    // Same hole, no pause event. This is the operating system, not the runner.
    const summary = processActivity(activity(points));
    assert.ok(summary.droppedS > 100, `dropped ${summary.droppedS}`);
    assert.equal(summary.pausedS, 0);
  });
});

describe('determinism', () => {
  it('produces byte-identical output when run twice', () => {
    const raw = activity(straightRun(600, 3, (s) => 110 + Math.sin(s / 20) * 8));
    const a = JSON.stringify(processActivity(raw));
    const b = JSON.stringify(processActivity(raw));
    assert.equal(a, b);
  });

  it('does not depend on the order points arrive in', () => {
    const raw = activity(straightRun(300, 3));
    const shuffled: RawActivity = { ...raw, points: [...raw.points].reverse() };
    assert.equal(
      JSON.stringify(processActivity(raw)),
      JSON.stringify(processActivity(shuffled)),
    );
  });

  it('stamps the pipeline version on every activity', () => {
    assert.equal(
      processActivity(activity(straightRun(10, 3))).pipelineVersion,
      PIPELINE_VERSION,
    );
  });
});

describe('splits', () => {
  it('cuts a run into kilometres', () => {
    // 1000 seconds at 3 m/s is 3,000 m.
    const summary = processActivity(activity(straightRun(1000, 3)));
    assert.equal(summary.splits.length, 3);
    const first = summary.splits[0];
    assert.ok(first !== undefined);
    assert.ok(Math.abs(first.distanceM - 1000) < 20, `first split ${first.distanceM}`);
  });

  it('leaves no splits for an empty activity', () => {
    assert.deepEqual(processActivity(activity([])).splits, []);
  });
});
