import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// What happened to an upload, and whether trying again would help.
sealed class UploadOutcome {
  const UploadOutcome();
}

/// Stored on the server. Covers both a first upload and a repeat, because both
/// mean the same thing to the phone: stop trying.
class UploadAccepted extends UploadOutcome {
  const UploadAccepted({required this.alreadyThere});
  final bool alreadyThere;
}

/// The server will never accept this, so retrying is pointless. The run stays
/// on the phone and the reason is shown.
class UploadRejected extends UploadOutcome {
  const UploadRejected(this.reason);
  final String reason;
}

/// Something temporary: no signal, server restarting, rate limited. Try later.
class UploadDeferred extends UploadOutcome {
  const UploadDeferred(this.reason);
  final String reason;
}

class ApiClient {
  ApiClient({required this.baseUrl, required this.token, http.Client? client})
    : _client = client ?? http.Client();

  final String baseUrl;
  final String token;
  final http.Client _client;

  static const Duration _timeout = Duration(seconds: 60);

  /// Uploads one activity.
  ///
  /// The body is gzipped. A two-hour run is around 100 KB compressed, which
  /// matters on mobile data and matters more when the upload is being retried
  /// from a train.
  Future<UploadOutcome> upload(Map<String, Object?> activity) async {
    final Uri uri;
    try {
      uri = Uri.parse('$baseUrl/api/activities');
    } on FormatException catch (e) {
      return UploadRejected('Server address is not a valid URL: ${e.message}');
    }

    try {
      final response = await _client
          .post(
            uri,
            headers: {
              'authorization': 'Bearer $token',
              'content-type': 'application/json',
              'content-encoding': 'gzip',
            },
            body: gzip.encode(utf8.encode(jsonEncode(activity))),
          )
          .timeout(_timeout);

      return interpretStatus(response.statusCode, response.body);
    } on SocketException catch (e) {
      return UploadDeferred('No connection: ${e.message}');
    } on HttpException catch (e) {
      return UploadDeferred(e.message);
    } on FormatException catch (e) {
      return UploadRejected('Server address is not a valid URL: ${e.message}');
    } catch (e) {
      // A timeout or anything else unforeseen. Treated as temporary, because
      // the alternative is throwing away a run over a hiccup.
      return UploadDeferred(e.toString());
    }
  }

  Future<bool> checkHealth() async {
    try {
      final response = await _client
          .get(Uri.parse('$baseUrl/health'))
          .timeout(const Duration(seconds: 10));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Maps a status code onto "done", "give up" or "try again later".
  ///
  /// Public because it is a pure function and the most important decision this
  /// class makes: getting it wrong either loses runs or retries forever.
  ///
  /// The split that matters is 4xx against 5xx. A rejected body will be
  /// rejected identically forever, so retrying it is a loop. A 5xx or a
  /// dropped connection is worth another go.
  static UploadOutcome interpretStatus(int status, String body) {
    if (status == 201) return const UploadAccepted(alreadyThere: false);
    if (status == 200) return const UploadAccepted(alreadyThere: true);

    if (status == 401) {
      return const UploadRejected(
        'The server rejected the token. Check settings.',
      );
    }
    if (status == 429) {
      return const UploadDeferred(
        'Server is rate limiting. Will try again later.',
      );
    }
    if (status >= 400 && status < 500) {
      return UploadRejected(
        'Server refused the upload ($status): ${_summarise(body)}',
      );
    }
    return UploadDeferred('Server error ($status). Will try again later.');
  }

  static String _summarise(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, Object?>) {
        final problems = decoded['problems'];
        if (problems is List && problems.isNotEmpty) return problems.join('; ');
        final error = decoded['error'];
        if (error is String) return error;
      }
    } catch (_) {
      // Not JSON. Fall through to the raw text.
    }
    return body.length > 200 ? '${body.substring(0, 200)}…' : body;
  }

  void close() => _client.close();
}
