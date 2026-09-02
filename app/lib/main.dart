import 'package:flutter/material.dart';

import 'data/database.dart';
import 'data/session_repository.dart';
import 'data/settings_repository.dart';
import 'recording/recorder.dart';
import 'sync/sync_service.dart';
import 'ui/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final db = await openTrackerDatabase();
  final sessions = SessionRepository(db);
  final settings = SettingsRepository(db);

  runApp(
    TrackerApp(
      recorder: Recorder(sessions),
      sync: SyncService(sessions, settings),
      settings: settings,
    ),
  );
}

class TrackerApp extends StatelessWidget {
  const TrackerApp({
    required this.recorder,
    required this.sync,
    required this.settings,
    super.key,
  });

  final Recorder recorder;
  final SyncService sync;
  final SettingsRepository settings;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tracker',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFE07A2F),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: HomeScreen(recorder: recorder, sync: sync, settings: settings),
    );
  }
}
