import { z } from 'zod';

import type { RawActivity } from './pipeline/types.ts';

/**
 * The shape of an upload, checked before any of it is trusted.
 *
 * This is the only place untrusted input crosses into the system, so it uses a
 * schema library instead of hand-written checks. Hand-written validation is
 * where the field somebody forgot to check lives.
 */

const nullableNumber = z
  .number()
  .nullish()
  .transform((v) => v ?? null);

const rawPoint = z.object({
  seq: z.number().int().nonnegative(),
  ts: z.number().int(),
  gpsTs: z.number().int(),
  lat: z.number().min(-90).max(90),
  lon: z.number().min(-180).max(180),
  accuracy: nullableNumber,
  altitude: nullableNumber,
  altitudeAccuracy: nullableNumber,
  speed: nullableNumber,
  speedAccuracy: nullableNumber,
  heading: nullableNumber,
  isMocked: z
    .boolean()
    .nullish()
    .transform((v) => v ?? false),
  battery: z
    .number()
    .int()
    .min(0)
    .max(100)
    .nullish()
    .transform((v) => v ?? null),
});

const rawEvent = z.object({
  seq: z.number().int().nonnegative(),
  ts: z.number().int(),
  kind: z.string().min(1).max(64),
  detail: z
    .record(z.string(), z.unknown())
    .nullish()
    .transform((v) => v ?? null),
});

export const rawActivitySchema = z
  .object({
    // Also used as a filename, so the character set is restricted here as well
    // as in the store. Two checks, because this one produces a clear message
    // and the other one is the last line of defence.
    id: z.string().regex(/^[A-Za-z0-9_-]{1,128}$/, 'must be a UUID-like id'),
    startedAt: z.number().int(),
    endedAt: z.number().int(),
    device: z.string().min(1).max(200),
    osVersion: z.string().min(1).max(200),
    appVersion: z.string().min(1).max(64),
    sampleIntervalMs: z.number().int().positive(),
    accuracyProfile: z.string().min(1).max(64),
    points: z.array(rawPoint).min(1).max(200_000),
    events: z
      .array(rawEvent)
      .nullish()
      .transform((v) => v ?? []),
  })
  .refine((a) => a.endedAt >= a.startedAt, {
    message: 'endedAt must not be before startedAt',
    path: ['endedAt'],
  });

export type UploadBody = z.infer<typeof rawActivitySchema>;

/**
 * Fails the build if the wire format and the domain type drift apart. There is
 * no runtime cost and no way to forget to run it.
 */
export type SchemaMatchesDomain = UploadBody extends RawActivity ? true : never;
const _schemaMatchesDomain: SchemaMatchesDomain = true;
void _schemaMatchesDomain;

export type ParseResult =
  { ok: true; raw: RawActivity } | { ok: false; problems: string[] };

export function parseUpload(body: unknown): ParseResult {
  const result = rawActivitySchema.safeParse(body);
  if (result.success) return { ok: true, raw: result.data };

  return {
    ok: false,
    // Only the first few, so a body with 10,000 bad points does not answer with
    // 10,000 lines.
    problems: result.error.issues
      .slice(0, 10)
      .map((issue) => `${issue.path.join('.') || 'body'}: ${issue.message}`),
  };
}
