import 'dart:async';
import 'dart:convert';
import 'dart:io' show InternetAddress;

import 'package:http/http.dart' as http;

import '../core/protocol.dart';
import '../core/secret_book.dart';
import '../core/secret_placeholders.dart';
import '../core/tool_runtime.dart';

/// What `http_request` reads from the settings, when it is called.
class HttpRequestSettings {
  const HttpRequestSettings({
    this.enabled = true,
    this.confirm = 'secretOrWrite',
    this.maxResponseChars = 20000,
    this.timeoutSeconds = 30,
    this.allowInsecure = false,
    this.maxRedirects = 5,
  });

  final bool enabled;

  /// `secretOrWrite`, `all` or `never`.
  final String confirm;
  final int maxResponseChars;
  final int timeoutSeconds;
  final bool allowInsecure;

  /// How many redirects are followed; a longer chain is a loop (a setting).
  final int maxRedirects;
}

/// Looks a host name up: the addresses it points at. A test gives its own, so nothing needs the network.
typedef HostResolver = Future<List<InternetAddress>> Function(String host);

/// The tool `http_request` (path A): a model asks the app to call an address, writing
/// `{{secret:ID}}` where a key or a token goes; the app puts the value in, only for the hosts that secret is
/// bound to, sends the request itself (not through proot), and hands back the answer with every value taken out.
///
/// What makes it safe is where the value can go: every secret used is checked against its own hosts before
/// anything is sent, on the first address and on every redirect; a redirect to another host is not followed
/// when a secret is in the request; an address inside the device or the local network (also one a name
/// resolves to) is never called. What it cannot do: a name that is looked up here and again by the client
/// could answer differently the second time (DNS rebinding); the check is made on the answer of this lookup.
class HttpRequestTool {
  HttpRequestTool({required this.book, this.settings = const HttpRequestSettings(), this.client, HostResolver? resolver})
      : _resolver = resolver ?? InternetAddress.lookup;

  final SecretBook book;
  final HttpRequestSettings settings;

  /// The client the request goes through (a test gives its own); null: a new one for each call.
  final http.Client? client;
  final HostResolver _resolver;

  /// How many redirects are followed (the setting `httpRequestMaxRedirects`).
  int get maxRedirects => settings.maxRedirects;

  /// Headers a model may not set: they decide where a request goes, or how it is framed.
  static const forbiddenHeaders = {'host', 'content-length', 'transfer-encoding', 'connection', 'upgrade', 'expect', 'te', 'trailer'};

  static final _headerName = RegExp(r"^[A-Za-z0-9!#$%&'*+.^_`|~-]+$");

  // ------------------------------------------------------------------ what the model is offered

  /// The definition the model is offered, with the ids of the secrets it may name written into the
  /// description (the model cannot look them up). Null when the tool is off.
  ToolDefinition? definition() {
    if (!settings.enabled) return null;
    final usable = [for (final entry in book.entries) if (entry.modelMayUse) entry];
    final list = usable.isEmpty
        ? 'No secret is available now: a call carries no key.'
        : 'Secrets you may name (each is sent only to the hosts shown): '
            '${usable.map((e) => '{{secret:${e.id}}} (${e.label}) -> ${e.hosts.join(', ')}').join('; ')}.';
    return ToolDefinition(
      name: Protocol.httpRequestName,
      description: '${Protocol.httpRequest.description} Use this, not curl, to call an API. $list '
          'A placeholder works in the url (after the host), in a header value and in the body, not in a header name or in the host. '
          'Only https is used with a secret. A redirect to another host is not followed when a secret is in the request. '
          'The answer is the status, a few headers (content type, rate-limit headers) and the body, cut when long; '
          'the values of the secrets are taken out of it.',
      parameters: Protocol.httpRequest.parameters,
    );
  }

  // ------------------------------------------------------------------ approval

  static bool _isRead(String method) => method == 'GET' || method == 'HEAD';

  /// The text of the whole request where a placeholder may stand or be mistaken for standing: the address,
  /// the header names and values, the body. Null when the arguments are not of a shape that can be read.
  static String? _everything(Map<String, Object?> arguments) {
    final url = arguments['url'];
    if (url is! String) return null;
    final parts = <String>[url];
    final headers = arguments['headers'];
    if (headers != null) {
      if (headers is! Map) return null;
      for (final entry in headers.entries) {
        parts
          ..add('${entry.key}')
          ..add('${entry.value}');
      }
    }
    final body = arguments['body'];
    if (body != null) {
      if (body is! String) return null;
      parts.add(body);
    }
    final json = arguments['json'];
    if (json != null) parts.add(jsonEncode(json));
    return parts.join('\n');
  }

  /// Whether the user approves this call first (see [HttpRequestSettings.confirm]). A call whose arguments
  /// cannot be read asks, whatever the mode but `never`.
  bool needsApproval(Map<String, Object?> arguments) {
    switch (settings.confirm) {
      case 'never':
        return false;
      case 'all':
        return true;
    }
    final method = arguments['method'];
    final text = _everything(arguments);
    if (text == null || (method != null && method is! String)) return true;
    return SecretPlaceholders.hasAny(text) || !_isRead(((method as String?) ?? 'GET').toUpperCase());
  }

  // ------------------------------------------------------------------ the call

  Future<ToolOutcome> run(Map<String, Object?> arguments) async {
    if (!settings.enabled) return _refuse('http_request is turned off in the settings.', '設定でオフです');
    final request = _read(arguments);
    if (request is String) return _refuse(request, request);

    final call = request as _Call;
    final ids = SecretPlaceholders.idsIn(call.everything);
    // the placeholders may stand in the address (after the host), in a header value and in the body: not in
    // a header name, not in the scheme or the host
    for (final name in call.headers.keys) {
      if (SecretPlaceholders.hasAny(name)) return _refuse('A placeholder cannot be part of a header name.', 'ヘッダー名にプレースホルダーは書けません');
    }
    final authority = _authorityOf(call.url);
    if (authority == null) return _refuse('The url is not a full address (https://host/path).', 'URL が読み取れません');
    if (SecretPlaceholders.hasAny(authority.$1) || SecretPlaceholders.hasAny(authority.$2)) {
      return _refuse('A placeholder cannot be part of the scheme or the host of the address: the secret would decide where it goes.', 'プレースホルダーはホスト部に書けません');
    }

    // which secrets are named, and may they be used
    final values = <String, String>{};
    final problems = <String>[];
    for (final id in ids) {
      final info = book.byId(id);
      final value = book.valueOf(id);
      if (info == null) {
        problems.add('"$id": no such secret');
      } else if (value == null || info.unusableReason != null) {
        problems.add('"$id": ${info.unusableReason ?? 'not available'}');
      } else {
        values[id] = value;
      }
    }
    if (problems.isNotEmpty) {
      final usable = [for (final e in book.entries) if (e.modelMayUse) e.id];
      return _refuse(
        'Nothing was sent. ${problems.join('; ')}. Secrets you may name: ${usable.isEmpty ? 'none' : usable.join(', ')}.',
        '使えない秘密: ${ids.join(', ')}',
      );
    }

    // the address with the values in (percent-encoded: they stand in a path or a query), checked as it will be sent
    final finalUrl = SecretPlaceholders.substitute(call.url, (id) => values[id] == null ? null : Uri.encodeComponent(values[id]!));
    final first = _checkUrl(finalUrl, ids);
    if (first != null) return _refuse('Nothing was sent. $first', '送りませんでした: $first');

    final headers = <String, String>{};
    for (final entry in call.headers.entries) {
      final value = SecretPlaceholders.substitute(entry.value, (id) => values[id]);
      if (RegExp(r'[\r\n\u0000]').hasMatch(value)) return _refuse('A header value has a line break.', 'ヘッダーの値に改行があります');
      headers[entry.key] = value;
    }
    final body = call.body == null ? null : SecretPlaceholders.substitute(call.body!, (id) => values[id]);
    if (call.jsonBody != null && !headers.keys.any((k) => k.toLowerCase() == 'content-type')) headers['Content-Type'] = 'application/json';

    // the address as written, with the placeholders: what the log and the card show, never the values
    final shown = '${call.method} ${call.url}';
    final timeout = Duration(seconds: call.timeoutSeconds == null ? settings.timeoutSeconds : call.timeoutSeconds!.clamp(1, settings.timeoutSeconds));
    final ownClient = client == null;
    final used = client ?? http.Client();
    String redact(String text) => SecretRedaction.redact(text, values);
    try {
      final result = await _send(used, call.method, finalUrl, headers, body, values.isNotEmpty, ids, timeout, values).timeout(timeout);
      final text = redact(result.text);
      final failed = result.status >= 400;
      return ToolOutcome(text, ToolActivity('HTTP', redact('$shown → ${result.status}'), failed: failed));
    } on _Refused catch (e) {
      return _refuse(redact('Nothing more was sent. ${e.reason}'), redact('取りやめました: ${e.reason}'));
    } on TimeoutException {
      return _refuse('The request took longer than ${timeout.inSeconds} seconds and was given up.', redact('$shown: 時間切れ（${timeout.inSeconds} 秒）'));
    } catch (e) {
      // an error text may echo the address, and the address may carry a value: it goes through the same filter
      return _refuse(redact('The request failed: $e'), redact('$shown: 失敗: $e'));
    } finally {
      if (ownClient) used.close();
    }
  }

  ToolOutcome _refuse(String response, String summary) => ToolOutcome(response, ToolActivity('HTTP', summary, failed: true));

  /// The arguments as a request, or a sentence saying what is wrong.
  Object _read(Map<String, Object?> arguments) {
    final rawMethod = arguments['method'];
    if (rawMethod != null && rawMethod is! String) return 'method must be text.';
    final method = ((rawMethod as String?) ?? 'GET').trim().toUpperCase();
    if (!Protocol.httpRequestMethods.contains(method)) return 'method must be one of ${Protocol.httpRequestMethods.join(', ')}.';
    final url = arguments['url'];
    if (url is! String || url.trim().isEmpty) return 'url is required.';
    final headers = <String, String>{};
    final rawHeaders = arguments['headers'];
    if (rawHeaders != null) {
      if (rawHeaders is! Map) return 'headers must be an object of text.';
      for (final entry in rawHeaders.entries) {
        final name = '${entry.key}';
        if (entry.value is! String && entry.value is! num && entry.value is! bool) return 'a header value must be text.';
        if (!_headerName.hasMatch(name) && !SecretPlaceholders.hasAny(name)) return 'the header name "$name" is not valid.';
        if (forbiddenHeaders.contains(name.toLowerCase())) return 'the header "$name" cannot be set: the app sets it.';
        headers[name] = '${entry.value}';
      }
    }
    final rawBody = arguments['body'];
    if (rawBody != null && rawBody is! String) return 'body must be text (use json for an object).';
    final json = arguments['json'];
    if (rawBody != null && json != null) return 'give either body or json, not both.';
    final timeout = arguments['timeout_seconds'];
    if (timeout != null && timeout is! num) return 'timeout_seconds must be a number.';
    final body = json != null ? jsonEncode(json) : rawBody as String?;
    return _Call(
      method: method,
      url: url.trim(),
      headers: headers,
      body: body == null || body.isEmpty ? null : body,
      jsonBody: json,
      timeoutSeconds: timeout is num ? timeout.toInt() : null,
    );
  }

  /// The scheme part and the authority part of [url] as written (before the path), or null when it has no `://`.
  static (String, String)? _authorityOf(String url) {
    final at = url.indexOf('://');
    if (at < 0) return null;
    final rest = url.substring(at + 3);
    final end = rest.indexOf(RegExp(r'[/?#]'));
    return (url.substring(0, at), end < 0 ? rest : rest.substring(0, end));
  }

  /// Why [url] may not be called with the secrets [ids], or null. Every secret used must be allowed to go to this
  /// host; with none, any public address is fine (http too), but never one inside the device or its network.
  String? _checkUrl(String url, List<String> ids) {
    if (ids.isEmpty) return SecretHosts.problem(url, const ['*'], allowInsecure: true);
    for (final id in ids) {
      final info = book.byId(id)!;
      final problem = SecretHosts.problem(url, info.hosts, allowInsecure: settings.allowInsecure);
      if (problem != null) return '{{secret:$id}}: $problem.';
    }
    return null;
  }

  /// Looks the host up and refuses when it points inside the device or the local network.
  Future<String?> _checkResolved(String url) async {
    final host = SecretHosts.normalizeHost(Uri.tryParse(url)?.host ?? '');
    if (host == null) return 'the host cannot be read';
    if (host.contains(':') || RegExp(r'^[0-9.]+$').hasMatch(host)) return null; // an address already: checked as one
    final List<InternetAddress> addresses;
    try {
      addresses = await _resolver(host);
    } catch (_) {
      return null; // it cannot be looked up: the request fails by itself
    }
    for (final address in addresses) {
      if (SecretHosts.isPrivate(address.address)) return '$host points to an address inside the device or its network (${address.address})';
    }
    return null;
  }

  Future<_Result> _send(
    http.Client http0,
    String method,
    String firstUrl,
    Map<String, String> headers,
    String? body,
    bool withSecrets,
    List<String> ids,
    Duration timeout,
    Map<String, String> values,
  ) async {
    var url = firstUrl;
    var currentMethod = method;
    var currentBody = body;
    final notes = <String>[];
    for (var hop = 0; ; hop++) {
      final blocked = await _checkResolved(url);
      if (blocked != null) throw _Refused(blocked);
      final request = http.Request(currentMethod, Uri.parse(url))
        ..followRedirects = false
        ..headers.addAll(headers);
      if (currentBody != null && currentMethod != 'GET' && currentMethod != 'HEAD') request.body = currentBody;
      final response = await http0.send(request);
      final status = response.statusCode;
      final location = response.headers['location'];
      if (const {301, 302, 303, 307, 308}.contains(status) && location != null && location.isNotEmpty) {
        final next = Uri.tryParse(url)?.resolve(location).toString();
        // drain what the redirect carries (a connection is not left open)
        await response.stream.drain<void>();
        if (next == null) return _Result(status, 'HTTP $status (the redirect address cannot be read)');
        if (hop >= maxRedirects) return _Result(status, 'HTTP $status\nToo many redirects (more than $maxRedirects): the last address was not followed.');
        final fromHost = SecretHosts.normalizeHost(Uri.tryParse(url)?.host ?? '');
        final toHost = SecretHosts.normalizeHost(Uri.tryParse(next)?.host ?? '');
        // a secret is in the request: only the same host is followed, and the new address is checked like the first
        if (withSecrets && (toHost == null || toHost != fromHost)) {
          return _Result(status, 'HTTP $status\nRedirect to another host (${toHost ?? 'unreadable'}) was not followed: the request carries a secret, and a secret is sent only to the host it is bound to.');
        }
        final problem = _checkUrl(next, ids);
        if (problem != null) return _Result(status, 'HTTP $status\nThe redirect was not followed: $problem');
        notes.add('redirected to ${Uri.tryParse(next)?.host ?? next}');
        url = next;
        if (status == 303 || ((status == 301 || status == 302) && currentMethod == 'POST')) {
          currentMethod = currentMethod == 'HEAD' ? 'HEAD' : 'GET';
          currentBody = null;
        }
        continue;
      }
      return _Result(status, await _describe(response, notes, method == 'HEAD' || currentMethod == 'HEAD', values));
    }
  }

  /// The status, a few headers, and the body (cut) of [response].
  Future<String> _describe(http.StreamedResponse response, List<String> notes, bool head, Map<String, String> values) async {
    final b = StringBuffer('HTTP ${response.statusCode}${response.reasonPhrase == null || response.reasonPhrase!.isEmpty ? '' : ' ${response.reasonPhrase}'}');
    for (final note in notes) {
      b.write('\n($note)');
    }
    for (final entry in response.headers.entries) {
      final name = entry.key.toLowerCase();
      if (name == 'content-type' || name == 'content-length' || name == 'retry-after' || name.startsWith('x-ratelimit-') || name.startsWith('ratelimit-') || name.startsWith('x-rate-limit-')) {
        b.write('\n$name: ${entry.value}');
      }
    }
    if (head) {
      await response.stream.drain<void>();
      return b.toString();
    }
    // read no more than a text of the length allowed can come from (4 bytes a character at most)
    final limit = settings.maxResponseChars * 4 + 4;
    final bytes = <int>[];
    var cut = false;
    await for (final chunk in response.stream) {
      bytes.addAll(chunk);
      if (bytes.length > limit) {
        cut = true;
        break;
      }
    }
    // the values are taken out of the whole text first and the cut is made after: a value that stood across
    // the cut would otherwise leave its first half in the answer (and one cut by the read limit its tail is
    // trimmed too)
    var text = SecretRedaction.redact(utf8.decode(bytes, allowMalformed: true), values);
    if (text.length > settings.maxResponseChars) {
      text = SecretRedaction.redact(text.substring(0, settings.maxResponseChars), values, trimTail: true);
      cut = true;
    } else if (cut) {
      text = SecretRedaction.redact(text, values, trimTail: true);
    }
    if (text.isNotEmpty) {
      b
        ..write('\n\n')
        ..write(text);
    }
    if (cut) b.write('\n[… the rest of the answer was left out (more than ${settings.maxResponseChars} characters)]');
    return b.toString();
  }
}

class _Call {
  const _Call({required this.method, required this.url, required this.headers, this.body, this.jsonBody, this.timeoutSeconds});

  final String method;
  final String url;
  final Map<String, String> headers;
  final String? body;
  final Object? jsonBody;
  final int? timeoutSeconds;

  /// Everything a placeholder may be in, for finding them.
  String get everything => [url, ...headers.keys, ...headers.values, ?body].join('\n');
}

class _Result {
  const _Result(this.status, this.text);
  final int status;
  final String text;
}

class _Refused implements Exception {
  const _Refused(this.reason);
  final String reason;
}
