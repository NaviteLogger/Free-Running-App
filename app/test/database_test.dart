import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tracker/data/database.dart';
import 'package:tracker/data/models.dart';
import 'package:tracker/data/session_repository.dart';
import 'package:tracker/recording/geo.dart';

/// These run against real SQLite on the host, so the schema, the pragmas and
/// the repository queries are exercised for real rather than mocked.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late SessionRepository repo;

  setUp(() async {
    db = await openTrackerDatabase(overridePath: inMemoryDatabasePath);
    repo = SessionRepository(db);
  });

  tearDown(() async => db.close());

  Session makeSession({
    String id = 'session-1',
    SessionState state = SessionState.recording,
    DateTime? startedAt,
  }) => Session(
    id: id,
    state: state,
    startedAt: startedAt ?? DateTime.utc(2026, 9, 1, 8),
    device: 'OnePlus CPH2581 (test)',
    osVersion: 'Android 16',
    appVersion: '1.0.0+1',
    sampleIntervalMs: 1000,
    accuracyProfile: 'best',
  );

  Fix makeFix(
    int seq, {
    double lat = 52.2,
    double lon = 21.0,
    double? accuracy,
  }) => Fix(
    sessionId: 'session-1',
    seq: seq,
    ts: DateTime.utc(2026, 9, 1, 8).add(Duration(seconds: seq)),
    gpsTs: DateTime.utc(2026, 9, 1, 8).add(Duration(seconds: seq)),
    lat: lat,
    lon: lon,
    accuracy: accuracy,
    battery: 90,
  );

  group('schema', () {
    test('WAL is active on a file-backed database', () async {
      // The in-memory database used by the other tests cannot do WAL, so this
      // one uses a real file. WAL is what makes a committed row survive the
      // process being killed, so it is worth checking rather than assuming.
      final dir = Directory.systemTemp.createTempSync('tracker_wal');
      final fileDb = await openTrackerDatabase(
        overridePath: '${dir.path}/tracker.db',
      );
      final mode = (await fileDb.rawQuery('PRAGMA journal_mode'))
          .first
          .values
          .first;
      expect(mode, 'wal');
      await fileDb.close();
      dir.deleteSync(recursive: true);
    });

    test('synchronous is NORMAL', () async {
      final rows = await db.rawQuery('PRAGMA synchronous');
      // 1 == NORMAL. Paired with WAL this survives a process kill, which is
      // the case the recorder has to withstand.
      expect(rows.first.values.first, 1);
    });

    test(
      'foreign keys cascade so deleting a session takes its fixes',
      () async {
        await repo.insertSession(makeSession());
        await repo.insertFix(makeFix(0));
        await repo.insertEvent(
          SessionEvent(
            sessionId: 'session-1',
            seq: 0,
            ts: DateTime.utc(2026, 9, 1, 8),
            kind: EventKind.start,
          ),
        );

        await repo.deleteSession('session-1');

        expect(await repo.fixCount('session-1'), 0);
        expect(await repo.eventsFor('session-1'), isEmpty);
      },
    );

    test('state column rejects a value outside the three allowed', () async {
      await expectLater(
        db.insert('sessions', {
          ...makeSession().toRow(),
          'id': 'bad',
          'state': 'jogging',
        }),
        throwsA(isA<DatabaseException>()),
      );
    });

    test('a session id cannot be inserted twice', () async {
      await repo.insertSession(makeSession());
      await expectLater(
        repo.insertSession(makeSession()),
        throwsA(isA<DatabaseException>()),
      );
    });

    test('two fixes may share a timestamp but not a seq', () async {
      await repo.insertSession(makeSession());
      final a = makeFix(0);
      await repo.insertFix(a);
      // Same instant, different seq: allowed, and ordering is preserved.
      await repo.insertFix(
        Fix(
          sessionId: a.sessionId,
          seq: 1,
          ts: a.ts,
          gpsTs: a.gpsTs,
          lat: a.lat,
          lon: a.lon,
        ),
      );
      expect(await repo.fixCount('session-1'), 2);

      await expectLater(
        repo.insertFix(makeFix(1)),
        throwsA(isA<DatabaseException>()),
      );
    });
  });

  group('round trip', () {
    test('a fix survives storage unchanged', () async {
      await repo.insertSession(makeSession());
      final written = Fix(
        sessionId: 'session-1',
        seq: 0,
        ts: DateTime.utc(2026, 9, 1, 8, 30, 15, 250),
        gpsTs: DateTime.utc(2026, 9, 1, 8, 30, 15),
        lat: 52.2296756,
        lon: 21.0122287,
        accuracy: 4.5,
        altitude: 113.2,
        altitudeAccuracy: 2.0,
        speed: 3.1,
        speedAccuracy: 0.4,
        heading: 271.5,
        isMocked: true,
        battery: 87,
      );
      await repo.insertFix(written);

      final read = (await repo.fixesFor('session-1')).single;
      expect(read.lat, written.lat);
      expect(read.lon, written.lon);
      expect(read.ts, written.ts);
      expect(read.gpsTs, written.gpsTs);
      expect(read.accuracy, written.accuracy);
      expect(read.isMocked, isTrue);
      expect(read.battery, 87);
      // Timestamps must come back as UTC; a run at 23:40 landing in the wrong
      // day is the bug this guards.
      expect(read.ts.isUtc, isTrue);
    });

    test('event detail survives as JSON', () async {
      await repo.insertSession(makeSession());
      await repo.insertEvent(
        SessionEvent(
          sessionId: 'session-1',
          seq: 0,
          ts: DateTime.utc(2026, 9, 1, 8),
          kind: EventKind.grants,
          detail: const {'batteryExempt': false, 'count': 3},
        ),
      );
      final read = (await repo.eventsFor('session-1')).single;
      expect(read.kind, EventKind.grants);
      expect(read.detail?['batteryExempt'], false);
      expect(read.detail?['count'], 3);
    });
  });

  group('interruption recovery', () {
    test('finds a session left recording', () async {
      await repo.insertSession(makeSession(state: SessionState.finished));
      await repo.insertSession(
        makeSession(id: 'session-2', state: SessionState.recording),
      );
      expect((await repo.findInterrupted())?.id, 'session-2');
    });

    test('finds nothing when everything is finished', () async {
      await repo.insertSession(makeSession(state: SessionState.finished));
      expect(await repo.findInterrupted(), isNull);
    });

    test('seq continues from stored rows rather than restarting', () async {
      await repo.insertSession(makeSession());
      for (var i = 0; i < 5; i++) {
        await repo.insertFix(makeFix(i));
      }
      // This is what stops a resumed session colliding with its own history.
      expect(await repo.nextFixSeq('session-1'), 5);
      expect(await repo.nextFixSeq('unknown-session'), 0);
    });
  });

  group('upload queue', () {
    test('lists only finished sessions that were never uploaded', () async {
      await repo.insertSession(makeSession(state: SessionState.recording));
      await repo.insertSession(
        makeSession(id: 'done', state: SessionState.finished),
      );
      await repo.insertSession(
        makeSession(id: 'sent', state: SessionState.finished),
      );
      await repo.markUploaded('sent', DateTime.utc(2026, 9, 1, 9));

      final pending = await repo.pendingUpload();
      expect(pending.map((s) => s.id), ['done']);
    });
  });

  group('distance', () {
    test('a known separation measures correctly', () {
      // Two points one degree of latitude apart is ~111.2 km.
      final metres = haversineMetres(52.0, 21.0, 53.0, 21.0);
      expect(metres, closeTo(111195, 200));
    });

    test('standing still accumulates nothing', () {
      final acc = DistanceAccumulator();
      for (var i = 0; i < 600; i++) {
        // Jitter of roughly a metre, which is what a stationary phone reports.
        acc.add(makeFix(i, lat: 52.2 + (i.isEven ? 0.000009 : 0), accuracy: 5));
      }
      expect(acc.metres, 0);
    });

    test('inaccurate fixes are excluded from the readout', () {
      final acc = DistanceAccumulator();
      acc.add(makeFix(0, lat: 52.2000, accuracy: 5));
      // A 90 m fix that teleports a block away must not add distance.
      acc.add(makeFix(1, lat: 52.2100, accuracy: 90));
      expect(acc.metres, 0);
    });

    test('real movement accumulates', () {
      final acc = DistanceAccumulator();
      acc.add(makeFix(0, lat: 52.2000, accuracy: 5));
      acc.add(makeFix(1, lat: 52.2010, accuracy: 5));
      expect(acc.metres, closeTo(111, 3));
    });

    test('a pause does not draw a line across the gap', () {
      final acc = DistanceAccumulator();
      acc.add(makeFix(0, lat: 52.2000, accuracy: 5));
      acc.breakSegment();
      acc.add(makeFix(1, lat: 52.3000, accuracy: 5));
      expect(acc.metres, 0);
    });

    test('replay of stored fixes reproduces the total', () {
      final fixes = [
        makeFix(0, lat: 52.2000, accuracy: 5),
        makeFix(1, lat: 52.2010, accuracy: 5),
        makeFix(2, lat: 52.2020, accuracy: 5),
      ];
      final live = DistanceAccumulator();
      for (final f in fixes) {
        live.add(f);
      }
      final replayed = DistanceAccumulator()..replay(fixes);
      expect(replayed.metres, live.metres);
    });
  });
}
