import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// Bump this and add a branch to [_migrate] for any schema change. Never edit
/// [_createStatements] in place once a build has shipped — the migration is
/// what upgrades an existing database, and a phone in the field only ever runs
/// migrations.
const int schemaVersion = 2;

Future<Database> openTrackerDatabase({String? overridePath}) async {
  final path = overridePath ?? p.join(await getDatabasesPath(), 'tracker.db');
  return openDatabase(
    path,
    version: schemaVersion,
    onConfigure: _configure,
    onCreate: (db, _) async {
      for (final statement in _createStatements) {
        await db.execute(statement);
      }
    },
    onUpgrade: _migrate,
  );
}

Future<void> _configure(Database db) async {
  // WAL is what makes a kill survivable: a committed row is already in the -wal
  // file on disk, so losing the process does not lose the row.
  //
  // synchronous=NORMAL skips an fsync per commit, which is the documented
  // pairing for WAL. The tradeoff is precise: a *process* kill is still safe
  // (the data reached the OS), only an OS crash or power loss can lose recent
  // commits. Force-stopping from the task switcher is the former, which is
  // exactly the case the recorder has to survive.
  //
  // journal_mode returns a row, so it has to go through rawQuery rather than
  // execute.
  await db.rawQuery('PRAGMA journal_mode=WAL');
  await db.execute('PRAGMA synchronous=NORMAL');
  await db.execute('PRAGMA foreign_keys=ON');
}

/// Steps are applied in order, so a phone that skipped several releases still
/// lands in the right place.
Future<void> _migrate(Database db, int from, int to) async {
  if (from < 2) {
    await db.execute(_settingsTable);
  }
  if (to > schemaVersion) {
    throw UnsupportedError(
      'Database is version $to, this build only knows $schemaVersion',
    );
  }
}

/// Server address and API token. Kept in the same database as everything else
/// so there is one file to back up and one file to delete.
const String _settingsTable = '''
  CREATE TABLE settings (
    key   TEXT PRIMARY KEY NOT NULL,
    value TEXT NOT NULL
  )
''';

const List<String> _createStatements = [
  // The session id is generated on the phone, not the server. That is what
  // makes the Phase 2 upload idempotent: the same id uploaded twice is one
  // activity, so a retry after a flaky connection is free.
  //
  // The provenance columns exist because the server reprocesses raw points
  // forever, and it cannot reconstruct the conditions they were captured
  // under. When the elevation smoothing is retuned in a year, knowing that a
  // given run was recorded at 1 Hz on a device that freezes background work is
  // the difference between explaining an anomaly and guessing at it.
  '''
  CREATE TABLE sessions (
    id                 TEXT    PRIMARY KEY NOT NULL,
    state              TEXT    NOT NULL CHECK (state IN ('recording','paused','finished')),
    started_at         INTEGER NOT NULL,
    ended_at           INTEGER,
    uploaded_at        INTEGER,
    device             TEXT    NOT NULL,
    os_version         TEXT    NOT NULL,
    app_version        TEXT    NOT NULL,
    sample_interval_ms INTEGER NOT NULL,
    accuracy_profile   TEXT    NOT NULL
  )
  ''',

  // The activity list orders by start time descending.
  'CREATE INDEX idx_sessions_started ON sessions (started_at DESC)',

  // Partial index for the Phase 2 upload queue: finished but not yet uploaded.
  // Partial because that set is tiny and usually empty, and there is no reason
  // to index the thousands of rows that are already sent.
  '''
  CREATE INDEX idx_sessions_pending ON sessions (started_at)
    WHERE state = 'finished' AND uploaded_at IS NULL
  ''',

  // Every fix the platform hands us is stored, including the wildly inaccurate
  // ones. Filtering on write would violate two of the project's criteria at
  // once: raw points are immutable, and every derived number must rebuild from
  // raw points alone. An accuracy gate applied here would be baked in forever;
  // applied during processing it can be retuned and the whole archive
  // reprocessed.
  //
  // The primary key is (session_id, seq) rather than a timestamp because two
  // fixes can share a millisecond. seq is a per-session counter, so it is both
  // unique and a guaranteed arrival order.
  //
  // WITHOUT ROWID: the primary key *is* the access path for every query we run,
  // so storing rows directly in that b-tree avoids a second index and a level
  // of indirection. Rows here are small and fixed-width, which is the case
  // WITHOUT ROWID is designed for.
  '''
  CREATE TABLE fixes (
    session_id        TEXT    NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    seq               INTEGER NOT NULL,
    ts                INTEGER NOT NULL,
    gps_ts            INTEGER NOT NULL,
    lat               REAL    NOT NULL,
    lon               REAL    NOT NULL,
    accuracy          REAL,
    altitude          REAL,
    altitude_accuracy REAL,
    speed             REAL,
    speed_accuracy    REAL,
    heading           REAL,
    is_mocked         INTEGER NOT NULL DEFAULT 0,
    battery           INTEGER,
    PRIMARY KEY (session_id, seq)
  ) WITHOUT ROWID
  ''',

  // This table is the answer to "how do you tell a pause from a freeze?".
  //
  // Both leave a hole in the fix timestamps and are otherwise identical. A hole
  // spanned by a `pause`/`resume` pair was deliberate and must be excluded from
  // moving time. A hole with no event was the OS suspending us, and is data
  // loss to be reported rather than silently smoothed over. Without this table
  // that distinction is unrecoverable, and the server computing moving time a
  // year from now has no way to guess.
  '''
  CREATE TABLE session_events (
    session_id TEXT    NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    seq        INTEGER NOT NULL,
    ts         INTEGER NOT NULL,
    kind       TEXT    NOT NULL,
    detail     TEXT,
    PRIMARY KEY (session_id, seq)
  ) WITHOUT ROWID
  ''',

  _settingsTable,
];
