import 'dart:convert';

import 'package:http/http.dart' as http;

/// One workflow run of the repository, as the chat reads it (a read-only view of GitHub Actions).
class CiRun {
  const CiRun({
    required this.id,
    required this.name,
    required this.headBranch,
    required this.headSha,
    required this.event,
    required this.status,
    required this.conclusion,
    required this.createdAt,
    this.url,
  });

  factory CiRun.fromJson(Map<String, Object?> json) => CiRun(
    id: json['id'] is num ? (json['id']! as num).toInt() : 0,
    name: '${json['name'] ?? ''}',
    headBranch: '${json['head_branch'] ?? ''}',
    headSha: '${json['head_sha'] ?? ''}',
    event: '${json['event'] ?? ''}',
    status: '${json['status'] ?? ''}',
    conclusion: json['conclusion'] == null ? '' : '${json['conclusion']}',
    createdAt: '${json['created_at'] ?? ''}',
    url: json['html_url'] is String ? json['html_url']! as String : null,
  );

  final int id;
  final String name;
  final String headBranch;
  final String headSha;
  final String event;

  /// `queued` / `in_progress` / `completed`.
  final String status;

  /// `success` / `failure` / `cancelled` / `skipped` / empty while it runs.
  final String conclusion;
  final String createdAt;
  final String? url;

  bool get running => status != 'completed';
  String get shortSha => headSha.length > 7 ? headSha.substring(0, 7) : headSha;

  String describe() {
    final state = running ? '実行中（$status）' : (conclusion.isEmpty ? '終了' : conclusion);
    return '$name [${event.isEmpty ? headBranch : event}] $state · $shortSha · $createdAt';
  }
}

/// One job of a run, with the steps that failed.
class CiJob {
  const CiJob({
    required this.name,
    required this.status,
    required this.conclusion,
    this.failedSteps = const [],
    this.url,
  });

  factory CiJob.fromJson(Map<String, Object?> json) {
    final steps = json['steps'];
    return CiJob(
      name: '${json['name'] ?? ''}',
      status: '${json['status'] ?? ''}',
      conclusion: json['conclusion'] == null ? '' : '${json['conclusion']}',
      failedSteps: [
        if (steps is List)
          for (final step in steps)
            if (step is Map && (step['conclusion'] == 'failure' || step['conclusion'] == 'cancelled'))
              '${step['name'] ?? ''}（${step['conclusion']}）',
      ],
      url: json['html_url'] is String ? json['html_url']! as String : null,
    );
  }

  final String name;
  final String status;
  final String conclusion;
  final List<String> failedSteps;
  final String? url;

  bool get failed => conclusion == 'failure' || conclusion == 'timed_out';

  String describe() {
    final state = status == 'completed' ? (conclusion.isEmpty ? '終了' : conclusion) : status;
    final steps = failedSteps.isEmpty ? '' : ' — 失敗したステップ: ${failedSteps.join('、')}';
    return '$name: $state$steps';
  }
}

/// Reads GitHub Actions (runs and their jobs) so the chat can say what CI did, instead of the user
/// copying the red job by hand. Read-only: nothing here writes to GitHub.
///
/// The token is the one the user typed for the MCP server they name (the app never reads a key of
/// its own here); without one the public API is called, which works for a public repository.
class CiClient {
  CiClient({
    required this.token,
    this.owner = 'keusidan',
    this.repo = 'arce.ai-gui',
    http.Client? client,
    this.timeout = const Duration(seconds: 30),
  }) : _client = client ?? http.Client();

  final String token;
  final String owner;
  final String repo;
  final Duration timeout;
  final http.Client _client;

  /// GitHub asks for a friendlier name than the app has inside it.
  static const userAgent = 'ARCE.AI';

  Map<String, String> get headers => {
    'Accept': 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28',
    'User-Agent': userAgent,
    if (token.trim().isNotEmpty) 'Authorization': 'Bearer ${token.trim()}',
  };

  /// Whether [repository] is `owner/name` (or empty for the app's own one).
  static bool validRepo(String repository) =>
      repository.trim().isEmpty || RegExp(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$').hasMatch(repository.trim());

  /// The runs of [branch] (every one when it is empty), newest first.
  Future<List<CiRun>> runs({
    String branch = '',
    String repository = '',
    int limit = 10,
  }) async {
    final (owner, repo) = _split(repository);
    final query = {
      'per_page': '${limit.clamp(1, 30).toInt()}',
      if (branch.trim().isNotEmpty) 'branch': branch.trim(),
    };
    final json = await _get('https://api.github.com/repos/$owner/$repo/actions/runs', query);
    final raw = json['workflow_runs'];
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map) CiRun.fromJson(item.cast<String, Object?>()),
    ];
  }

  /// What the jobs of [runId] did, with the steps that failed.
  Future<List<CiJob>> jobs(int runId, {String repository = ''}) async {
    final (owner, repo) = _split(repository);
    final json = await _get('https://api.github.com/repos/$owner/$repo/actions/runs/$runId/jobs', {'per_page': '50'});
    final raw = json['jobs'];
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map) CiJob.fromJson(item.cast<String, Object?>()),
    ];
  }

  /// The answer to one request as JSON. The bytes are read as UTF-8: GitHub sends JSON without a
  /// charset, and `package:http` would fall back to Latin-1 and spoil any Japanese in it.
  Future<Map<String, Object?>> _get(String url, Map<String, String> query) async {
    final uri = Uri.parse(url).replace(queryParameters: query);
    final response = await _client.get(uri, headers: headers).timeout(timeout);
    final body = utf8.decode(response.bodyBytes, allowMalformed: true);
    if (response.statusCode != 200) {
      throw CiException(
        response.statusCode == 401 || response.statusCode == 403
            ? 'HTTP ${response.statusCode}（トークンの権限に Actions: Read があるか確かめてください）'
            : 'HTTP ${response.statusCode}',
      );
    }
    final decoded = jsonDecode(body);
    if (decoded is! Map) throw const CiException('応答が JSON ではありません');
    return decoded.cast<String, Object?>();
  }

  (String, String) _split(String repository) {
    final text = repository.trim();
    if (text.isEmpty) return (owner, repo);
    final slash = text.indexOf('/');
    return (text.substring(0, slash), text.substring(slash + 1));
  }
}

class CiException implements Exception {
  const CiException(this.message);
  final String message;

  @override
  String toString() => message;
}
