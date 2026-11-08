import 'dart:convert';

/// An error that the app can report to a GitHub issue, in the form that leaves the device.
///
/// What is in it is chosen, not collected: the kind of error, its class, a short message, the top of
/// the stack inside the app, and a few facts about the setting it happened in (app version, system,
/// whether the device or an online model was answering, the host of the provider and the model's
/// name). Nothing of the conversation goes (no question, no answer, no file), and every text is
/// passed through [ErrorRedactor] first. Issues of a public repository are public.
class ErrorReport {
  const ErrorReport({
    required this.kind,
    required this.message,
    this.errorType = '',
    this.stack = '',
    this.facts = const {},
    required this.at,
  });

  /// `crash` (an uncaught error), `chat` (a reply that failed) or `test` (the check in the settings).
  final String kind;

  /// Redacted and cut.
  final String message;

  /// The class of the error (`FormatException`), when it is one.
  final String errorType;

  /// Redacted; only the frames inside the app.
  final String stack;

  /// Facts about the setting: version, os, engine, provider host, model. Redacted.
  final Map<String, String> facts;
  final DateTime at;

  static const maxMessageChars = 400;
  static const maxStackFrames = 10;

  /// Builds a report from raw material: every text is redacted and cut here, so a caller cannot
  /// forget it.
  factory ErrorReport.of({
    required String kind,
    required String message,
    Object? error,
    StackTrace? stack,
    Map<String, String> facts = const {},
    DateTime? at,
  }) {
    return ErrorReport(
      kind: kind,
      message: ErrorRedactor.cut(ErrorRedactor.redact(message), maxMessageChars),
      errorType: error == null ? '' : ErrorRedactor.redact(error.runtimeType.toString()),
      stack: stack == null ? '' : ErrorRedactor.appFrames(stack.toString(), maxFrames: maxStackFrames),
      facts: {for (final e in facts.entries) e.key: ErrorRedactor.cut(ErrorRedactor.redact(e.value), 120)},
      at: at ?? DateTime.now(),
    );
  }

  /// What makes two reports the same problem: the kind, the class, the message with its numbers and
  /// ids taken out (but not an HTTP status: 400 and 422 are different problems), and the top frame. The same problem is one issue, with a comment each time.
  String get signature {
    final topFrame = stack.split('\n').firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
    final normal = '$kind|$errorType|${message.replaceAll(RegExp(r'[0-9a-fA-F]{6,}'), '#').replaceAll(RegExp(r'(?<!HTTP )(?<!http )\b\d+\b'), '#')}|${topFrame.replaceAll(RegExp(r':\d+(:\d+)?'), '')}';
    return _fnv1a(normal);
  }

  /// The title of the issue.
  String get title {
    final head = message.split('\n').first.trim();
    final text = head.isEmpty ? errorType : head;
    final cut = text.length > 80 ? '${text.substring(0, 80)}…' : text;
    return '[auto/$kind] ${cut.isEmpty ? 'error' : cut}';
  }

  /// The body of the issue, in Markdown.
  String get body {
    final b = StringBuffer()
      ..writeln('Reported automatically by ARCE.AI. The text is redacted (keys, tokens, addresses, paths) and contains no conversation.')
      ..writeln()
      ..writeln('- kind: `$kind`');
    if (errorType.isNotEmpty) b.writeln('- type: `$errorType`');
    for (final e in facts.entries) {
      if (e.value.isNotEmpty) b.writeln('- ${e.key}: `${e.value}`');
    }
    b
      ..writeln('- at: ${at.toUtc().toIso8601String()}')
      ..writeln('- signature: `$signature`')
      ..writeln()
      ..writeln('```')
      ..writeln(message)
      ..writeln('```');
    if (stack.isNotEmpty) {
      b
        ..writeln()
        ..writeln('```')
        ..writeln(stack)
        ..writeln('```');
    }
    return b.toString();
  }

  /// The comment added when the same problem happens again.
  String comment(int count) {
    final b = StringBuffer('Happened again ($count times in all since the first report). at ${at.toUtc().toIso8601String()}');
    final version = facts['app'];
    if (version != null && version.isNotEmpty) b.write(', app `$version`');
    return b.toString();
  }

  Map<String, Object?> toJson() => {
        'kind': kind,
        'message': message,
        'errorType': errorType,
        'stack': stack,
        'facts': facts,
        'at': at.millisecondsSinceEpoch,
      };

  factory ErrorReport.fromJson(Map<String, Object?> json) => ErrorReport(
        kind: json['kind'] as String? ?? 'crash',
        message: json['message'] as String? ?? '',
        errorType: json['errorType'] as String? ?? '',
        stack: json['stack'] as String? ?? '',
        facts: {
          if (json['facts'] is Map)
            for (final e in (json['facts'] as Map).entries)
              if (e.key is String && e.value is String) e.key as String: e.value as String,
        },
        at: DateTime.fromMillisecondsSinceEpoch((json['at'] as num?)?.toInt() ?? 0),
      );

  static String _fnv1a(String text) {
    var hash = 0xcbf29ce484222325;
    for (final unit in utf8.encode(text)) {
      hash = (hash ^ unit) * 0x100000001b3;
    }
    return (hash & 0xffffffffffff).toRadixString(16).padLeft(12, '0');
  }
}

/// Which errors are worth a report. The ones the user can fix on their own (a wrong key, no network,
/// a rate limit, a provider that is down, a stop) would only fill the issues.
abstract final class ErrorPolicy {
  static bool shouldReport(String kind, String text) {
    if (kind == 'test') return true;
    final t = text.toLowerCase();
    // an error that was not caught is a bug, unless it is the network failing (a connection that dropped
    // in a background request)
    if (kind == 'crash') {
      const network = ['socketexception', 'failed host lookup', 'handshakeexception', 'timeoutexception', 'clientexception', 'connection closed', 'connection reset', 'connection refused', 'network is unreachable'];
      return !network.any(t.contains);
    }
    const theirs = [
      'http 401', 'http 403', 'http 404', 'http 408', 'http 429', 'http 500', 'http 502', 'http 503', 'http 504',
      'apiキー', 'timeout', 'タイムアウト', 'socketexception', 'failed host lookup', 'connection',
      '通信に失敗', '回数制限', 'ほかのチャット', '送る前', '会話が長すぎ', 'トークン',
    ];
    if (theirs.any(t.contains)) return false;
    // a request the provider refused as malformed, a reply the app could not read (or that came back
    // empty after the retries: a model and the app that do not fit), or an exception of the program
    // itself: these are the app's to fix
    const ours = ['http 400', 'http 422', 'not json', '返信が空', 'exception', 'bad state', 'typeerror', 'rangeerror', 'nosuchmethod', "type '", 'unexpected'];
    return ours.any(t.contains);
  }
}

/// Takes out of a text what must not leave the device. It errs on the side of taking too much.
abstract final class ErrorRedactor {
  static String redact(String input) {
    var text = input;
    // a key or a token written as a header, a field or a query value
    text = text.replaceAllMapped(
      RegExp(r'''(authorization|api[_-]?key|apikey|token|secret|password|passwd|x-api-key|access[_-]?token)(["']?\s*[:=]\s*["']?)(bearer\s+)?[^\s"',;&}\]]+''', caseSensitive: false),
      (m) => '${m.group(1)}${m.group(2)}${m.group(3) ?? ''}[removed]',
    );
    text = text.replaceAll(RegExp(r'bearer\s+[A-Za-z0-9._~+/=-]{8,}', caseSensitive: false), 'Bearer [removed]');
    // the well-known shapes of keys
    text = text.replaceAll(RegExp(r'\b(sk|pk|rk)-[A-Za-z0-9_-]{8,}'), '[key]');
    text = text.replaceAll(RegExp(r'\b(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})'), '[key]');
    text = text.replaceAll(RegExp(r'\bAIza[0-9A-Za-z_-]{20,}'), '[key]');
    text = text.replaceAll(RegExp(r'\b(xox[abprs]-[A-Za-z0-9-]{10,})'), '[key]');
    // any other long unbroken run of key-like characters
    text = text.replaceAll(RegExp(r'\b[A-Za-z0-9_-]{32,}\b'), '[long-token]');
    // addresses: keep the host, drop the login, the path and the query (they may carry ids and keys)
    text = text.replaceAllMapped(RegExp(r'(https?)://([^\s/?#"\x27)>\]]+)([^\s"\x27)>\]]*)'), (m) {
      var host = m.group(2)!;
      final at = host.lastIndexOf('@');
      if (at >= 0) host = host.substring(at + 1);
      return '${m.group(1)}://$host/…';
    });
    text = text.replaceAll(RegExp(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'), '[email]');
    // places on the device: the user's name is in them
    text = text.replaceAll(RegExp(r'/home/[^/\s]+'), '/home/[user]');
    text = text.replaceAll(RegExp(r'/Users/[^/\s]+'), '/Users/[user]');
    text = text.replaceAll(RegExp(r'[A-Za-z]:\\Users\\[^\\\s]+'), r'C:\Users\[user]');
    text = text.replaceAll(RegExp(r'/data/(user|data)/\d+/[^/\s]+'), '/data/[app]');
    text = text.replaceAll(RegExp(r'/storage/emulated/\d+'), '/storage/[user]');
    text = text.replaceAll(RegExp(r'/var/mobile/Containers/[^\s]+'), '/[container]');
    return text;
  }

  static String cut(String text, int max) {
    final t = text.trim();
    if (t.length <= max) return t;
    return '${t.substring(0, max)}…';
  }

  /// The frames of a stack trace that are inside the app (`package:arce_ai/…`), at most [maxFrames],
  /// with their line numbers; the frames of the framework and of other packages say nothing about
  /// the app's own bug, and the rest of the trace may name places on the device.
  static String appFrames(String stack, {required int maxFrames}) {
    final frames = <String>[];
    for (final line in stack.split('\n')) {
      final t = line.trim();
      if (t.contains('package:arce_ai/')) {
        frames.add(redact(t.replaceAll(RegExp(r'^#\d+\s+'), '')));
        if (frames.length >= maxFrames) break;
      }
    }
    return frames.join('\n');
  }
}
