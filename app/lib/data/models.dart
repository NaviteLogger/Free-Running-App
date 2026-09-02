import 'dart:convert';

enum SessionState {
  recording,
  paused,
  finished;

  static SessionState parse(String raw) =>
      SessionState.values.firstWhere((s) => s.name == raw);
}

/// Kinds of thing that happen to a session other than a position arriving.
///
/// [pause] and [resume] are user intent. Everything else is something that
/// happened *to* us, and is recorded so a hole in the fix stream can be
/// attributed rather than guessed at.
enum EventKind {
  start,
  pause,
  resume,
  finish,
  salvage,
  lifecycle,
  grants,
  error,
  watchdog,
}

class Session {
  const Session({
    required this.id,
    required this.state,
    required this.startedAt,
    required this.device,
    required this.osVersion,
    required this.appVersion,
    required this.sampleIntervalMs,
    required this.accuracyProfile,
    this.endedAt,
    this.uploadedAt,
  });

  final String id;
  final SessionState state;
  final DateTime startedAt;
  final DateTime? endedAt;
  final DateTime? uploadedAt;

  // Provenance. See the schema comment on the sessions table.
  final String device;
  final String osVersion;
  final String appVersion;
  final int sampleIntervalMs;
  final String accuracyProfile;

  Session copyWith({
    SessionState? state,
    DateTime? endedAt,
    DateTime? uploadedAt,
  }) => Session(
    id: id,
    state: state ?? this.state,
    startedAt: startedAt,
    endedAt: endedAt ?? this.endedAt,
    uploadedAt: uploadedAt ?? this.uploadedAt,
    device: device,
    osVersion: osVersion,
    appVersion: appVersion,
    sampleIntervalMs: sampleIntervalMs,
    accuracyProfile: accuracyProfile,
  );

  factory Session.fromRow(Map<String, Object?> row) => Session(
    id: row['id']! as String,
    state: SessionState.parse(row['state']! as String),
    startedAt: _time(row['started_at'])!,
    endedAt: _time(row['ended_at']),
    uploadedAt: _time(row['uploaded_at']),
    device: row['device']! as String,
    osVersion: row['os_version']! as String,
    appVersion: row['app_version']! as String,
    sampleIntervalMs: row['sample_interval_ms']! as int,
    accuracyProfile: row['accuracy_profile']! as String,
  );

  Map<String, Object?> toRow() => {
    'id': id,
    'state': state.name,
    'started_at': startedAt.millisecondsSinceEpoch,
    'ended_at': endedAt?.millisecondsSinceEpoch,
    'uploaded_at': uploadedAt?.millisecondsSinceEpoch,
    'device': device,
    'os_version': osVersion,
    'app_version': appVersion,
    'sample_interval_ms': sampleIntervalMs,
    'accuracy_profile': accuracyProfile,
  };
}

class Fix {
  const Fix({
    required this.sessionId,
    required this.seq,
    required this.ts,
    required this.gpsTs,
    required this.lat,
    required this.lon,
    this.accuracy,
    this.altitude,
    this.altitudeAccuracy,
    this.speed,
    this.speedAccuracy,
    this.heading,
    this.isMocked = false,
    this.battery,
  });

  final String sessionId;
  final int seq;

  /// When the fix reached us.
  final DateTime ts;

  /// When the fix was taken, according to the platform.
  ///
  /// Both are stored because they answer different questions. If the process is
  /// frozen and later thaws, arrivals cluster while GPS times stay evenly
  /// spaced — which distinguishes "delivered late" from "never sampled".
  final DateTime gpsTs;

  final double lat;
  final double lon;
  final double? accuracy;
  final double? altitude;
  final double? altitudeAccuracy;
  final double? speed;
  final double? speedAccuracy;
  final double? heading;
  final bool isMocked;
  final int? battery;

  factory Fix.fromRow(Map<String, Object?> row) => Fix(
    sessionId: row['session_id']! as String,
    seq: row['seq']! as int,
    ts: _time(row['ts'])!,
    gpsTs: _time(row['gps_ts'])!,
    lat: row['lat']! as double,
    lon: row['lon']! as double,
    accuracy: row['accuracy'] as double?,
    altitude: row['altitude'] as double?,
    altitudeAccuracy: row['altitude_accuracy'] as double?,
    speed: row['speed'] as double?,
    speedAccuracy: row['speed_accuracy'] as double?,
    heading: row['heading'] as double?,
    isMocked: (row['is_mocked'] as int? ?? 0) != 0,
    battery: row['battery'] as int?,
  );

  Map<String, Object?> toRow() => {
    'session_id': sessionId,
    'seq': seq,
    'ts': ts.millisecondsSinceEpoch,
    'gps_ts': gpsTs.millisecondsSinceEpoch,
    'lat': lat,
    'lon': lon,
    'accuracy': accuracy,
    'altitude': altitude,
    'altitude_accuracy': altitudeAccuracy,
    'speed': speed,
    'speed_accuracy': speedAccuracy,
    'heading': heading,
    'is_mocked': isMocked ? 1 : 0,
    'battery': battery,
  };
}

class SessionEvent {
  const SessionEvent({
    required this.sessionId,
    required this.seq,
    required this.ts,
    required this.kind,
    this.detail,
  });

  final String sessionId;
  final int seq;
  final DateTime ts;
  final EventKind kind;
  final Map<String, Object?>? detail;

  factory SessionEvent.fromRow(Map<String, Object?> row) {
    final raw = row['detail'] as String?;
    return SessionEvent(
      sessionId: row['session_id']! as String,
      seq: row['seq']! as int,
      ts: _time(row['ts'])!,
      kind: EventKind.values.firstWhere((k) => k.name == row['kind']),
      detail: raw == null ? null : jsonDecode(raw) as Map<String, Object?>,
    );
  }

  Map<String, Object?> toRow() => {
    'session_id': sessionId,
    'seq': seq,
    'ts': ts.millisecondsSinceEpoch,
    'kind': kind.name,
    'detail': detail == null ? null : jsonEncode(detail),
  };
}

/// Every timestamp in this schema is epoch milliseconds UTC. Local time is a
/// rendering concern only — storing it would mean a run at 23:40 lands in the
/// wrong week the first time the clocks change.
DateTime? _time(Object? millis) => millis == null
    ? null
    : DateTime.fromMillisecondsSinceEpoch(millis as int, isUtc: true);
