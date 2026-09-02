import 'dart:async';
import 'dart:io';

import 'package:battery_plus/battery_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:uuid/uuid.dart';

import '../data/models.dart';
import '../data/session_repository.dart';
import 'geo.dart';
import 'watchdog.dart';

/// Sampling rate. 1 Hz with no distance filter is the highest fidelity the
/// platform offers, and it is what the accuracy criteria were written against.
const Duration sampleInterval = Duration(seconds: 1);
const LocationAccuracy accuracyProfile = LocationAccuracy.best;

/// Why a start attempt was refused, when it was.
enum StartRefusal {
  locationServicesOff,
  permissionDenied,
  permissionPermanentlyDenied,
  batteryOptimisationActive,
}

class Recorder extends ChangeNotifier {
  Recorder(this._repo);

  final SessionRepository _repo;
  final Battery _battery = Battery();
  final Uuid _uuid = const Uuid();
  final Watchdog _watchdog = const Watchdog();

  StreamSubscription<Position>? _sub;
  Timer? _pollTimer;
  DistanceAccumulator _distance = DistanceAccumulator();

  Session? _session;
  int _fixSeq = 0;
  int _eventSeq = 0;
  int _fixCount = 0;
  int? _batteryLevel;
  Fix? _lastFix;
  bool _dozeExempt = false;

  Session? get session => _session;
  bool get isRecording => _session?.state == SessionState.recording;
  bool get isPaused => _session?.state == SessionState.paused;
  bool get isActive => _session != null;
  int get fixCount => _fixCount;
  double get metres => _distance.metres;
  Fix? get lastFix => _lastFix;
  bool get dozeExempt => _dozeExempt;

  Duration? get elapsed {
    final started = _session?.startedAt;
    if (started == null) return null;
    return DateTime.now().toUtc().difference(started);
  }

  /// A session left mid-flight by a kill or a crash, if there is one.
  Future<Session?> findInterrupted() => _repo.findInterrupted();

  Future<bool> refreshDozeExemption() async {
    _dozeExempt = await Permission.ignoreBatteryOptimizations.isGranted;
    notifyListeners();
    return _dozeExempt;
  }

  /// Starts a new session, or returns why it would not.
  ///
  /// The battery-optimisation check is a hard refusal rather than a warning.
  /// OxygenOS is documented to revoke that exemption on its own, days after it
  /// was granted, and a recorder that trusts a setup-time grant will silently
  /// lose a run weeks later. Refusing loudly at the start of a run costs a tap;
  /// discovering it afterwards costs the run.
  Future<StartRefusal?> start() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return StartRefusal.locationServicesOff;
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied) {
      return StartRefusal.permissionDenied;
    }
    if (permission == LocationPermission.deniedForever) {
      return StartRefusal.permissionPermanentlyDenied;
    }

    await Permission.notification.request();
    if (permission != LocationPermission.always) {
      await Permission.locationAlways.request();
    }

    if (!await refreshDozeExemption()) {
      await Permission.ignoreBatteryOptimizations.request();
      if (!await refreshDozeExemption()) {
        return StartRefusal.batteryOptimisationActive;
      }
    }

    final now = DateTime.now().toUtc();
    final session = Session(
      id: _uuid.v4(),
      state: SessionState.recording,
      startedAt: now,
      device: await _describeDevice(),
      osVersion: Platform.operatingSystemVersion,
      appVersion: await _describeApp(),
      sampleIntervalMs: sampleInterval.inMilliseconds,
      accuracyProfile: accuracyProfile.name,
    );
    await _repo.insertSession(session);

    _session = session;
    _fixSeq = 0;
    _eventSeq = 0;
    _fixCount = 0;
    _lastFix = null;
    _distance = DistanceAccumulator();

    await _record(EventKind.start);
    await _listen();
    await _watchdog.start();
    notifyListeners();
    return null;
  }

  /// Continues an interrupted session, keeping its id and its rows.
  ///
  /// The sequence counters are read back from the database rather than reset,
  /// so the new fixes append rather than collide. The gap between the last
  /// stored fix and now is left in the data as-is: it is real, and pretending
  /// otherwise would corrupt the moving-time calculation later.
  Future<StartRefusal?> resumeInterrupted(Session interrupted) async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return StartRefusal.locationServicesOff;
    }
    if (!await refreshDozeExemption()) {
      await Permission.ignoreBatteryOptimizations.request();
      if (!await refreshDozeExemption()) {
        return StartRefusal.batteryOptimisationActive;
      }
    }

    _session = interrupted;
    _fixSeq = await _repo.nextFixSeq(interrupted.id);
    _eventSeq = await _repo.nextEventSeq(interrupted.id);
    _fixCount = await _repo.fixCount(interrupted.id);
    _distance = DistanceAccumulator()
      ..replay(await _repo.fixesFor(interrupted.id));
    _lastFix = await _repo.lastFix(interrupted.id);

    await _repo.setState(interrupted.id, SessionState.recording);
    // The accumulator restarts its segment: the straight line across a gap of
    // unknown length is not distance anyone ran.
    _distance.breakSegment();
    await _record(EventKind.watchdog, {'recovered': true});
    await _listen();
    await _watchdog.start();
    notifyListeners();
    return null;
  }

  /// Closes an interrupted session without continuing it. The data already on
  /// disk is kept and becomes a finished (short) activity.
  Future<void> salvageInterrupted(Session interrupted) async {
    final last = await _repo.lastFix(interrupted.id);
    _session = interrupted;
    _eventSeq = await _repo.nextEventSeq(interrupted.id);
    await _record(EventKind.salvage);
    await _repo.finish(interrupted.id, last?.ts ?? interrupted.startedAt);
    _session = null;
    notifyListeners();
  }

  Future<void> pause() async {
    final session = _session;
    if (session == null || session.state != SessionState.recording) return;
    await _sub?.cancel();
    _sub = null;
    // The poll timer reads the battery and re-checks permissions. Neither
    // matters while paused, and leaving it running kept waking the UI.
    _pollTimer?.cancel();
    _pollTimer = null;
    await _repo.setState(session.id, SessionState.paused);
    _session = session.copyWith(state: SessionState.paused);
    // This event is what lets the server tell a deliberate stop from the OS
    // freezing us. Both look identical in the fix timestamps.
    await _watchdog.stop();
    await _record(EventKind.pause);
    notifyListeners();
  }

  Future<void> resume() async {
    final session = _session;
    if (session == null || session.state != SessionState.paused) return;
    await _repo.setState(session.id, SessionState.recording);
    _session = session.copyWith(state: SessionState.recording);
    await _record(EventKind.resume);
    _distance.breakSegment();
    await _listen();
    await _watchdog.start();
    notifyListeners();
  }

  Future<void> finish() async {
    final session = _session;
    if (session == null) return;
    await _sub?.cancel();
    _sub = null;
    _pollTimer?.cancel();
    _pollTimer = null;
    await _watchdog.stop();
    await _record(EventKind.finish, {
      'fixes': _fixCount,
      'metres': _distance.metres,
    });
    await _repo.finish(session.id, DateTime.now().toUtc());
    _session = null;
    _lastFix = null;
    notifyListeners();
  }

  /// Records an app lifecycle transition against the running session, so a hole
  /// in the fixes can be lined up with what the OS did to us.
  Future<void> noteLifecycle(String state) async {
    if (_session == null) return;
    await _record(EventKind.lifecycle, {'state': state});
  }

  Future<void> _listen() async {
    final settings = AndroidSettings(
      accuracy: accuracyProfile,
      distanceFilter: 0,
      intervalDuration: sampleInterval,
      foregroundNotificationConfig: const ForegroundNotificationConfig(
        notificationTitle: 'Recording run',
        notificationText: 'Logging GPS fixes',
        notificationChannelName: 'Recording',
        enableWakeLock: true,
        setOngoing: true,
        notificationIcon: AndroidResource(
          name: 'ic_launcher',
          defType: 'mipmap',
        ),
      ),
    );

    _sub = Geolocator.getPositionStream(locationSettings: settings).listen(
      _onPosition,
      onError: (Object error) =>
          _record(EventKind.error, {'message': '$error'}),
      cancelOnError: false,
    );

    await _poll();
    _pollTimer ??= Timer.periodic(const Duration(seconds: 30), (_) => _poll());
  }

  Future<void> _onPosition(Position position) async {
    final session = _session;
    if (session == null) return;

    final fix = Fix(
      sessionId: session.id,
      seq: _fixSeq++,
      ts: DateTime.now().toUtc(),
      gpsTs: position.timestamp.toUtc(),
      lat: position.latitude,
      lon: position.longitude,
      accuracy: position.accuracy,
      altitude: position.altitude,
      altitudeAccuracy: position.altitudeAccuracy,
      speed: position.speed,
      speedAccuracy: position.speedAccuracy,
      heading: position.heading,
      isMocked: position.isMocked,
      battery: _batteryLevel,
    );

    // Straight to disk, before anything else touches it.
    await _repo.insertFix(fix);

    _fixCount++;
    _lastFix = fix;
    _distance.add(fix);
    notifyListeners();
  }

  /// Battery level plus a re-check that the Doze exemption still holds.
  ///
  /// Polled on a slow timer because the reads are async and the fix write path
  /// is kept synchronous and short. Thirty seconds is far finer than a %/hour
  /// figure needs, and fine enough to catch a revoked exemption mid-run.
  Future<void> _poll() async {
    if (isRecording) await _watchdog.heartbeat();

    try {
      _batteryLevel = await _battery.batteryLevel;
    } catch (_) {
      _batteryLevel = null;
    }

    final wasExempt = _dozeExempt;
    final exempt = await refreshDozeExemption();
    if (wasExempt && !exempt) {
      await _record(EventKind.grants, {'batteryExempt': false});
    }
  }

  Future<void> _record(EventKind kind, [Map<String, Object?>? detail]) async {
    final session = _session;
    if (session == null) return;
    await _repo.insertEvent(
      SessionEvent(
        sessionId: session.id,
        seq: _eventSeq++,
        ts: DateTime.now().toUtc(),
        kind: kind,
        detail: detail,
      ),
    );
  }

  Future<String> _describeDevice() async {
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      return '${info.manufacturer} ${info.model} (${info.device})';
    } catch (_) {
      return 'unknown';
    }
  }

  Future<String> _describeApp() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return '${info.version}+${info.buildNumber}';
    } catch (_) {
      return 'unknown';
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _pollTimer?.cancel();
    super.dispose();
  }
}
