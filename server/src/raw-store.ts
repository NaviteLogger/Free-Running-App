import { createHash } from 'node:crypto';
import { mkdir, readFile, readdir, rename, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { gunzipSync, gzipSync } from 'node:zlib';

import type { RawActivity } from './pipeline/types.ts';

/**
 * The raw points, gzipped on disk, one file per activity.
 *
 * Written once and never changed. Every number the server publishes is rebuilt
 * from these files, so if one is edited the history of that run is gone. The
 * write path refuses to overwrite for that reason, and there is no update
 * method on purpose.
 *
 * Around 100 KB a run, so ten years of daily running is a few gigabytes. The
 * whole directory moves with one `rsync`.
 */
export class RawStore {
  readonly #dir: string;

  constructor(dir: string) {
    this.#dir = dir;
  }

  async init(): Promise<void> {
    await mkdir(this.#dir, { recursive: true });
  }

  path(id: string): string {
    return join(this.#dir, `${safeId(id)}.json.gz`);
  }

  async has(id: string): Promise<boolean> {
    try {
      await readFile(this.path(id));
      return true;
    } catch {
      return false;
    }
  }

  /**
   * Writes an activity, once.
   *
   * Throws if the id already has a file. Callers deal with a repeat upload by
   * checking first and answering with the activity that is already there,
   * which is what makes uploading safe to retry.
   *
   * The bytes go to a temporary name and are then renamed. A rename inside one
   * directory is atomic, so a crash mid-write leaves either the old state or
   * the new one, never half a file that later fails to parse.
   */
  async write(raw: RawActivity): Promise<{ bytes: number; sha256: string }> {
    if (await this.has(raw.id)) {
      throw new Error(`raw points for ${raw.id} already exist and are never rewritten`);
    }

    const json = JSON.stringify(raw);
    const packed = gzipSync(Buffer.from(json, 'utf8'), { level: 9 });
    const sha256 = createHash('sha256').update(packed).digest('hex');

    const target = this.path(raw.id);
    const temporary = `${target}.${process.pid}.tmp`;

    await mkdir(this.#dir, { recursive: true });
    await writeFile(temporary, packed, { flag: 'wx' });
    await rename(temporary, target);

    return { bytes: packed.byteLength, sha256 };
  }

  async read(id: string): Promise<RawActivity> {
    const packed = await readFile(this.path(id));
    return JSON.parse(gunzipSync(packed).toString('utf8')) as RawActivity;
  }

  /** Every stored id, for a full reprocess. */
  async ids(): Promise<string[]> {
    try {
      const names = await readdir(this.#dir);
      return names
        .filter((n) => n.endsWith('.json.gz'))
        .map((n) => n.slice(0, -'.json.gz'.length))
        .sort();
    } catch {
      return [];
    }
  }
}

/**
 * Ids come from a phone and end up in a file path, so they are checked rather
 * than trusted. A UUID is letters, digits and hyphens; anything else is
 * refused before it can walk out of the directory.
 */
function safeId(id: string): string {
  if (!/^[A-Za-z0-9_-]{1,128}$/.test(id)) {
    throw new Error(`unsafe activity id: ${JSON.stringify(id)}`);
  }
  return id;
}
