import 'dart:async';

import 'package:flutter/material.dart';

import '../recording/recorder.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({required this.recorder, super.key});

  final Recorder recorder;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  Timer? _ticker;

  Recorder get _recorder => widget.recorder;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _recorder.addListener(_onChange);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    // Deferred until after the first frame so a dialog has a Navigator to
    // attach to.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_recorder.refreshDozeExemption());
      unawaited(_offerRecoveryIfNeeded());
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _recorder.removeListener(_onChange);
    _ticker?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    unawaited(_recorder.noteLifecycle(state.name));
    if (state == AppLifecycleState.resumed) {
      unawaited(_recorder.refreshDozeExemption());
    }
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  /// A session still marked recording means the last run ended by something
  /// other than the Stop button. Offering this on launch is what turns a killed
  /// run into a recovered one.
  Future<void> _offerRecoveryIfNeeded() async {
    if (_recorder.isActive) return;
    final interrupted = await _recorder.findInterrupted();
    if (interrupted == null || !mounted) return;

    final started = interrupted.startedAt.toLocal();
    final resume = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Unfinished run'),
        content: Text(
          'A run started at ${_clock(started)} on ${started.day}/${started.month} '
          'was never stopped — the app was killed or crashed.\n\n'
          'Everything recorded up to that point is already saved.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Save and close it'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Keep recording'),
          ),
        ],
      ),
    );

    if (!mounted) return;
    if (resume ?? false) {
      final refusal = await _recorder.resumeInterrupted(interrupted);
      if (refusal != null && mounted) await _explain(refusal);
    } else {
      await _recorder.salvageInterrupted(interrupted);
    }
  }

  Future<void> _start() async {
    final refusal = await _recorder.start();
    if (refusal != null && mounted) await _explain(refusal);
  }

  Future<void> _explain(StartRefusal refusal) async {
    final (title, body) = switch (refusal) {
      StartRefusal.locationServicesOff => (
        'Location is off',
        'Turn location on in system settings, then try again.',
      ),
      StartRefusal.permissionDenied => (
        'Location permission needed',
        'The app cannot record without it.',
      ),
      StartRefusal.permissionPermanentlyDenied => (
        'Permission blocked',
        'Grant it in Settings › Apps › tracker › Permissions › Location, '
            'and choose "Allow all the time".',
      ),
      StartRefusal.batteryOptimisationActive => (
        'Battery optimisation is on',
        'This phone will suspend the recorder within minutes and you will '
            'lose most of the run.\n\n'
            'Settings › Apps › tracker › Battery → Unrestricted.\n\n'
            'OxygenOS is known to switch this back on by itself, which is why '
            'it is checked before every run rather than once during setup.',
      ),
    };

    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final recording = _recorder.isRecording;
    final paused = _recorder.isPaused;
    final active = _recorder.isActive;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!_recorder.dozeExempt)
                Card(
                  color: theme.colorScheme.errorContainer,
                  child: const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text(
                      'Battery optimisation is on. Recording will be killed.',
                    ),
                  ),
                ),
              const Spacer(),

              // The distance readout. The only number that matters mid-run.
              Text(
                (_recorder.metres / 1000).toStringAsFixed(2),
                textAlign: TextAlign.center,
                style: theme.textTheme.displayLarge?.copyWith(
                  fontWeight: FontWeight.w300,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              Text(
                'km',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                active
                    ? '${_duration(_recorder.elapsed)}   ·   ${_recorder.fixCount} fixes'
                    : 'Ready',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const Spacer(),

              Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      onPressed: active ? null : _start,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 20),
                      ),
                      child: const Text('Start'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.tonal(
                      onPressed: !active
                          ? null
                          : recording
                          ? _recorder.pause
                          : _recorder.resume,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 20),
                      ),
                      child: Text(paused ? 'Resume' : 'Pause'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: active ? _recorder.finish : null,
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 20),
                      ),
                      child: const Text('Stop'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _clock(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  static String _duration(Duration? d) {
    if (d == null) return '--:--';
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}
