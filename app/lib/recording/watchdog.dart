import 'package:flutter/services.dart';

/// Dart side of the native watchdog. See `Watchdog.kt` for what it does and why
/// alarms are the mechanism.
///
/// Every call is best-effort. The watchdog is a safety net for a hostile OS,
/// not a correctness requirement, and no failure here should ever be allowed to
/// take down a recording that is otherwise working.
class Watchdog {
  const Watchdog();

  static const MethodChannel _channel = MethodChannel(
    'dev.freerunning.tracker/watchdog',
  );

  /// Arms the alarm and starts expecting heartbeats.
  Future<void> start() => _invoke('start');

  /// Says the recorder is still alive. Called from the recorder's poll timer.
  Future<void> heartbeat() => _invoke('heartbeat');

  /// Disarms. Called on pause and on finish, so a deliberate stop does not
  /// raise a false alarm.
  Future<void> stop() => _invoke('stop');

  Future<void> _invoke(String method) async {
    try {
      await _channel.invokeMethod<void>(method);
    } on MissingPluginException {
      // Host tests and any non-Android target.
    } on PlatformException {
      // Nothing here is worth failing a run over.
    }
  }
}
