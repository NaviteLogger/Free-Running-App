import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, before, beforeEach, describe, it } from 'node:test';
import type { DatabaseSync } from 'node:sqlite';

import {
  activityExists,
  countActivities,
  getActivity,
  listActivities,
  openDatabase,
  ensureToken,
} from '../src/db.ts';
import { ingest, reprocessAll } from '../src/ingest.ts';
import { parseUpload } from '../src/upload-schema.ts';
import { RawStore } from '../src/raw-store.ts';
import type { RawActivity, RawPoint } from '../src/pipeline/types.ts';

const START = Date.UTC(2026, 8, 1, 7, 0, 0);
let workDir: string;
let db: DatabaseSync;
let store: RawStore;

before(() => {
  workDir = mkdtempSync(join(tmpdir(), 'freerunning-'));
});

after(() => {
  rmSync(workDir, { recursive: true, force: true });
});

beforeEach(async () => {
  db = openDatabase(':memory:');
  store = new RawStore(join(workDir, `raw-${Math.random().toString(36).slice(2)}`));
  await store.init();
});

function makeActivity(id = 'run-1', seconds = 120): RawActivity {
  const degPerMetre = 1 / 111_195;
  const points: RawPoint[] = [];
  for (let s = 0; s < seconds; s++) {
    points.push({
      seq: s,
      ts: START + s * 1000,
      gpsTs: START + s * 1000,
      lat: 52.2 + s * 3 * degPerMetre,
      lon: 21.0,
      accuracy: 5,
      altitude: 110,
      altitudeAccuracy: 3,
      speed: null,
      speedAccuracy: null,
      heading: null,
      isMocked: false,
      battery: 90,
    });
  }
  return {
    id,
    startedAt: START,
    endedAt: START + seconds * 1000,
    device: 'OnePlus CPH2581',
    osVersion: 'Android 16',
    appVersion: '1.0.0+1',
    sampleIntervalMs: 1000,
    accuracyProfile: 'best',
    points,
    events: [],
  };
}

describe('idempotent upload', () => {
  it('the same id uploaded twice gives one activity', async () => {
    const raw = makeActivity();
    const first = await ingest(db, store, raw, 'upload');
    const second = await ingest(db, store, raw, 'upload');

    assert.equal(first.outcome, 'created');
    assert.equal(second.outcome, 'duplicate');
    assert.equal(countActivities(db), 1);
  });

  it('a second upload does not rewrite the raw file', async () => {
    const raw = makeActivity();
    await ingest(db, store, raw, 'upload');

    // Same id, different points. The first upload is the record; a later one
    // must not be able to change history.
    const tampered: RawActivity = { ...raw, points: raw.points.slice(0, 5) };
    await ingest(db, store, tampered, 'upload');

    const stored = await store.read(raw.id);
    assert.equal(stored.points.length, raw.points.length);
  });

  it('rebuilds a missing row from the raw file already on disk', async () => {
    const raw = makeActivity();
    await ingest(db, store, raw, 'upload');
    // As if the process died between writing the file and writing the row.
    db.exec('DELETE FROM activities');
    assert.equal(activityExists(db, raw.id), false);

    const result = await ingest(db, store, raw, 'upload');
    assert.equal(result.outcome, 'duplicate');
    assert.equal(activityExists(db, raw.id), true);
  });
});

describe('raw points are write-once', () => {
  it('refuses a direct second write', async () => {
    const raw = makeActivity();
    await store.write(raw);
    await assert.rejects(() => store.write(raw), /never rewritten/);
  });

  it('refuses an id that would escape the directory', async () => {
    const raw = makeActivity('../../etc/passwd');
    await assert.rejects(() => store.write(raw), /unsafe activity id/);
  });

  it('round-trips through gzip unchanged', async () => {
    const raw = makeActivity();
    await store.write(raw);
    assert.deepEqual(await store.read(raw.id), raw);
  });
});

describe('rebuild from raw', () => {
  it('drops every summary and rebuilds them from the files', async () => {
    await ingest(db, store, makeActivity('a'), 'upload');
    await ingest(db, store, makeActivity('b'), 'upload');

    const before = [getActivity(db, 'a'), getActivity(db, 'b')];

    // The whole point of keeping raw points: this table is disposable.
    db.exec('DELETE FROM activities');
    assert.equal(countActivities(db), 0);

    const rebuilt = await reprocessAll(db, store, 12345);
    assert.equal(rebuilt, 2);

    const after = [getActivity(db, 'a'), getActivity(db, 'b')];
    // received_at is when the row was written and is expected to differ.
    for (const [i, row] of after.entries()) {
      const original = before[i] as Record<string, unknown>;
      const current = row as Record<string, unknown>;
      delete original['received_at'];
      delete current['received_at'];
      assert.deepEqual(current, original);
    }
  });
});

describe('activity list', () => {
  it('returns newest first and carries a polyline for the thumbnail', async () => {
    const older = { ...makeActivity('older'), startedAt: START - 86_400_000 };
    await ingest(db, store, older, 'upload');
    await ingest(db, store, makeActivity('newer'), 'upload');

    const list = listActivities(db);
    assert.deepEqual(
      list.map((a) => a.id),
      ['newer', 'older'],
    );
    assert.ok((list[0]?.polyline.length ?? 0) > 0);
  });
});

describe('upload validation', () => {
  it('accepts a well-formed body', () => {
    assert.equal(parseUpload(makeActivity()).ok, true);
  });

  const rejects: [string, unknown][] = [
    ['not an object', 'hello'],
    ['null', null],
    ['no points', { ...makeActivity(), points: [] }],
    ['points not an array', { ...makeActivity(), points: 'lots' }],
    ['id with a slash', { ...makeActivity(), id: 'a/b' }],
    [
      'latitude off the planet',
      {
        ...makeActivity(),
        points: [{ seq: 0, gpsTs: START, lat: 999, lon: 21 }],
      },
    ],
    ['missing device', { ...makeActivity(), device: undefined }],
  ];

  for (const [name, body] of rejects) {
    it(`rejects ${name}`, () => {
      const result = parseUpload(body);
      assert.equal(result.ok, false);
      if (!result.ok) assert.ok(result.problems.length > 0);
    });
  }
});

describe('token', () => {
  it('is made once and then reused', () => {
    const first = ensureToken(db);
    const second = ensureToken(db);
    assert.equal(first.created, true);
    assert.equal(second.created, false);
    assert.equal(first.token, second.token);
    assert.ok(first.token.length >= 32);
  });

  it('deleting the row issues a new one', () => {
    const first = ensureToken(db);
    db.exec("DELETE FROM settings WHERE key = 'api_token'");
    const second = ensureToken(db);
    assert.notEqual(first.token, second.token);
  });
});
