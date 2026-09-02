import { randomBytes } from 'node:crypto';
import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { DatabaseSync } from 'node:sqlite';

import type { Summary } from './pipeline/types.ts';

/** Bump and add a step to `migrate` for any schema change. */
export const SCHEMA_VERSION = 1;

export type ActivityRow = Summary & {
  receivedAt: number;
  device: string;
  osVersion: string;
  appVersion: string;
  /** upload or gpx */
  source: string;
};

export type ActivityListItem = {
  id: string;
  startedAt: number;
  distanceM: number;
  movingS: number;
  paceSPerKm: number;
  ascentM: number;
  polyline: string;
};

export function openDatabase(path: string): DatabaseSync {
  if (path !== ':memory:') mkdirSync(dirname(path), { recursive: true });
  const db = new DatabaseSync(path);

  db.exec('PRAGMA journal_mode = WAL');
  db.exec('PRAGMA synchronous = NORMAL');
  db.exec('PRAGMA foreign_keys = ON');

  migrate(db);
  return db;
}

function migrate(db: DatabaseSync): void {
  const current = Number(
    (db.prepare('PRAGMA user_version').get() as { user_version?: number } | undefined)
      ?.user_version ?? 0,
  );
  if (current >= SCHEMA_VERSION) return;

  if (current < 1) {
    // Everything here is derived from the raw points on disk and can be
    // rebuilt by dropping the table and reprocessing. If a column ever appears
    // that cannot be rebuilt that way, something is being stored in the wrong
    // place.
    db.exec(`
      CREATE TABLE activities (
        id                 TEXT    PRIMARY KEY NOT NULL,
        started_at         INTEGER NOT NULL,
        ended_at           INTEGER NOT NULL,
        received_at        INTEGER NOT NULL,
        pipeline_version   INTEGER NOT NULL,
        distance_m         REAL    NOT NULL,
        elapsed_s          INTEGER NOT NULL,
        moving_s           INTEGER NOT NULL,
        ascent_m           REAL    NOT NULL,
        descent_m          REAL    NOT NULL,
        pace_s_per_km      REAL    NOT NULL,
        point_count        INTEGER NOT NULL,
        used_point_count   INTEGER NOT NULL,
        paused_s           INTEGER NOT NULL,
        dropped_s          INTEGER NOT NULL,
        polyline           TEXT    NOT NULL,
        splits             TEXT    NOT NULL,
        device             TEXT    NOT NULL,
        os_version         TEXT    NOT NULL,
        app_version        TEXT    NOT NULL,
        source             TEXT    NOT NULL
      );

      CREATE INDEX idx_activities_started ON activities (started_at DESC);

      CREATE TABLE settings (
        key   TEXT PRIMARY KEY NOT NULL,
        value TEXT NOT NULL
      );
    `);
  }

  db.exec(`PRAGMA user_version = ${SCHEMA_VERSION}`);
}

/**
 * The API token, made on first start and kept in the database.
 *
 * To revoke it, delete the row and restart. A new one is printed once.
 */
export function ensureToken(db: DatabaseSync): { token: string; created: boolean } {
  const existing = db
    .prepare('SELECT value FROM settings WHERE key = ?')
    .get('api_token') as { value?: string } | undefined;

  if (existing?.value !== undefined) return { token: existing.value, created: false };

  const token = randomBytes(32).toString('base64url');
  db.prepare('INSERT INTO settings (key, value) VALUES (?, ?)').run('api_token', token);
  return { token, created: true };
}

/**
 * Stores a processed activity.
 *
 * `INSERT OR REPLACE` and not `INSERT`: reprocessing an activity has to
 * overwrite the old numbers. Uploading is kept idempotent one level up, where
 * a second upload of the same id is answered without touching the raw file.
 */
export function saveActivity(db: DatabaseSync, row: ActivityRow): void {
  db.prepare(
    `INSERT OR REPLACE INTO activities (
       id, started_at, ended_at, received_at, pipeline_version,
       distance_m, elapsed_s, moving_s, ascent_m, descent_m, pace_s_per_km,
       point_count, used_point_count, paused_s, dropped_s,
       polyline, splits, device, os_version, app_version, source
     ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`,
  ).run(
    row.activityId,
    row.startedAt,
    row.endedAt,
    row.receivedAt,
    row.pipelineVersion,
    row.distanceM,
    row.elapsedS,
    row.movingS,
    row.ascentM,
    row.descentM,
    row.paceSPerKm,
    row.pointCount,
    row.usedPointCount,
    row.pausedS,
    row.droppedS,
    row.polyline,
    JSON.stringify(row.splits),
    row.device,
    row.osVersion,
    row.appVersion,
    row.source,
  );
}

export function activityExists(db: DatabaseSync, id: string): boolean {
  return db.prepare('SELECT 1 FROM activities WHERE id = ?').get(id) !== undefined;
}

/**
 * The activity list. Reads indexed columns only and never opens a raw file,
 * which is what keeps this inside its time budget as the archive grows.
 */
export function listActivities(
  db: DatabaseSync,
  limit = 100,
  offset = 0,
): ActivityListItem[] {
  const rows = db
    .prepare(
      `SELECT id, started_at, distance_m, moving_s, pace_s_per_km, ascent_m, polyline
         FROM activities
        ORDER BY started_at DESC
        LIMIT ? OFFSET ?`,
    )
    .all(limit, offset) as Record<string, string | number>[];

  return rows.map((r) => ({
    id: String(r['id']),
    startedAt: Number(r['started_at']),
    distanceM: Number(r['distance_m']),
    movingS: Number(r['moving_s']),
    paceSPerKm: Number(r['pace_s_per_km']),
    ascentM: Number(r['ascent_m']),
    polyline: String(r['polyline']),
  }));
}

export function getActivity(
  db: DatabaseSync,
  id: string,
): Record<string, unknown> | null {
  const row = db.prepare('SELECT * FROM activities WHERE id = ?').get(id) as
    Record<string, string | number> | undefined;
  if (row === undefined) return null;
  return { ...row, splits: JSON.parse(String(row['splits'])) as unknown };
}

export function countActivities(db: DatabaseSync): number {
  const row = db.prepare('SELECT COUNT(*) AS n FROM activities').get() as { n: number };
  return Number(row.n);
}
