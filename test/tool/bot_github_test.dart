import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../../tool/bot/bot_core.dart';
import '../../tool/bot/bot_github.dart';
import '../../tool/bot/bot_model.dart';

void main() {
  group('RestGitHub', () {
    late List<http.Request> seen;
    late Map<String, Object? Function(http.Request)> routes;

    RestGitHub make() {
      seen = [];
      final client = MockClient((request) async {
        seen.add(request);
        final key = '${request.method} ${request.url.path}';
        final handler = routes[key];
        if (handler == null) return http.Response('{"message":"no route $key"}', 404);
        final body = handler(request);
        return http.Response(jsonEncode(body), body is Map && body['__status'] is int ? body['__status'] as int : 200);
      });
      return RestGitHub(repository: 'o/r', token: 'tok', client: client);
    }

    test('every request carries the app\'s token and the API version', () async {
      routes = {'GET /repos/o/r': (_) => {'default_branch': 'main'}};
      final github = make();
      expect(await github.defaultBranch(), 'main');
      expect(seen.single.headers['Authorization'], 'Bearer tok');
      expect(seen.single.headers['X-GitHub-Api-Version'], isNotEmpty);
    });

    test('the thread of a pull request says its branch and whether it is in this repository', () async {
      routes = {
        'GET /repos/o/r/issues/5': (_) => {'title': 'T', 'body': 'B', 'state': 'open', 'pull_request': {}},
        'GET /repos/o/r/pulls/5': (_) => {'head': {'ref': 'bot/issue-1', 'repo': {'full_name': 'o/r'}}},
      };
      final thread = await make().thread(5);
      expect((thread.title, thread.isPullRequest, thread.headRef, thread.headIsThisRepository, thread.open), ('T', true, 'bot/issue-1', true, true));

      routes = {
        'GET /repos/o/r/issues/5': (_) => {'title': 'T', 'body': null, 'state': 'closed', 'pull_request': {}},
        'GET /repos/o/r/pulls/5': (_) => {'head': {'ref': 'bot/issue-1', 'repo': {'full_name': 'someone/fork'}}},
      };
      final fork = await make().thread(5);
      expect((fork.headIsThisRepository, fork.open, fork.body), (false, false, 'null'.replaceAll('null', '')), reason: 'a fork is not this repository');
    });

    test('the newest comments, oldest first', () async {
      routes = {
        'GET /repos/o/r/issues/5/comments': (_) => [
              for (var i = 1; i <= 30; i++) {'user': {'login': 'u$i'}, 'body': 'c$i'},
            ],
      };
      final comments = await make().comments(5, limit: 3);
      expect(comments, [('u28', 'c28'), ('u29', 'c29'), ('u30', 'c30')]);
    });

    test('paths are the files of the tree; a file is decoded from base64; a file that is not text is null', () async {
      routes = {
        'GET /repos/o/r/git/trees/main': (_) => {
              'tree': [
                {'type': 'blob', 'path': 'lib/a.dart'},
                {'type': 'tree', 'path': 'lib'},
                {'type': 'blob', 'path': 'README.md'},
              ],
            },
        'GET /repos/o/r/contents/lib/a.dart': (_) => {'type': 'file', 'encoding': 'base64', 'content': '${base64.encode(utf8.encode('日本語\n'))}\n'},
        'GET /repos/o/r/contents/img.png': (_) => {'type': 'file', 'encoding': 'base64', 'content': base64.encode([0xff, 0xfe, 0x00])},
      };
      final github = make();
      expect(await github.paths('main'), ['lib/a.dart', 'README.md']);
      expect(await github.fileText('lib/a.dart', 'main'), '日本語\n');
      expect(await github.fileText('img.png', 'main'), isNull);
      expect(await github.fileText('missing', 'main'), isNull);
    });

    test('a commit on a new branch: blobs, a tree on the base tree, a commit on the base tip, and a new ref', () async {
      routes = {
        'GET /repos/o/r/git/ref/heads/bot/issue-1-x': (_) => {'__status': 404},
        'GET /repos/o/r/git/ref/heads/main': (_) => {'object': {'sha': 'base-sha'}},
        'GET /repos/o/r/git/commits/base-sha': (_) => {'tree': {'sha': 'base-tree'}},
        'POST /repos/o/r/git/blobs': (r) => {'sha': 'blob-${(jsonDecode(r.body) as Map)['content'].hashCode % 1000}'},
        'POST /repos/o/r/git/trees': (_) => {'sha': 'new-tree'},
        'POST /repos/o/r/git/commits': (_) => {'sha': 'new-commit'},
        'POST /repos/o/r/git/refs': (_) => {'ref': 'refs/heads/bot/issue-1-x'},
      };
      final github = make();
      final sha = await github.commit(
        branch: 'bot/issue-1-x',
        baseRef: 'main',
        message: 'msg',
        edits: const [BotEdit('lib/a.dart', 'a'), BotEdit('lib/b.dart', 'b')],
      );
      expect(sha, 'new-commit');
      final tree = jsonDecode(seen.firstWhere((r) => r.url.path.endsWith('/git/trees')).body) as Map;
      expect(tree['base_tree'], 'base-tree');
      expect((tree['tree'] as List).map((e) => (e as Map)['path']), ['lib/a.dart', 'lib/b.dart']);
      final commit = jsonDecode(seen.firstWhere((r) => r.url.path.endsWith('/git/commits') && r.method == 'POST').body) as Map;
      expect(commit['parents'], ['base-sha']);
      expect(commit['tree'], 'new-tree');
      final ref = jsonDecode(seen.last.body) as Map;
      expect((seen.last.method, ref['ref'], ref['sha']), ('POST', 'refs/heads/bot/issue-1-x', 'new-commit'));
    });

    test('a commit on a branch that exists builds on its tip and moves it, never forced', () async {
      routes = {
        'GET /repos/o/r/git/ref/heads/bot/issue-1-x': (_) => {'object': {'sha': 'tip'}},
        'GET /repos/o/r/git/commits/tip': (_) => {'tree': {'sha': 'tip-tree'}},
        'POST /repos/o/r/git/blobs': (_) => {'sha': 'b'},
        'POST /repos/o/r/git/trees': (_) => {'sha': 't'},
        'POST /repos/o/r/git/commits': (_) => {'sha': 'c'},
        'PATCH /repos/o/r/git/refs/heads/bot/issue-1-x': (_) => {},
      };
      final github = make();
      await github.commit(branch: 'bot/issue-1-x', baseRef: 'main', message: 'm', edits: const [BotEdit('lib/a.dart', 'a')]);
      final commit = jsonDecode(seen.firstWhere((r) => r.url.path.endsWith('/git/commits') && r.method == 'POST').body) as Map;
      expect(commit['parents'], ['tip']);
      final patch = seen.last;
      expect(patch.method, 'PATCH');
      expect((jsonDecode(patch.body) as Map)['force'], false);
    });

    test('the bot writes to bot/ branches only, whatever it is asked', () async {
      routes = {};
      final github = make();
      for (final branch in ['main', 'master', 'release', 'feature/x', 'bot', 'bot/', 'bot/..', 'bot/a..b', 'bot/x.lock', 'bot/x y', 'bot/\u0000', 'refs/heads/main', 'xbot/y', '/bot/x']) {
        expect(RestGitHub.isBotBranch(branch), isFalse, reason: branch);
        await expectLater(github.commit(branch: branch, baseRef: 'main', message: 'm', edits: const [BotEdit('lib/a.dart', 'a')]), throwsA(isA<GitHubException>()), reason: branch);
      }
      expect(seen, isEmpty, reason: 'nothing was sent to GitHub for any of them');
      for (final branch in ['bot/issue-1', 'bot/issue-12-add-a-setting', 'bot/a/b.c']) {
        expect(RestGitHub.isBotBranch(branch), isTrue, reason: branch);
      }
    });

    test('a draft pull request, and a comment', () async {
      routes = {
        'POST /repos/o/r/pulls': (r) => {'html_url': 'https://github.com/o/r/pull/9', 'sent': jsonDecode(r.body)},
        'POST /repos/o/r/issues/5/comments': (_) => {},
      };
      final github = make();
      expect(await github.openDraftPullRequest(head: 'bot/x', base: 'main', title: 'T', body: 'B'), 'https://github.com/o/r/pull/9');
      expect((jsonDecode(seen.first.body) as Map)['draft'], true);
      await github.comment(5, 'hello');
      expect((jsonDecode(seen.last.body) as Map)['body'], 'hello');
    });

    test('an error from GitHub is an error with its status, not a silent nothing', () async {
      routes = {'POST /repos/o/r/issues/5/comments': (_) => {'__status': 403, 'message': 'forbidden'}};
      await expectLater(make().comment(5, 'x'), throwsA(isA<GitHubException>().having((e) => e.message, 'message', contains('HTTP 403'))));
    });
  });

  group('OpenAiChatModel', () {
    test('sends the two messages with the key, and returns the text of the first choice', () async {
      late http.Request seen;
      final model = OpenAiChatModel(
        url: 'https://llm.example/v1/chat/completions',
        apiKey: 'k',
        model: 'm1',
        extraBody: const {'reasoning_effort': 'low'},
        client: MockClient((request) async {
          seen = request;
          return http.Response(jsonEncode({'choices': [{'message': {'content': 'hello'}}]}), 200);
        }),
      );
      expect(await model.ask(system: 'S', user: 'U'), 'hello');
      expect(seen.headers['Authorization'], 'Bearer k');
      final body = jsonDecode(seen.body) as Map;
      expect(body['model'], 'm1');
      expect(body['reasoning_effort'], 'low');
      expect((body['messages'] as List).map((m) => (m as Map)['role']), ['system', 'user']);
    });

    test('an error or an answer without text is an error', () async {
      OpenAiChatModel with_(http.Response response) => OpenAiChatModel(url: 'https://x.example', apiKey: 'k', model: 'm', client: MockClient((_) async => response));
      await expectLater(with_(http.Response('nope', 500)).ask(system: 's', user: 'u'), throwsA(isA<StateError>().having((e) => e.message, 'message', contains('HTTP 500'))));
      await expectLater(with_(http.Response('{"choices":[]}', 200)).ask(system: 's', user: 'u'), throwsA(isA<StateError>()));
    });
  });
}
