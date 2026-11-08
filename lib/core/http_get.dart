import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class HttpStatusException implements Exception {
  HttpStatusException(this.status, this.message);
  final int status;
  final String message;

  @override
  String toString() => message;
}

/// The only network primitive the core needs; tests substitute a fake.
typedef HttpGet = Future<String> Function(String url, Map<String, String> headers);

/// A POST with a text body (JSON for the search services that take one).
typedef HttpPost = Future<String> Function(String url, Map<String, String> headers, String body);

HttpPost packageHttpPost({
  http.Client? client,
  Duration timeout = const Duration(seconds: 20),
  Duration Function()? timeoutOf,
}) {
  final c = client ?? http.Client();
  return (url, headers, body) async {
    final response = await c.post(Uri.parse(url), headers: {'User-Agent': 'ARCE.AI', ...headers}, body: body).timeout(timeoutOf?.call() ?? timeout);
    if (response.statusCode < 200 || response.statusCode > 299) {
      throw HttpStatusException(response.statusCode, 'HTTP ${response.statusCode} for ${url.split('?').first}');
    }
    // the body is read as UTF-8 whatever the server says, as the JSON of these services is
    return utf8.decode(response.bodyBytes);
  };
}

/// [timeoutOf], when given, is asked on every call, so a changed setting applies at once.
HttpGet packageHttpGet({
  http.Client? client,
  Duration timeout = const Duration(seconds: 20),
  Duration Function()? timeoutOf,
}) {
  final c = client ?? http.Client();
  return (url, headers) async {
    final response = await c.get(Uri.parse(url), headers: {'User-Agent': 'ARCE.AI', ...headers}).timeout(timeoutOf?.call() ?? timeout);
    if (response.statusCode < 200 || response.statusCode > 299) {
      throw HttpStatusException(response.statusCode, 'HTTP ${response.statusCode} for ${url.split('?').first}');
    }
    // Like the POST above: GitHub sends JSON without a charset, and `response.body` falls back to
    // Latin-1 then, which turned Japanese in a release note into mojibake.
    return utf8.decode(response.bodyBytes, allowMalformed: true);
  };
}
