import 'package:sqflite/sqflite.dart';

/// Server address and API token.
///
/// Kept in the same database as the runs so there is one file to back up, one
/// file to copy to a new phone, and one file to delete. Android keeps app
/// storage private to the app.
class SettingsRepository {
  SettingsRepository(this._db);

  static const String serverUrlKey = 'server_url';
  static const String apiTokenKey = 'api_token';

  final Database _db;

  Future<String?> read(String key) async {
    final rows = await _db.query(
      'settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
    );
    if (rows.isEmpty) return null;
    final value = rows.first['value'];
    return value is String && value.isNotEmpty ? value : null;
  }

  Future<void> write(String key, String value) async {
    await _db.insert('settings', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> clear(String key) async {
    await _db.delete('settings', where: 'key = ?', whereArgs: [key]);
  }

  /// Trailing slashes are trimmed so `https://host/` and `https://host` build
  /// the same request path.
  Future<String?> serverUrl() async {
    final raw = await read(serverUrlKey);
    if (raw == null) return null;
    final trimmed = raw.trim().replaceAll(RegExp(r'/+$'), '');
    return trimmed.isEmpty ? null : trimmed;
  }

  Future<String?> apiToken() => read(apiTokenKey);

  Future<bool> isConfigured() async =>
      await serverUrl() != null && await apiToken() != null;
}
