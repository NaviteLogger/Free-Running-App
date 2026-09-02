import 'package:flutter/foundation.dart';

import '../data/models.dart';
import '../data/session_repository.dart';
import '../data/settings_repository.dart';
import 'api_client.dart';

class SyncReport {
  const SyncReport({
    this.uploaded = 0,
    this.deferred = 0,
    this.rejected = 0,
    this.message,
  });

  final int uploaded;
  final int deferred;
  final int rejected;
  final String? message;

  bool get didAnything => uploaded > 0 || rejected > 0;
}

/// Sends finished runs to the server, and keeps the ones it cannot send.
///
/// A run is never deleted from the phone by this class. The phone is the copy
/// of record until the server has said it has the data, and a run that fails to
/// upload stays in the queue for the next attempt.
class SyncService extends ChangeNotifier {
  SyncService(
    this._sessions,
    this._settings, {
    ApiClient Function(String baseUrl, String token)? clientFactory,
  }) : _clientFactory =
           clientFactory ??
           ((baseUrl, token) => ApiClient(baseUrl: baseUrl, token: token));

  final SessionRepository _sessions;
  final SettingsRepository _settings;

  /// Injectable so the tests can drive the whole queue without a network.
  final ApiClient Function(String, String) _clientFactory;

  bool _running = false;
  String? _lastMessage;
  DateTime? _lastAttempt;

  bool get isRunning => _running;
  String? get lastMessage => _lastMessage;
  DateTime? get lastAttempt => _lastAttempt;

  Future<int> pendingCount() async => (await _sessions.pendingUpload()).length;

  /// Uploads everything waiting.
  ///
  /// Safe to call whenever: on app start, after finishing a run, on returning
  /// to the foreground. Overlapping calls collapse into one.
  Future<SyncReport> syncNow() async {
    if (_running) return const SyncReport(message: 'Already running');

    final baseUrl = await _settings.serverUrl();
    final token = await _settings.apiToken();
    if (baseUrl == null || token == null) {
      return _finish(const SyncReport(message: 'No server configured'));
    }

    final pending = await _sessions.pendingUpload();
    if (pending.isEmpty) {
      return _finish(const SyncReport(message: 'Nothing to upload'));
    }

    _running = true;
    _lastAttempt = DateTime.now();
    notifyListeners();

    final client = _clientFactory(baseUrl, token);
    var uploaded = 0;
    var deferred = 0;
    var rejected = 0;
    String? message;

    try {
      for (final session in pending) {
        final outcome = await client.upload(await _payload(session));

        switch (outcome) {
          case UploadAccepted():
            // Marked only after the server has confirmed it. If the process
            // dies before this line, the run is uploaded again next time and
            // the server answers "already have it".
            await _sessions.markUploaded(session.id, DateTime.now().toUtc());
            uploaded++;
          case UploadDeferred(:final reason):
            deferred++;
            message ??= reason;
            // Stop on the first temporary failure. If the network is down, the
            // rest will fail the same way, and trying twenty more times drains
            // the battery for nothing.
            return _finish(
              SyncReport(
                uploaded: uploaded,
                deferred: pending.length - uploaded,
                rejected: rejected,
                message: message,
              ),
            );
          case UploadRejected(:final reason):
            rejected++;
            message ??= reason;
        }
      }
    } finally {
      client.close();
    }

    return _finish(
      SyncReport(
        uploaded: uploaded,
        deferred: deferred,
        rejected: rejected,
        message: message ?? 'Uploaded $uploaded',
      ),
    );
  }

  SyncReport _finish(SyncReport report) {
    _running = false;
    _lastMessage = report.message;
    notifyListeners();
    return report;
  }

  /// Builds the upload body: the session, every fix, and every event.
  ///
  /// Sent exactly as recorded. No filtering, no smoothing, no distance. The
  /// server does all of that, which is what lets the processing be improved
  /// later and re-run over runs that were uploaded years ago.
  Future<Map<String, Object?>> _payload(Session session) async {
    final fixes = await _sessions.fixesFor(session.id);
    final events = await _sessions.eventsFor(session.id);

    return {
      'id': session.id,
      'startedAt': session.startedAt.millisecondsSinceEpoch,
      'endedAt': (session.endedAt ?? session.startedAt).millisecondsSinceEpoch,
      'device': session.device,
      'osVersion': session.osVersion,
      'appVersion': session.appVersion,
      'sampleIntervalMs': session.sampleIntervalMs,
      'accuracyProfile': session.accuracyProfile,
      'points': [
        for (final fix in fixes)
          {
            'seq': fix.seq,
            'ts': fix.ts.millisecondsSinceEpoch,
            'gpsTs': fix.gpsTs.millisecondsSinceEpoch,
            'lat': fix.lat,
            'lon': fix.lon,
            'accuracy': fix.accuracy,
            'altitude': fix.altitude,
            'altitudeAccuracy': fix.altitudeAccuracy,
            'speed': fix.speed,
            'speedAccuracy': fix.speedAccuracy,
            'heading': fix.heading,
            'isMocked': fix.isMocked,
            'battery': fix.battery,
          },
      ],
      'events': [
        for (final event in events)
          {
            'seq': event.seq,
            'ts': event.ts.millisecondsSinceEpoch,
            'kind': event.kind.name,
            'detail': event.detail,
          },
      ],
    };
  }
}
