import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../core/error_report.dart';

/// What the reporter needs from the settings, read at the time of each report.
class ErrorReportConfig {
  const ErrorReportConfig({required this.enabled, required this.repo, required this.token, this.minHours = 6, this.maxPerHour = 5});

  final bool enabled;

  /// `owner/name`.
  final String repo;
  final String token;

  /// The same problem gets a new comment at most this often (hours); in between it is only counted.
  final int minHours;

  /// All reports together, per hour.
  final int maxPerHour;

  static final _repoPattern = RegExp(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$');

  bool get repoValid => _repoPattern.hasMatch(repo.trim());
  bool get ready => enabled && token.trim().isNotEmpty && repoValid;

  /// Why nothing is sent, in words; null when it is ready.
  String? get problem {
    if (!enabled) return '送信はオフです';
    if (token.trim().isEmpty) return 'トークンが未設定です';
    if (!repoValid) return '送り先のリポジトリ（owner/name）が正しくありません';
    return null;
  }
}

/// How one report ended.
class ReportOutcome {
  const ReportOutcome(this.status, {this.ok = false, this.issue});

  /// For the screen.
  final String status;
  final bool ok;
  final int? issue;
}

/// One line of the list of recent reports on the settings screen.
class ReportEntry {
  const ReportEntry(this.report, this.status);
  final ErrorReport report;
  final String status;
}

/// Sends error reports to a GitHub issue with the user's own token (Issues: write on that one
/// repository is enough). It is careful, because it runs by itself:
///
/// - the same problem is one issue: the next time it only adds a comment, and at most every few hours;
/// - all together at most a few reports an hour, whatever happens;
/// - a refusal of the token or of the repository stops the sending until the setting changes;
/// - a report that could not be sent (no network, a server error) waits, up to 20, and is tried again.
class ErrorReporter extends ChangeNotifier {
  ErrorReporter({required this.prefs, required this.config, http.Client? client, DateTime Function()? now})
      : _client = client ?? http.Client(),
        _now = now ?? DateTime.now {
    _load();
  }

  static const _key = 'errorReports.v1';
  static const _maxQueue = 20;
  static const _maxRecent = 20;

  final SharedPreferences prefs;
  final http.Client _client;
  final DateTime Function() _now;
  /// What the settings say now.
  final ErrorReportConfig Function() config;

  /// signature -> {number, lastCommentAt, count}
  final Map<String, Map<String, int>> _issues = {};
  final List<int> _sent = []; // when each report was sent (epoch ms)
  final List<ErrorReport> _queue = [];
  final List<ReportEntry> _recent = [];

  /// The token and repository the last refusal was for; nothing is sent for them until they change.
  String _refusedFor = '';

  List<ReportEntry> get recent => List.unmodifiable(_recent.reversed);

  void _load() {
    try {
      final raw = prefs.getString(_key);
      if (raw == null) return;
      final json = jsonDecode(raw) as Map;
      for (final e in (json['issues'] as Map? ?? const {}).entries) {
        final v = e.value as Map;
        _issues[e.key as String] = {
          'number': (v['number'] as num).toInt(),
          'lastCommentAt': (v['lastCommentAt'] as num?)?.toInt() ?? 0,
          'count': (v['count'] as num?)?.toInt() ?? 1,
        };
      }
      _sent.addAll([for (final t in (json['sent'] as List? ?? const [])) (t as num).toInt()]);
      for (final q in (json['queue'] as List? ?? const [])) {
        _queue.add(ErrorReport.fromJson((q as Map).cast()));
      }
    } catch (_) {
      // a damaged note only means the reports start afresh
    }
  }

  Future<void> _save() => prefs.setString(
        _key,
        jsonEncode({
          'issues': _issues,
          'sent': _sent,
          'queue': [for (final q in _queue) q.toJson()],
        }),
      );

  void _note(ErrorReport report, String status) {
    _recent.add(ReportEntry(report, status));
    while (_recent.length > _maxRecent) {
      _recent.removeAt(0);
    }
    notifyListeners();
  }

  String _refusalKey(ErrorReportConfig c) => '${c.repo.trim()}|${c.token.hashCode}';

  /// Sends [report] (or counts it, or leaves it waiting). Never throws.
  Future<ReportOutcome> report(ErrorReport report) async {
    final c = config();
    final problem = c.problem;
    if (problem != null) {
      _note(report, '送りません（$problem）');
      return ReportOutcome(problem);
    }
    if (_refusedFor == _refusalKey(c)) {
      _note(report, '送りません（トークンかリポジトリが断られました。設定を直すと再開します）');
      return const ReportOutcome('refused');
    }
    final hourAgo = _now().millisecondsSinceEpoch - const Duration(hours: 1).inMilliseconds;
    _sent.removeWhere((t) => t < hourAgo);
    if (_sent.length >= c.maxPerHour) {
      _note(report, '送りません（1 時間の上限 ${c.maxPerHour} 件に達しました）');
      return const ReportOutcome('rate-limited');
    }
    return _send(report, c);
  }

  Future<ReportOutcome> _send(ErrorReport report, ErrorReportConfig c) async {
    final nowMs = _now().millisecondsSinceEpoch;
    final known = _issues[report.signature];
    try {
      if (known != null) {
        known['count'] = (known['count'] ?? 1) + 1;
        final gap = Duration(hours: c.minHours < 1 ? 1 : c.minHours).inMilliseconds;
        if (nowMs - (known['lastCommentAt'] ?? 0) < gap) {
          await _save();
          _note(report, '同じ問題（issue #${known['number']}）に数えました（${known['count']} 回目）');
          return ReportOutcome('counted', ok: true, issue: known['number']);
        }
        final response = await _post(c, '/repos/${c.repo.trim()}/issues/${known['number']}/comments', {'body': report.comment(known['count']!)});
        if (response.statusCode == 201) {
          known['lastCommentAt'] = nowMs;
          _sent.add(nowMs);
          await _save();
          _note(report, 'issue #${known['number']} にコメントしました（${known['count']} 回目）');
          return ReportOutcome('commented', ok: true, issue: known['number']);
        }
        // the issue was deleted or cannot take comments: it is a new problem again
        if (response.statusCode == 404 || response.statusCode == 410) {
          _issues.remove(report.signature);
          return await _create(report, c, nowMs);
        }
        return _failure(report, c, response.statusCode);
      }
      return await _create(report, c, nowMs);
    } on Object catch (e) {
      return _wait(report, 'つながりませんでした（${ErrorRedactor.cut(ErrorRedactor.redact('$e'), 80)}）。あとで送り直します');
    }
  }

  Future<ReportOutcome> _create(ErrorReport report, ErrorReportConfig c, int nowMs) async {
    try {
      final response = await _post(c, '/repos/${c.repo.trim()}/issues', {'title': report.title, 'body': report.body});
      if (response.statusCode == 201) {
        final number = (jsonDecode(response.body) as Map)['number'] as num;
        _issues[report.signature] = {'number': number.toInt(), 'lastCommentAt': nowMs, 'count': 1};
        _sent.add(nowMs);
        await _save();
        _note(report, 'issue #$number を作りました');
        return ReportOutcome('created', ok: true, issue: number.toInt());
      }
      return _failure(report, c, response.statusCode);
    } on Object catch (e) {
      return _wait(report, 'つながりませんでした（${ErrorRedactor.cut(ErrorRedactor.redact('$e'), 80)}）。あとで送り直します');
    }
  }

  ReportOutcome _failure(ErrorReport report, ErrorReportConfig c, int status) {
    if (status == 401 || status == 403 || status == 404) {
      // the token or the repository is wrong (or the token cannot write issues): trying again would only fail
      _refusedFor = _refusalKey(c);
      _note(report, '断られました（HTTP $status）。トークンの権限（Issues の書き込み）とリポジトリを確かめてください');
      return ReportOutcome('refused-$status');
    }
    if (status == 429 || status >= 500) return _wait(report, '送れませんでした（HTTP $status）。あとで送り直します');
    _note(report, '送れませんでした（HTTP $status）。この報告は捨てます');
    return ReportOutcome('dropped-$status');
  }

  ReportOutcome _wait(ErrorReport report, String status) {
    _queue.add(report);
    while (_queue.length > _maxQueue) {
      _queue.removeAt(0);
    }
    unawaited(_save());
    _note(report, status);
    return const ReportOutcome('queued');
  }

  /// Sends the reports that waited (no network earlier). Call it when the app starts and after a
  /// report went through.
  Future<void> flush() async {
    final c = config();
    if (!c.ready || _refusedFor == _refusalKey(c) || _queue.isEmpty) return;
    final waiting = List.of(_queue);
    _queue.clear();
    for (final r in waiting) {
      final outcome = await report(r);
      if (outcome.status == 'queued') break; // still no network: the rest waits as it is
    }
  }

  /// Sends a report that says it is a test, to find out whether the token and the repository work.
  Future<ReportOutcome> test({Map<String, String> facts = const {}}) {
    final at = _now();
    return report(ErrorReport.of(kind: 'test', message: 'Test report from ARCE.AI (${at.toUtc().toIso8601String()}). Nothing is wrong.', facts: facts, at: at));
  }

  Future<http.Response> _post(ErrorReportConfig c, String path, Map<String, Object?> body) {
    return _client
        .post(
          Uri.parse('https://api.github.com$path'),
          headers: {
            'Authorization': 'Bearer ${c.token.trim()}',
            'Accept': 'application/vnd.github+json',
            'X-GitHub-Api-Version': '2022-11-28',
            'User-Agent': 'ARCE.AI',
            'Content-Type': 'application/json; charset=utf-8',
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 20));
  }
}
