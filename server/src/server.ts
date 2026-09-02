import { createServer } from 'node:http';
import type { Server } from 'node:http';
import type { DatabaseSync } from 'node:sqlite';

import { ensureToken, openDatabase } from './db.ts';
import { bearerAuth } from './http/auth.ts';
import { rateLimit } from './http/rate-limit.ts';
import { createHandler } from './http/router.ts';
import { RawStore } from './raw-store.ts';
import { IMPORT_PATH, UPLOAD_PATH, buildRoutes } from './routes.ts';
import type { Config } from './config.ts';

export type App = {
  server: Server;
  db: DatabaseSync;
  store: RawStore;
  token: string;
  tokenIsNew: boolean;
};

export async function buildApp(config: Config): Promise<App> {
  const db = openDatabase(config.dbPath);
  const store = new RawStore(config.rawDir);
  await store.init();

  const { token, created } = ensureToken(db);

  const handler = createHandler(buildRoutes(db, store), [
    // Rate limiting runs before the token check, so a flood of bad tokens costs
    // no more than a flood of good ones.
    rateLimit({ capacity: 20, refillPerSecond: 0.2, paths: [UPLOAD_PATH, IMPORT_PATH] }),
    bearerAuth(token),
  ]);

  return {
    server: createServer(handler),
    db,
    store,
    token,
    tokenIsNew: created,
  };
}
