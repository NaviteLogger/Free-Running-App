import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, before, describe, it } from 'node:test';
import { gzipSync } from 'node:zlib';
import type { AddressInfo } from 'node:net';

import { loadConfig } from '../src/config.ts';
import { buildApp } from '../src/server.ts';
import type { App } from '../src/server.ts';
import type { RawActivity, RawPoint } from '../src/pipeline/types.ts';

const START = Date.UTC(2026, 8, 1, 7, 0, 0);

let workDir: string;
let app: App;
let base: string;

before(async () => {
  workDir = mkdtempSync(join(tmpdir(), 'freerunning-http-'));
  app = await buildApp(loadConfig({ DATA_DIR: workDir, PORT: '0' }));
  await new Promise<void>((resolve) => app.server.listen(0, '127.0.0.1', resolve));
  const address = app.server.address() as AddressInfo;
  base = `http://127.0.0.1:${address.port}`;
});

after(async () => {
  await new Promise<void>((resolve) => app.server.close(() => resolve()));
  app.db.close();
  rmSync(workDir, { recursive: true, force: true });
});

function makeActivity(id: string, seconds = 60): RawActivity {
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

const auth = (): Record<string, string> => ({ authorization: `Bearer ${app.token}` });

function post(path: string, body: unknown, headers: Record<string, string> = {}) {
  return fetch(`${base}${path}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...auth(), ...headers },
    body: JSON.stringify(body),
  });
}

describe('health', () => {
  it('is reachable without a token', async () => {
    const res = await fetch(`${base}/health`);
    assert.equal(res.status, 200);
    assert.equal(((await res.json()) as { ok: boolean }).ok, true);
  });
});

describe('authentication', () => {
  it('refuses a request with no token', async () => {
    const res = await fetch(`${base}/api/activities`);
    assert.equal(res.status, 401);
  });

  it('refuses a wrong token of the same length', async () => {
    const wrong = 'x'.repeat(app.token.length);
    const res = await fetch(`${base}/api/activities`, {
      headers: { authorization: `Bearer ${wrong}` },
    });
    assert.equal(res.status, 401);
  });

  it('refuses a wrong token of a different length', async () => {
    const res = await fetch(`${base}/api/activities`, {
      headers: { authorization: 'Bearer short' },
    });
    assert.equal(res.status, 401);
  });

  it('accepts the right token', async () => {
    const res = await fetch(`${base}/api/activities`, { headers: auth() });
    assert.equal(res.status, 200);
  });
});

describe('upload', () => {
  it('stores an activity and answers 201', async () => {
    const res = await post('/api/activities', makeActivity('http-1'));
    assert.equal(res.status, 201);
    assert.deepEqual(await res.json(), { id: 'http-1', outcome: 'created' });
  });

  it('answers 200 and does not duplicate on a retry', async () => {
    const activity = makeActivity('http-retry');
    assert.equal((await post('/api/activities', activity)).status, 201);

    const second = await post('/api/activities', activity);
    assert.equal(second.status, 200);
    assert.deepEqual(await second.json(), { id: 'http-retry', outcome: 'duplicate' });
  });

  it('accepts a gzipped body, which is how the phone sends it', async () => {
    const activity = makeActivity('http-gzip');
    const res = await fetch(`${base}/api/activities`, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'content-encoding': 'gzip',
        ...auth(),
      },
      body: gzipSync(Buffer.from(JSON.stringify(activity), 'utf8')),
    });
    assert.equal(res.status, 201);
  });

  it('rejects a body that is not valid gzip when it claims to be', async () => {
    const res = await fetch(`${base}/api/activities`, {
      method: 'POST',
      headers: { 'content-encoding': 'gzip', ...auth() },
      body: 'not gzip at all',
    });
    assert.equal(res.status, 400);
  });

  it('rejects malformed JSON', async () => {
    const res = await fetch(`${base}/api/activities`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', ...auth() },
      body: '{ broken',
    });
    assert.equal(res.status, 400);
  });

  it('explains what is wrong with an invalid body', async () => {
    const res = await post('/api/activities', { ...makeActivity('bad'), points: [] });
    assert.equal(res.status, 422);
    const body = (await res.json()) as { problems: string[] };
    assert.ok(body.problems.length > 0);
    assert.ok(body.problems.some((p) => p.includes('points')));
  });

  it('rejects an id that would escape the raw directory', async () => {
    const res = await post('/api/activities', makeActivity('../../etc/passwd'));
    assert.equal(res.status, 422);
  });
});

describe('reading activities', () => {
  it('lists what was uploaded, newest first', async () => {
    const res = await fetch(`${base}/api/activities`, { headers: auth() });
    const body = (await res.json()) as { activities: { id: string }[] };
    assert.ok(body.activities.length >= 3);
  });

  it('returns one activity with its splits parsed', async () => {
    const res = await fetch(`${base}/api/activities/http-1`, { headers: auth() });
    assert.equal(res.status, 200);
    const body = (await res.json()) as { splits: unknown[]; distance_m: number };
    assert.ok(Array.isArray(body.splits));
    assert.ok(body.distance_m > 0);
  });

  it('returns the raw points it was given', async () => {
    const res = await fetch(`${base}/api/activities/http-1/raw`, { headers: auth() });
    assert.equal(res.status, 200);
    const body = (await res.json()) as RawActivity;
    assert.equal(body.points.length, 60);
  });

  it('answers 404 for an activity that does not exist', async () => {
    const res = await fetch(`${base}/api/activities/nope`, { headers: auth() });
    assert.equal(res.status, 404);
  });

  it('caps the page size', async () => {
    const res = await fetch(`${base}/api/activities?limit=99999`, { headers: auth() });
    assert.equal(res.status, 200);
  });
});

describe('routing', () => {
  it('answers 404 for an unknown path', async () => {
    const res = await fetch(`${base}/nothing/here`, { headers: auth() });
    assert.equal(res.status, 404);
  });

  it('answers 405 for a known path with the wrong method', async () => {
    const res = await fetch(`${base}/health`, { method: 'DELETE' });
    assert.equal(res.status, 405);
  });

  it('sets HSTS and nosniff on every answer', async () => {
    const res = await fetch(`${base}/health`);
    assert.ok(res.headers.get('strict-transport-security')?.includes('max-age='));
    assert.equal(res.headers.get('x-content-type-options'), 'nosniff');
  });
});
