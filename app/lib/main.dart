import 'package:flutter/material.dart';

import 'data/database.dart';
import 'data/session_repository.dart';
import 'recording/recorder.dart';
import 'ui/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final db = await openTrackerDatabase();
  runApp(TrackerApp(recorder: Recorder(SessionRepository(db))));
}

class TrackerApp extends StatelessWidget {
  const TrackerApp({required this.recorder, super.key});

  final Recorder recorder;

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
      home: HomeScreen(recorder: recorder),
    );
  }
}
