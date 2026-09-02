import type { DatabaseSync } from 'node:sqlite';

import { countActivities, getActivity, listActivities } from './db.ts';
import { ingest } from './ingest.ts';
import { HttpError } from './http/router.ts';
import type { Route } from './http/router.ts';
import type { RawStore } from './raw-store.ts';
import { parseUpload } from './upload-schema.ts';

export const UPLOAD_PATH = '/api/activities';

export function buildRoutes(db: DatabaseSync, store: RawStore): Route[] {
  return [
    {
      method: 'GET',
      path: '/health',
      public: true,
      handler: () => ({
        status: 200,
        body: { ok: true, activities: countActivities(db) },
      }),
    },

    {
      method: 'POST',
      path: UPLOAD_PATH,
      handler: async (ctx) => {
        const parsed = parseUpload(await ctx.body());
        if (!parsed.ok) {
          throw new HttpError(422, 'upload failed validation', parsed.problems);
        }

        const result = await ingest(db, store, parsed.raw, 'upload');
        // 200 for a repeat and 201 for the first, so the phone can tell what
        // happened. Both mean "it is stored, stop retrying".
        return {
          status: result.outcome === 'created' ? 201 : 200,
          body: result,
        };
      },
    },

    {
      method: 'GET',
      path: UPLOAD_PATH,
      handler: (ctx) => {
        const limit = clampInt(ctx.url.searchParams.get('limit'), 100, 1, 500);
        const offset = clampInt(ctx.url.searchParams.get('offset'), 0, 0, 1_000_000);
        return {
          status: 200,
          body: { activities: listActivities(db, limit, offset) },
        };
      },
    },

    {
      method: 'GET',
      path: '/api/activities/:id',
      handler: (ctx) => {
        const id = ctx.params['id'];
        if (id === undefined) throw new HttpError(400, 'missing id');

        const activity = getActivity(db, id);
        if (activity === null) throw new HttpError(404, 'no such activity');
        return { status: 200, body: activity };
      },
    },

    {
      method: 'GET',
      path: '/api/activities/:id/raw',
      handler: async (ctx) => {
        const id = ctx.params['id'];
        if (id === undefined) throw new HttpError(400, 'missing id');
        if (!(await store.has(id))) throw new HttpError(404, 'no such activity');
        return { status: 200, body: await store.read(id) };
      },
    },
  ];
}

function clampInt(
  raw: string | null,
  fallback: number,
  min: number,
  max: number,
): number {
  if (raw === null) return fallback;
  const value = Number(raw);
  if (!Number.isInteger(value)) return fallback;
  return Math.min(max, Math.max(min, value));
}
