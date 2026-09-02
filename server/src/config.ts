import { resolve } from 'node:path';

export type Config = {
  port: number;
  host: string;
  dataDir: string;
  dbPath: string;
  rawDir: string;
};

/**
 * Everything the server needs to start, read from the environment once.
 *
 * The API token is deliberately absent. It lives in the database so it can be
 * changed by editing a row, with no redeploy and no environment file to leak.
 */
export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const dataDir = resolve(env['DATA_DIR'] ?? './data');
  const port = Number(env['PORT'] ?? 8080);

  // 0 is allowed and means "any free port", which is how the operating system
  // is asked for one. Tests rely on it, and so does anything run under a
  // supervisor that hands out ports.
  if (!Number.isInteger(port) || port < 0 || port > 65535) {
    throw new Error(`PORT must be between 0 and 65535, got ${env['PORT']}`);
  }

  return {
    port,
    // Loopback by default. Caddy sits in front and terminates TLS, so the
    // process itself should not be reachable from outside the machine unless
    // somebody says so on purpose.
    host: env['HOST'] ?? '127.0.0.1',
    dataDir,
    dbPath: resolve(dataDir, 'tracker.db'),
    rawDir: resolve(dataDir, 'raw'),
  };
}
