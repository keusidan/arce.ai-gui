// The real GitHub behind [BotGitHub]: the REST API, called with the token of the bot's GitHub App.
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'bot_core.dart';
import 'bot_runner.dart';

class GitHubException implements Exception {
  GitHubException(this.message);
  final String message;

  @override
  String toString() => message;
}

class RestGitHub implements BotGitHub {
  RestGitHub({required this.repository, required this.token, http.Client? client, this.api = 'https://api.github.com'})
      : _client = client ?? http.Client();

  /// `owner/name`.
  final String repository;
  final String token;
  final String api;
  final http.Client _client;

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $token',
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'Content-Type': 'application/json',
        'User-Agent': 'arce-bot',
      };

  Uri _uri(String path, [Map<String, String>? query]) => Uri.parse('$api/repos/$repository$path').replace(queryParameters: query);

  Future<Object?> _get(String path, [Map<String, String>? query]) async {
    final response = await _client.get(_uri(path, query), headers: _headers).timeout(const Duration(seconds: 60));
    if (response.statusCode == 404) return null;
    if (response.statusCode >= 300) throw GitHubException('GET $path: HTTP ${response.statusCode} ${_short(response.body)}');
    return jsonDecode(utf8.decode(response.bodyBytes));
  }

  Future<Object?> _send(String method, String path, Object body) async {
    final request = http.Request(method, _uri(path))
      ..headers.addAll(_headers)
      ..body = jsonEncode(body);
    final streamed = await _client.send(request).timeout(const Duration(seconds: 60));
    final response = await http.Response.fromStream(streamed);
    if (response.statusCode >= 300) throw GitHubException('$method $path: HTTP ${response.statusCode} ${_short(response.body)}');
    return response.body.isEmpty ? null : jsonDecode(utf8.decode(response.bodyBytes));
  }

  static String _short(String text) => text.length <= 300 ? text : '${text.substring(0, 300)}…';

  @override
  Future<ThreadInfo> thread(int number) async {
    final issue = await _get('/issues/$number');
    if (issue is! Map) throw GitHubException('there is no issue or pull request #$number');
    final isPull = issue['pull_request'] != null;
    var headRef = '';
    var sameRepo = false;
    if (isPull) {
      final pull = await _get('/pulls/$number');
      if (pull is Map && pull['head'] is Map) {
        final head = pull['head'] as Map;
        headRef = '${head['ref'] ?? ''}';
        final repo = head['repo'];
        sameRepo = repo is Map && repo['full_name'] == repository;
      }
    }
    return ThreadInfo(
      title: '${issue['title'] ?? ''}',
      body: '${issue['body'] ?? ''}',
      isPullRequest: isPull,
      headRef: headRef,
      headIsThisRepository: sameRepo,
      open: issue['state'] == 'open',
    );
  }

  @override
  Future<List<(String, String)>> comments(int number, {int limit = 20}) async {
    final list = await _get('/issues/$number/comments', {'per_page': '100'});
    if (list is! List) return const [];
    final all = [
      for (final item in list)
        if (item is Map)
          (item['user'] is Map ? '${(item['user'] as Map)['login']}' : 'unknown', '${item['body'] ?? ''}'),
    ];
    return all.length <= limit ? all : all.sublist(all.length - limit);
  }

  @override
  Future<String> defaultBranch() async {
    final repo = await _get('');
    if (repo is! Map || repo['default_branch'] is! String) throw GitHubException('the repository was not found');
    return repo['default_branch'] as String;
  }

  @override
  Future<List<String>> paths(String ref) async {
    final tree = await _get('/git/trees/${Uri.encodeComponent(ref)}', {'recursive': '1'});
    if (tree is! Map || tree['tree'] is! List) return const [];
    return [
      for (final item in tree['tree'] as List)
        if (item is Map && item['type'] == 'blob' && item['path'] is String) item['path'] as String,
    ];
  }

  @override
  Future<String?> fileText(String path, String ref) async {
    final file = await _get('/contents/${path.split('/').map(Uri.encodeComponent).join('/')}', {'ref': ref});
    if (file is! Map || file['type'] != 'file' || file['content'] is! String || file['encoding'] != 'base64') return null;
    try {
      return utf8.decode(base64.decode((file['content'] as String).replaceAll('\n', '')));
    } on FormatException {
      return null; // not text
    }
  }

  Future<String?> _branchSha(String branch) async {
    final ref = await _get('/git/ref/heads/${branch.split('/').map(Uri.encodeComponent).join('/')}');
    if (ref is! Map || ref['object'] is! Map) return null;
    return '${(ref['object'] as Map)['sha']}';
  }

  /// The only branches the bot writes to: its own. Whatever the caller passes, `main` and every other
  /// branch are out of reach (the token of the App could write there; the bot must not).
  static final _botBranch = RegExp(r'^bot/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$');

  static bool isBotBranch(String branch) => _botBranch.hasMatch(branch) && !branch.contains('..') && !branch.endsWith('.lock') && !branch.endsWith('/');

  @override
  Future<String> commit({required String branch, required String baseRef, required String message, required List<BotEdit> edits}) async {
    if (!isBotBranch(branch)) throw GitHubException('the bot only writes to branches named bot/…, not "$branch"');
    // a new branch starts at the tip of the base; an existing one (the bot's own pull request) is built on
    var parent = await _branchSha(branch);
    final isNew = parent == null;
    parent ??= await _branchSha(baseRef);
    if (parent == null) throw GitHubException('the base branch $baseRef was not found');
    final parentCommit = await _get('/git/commits/$parent');
    if (parentCommit is! Map || parentCommit['tree'] is! Map) throw GitHubException('the parent commit was not readable');
    final baseTree = '${(parentCommit['tree'] as Map)['sha']}';

    final entries = <Map<String, Object?>>[];
    for (final edit in edits) {
      final blob = await _send('POST', '/git/blobs', {'content': edit.content, 'encoding': 'utf-8'});
      entries.add({'path': edit.path, 'mode': '100644', 'type': 'blob', 'sha': (blob as Map)['sha']});
    }
    final tree = await _send('POST', '/git/trees', {'base_tree': baseTree, 'tree': entries});
    final commit = await _send('POST', '/git/commits', {
      'message': message,
      'tree': (tree as Map)['sha'],
      'parents': [parent],
    });
    final sha = '${(commit as Map)['sha']}';
    if (isNew) {
      await _send('POST', '/git/refs', {'ref': 'refs/heads/$branch', 'sha': sha});
    } else {
      // never forced: a branch that moved meanwhile is an error, not something to overwrite
      await _send('PATCH', '/git/refs/heads/${branch.split('/').map(Uri.encodeComponent).join('/')}', {'sha': sha, 'force': false});
    }
    return sha;
  }

  @override
  Future<String> openDraftPullRequest({required String head, required String base, required String title, required String body}) async {
    final pull = await _send('POST', '/pulls', {'title': title, 'head': head, 'base': base, 'body': body, 'draft': true});
    return '${(pull as Map)['html_url']}';
  }

  @override
  Future<void> comment(int number, String body) async {
    await _send('POST', '/issues/$number/comments', {'body': body});
  }
}
