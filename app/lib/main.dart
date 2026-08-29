// Phase 0 spike: does this phone let a location loop survive the screen going
// off, the app being backgrounded, and the task being swiped away?
//
// This is an instrument, not a product. Every design choice here is about making
// gaps in the fix stream visible and attributable. The UI is disposable; what
// carries into Phase 1 is whatever we learn about which of these survives.
//
// Fixes are appended to a JSONL file, one object per line, flushed on every
// write. A crash or a kill therefore loses at most the fix in flight, and the
// file is still parseable up to the truncation point.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';

void main() => runApp(const TrackerApp());

class TrackerApp extends StatelessWidget {
  const TrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Phase 0',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFE07A2F),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const RecorderPage(),
    );
  }
}

/// Append-only JSONL sink for one recording session.
class SessionLog {
  SessionLog._(this.file, this.startedAt);

  final File file;
  final DateTime startedAt;

  static Future<SessionLog> create() async {
    final dir = await getApplicationDocumentsDirectory();
    final now = DateTime.now();
    final stamp = now
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    final file = File('${dir.path}/phase0-$stamp.jsonl');
    await file.create(recursive: true);
    return SessionLog._(file, now);
  }

  /// Most recent session file on disk, for the share button when nothing is
  /// currently recording.
  static Future<File?> latest() async {
    final dir = await getApplicationDocumentsDirectory();
    final logs = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.jsonl'))
        .toList();
    if (logs.isEmpty) return null;
    logs.sort((a, b) => a.path.compareTo(b.path));
    return logs.last;
  }

  /// Synchronous + flushed. At ~1 Hz the cost is irrelevant and durability is
  /// the whole point: we are specifically testing what happens when the process
  /// dies without warning.
  void write(Map<String, Object?> row) {
    file.writeAsStringSync(
      '${jsonEncode(row)}\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  void event(String type, [Map<String, Object?> extra = const {}]) {
    write({
      't': type,
      'ts': DateTime.now().millisecondsSinceEpoch,
      ...extra,
    });
  }
}

class Grants {
  const Grants({
    this.fine = false,
    this.always = false,
    this.notifications = false,
    this.batteryExempt = false,
  });

  final bool fine;
  final bool always;
  final bool notifications;
  final bool batteryExempt;

  Map<String, Object?> toJson() => {
        'fine': fine,
        'always': always,
        'notifications': notifications,
        'batteryExempt': batteryExempt,
      };
}

class RecorderPage extends StatefulWidget {
  const RecorderPage({super.key});

  @override
  State<RecorderPage> createState() => _RecorderPageState();
}

class _RecorderPageState extends State<RecorderPage>
    with WidgetsBindingObserver {
  SessionLog? _log;
  StreamSubscription<Position>? _sub;
  Timer? _ticker;

  Grants _grants = const Grants();
  int _fixCount = 0;
  Position? _lastFix;
  DateTime? _lastArrival;
  Duration _maxGap = Duration.zero;
  final List<String> _recent = [];
  String? _banner;

  bool get _recording => _sub != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshGrants();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    _sub?.cancel();
    super.dispose();
  }

  // Lifecycle transitions are logged into the same stream as the fixes so a gap
  // can be lined up against what the OS did to us at that moment.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _log?.event('lifecycle', {'state': state.name});
    _note('lifecycle: ${state.name}');
  }

  void _note(String line) {
    final t = TimeOfDay.fromDateTime(DateTime.now());
    final stamp =
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    if (!mounted) return;
    setState(() {
      _recent.insert(0, '$stamp  $line');
      if (_recent.length > 40) _recent.removeLast();
    });
  }

  Future<void> _refreshGrants() async {
    final perm = await Geolocator.checkPermission();
    final grants = Grants(
      fine: perm == LocationPermission.always ||
          perm == LocationPermission.whileInUse,
      always: perm == LocationPermission.always,
      notifications: await Permission.notification.isGranted,
      batteryExempt: await Permission.ignoreBatteryOptimizations.isGranted,
    );
    if (!mounted) return;
    setState(() => _grants = grants);
  }

  /// Returns an error string if we cannot record at all. Everything short of
  /// that is a warning: whether the optional grants are actually *required* is
  /// one of the things this spike exists to find out, so we start regardless
  /// and record what we had.
  Future<String?> _requestPermissions() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return 'Location is switched off in system settings.';
    }

    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied) {
      return 'Location permission denied.';
    }
    if (perm == LocationPermission.deniedForever) {
      return 'Location permission permanently denied. Grant it in Settings › Apps › tracker › Permissions.';
    }

    // Android 13+ will not show the foreground-service notification without
    // this, and a foreground service with no visible notification is a service
    // Android feels free to kill.
    await Permission.notification.request();

    // Deliberately a separate step: Android will not show "Allow all the time"
    // in the same dialog as the foreground grant, and on some versions it does
    // not show a dialog at all, it just opens Settings.
    if (perm != LocationPermission.always) {
      await Permission.locationAlways.request();
    }

    // Doze is the single most likely cause of a gap. Ask, but do not insist.
    if (!await Permission.ignoreBatteryOptimizations.isGranted) {
      await Permission.ignoreBatteryOptimizations.request();
    }

    await _refreshGrants();
    return null;
  }

  Future<void> _start() async {
    setState(() => _banner = null);

    final error = await _requestPermissions();
    if (error != null) {
      setState(() => _banner = error);
      return;
    }

    final log = await SessionLog.create();
    log.event('session', {
      'event': 'start',
      'grants': _grants.toJson(),
      'device': {
        'os': Platform.operatingSystem,
        'osVersion': Platform.operatingSystemVersion,
      },
    });

    // distanceFilter 0 and a 1s interval on purpose: this is the highest
    // fidelity the platform will give us, which is what makes a gap unambiguous.
    // A real run would use a coarser filter to save battery.
    final settings = AndroidSettings(
      accuracy: LocationAccuracy.best,
      distanceFilter: 0,
      intervalDuration: Duration(seconds: 1),
      foregroundNotificationConfig: const ForegroundNotificationConfig(
        notificationTitle: 'Phase 0 recording',
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

    final sub = Geolocator.getPositionStream(locationSettings: settings).listen(
      _onFix,
      onError: (Object e) {
        log.event('error', {'message': e.toString()});
        _note('error: $e');
      },
      cancelOnError: false,
    );

    setState(() {
      _log = log;
      _sub = sub;
      _fixCount = 0;
      _lastFix = null;
      _lastArrival = null;
      _maxGap = Duration.zero;
      _recent.clear();
    });

    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });

    _note('started → ${log.file.path.split('/').last}');
  }

  void _onFix(Position p) {
    final log = _log;
    if (log == null) return;

    final arrival = DateTime.now();
    final prev = _lastArrival;
    final gap = prev == null ? Duration.zero : arrival.difference(prev);

    log.write({
      't': 'fix',
      // Arrival and GPS time are both recorded because they answer different
      // questions. If the service is suspended and then flushes a burst, the
      // arrivals cluster while the GPS timestamps stay evenly spaced — that
      // distinguishes "buffered" from "genuinely lost".
      'ts': arrival.millisecondsSinceEpoch,
      'gpsTs': p.timestamp.millisecondsSinceEpoch,
      'lat': p.latitude,
      'lon': p.longitude,
      'acc': p.accuracy,
      'alt': p.altitude,
      'altAcc': p.altitudeAccuracy,
      'spd': p.speed,
      'spdAcc': p.speedAccuracy,
      'hdg': p.heading,
      'mocked': p.isMocked,
      'gapMs': gap.inMilliseconds,
    });

    if (!mounted) {
      // UI is gone but the isolate is alive — still record the gap so it shows
      // up when we come back.
      _lastArrival = arrival;
      _fixCount++;
      if (gap > _maxGap) _maxGap = gap;
      return;
    }

    setState(() {
      _fixCount++;
      _lastFix = p;
      _lastArrival = arrival;
      if (gap > _maxGap) {
        _maxGap = gap;
      }
    });

    // Only surface notable gaps in the visible log; at 1 Hz everything else is
    // noise.
    if (gap.inSeconds >= 5) {
      _note('gap of ${gap.inSeconds}s before fix #$_fixCount');
    }
  }

  Future<void> _stop() async {
    final log = _log;
    await _sub?.cancel();
    _ticker?.cancel();
    log?.event('session', {
      'event': 'stop',
      'fixes': _fixCount,
      'maxGapMs': _maxGap.inMilliseconds,
    });
    setState(() {
      _sub = null;
      _ticker = null;
    });
    _note('stopped after $_fixCount fixes');
  }

  Future<void> _share() async {
    final file = _log?.file ?? await SessionLog.latest();
    if (file == null) {
      setState(() => _banner = 'No log files yet.');
      return;
    }
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path)],
        subject: 'Phase 0 fix log',
        text: 'Phase 0 GPS log: ${file.path.split('/').last}',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sinceLast = _lastArrival == null
        ? null
        : DateTime.now().difference(_lastArrival!);
    final elapsed = _log == null
        ? null
        : DateTime.now().difference(_log!.startedAt);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Phase 0 — recording gate'),
        backgroundColor: theme.colorScheme.surfaceContainerHighest,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_banner != null) ...[
              Card(
                color: theme.colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    _banner!,
                    style: TextStyle(
                      color: theme.colorScheme.onErrorContainer,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
            _StatusCard(
              recording: _recording,
              sinceLast: sinceLast,
            ),
            const SizedBox(height: 12),
            _StatGrid(
              fixes: _fixCount,
              elapsed: elapsed,
              maxGap: _maxGap,
              sinceLast: sinceLast,
              accuracy: _lastFix?.accuracy,
            ),
            const SizedBox(height: 12),
            _GrantRow(grants: _grants, onRefresh: _refreshGrants),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _recording ? null : _start,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Start'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: _recording ? _stop : null,
                    icon: const Icon(Icons.stop),
                    label: const Text('Stop'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _share,
                    icon: const Icon(Icons.ios_share),
                    label: const Text('Log'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Text('Events', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            if (_recent.isEmpty)
              Text(
                'Nothing yet. Press Start, then lock the phone and walk.',
                style: theme.textTheme.bodySmall,
              ),
            for (final line in _recent)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  line,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.recording, required this.sinceLast});

  final bool recording;
  final Duration? sinceLast;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Stale means the stream is technically alive but nothing is arriving —
    // the exact failure this spike is hunting for.
    final stale = recording && (sinceLast?.inSeconds ?? 0) > 10;
    final color = !recording
        ? theme.colorScheme.surfaceContainerHighest
        : stale
            ? theme.colorScheme.errorContainer
            : theme.colorScheme.primaryContainer;
    final label = !recording
        ? 'IDLE'
        : stale
            ? 'STALE — no fix for ${sinceLast!.inSeconds}s'
            : 'RECORDING';

    return Card(
      color: color,
      child: SizedBox(
        width: double.infinity,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: 1.5,
            ),
          ),
        ),
      ),
    );
  }
}

class _StatGrid extends StatelessWidget {
  const _StatGrid({
    required this.fixes,
    required this.elapsed,
    required this.maxGap,
    required this.sinceLast,
    required this.accuracy,
  });

  final int fixes;
  final Duration? elapsed;
  final Duration maxGap;
  final Duration? sinceLast;
  final double? accuracy;

  static String _dur(Duration? d) {
    if (d == null) return '—';
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    // Expected fix count vs actual is the headline number: at 1 Hz, a session
    // that ran 600s and logged 240 fixes lost 60% of the track.
    final expected = elapsed?.inSeconds ?? 0;
    final yieldPct =
        expected > 0 ? (fixes / expected * 100).clamp(0, 999).round() : null;

    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      childAspectRatio: 1.6,
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      children: [
        _Stat(label: 'fixes', value: '$fixes'),
        _Stat(label: 'elapsed', value: _dur(elapsed)),
        _Stat(
          label: 'yield',
          value: yieldPct == null ? '—' : '$yieldPct%',
          warn: yieldPct != null && yieldPct < 90,
        ),
        _Stat(
          label: 'max gap',
          value: maxGap == Duration.zero ? '—' : '${maxGap.inSeconds}s',
          warn: maxGap.inSeconds >= 10,
        ),
        _Stat(label: 'last fix', value: _dur(sinceLast)),
        _Stat(
          label: 'accuracy',
          value: accuracy == null ? '—' : '${accuracy!.toStringAsFixed(0)}m',
          warn: accuracy != null && accuracy! > 30,
        ),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, this.warn = false});

  final String label;
  final String value;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      color: warn ? theme.colorScheme.errorContainer : null,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              value,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(label, style: theme.textTheme.labelSmall),
          ],
        ),
      ),
    );
  }
}

class _GrantRow extends StatelessWidget {
  const _GrantRow({required this.grants, required this.onRefresh});

  final Grants grants;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _Chip(label: 'fine', ok: grants.fine),
        _Chip(label: 'always', ok: grants.always),
        _Chip(label: 'notify', ok: grants.notifications),
        _Chip(label: 'no-doze', ok: grants.batteryExempt),
        IconButton(
          onPressed: onRefresh,
          icon: const Icon(Icons.refresh, size: 18),
          tooltip: 'Re-check permissions',
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.ok});

  final String label;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Chip(
      visualDensity: VisualDensity.compact,
      avatar: Icon(
        ok ? Icons.check_circle : Icons.cancel,
        size: 16,
        color: ok ? Colors.green : theme.colorScheme.error,
      ),
      label: Text(label, style: const TextStyle(fontSize: 12)),
    );
  }
}
