import 'package:sqflite/sqflite.dart';

import 'models.dart';

/// All database access lives here so the recording loop never touches SQL and
/// the invariants below hold in one place.
class SessionRepository {
  SessionRepository(this._db);

  final Database _db;

  Future<void> insertSession(Session session) =>
      _db.insert('sessions', session.toRow());

  /// One INSERT, no transaction, no batching.
  ///
  /// Batching fixes into a transaction would be faster and would also mean an
  /// unexpected kill loses everything since the last commit. The whole point of
  /// this design is that a kill costs at most the fix in flight, so the write
  /// stays one row at a time.
  Future<void> insertFix(Fix fix) => _db.insert('fixes', fix.toRow());

  Future<void> insertEvent(SessionEvent event) =>
      _db.insert('session_events', event.toRow());

  Future<Session?> findById(String id) async {
    final rows = await _db.query('sessions', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : Session.fromRow(rows.first);
  }

  /// A session left in `recording` or `paused` means the app died mid-run —
  /// either the OS killed it or it crashed. Checked on every launch; this is
  /// what turns a lost run into a recoverable one.
  Future<Session?> findInterrupted() async {
    final rows = await _db.query(
      'sessions',
      where: 'state IN (?, ?)',
      whereArgs: [SessionState.recording.name, SessionState.paused.name],
      orderBy: 'started_at DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : Session.fromRow(rows.first);
  }

  Future<List<Session>> recentSessions({int limit = 100}) async {
    final rows = await _db.query(
      'sessions',
      orderBy: 'started_at DESC',
      limit: limit,
    );
    return rows.map(Session.fromRow).toList();
  }

  /// Phase 2's upload queue. Backed by the partial index.
  Future<List<Session>> pendingUpload() async {
    final rows = await _db.query(
      'sessions',
      where: 'state = ? AND uploaded_at IS NULL',
      whereArgs: [SessionState.finished.name],
      orderBy: 'started_at',
    );
    return rows.map(Session.fromRow).toList();
  }

  Future<void> setState(String sessionId, SessionState state) => _db.update(
    'sessions',
    {'state': state.name},
    where: 'id = ?',
    whereArgs: [sessionId],
  );

  Future<void> finish(String sessionId, DateTime endedAt) => _db.update(
    'sessions',
    {
      'state': SessionState.finished.name,
      'ended_at': endedAt.millisecondsSinceEpoch,
    },
    where: 'id = ?',
    whereArgs: [sessionId],
  );

  Future<void> markUploaded(String sessionId, DateTime at) => _db.update(
    'sessions',
    {'uploaded_at': at.millisecondsSinceEpoch},
    where: 'id = ?',
    whereArgs: [sessionId],
  );

  /// Next sequence number for a session's fixes.
  ///
  /// Read from the database rather than kept in memory, so resuming an
  /// interrupted session continues the numbering instead of colliding with rows
  /// that are already there.
  Future<int> nextFixSeq(String sessionId) async {
    final rows = await _db.rawQuery(
      'SELECT COALESCE(MAX(seq), -1) + 1 AS next FROM fixes WHERE session_id = ?',
      [sessionId],
    );
    return rows.first['next']! as int;
  }

  Future<int> nextEventSeq(String sessionId) async {
    final rows = await _db.rawQuery(
      'SELECT COALESCE(MAX(seq), -1) + 1 AS next FROM session_events WHERE session_id = ?',
      [sessionId],
    );
    return rows.first['next']! as int;
  }

  Future<int> fixCount(String sessionId) async {
    final rows = await _db.rawQuery(
      'SELECT COUNT(*) AS n FROM fixes WHERE session_id = ?',
      [sessionId],
    );
    return rows.first['n']! as int;
  }

  Future<Fix?> lastFix(String sessionId) async {
    final rows = await _db.query(
      'fixes',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'seq DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : Fix.fromRow(rows.first);
  }

  Future<List<Fix>> fixesFor(String sessionId) async {
    final rows = await _db.query(
      'fixes',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'seq',
    );
    return rows.map(Fix.fromRow).toList();
  }

  Future<List<SessionEvent>> eventsFor(String sessionId) async {
    final rows = await _db.query(
      'session_events',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'seq',
    );
    return rows.map(SessionEvent.fromRow).toList();
  }

  Future<void> deleteSession(String sessionId) =>
      _db.delete('sessions', where: 'id = ?', whereArgs: [sessionId]);
}
