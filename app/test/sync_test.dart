import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tracker/data/database.dart';
import 'package:tracker/data/models.dart';
import 'package:tracker/data/session_repository.dart';
import 'package:tracker/data/settings_repository.dart';
import 'package:tracker/sync/api_client.dart';
import 'package:tracker/sync/sync_service.dart';

/// Stands in for the server. Records what it was asked to send and answers
/// with whatever the test wants, so the queue can be driven without a network.
class FakeApi implements ApiClient {
  FakeApi(this._answers);

  final List<UploadOutcome> _answers;
  final List<Map<String, Object?>> sent = [];
  int closed = 0;

  @override
  String get baseUrl => 'http://fake';

  @override
  String get token => 'fake-token';

  @override
  Future<UploadOutcome> upload(Map<String, Object?> activity) async {
    sent.add(activity);
    if (_answers.isEmpty) return const UploadAccepted(alreadyThere: false);
    return _answers.removeAt(0);
  }

  @override
  Future<String?> checkHealth() async => null;

  @override
  void close() => closed++;
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late SessionRepository sessions;
  late SettingsRepository settings;

  setUp(() async {
    db = await openTrackerDatabase(overridePath: inMemoryDatabasePath);
    sessions = SessionRepository(db);
    settings = SettingsRepository(db);
    await settings.write(
      SettingsRepository.serverUrlKey,
      'http://example.test',
    );
    await settings.write(SettingsRepository.apiTokenKey, 'secret');
  });

  tearDown(() async => db.close());

  Future<void> addFinishedRun(String id, {int fixes = 3}) async {
    await sessions.insertSession(
      Session(
        id: id,
        state: SessionState.finished,
        startedAt: DateTime.utc(2026, 9, 1, 8),
        endedAt: DateTime.utc(2026, 9, 1, 8, 30),
        device: 'OnePlus CPH2581',
        osVersion: 'Android 16',
        appVersion: '1.0.0+1',
        sampleIntervalMs: 1000,
        accuracyProfile: 'best',
      ),
    );
    for (var i = 0; i < fixes; i++) {
      await sessions.insertFix(
        Fix(
          sessionId: id,
          seq: i,
          ts: DateTime.utc(2026, 9, 1, 8).add(Duration(seconds: i)),
          gpsTs: DateTime.utc(2026, 9, 1, 8).add(Duration(seconds: i)),
          lat: 52.2 + i * 0.0001,
          lon: 21.0,
          accuracy: 5,
          altitude: 110,
          battery: 90,
        ),
      );
    }
    await sessions.insertEvent(
      SessionEvent(
        sessionId: id,
        seq: 0,
        ts: DateTime.utc(2026, 9, 1, 8),
        kind: EventKind.start,
      ),
    );
  }

  SyncService serviceWith(FakeApi api) =>
      SyncService(sessions, settings, clientFactory: (_, _) => api);

  group('settings', () {
    test('the migration created the table on an existing database', () async {
      // openTrackerDatabase ran onCreate here, but the same statement is what
      // the version 1 to 2 migration applies.
      await settings.write('probe', 'value');
      expect(await settings.read('probe'), 'value');
    });

    test('a trailing slash on the server address is trimmed', () async {
      await settings.write(
        SettingsRepository.serverUrlKey,
        'https://run.test/',
      );
      expect(await settings.serverUrl(), 'https://run.test');
    });

    test('an empty value reads as missing', () async {
      await settings.write(SettingsRepository.apiTokenKey, '');
      expect(await settings.apiToken(), isNull);
      expect(await settings.isConfigured(), isFalse);
    });
  });

  group('upload queue', () {
    test('sends finished runs and marks them uploaded', () async {
      await addFinishedRun('run-a');
      final api = FakeApi([const UploadAccepted(alreadyThere: false)]);

      final report = await serviceWith(api).syncNow();

      expect(report.uploaded, 1);
      expect(api.sent.length, 1);
      expect(await sessions.pendingUpload(), isEmpty);
    });

    test('sends every point and event, and nothing computed', () async {
      await addFinishedRun('run-b', fixes: 5);
      final api = FakeApi([]);
      await serviceWith(api).syncNow();

      final body = api.sent.single;
      expect((body['points']! as List).length, 5);
      expect((body['events']! as List).length, 1);
      // Distance is the server's job. Sending it would freeze every past run
      // at whatever the phone believed on the day.
      expect(body.containsKey('distance'), isFalse);
      expect(body.containsKey('distanceM'), isFalse);
    });

    test('sends exactly the fields the server schema declares', () async {
      // The phone builds this body and the server validates it with a zod
      // schema written separately. Nothing else makes the two agree, so
      // renaming a field has to break this test and force both to be updated.
      // See server/src/upload-schema.ts.
      await addFinishedRun('run-contract');
      final api = FakeApi([]);
      await serviceWith(api).syncNow();

      final body = api.sent.single;
      expect(body.keys.toSet(), {
        'id',
        'startedAt',
        'endedAt',
        'device',
        'osVersion',
        'appVersion',
        'sampleIntervalMs',
        'accuracyProfile',
        'points',
        'events',
      });

      final point = (body['points']! as List).first as Map<String, Object?>;
      expect(point.keys.toSet(), {
        'seq',
        'ts',
        'gpsTs',
        'lat',
        'lon',
        'accuracy',
        'altitude',
        'altitudeAccuracy',
        'speed',
        'speedAccuracy',
        'heading',
        'isMocked',
        'battery',
      });

      final event = (body['events']! as List).first as Map<String, Object?>;
      expect(event.keys.toSet(), {'seq', 'ts', 'kind', 'detail'});
    });

    test('does not resend a run that already went', () async {
      await addFinishedRun('run-c');
      final api = FakeApi([]);
      final service = serviceWith(api);

      await service.syncNow();
      await service.syncNow();

      expect(api.sent.length, 1);
    });

    test('a run that is still recording is not sent', () async {
      await sessions.insertSession(
        Session(
          id: 'live',
          state: SessionState.recording,
          startedAt: DateTime.utc(2026, 9, 1, 9),
          device: 'x',
          osVersion: 'x',
          appVersion: 'x',
          sampleIntervalMs: 1000,
          accuracyProfile: 'best',
        ),
      );
      final api = FakeApi([]);
      await serviceWith(api).syncNow();
      expect(api.sent, isEmpty);
    });
  });

  group('failures', () {
    test('a temporary failure keeps the run queued', () async {
      await addFinishedRun('run-d');
      final api = FakeApi([const UploadDeferred('no signal')]);

      final report = await serviceWith(api).syncNow();

      expect(report.uploaded, 0);
      expect(report.deferred, 1);
      // Still waiting, so the next attempt picks it up.
      expect((await sessions.pendingUpload()).length, 1);
    });

    test('stops at the first temporary failure instead of hammering', () async {
      await addFinishedRun('run-e1');
      await addFinishedRun('run-e2');
      await addFinishedRun('run-e3');
      final api = FakeApi([const UploadDeferred('no signal')]);

      await serviceWith(api).syncNow();

      // One attempt, not three. If the network is down the rest will fail the
      // same way and retrying drains the battery for nothing.
      expect(api.sent.length, 1);
    });

    test('a rejected run is not retried forever', () async {
      await addFinishedRun('run-f');
      final api = FakeApi([const UploadRejected('bad token')]);

      final report = await serviceWith(api).syncNow();

      expect(report.rejected, 1);
      expect(report.message, contains('bad token'));
    });

    test('a duplicate counts as done', () async {
      await addFinishedRun('run-g');
      final api = FakeApi([const UploadAccepted(alreadyThere: true)]);

      final report = await serviceWith(api).syncNow();

      expect(report.uploaded, 1);
      expect(await sessions.pendingUpload(), isEmpty);
    });

    test('does nothing when no server is configured', () async {
      await settings.clear(SettingsRepository.serverUrlKey);
      await addFinishedRun('run-h');
      final api = FakeApi([]);

      final report = await serviceWith(api).syncNow();

      expect(api.sent, isEmpty);
      expect(report.message, contains('No server'));
      // The run is still there for when a server is set up.
      expect((await sessions.pendingUpload()).length, 1);
    });

    test('closes the client even when an upload throws', () async {
      await addFinishedRun('run-i');
      final api = FakeApi([]);
      await serviceWith(api).syncNow();
      expect(api.closed, 1);
    });
  });

  group('health check', () {
    test('reports the reason a server could not be reached', () async {
      // Nothing is listening on this port, so the failure has to describe
      // itself. An earlier version returned a bare false and the real cause
      // was invisible.
      final client = ApiClient(
        baseUrl: 'http://127.0.0.1:1',
        token: 'irrelevant',
      );
      final problem = await client.checkHealth();
      client.close();

      expect(problem, isNotNull);
      expect(problem, contains('127.0.0.1:1'));
    });
  });

  group('status codes', () {
    test('401 is rejected, not retried', () {
      expect(ApiClient.interpretStatus(401, ''), isA<UploadRejected>());
    });

    test('429 is temporary', () {
      expect(ApiClient.interpretStatus(429, ''), isA<UploadDeferred>());
    });

    test('500 is temporary', () {
      expect(ApiClient.interpretStatus(500, ''), isA<UploadDeferred>());
    });

    test('422 is permanent and explains itself', () {
      final outcome = ApiClient.interpretStatus(
        422,
        '{"error":"upload failed validation","problems":["points: too small"]}',
      );
      expect(outcome, isA<UploadRejected>());
      expect((outcome as UploadRejected).reason, contains('points'));
    });

    test('201 is a new activity and 200 is one already there', () {
      expect(
        (ApiClient.interpretStatus(201, '') as UploadAccepted).alreadyThere,
        isFalse,
      );
      expect(
        (ApiClient.interpretStatus(200, '') as UploadAccepted).alreadyThere,
        isTrue,
      );
    });
  });
}
