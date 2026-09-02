import { HttpError } from './router.ts';
import type { Middleware } from './router.ts';

export type RateLimitOptions = {
  /** Requests allowed in a burst. */
  capacity: number;
  /** Tokens added per second. */
  refillPerSecond: number;
  /** Only these paths are limited. */
  paths: readonly string[];
};

/**
 * A token bucket, in memory, keyed by client address.
 *
 * In memory because there is one process and one user. A restart forgets the
 * counters, which is fine: this exists to stop a runaway client or a scanner
 * hammering the upload route, not to enforce a quota.
 *
 * Only upload is limited. Reads are cheap and behind the same token.
 */
export function rateLimit(
  options: RateLimitOptions,
  now: () => number = Date.now,
): Middleware {
  const buckets = new Map<string, { tokens: number; updatedAt: number }>();
  const limited = new Set(options.paths);

  return (ctx, route) => {
    if (!limited.has(route.path)) return;

    const at = now();
    const bucket = buckets.get(ctx.ip) ?? { tokens: options.capacity, updatedAt: at };

    const elapsedSeconds = Math.max(0, (at - bucket.updatedAt) / 1000);
    bucket.tokens = Math.min(
      options.capacity,
      bucket.tokens + elapsedSeconds * options.refillPerSecond,
    );
    bucket.updatedAt = at;

    if (bucket.tokens < 1) {
      buckets.set(ctx.ip, bucket);
      const waitSeconds = Math.ceil((1 - bucket.tokens) / options.refillPerSecond);
      throw new HttpError(429, `too many requests, retry in ${waitSeconds}s`);
    }

    bucket.tokens -= 1;
    buckets.set(ctx.ip, bucket);

    // Stop the map growing without bound if something walks a range of
    // addresses. Full buckets carry no information worth keeping.
    if (buckets.size > 1000) {
      for (const [ip, entry] of buckets) {
        if (entry.tokens >= options.capacity) buckets.delete(ip);
      }
    }
  };
}
