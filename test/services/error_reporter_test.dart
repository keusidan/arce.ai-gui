import 'dart:convert';

import 'package:arce_ai/core/error_report.dart';
import 'package:arce_ai/services/error_reporter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// GitHub as the test plays it: it records every request and answers from a script.
class FakeGitHub {
  final requests = <({String method, String path, Map<String, Object?> body, Map<String, String> headers})>[];
  var nextIssue = 100;

  /// Decides the answer for a request; null means the normal one (201 and a number).
  http.Response? Function(String path)? override;
  Object? failWith;

  MockClient get client => MockClient((request) async {
        if (failWith != null) throw failWith!;
        requests.add((method: request.method, path: request.url.path, body: jsonDecode(request.body) as Map<String, Object?>, headers: request.headers));
        final custom = override?.call(request.url.path);
        if (custom != null) return custom;
        return http.Response(jsonEncode({'number': nextIssue++}), 201);
      });
}

ErrorReport report(String message, {String kind = 'chat', DateTime? at}) => ErrorReport.of(kind: kind, message: message, at: at ?? DateTime.utc(2026, 10, 27), facts: {'app': '0.11.0'});

void main() {
  late FakeGitHub github;
  late DateTime now;
  var config = const ErrorReportConfig(enabled: true, repo: 'keusidan/arce.ai', token: 'github_pat_test');

  ErrorReporter make() {
    return ErrorReporter(prefs: _prefs, client: github.client, now: () => now, config: () => config);
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _prefs = await SharedPreferences.getInstance();
    github = FakeGitHub();
    now = DateTime.utc(2026, 10, 27, 12);
    config = const ErrorReportConfig(enabled: true, repo: 'keusidan/arce.ai', token: 'github_pat_test');
  });

  test('新しい問題は、issue を作る。トークンはヘッダーだけ、題名と本文は伏せ字の報告', () async {
    final outcome = await make().report(report('プロバイダが失敗しました（HTTP 400）: Unknown parameter'));
    expect(outcome.ok, isTrue);
    expect(outcome.issue, 100);
    final request = github.requests.single;
    expect((request.method, request.path), ('POST', '/repos/keusidan/arce.ai/issues'));
    expect(request.headers['Authorization'], 'Bearer github_pat_test');
    expect(request.headers['X-GitHub-Api-Version'], '2022-11-28');
    expect(request.body['title'], allOf(startsWith('[auto/chat]'), contains('HTTP 400')));
    expect(request.body['body'], allOf(contains('Unknown parameter'), contains('contains no conversation')));
    expect('${request.body}', isNot(contains('github_pat_test')), reason: 'the token never goes into the text');
  });

  test('同じ問題は、同じ issue に数える。間隔が過ぎたらコメントを足す（その 2 回目で 2 回目と書く）', () async {
    final reporter = make();
    await reporter.report(report('HTTP 400 at 12:01'));
    now = now.add(const Duration(minutes: 30));
    final counted = await reporter.report(report('HTTP 400 at 12:31'));
    expect(counted.status, 'counted');
    expect(github.requests, hasLength(1), reason: 'only counted: no new request in the gap');

    now = now.add(const Duration(hours: 7));
    final commented = await reporter.report(report('HTTP 400 at 19:40'));
    expect(commented.status, 'commented');
    final request = github.requests.last;
    expect(request.path, '/repos/keusidan/arce.ai/issues/100/comments');
    expect(request.body['body'], contains('3 times'), reason: 'three times in all since the first report');
  });

  test('覚えは保存され、次に起動しても同じ issue に数える', () async {
    await make().report(report('HTTP 400'));
    final later = make(); // the app started again
    final outcome = await later.report(report('HTTP 400'));
    expect((outcome.status, outcome.issue), ('counted', 100));
    expect(github.requests, hasLength(1));
  });

  test('issue が消されていたら（コメントが 404）、新しい issue を作り直す', () async {
    final reporter = make();
    await reporter.report(report('HTTP 400'));
    now = now.add(const Duration(hours: 7));
    github.override = (path) => path.endsWith('/comments') ? http.Response('{}', 404) : null;
    final outcome = await reporter.report(report('HTTP 400'));
    expect(outcome.status, 'created');
    expect(outcome.issue, 101);
  });

  test('1 時間の件数の上限を超えたら送らない。1 時間たつとまた送れる', () async {
    config = const ErrorReportConfig(enabled: true, repo: 'keusidan/arce.ai', token: 't', maxPerHour: 2);
    final reporter = make();
    expect((await reporter.report(report('エラー A HTTP 400'))).ok, isTrue);
    expect((await reporter.report(report('エラー B HTTP 422'))).ok, isTrue);
    expect((await reporter.report(report('エラー C not JSON'))).status, 'rate-limited');
    expect(github.requests, hasLength(2));
    now = now.add(const Duration(minutes: 61));
    expect((await reporter.report(report('エラー C not JSON'))).ok, isTrue);
  });

  test('オフ・トークン無し・リポジトリの書き方が違う、のときは何も送らない', () async {
    for (final c in [
      const ErrorReportConfig(enabled: false, repo: 'a/b', token: 't'),
      const ErrorReportConfig(enabled: true, repo: 'a/b', token: ' '),
      const ErrorReportConfig(enabled: true, repo: 'https://github.com/a/b', token: 't'),
      const ErrorReportConfig(enabled: true, repo: 'a/b/c', token: 't'),
    ]) {
      config = c;
      final outcome = await make().report(report('HTTP 400'));
      expect(outcome.ok, isFalse);
      expect(c.problem, isNotNull);
    }
    expect(github.requests, isEmpty);
  });

  test('トークンやリポジトリが断られたら（401・403・404）、設定が変わるまで送らない', () async {
    final reporter = make();
    github.override = (path) => http.Response('{"message":"Resource not accessible"}', 403);
    expect((await reporter.report(report('エラー A HTTP 400'))).status, 'refused-403');
    expect(github.requests, hasLength(1));
    // the same token and repository: not even tried
    expect((await reporter.report(report('エラー B HTTP 422'))).status, 'refused');
    expect(github.requests, hasLength(1));
    // a new token: tried again
    config = const ErrorReportConfig(enabled: true, repo: 'keusidan/arce.ai', token: 'a_new_token');
    github.override = null;
    expect((await reporter.report(report('エラー B HTTP 422'))).ok, isTrue);
  });

  test('つながらないときや、サーバーの失敗（5xx）では、報告は待たせて、あとで送る（20 件まで）', () async {
    final reporter = make();
    github.failWith = Exception('no network');
    expect((await reporter.report(report('エラー A HTTP 400'))).status, 'queued');
    github.failWith = null;
    github.override = (path) => http.Response('', 503);
    expect((await reporter.report(report('エラー B HTTP 422'))).status, 'queued');
    expect(github.requests, hasLength(1), reason: 'the 503 reached the server; the first never did');

    github.override = null;
    await reporter.flush();
    expect(github.requests.where((r) => r.path.endsWith('/issues')), hasLength(3), reason: 'both waiting reports went out (one of them had been tried before)');
    await reporter.flush();
    expect(github.requests, hasLength(3), reason: 'nothing is sent twice');
  });

  test('待たせた報告は、アプリを閉じても残る', () async {
    github.failWith = Exception('offline');
    await make().report(report('エラー A HTTP 400'));
    github.failWith = null;
    final later = make();
    await later.flush();
    expect(github.requests.single.body['title'], contains('HTTP 400'));
  });

  test('それ以外の失敗（たとえば 422）は、その報告を捨てて、待たせない', () async {
    final reporter = make();
    github.override = (path) => http.Response('{"message":"Validation Failed"}', 422);
    expect((await reporter.report(report('HTTP 400'))).status, 'dropped-422');
    github.override = null;
    await reporter.flush();
    expect(github.requests, hasLength(1), reason: 'it was dropped, not kept');
  });

  test('テスト送信は、種類が test の報告を送る。最近の報告に、結果の文が残る', () async {
    final reporter = make();
    final outcome = await reporter.test(facts: {'app': '0.11.0'});
    expect(outcome.ok, isTrue);
    expect(github.requests.single.body['title'], startsWith('[auto/test]'));
    expect(reporter.recent.single.status, contains('issue #100'));
  });
}

late SharedPreferences _prefs;
