import { loadConfig } from './config.ts';
import { buildApp } from './server.ts';

const config = loadConfig();
const app = await buildApp(config);

if (app.tokenIsNew) {
  // Printed once, on the first start. It is not shown again, and it is not
  // logged on later starts, so it does not sit in a log file forever.
  console.log('');
  console.log('  A new API token was generated. Put it in the phone app:');
  console.log('');
  console.log(`    ${app.token}`);
  console.log('');
  console.log(
    "  To revoke it: DELETE FROM settings WHERE key = 'api_token'; then restart.",
  );
  console.log('');
}

app.server.listen(config.port, config.host, () => {
  console.log(`listening on http://${config.host}:${config.port}`);
  console.log(`data in ${config.dataDir}`);
});

/** Finish in-flight requests and close the database cleanly. */
for (const signal of ['SIGINT', 'SIGTERM'] as const) {
  process.on(signal, () => {
    console.log(`\n${signal}, shutting down`);
    app.server.close(() => {
      app.db.close();
      process.exit(0);
    });
    // WAL means a committed row is already on disk, so a hard exit after a
    // grace period costs nothing.
    setTimeout(() => process.exit(0), 5000).unref();
  });
}
