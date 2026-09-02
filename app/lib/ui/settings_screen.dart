import 'package:flutter/material.dart';

import '../data/settings_repository.dart';
import '../sync/api_client.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({required this.settings, super.key});

  final SettingsRepository settings;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _url = TextEditingController();
  final _token = TextEditingController();
  bool _loading = true;
  bool _obscureToken = true;
  String? _testResult;
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    _url.text = await widget.settings.serverUrl() ?? '';
    _token.text = await widget.settings.apiToken() ?? '';
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    await widget.settings.write(
      SettingsRepository.serverUrlKey,
      _url.text.trim(),
    );
    await widget.settings.write(
      SettingsRepository.apiTokenKey,
      _token.text.trim(),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Saved')));
    Navigator.of(context).pop();
  }

  /// Calls /health, which needs no token. A failure here means the address is
  /// wrong or the server is down, and separates that from a bad token.
  Future<void> _testConnection() async {
    setState(() {
      _testing = true;
      _testResult = null;
    });

    final client = ApiClient(
      baseUrl: _url.text.trim().replaceAll(RegExp(r'/+$'), ''),
      token: _token.text.trim(),
    );
    final problem = await client.checkHealth();
    client.close();

    if (!mounted) return;
    setState(() {
      _testing = false;
      _testResult = problem ?? 'Server answered';
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Server')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Server address',
              hintText: 'https://run.example.com',
              helperText: 'No trailing slash needed',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _token,
            obscureText: _obscureToken,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: 'API token',
              helperText: 'Printed once when the server first started',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(
                  _obscureToken ? Icons.visibility : Icons.visibility_off,
                ),
                onPressed: () => setState(() => _obscureToken = !_obscureToken),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _testing ? null : _testConnection,
                  child: Text(_testing ? 'Testing…' : 'Test connection'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _save,
                  child: const Text('Save'),
                ),
              ),
            ],
          ),
          if (_testResult != null) ...[
            const SizedBox(height: 12),
            Text(_testResult!, textAlign: TextAlign.center),
          ],
          const SizedBox(height: 32),
          Text(
            'Runs stay on the phone until the server confirms it has them. '
            'Nothing is deleted here.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
