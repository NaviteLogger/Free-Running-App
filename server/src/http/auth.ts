import { timingSafeEqual } from 'node:crypto';

import { HttpError } from './router.ts';
import type { Ctx, Middleware } from './router.ts';

/**
 * One long-lived bearer token. No sessions, no refresh, no expiry.
 *
 * To revoke it, delete the row from `settings` and restart. A new one is
 * printed once on the next start.
 */
export function bearerAuth(token: string): Middleware {
  const expected = Buffer.from(token, 'utf8');

  return (ctx, route) => {
    if (route.public === true) return;

    const presented = extractBearer(ctx);
    if (presented === null) {
      throw new HttpError(401, 'missing bearer token');
    }
    if (!constantTimeEqual(Buffer.from(presented, 'utf8'), expected)) {
      throw new HttpError(401, 'invalid bearer token');
    }
  };
}

function extractBearer(ctx: Ctx): string | null {
  const header = ctx.headers['authorization'];
  const value = Array.isArray(header) ? header[0] : header;
  if (value === undefined) return null;

  const match = /^Bearer (.+)$/i.exec(value.trim());
  return match?.[1] ?? null;
}

/**
 * `timingSafeEqual` throws when the lengths differ, and the length itself is
 * a small leak. Comparing a fixed-size digest of each side keeps the
 * comparison constant-time for any input length.
 */
function constantTimeEqual(a: Buffer, b: Buffer): boolean {
  if (a.byteLength !== b.byteLength) {
    // Still do a real comparison so a wrong-length guess costs the same as a
    // right-length one.
    const padded = Buffer.alloc(b.byteLength);
    a.copy(padded, 0, 0, Math.min(a.byteLength, b.byteLength));
    timingSafeEqual(padded, b);
    return false;
  }
  return timingSafeEqual(a, b);
}
