import type { DatabaseSync } from 'node:sqlite';

import { activityExists, saveActivity } from './db.ts';
import { processActivity } from './pipeline/run.ts';
import type { RawActivity } from './pipeline/types.ts';
import type { RawStore } from './raw-store.ts';

export type IngestResult = {
  id: string;
  /** created on the first upload, duplicate on any repeat. */
  outcome: 'created' | 'duplicate';
};

/**
 * Takes an upload and turns it into an activity.
 *
 * Uploading the same id twice gives one activity. The phone generates the id
 * before the first fix, so a retry after a dropped connection is free and needs
 * no coordination between the two sides.
 *
 * The check is on the raw file and not on the database row. The file is the
 * record; the row is a cache of numbers derived from it. If a crash ever leaves
 * a file with no row, a repeat upload rebuilds the row from the file it already
 * has and does not need the phone to send anything again.
 */
export async function ingest(
  db: DatabaseSync,
  store: RawStore,
  raw: RawActivity,
  source: 'upload' | 'gpx',
  now = Date.now(),
): Promise<IngestResult> {
  if (await store.has(raw.id)) {
    if (!activityExists(db, raw.id)) {
      await reprocess(db, store, raw.id, source, now);
    }
    return { id: raw.id, outcome: 'duplicate' };
  }

  await store.write(raw);
  writeSummary(db, raw, source, now);
  return { id: raw.id, outcome: 'created' };
}

/** Rebuilds one activity's numbers from the raw file already on disk. */
export async function reprocess(
  db: DatabaseSync,
  store: RawStore,
  id: string,
  source: 'upload' | 'gpx',
  now = Date.now(),
): Promise<void> {
  const raw = await store.read(id);
  writeSummary(db, raw, source, now);
}

/**
 * Rebuilds every activity from the raw files.
 *
 * This is the check that matters for the whole design: the summary table can be
 * dropped and rebuilt from the raw points alone. If that ever stops being true,
 * something is being stored that should not be.
 */
export async function reprocessAll(
  db: DatabaseSync,
  store: RawStore,
  now = Date.now(),
): Promise<number> {
  const ids = await store.ids();
  for (const id of ids) {
    await reprocess(db, store, id, 'upload', now);
  }
  return ids.length;
}

function writeSummary(
  db: DatabaseSync,
  raw: RawActivity,
  source: 'upload' | 'gpx',
  now: number,
): void {
  saveActivity(db, {
    ...processActivity(raw),
    receivedAt: now,
    device: raw.device,
    osVersion: raw.osVersion,
    appVersion: raw.appVersion,
    source,
  });
}
