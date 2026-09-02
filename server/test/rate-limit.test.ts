import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import { rateLimit } from '../src/http/rate-limit.ts';
import { HttpError, compile } from '../src/http/router.ts';
import type { Ctx } from '../src/http/router.ts';

const routes = compile([
  { method: 'POST', path: '/api/activities', handler: () => ({ status: 200 }) },
  { method: 'GET', path: '/health', handler: () => ({ status: 200 }), public: true },
]);

const [uploadRoute, healthRoute] = routes;
if (uploadRoute === undefined || healthRoute === undefined) {
  throw new Error('route table did not compile');
}

function ctxFrom(ip: string): Ctx {
  return {
    method: 'POST',
    url: new URL('http://localhost/api/activities'),
    params: {},
    headers: {},
    ip,
    body: () => Promise.resolve({}),
  };
}

describe('rate limit', () => {
  it('allows a burst up to the capacity', () => {
    const limit = rateLimit(
      { capacity: 3, refillPerSecond: 1, paths: ['/api/activities'] },
      () => 0,
    );
    const ctx = ctxFrom('10.0.0.1');
    for (let i = 0; i < 3; i++) limit(ctx, uploadRoute);
    assert.throws(() => limit(ctx, uploadRoute), HttpError);
  });

  it('refills over time', () => {
    let now = 0;
    const limit = rateLimit(
      { capacity: 2, refillPerSecond: 1, paths: ['/api/activities'] },
      () => now,
    );
    const ctx = ctxFrom('10.0.0.2');

    limit(ctx, uploadRoute);
    limit(ctx, uploadRoute);
    assert.throws(() => limit(ctx, uploadRoute), HttpError);

    now = 2000; // two seconds, two tokens back
    limit(ctx, uploadRoute);
    limit(ctx, uploadRoute);
    assert.throws(() => limit(ctx, uploadRoute), HttpError);
  });

  it('counts each address separately', () => {
    const limit = rateLimit(
      { capacity: 1, refillPerSecond: 1, paths: ['/api/activities'] },
      () => 0,
    );
    limit(ctxFrom('10.0.0.3'), uploadRoute);
    assert.throws(() => limit(ctxFrom('10.0.0.3'), uploadRoute), HttpError);
    // A different client is unaffected.
    limit(ctxFrom('10.0.0.4'), uploadRoute);
  });

  it('leaves unlisted routes alone', () => {
    const limit = rateLimit(
      { capacity: 1, refillPerSecond: 1, paths: ['/api/activities'] },
      () => 0,
    );
    const ctx = ctxFrom('10.0.0.5');
    for (let i = 0; i < 100; i++) limit(ctx, healthRoute);
  });

  it('answers 429 and says how long to wait', () => {
    const limit = rateLimit(
      { capacity: 1, refillPerSecond: 0.5, paths: ['/api/activities'] },
      () => 0,
    );
    const ctx = ctxFrom('10.0.0.6');
    limit(ctx, uploadRoute);
    try {
      limit(ctx, uploadRoute);
      assert.fail('should have been limited');
    } catch (error) {
      assert.ok(error instanceof HttpError);
      assert.equal(error.status, 429);
      assert.match(error.message, /retry in \d+s/);
    }
  });
});
