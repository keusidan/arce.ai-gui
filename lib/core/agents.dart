import 'protocol.dart';

/// An agent is a role, not a model (spec §17): extra system instructions, the tools it may
/// call, and the smallest model it is expected to work with.
class AgentDefinition {
  const AgentDefinition({
    required this.id,
    required this.displayName,
    required this.instructions,
    required this.tools,
    required this.minModelParamsB,
    required this.keywords,
  });

  final String id;
  final String displayName;
  final String instructions;
  final List<ToolDefinition> tools;

  /// Parameters in billions; small models are unreliable at tool use (spec §17.2).
  final double minModelParamsB;

  /// Lower-cased words that suggest this agent in a request.
  final List<String> keywords;
}

abstract final class Agents {
  static final general = AgentDefinition(
    id: 'general',
    displayName: 'General Chat',
    instructions: 'Answer conversationally. Use tools only when they are clearly needed.',
    tools: [
      Protocol.askUser,
      Protocol.webSearch,
      Protocol.getWeather,
      Protocol.getTime,
      Protocol.getSettings,
      Protocol.updateSettings,
      Protocol.addProvider,
    ],
    minModelParamsB: 1.7,
    keywords: const [],
  );

  static final coding = AgentDefinition(
    id: 'coding',
    displayName: 'Coding',
    instructions: 'You are writing code. Give complete, runnable files, each in its own fenced block '
        'with the language (```kotlin, ```python, ```html ...). Ask with ask_user when a key choice '
        '(language, platform, scope) is missing instead of guessing.',
    tools: [Protocol.askUser, Protocol.webSearch, Protocol.getSettings, Protocol.updateSettings, Protocol.addProvider, Protocol.delegate],
    minModelParamsB: 4.0,
    keywords: const [
      '作って', '実装', 'コード', 'プログラム', '関数', 'バグ', 'エラー', 'code', 'implement',
      'function', 'bug', 'kotlin', 'python', 'java', 'javascript', 'rust', 'c++', 'script', 'スクリプト',
    ],
  );

  static final research = AgentDefinition(
    id: 'research',
    displayName: 'Research / Search',
    instructions: 'Research the question. Search first, compare sources, and cite the URLs you rely on.',
    tools: [
      Protocol.webSearch,
      Protocol.getTime,
      Protocol.askUser,
      Protocol.getSettings,
      Protocol.updateSettings,
      Protocol.addProvider,
    ],
    minModelParamsB: 4.0,
    keywords: const ['調べ', '検索', '最新', 'ニュース', '比較', 'ソース', 'search', 'latest', 'news', 'compare', 'source'],
  );

  static final artifact = AgentDefinition(
    id: 'artifact',
    displayName: 'Artifact',
    instructions: 'Build a self-contained web page. Put all HTML, CSS and JavaScript in ONE ```html block '
        'so it can be previewed; do not load external scripts. Add a short usage note after the block.',
    tools: [Protocol.askUser, Protocol.getSettings, Protocol.updateSettings, Protocol.addProvider],
    minModelParamsB: 4.0,
    keywords: const [
      'html', 'css', 'webページ', 'ウェブページ', 'サイト', 'ゲーム', 'プレビュー', 'artifact',
      'アーティファクト', '生成物', 'ui', 'page', 'game',
    ],
  );

  static final fileAnalysis = AgentDefinition(
    id: 'file-analysis',
    displayName: 'File Analysis',
    instructions: 'The user attached files. Base the answer on their contents and quote the relevant parts.',
    tools: [Protocol.askUser, Protocol.getSettings, Protocol.updateSettings, Protocol.addProvider],
    minModelParamsB: 4.0,
    keywords: const ['ファイル', '添付', '要約', '解析', '読んで', 'file', 'attached', 'summarize', 'analyze'],
  );

  static final all = [general, coding, research, artifact, fileAnalysis];

  static AgentDefinition? byId(String? id) {
    for (final a in all) {
      if (a.id == id) return a;
    }
    return null;
  }
}

/// Rule-based selection (spec §17.1): keyword hits narrow the candidates; the user can
/// always override. Attachments steer towards file analysis.
abstract final class AgentSelector {
  static AgentDefinition select(String request, bool hasAttachments, String? override) {
    final forced = Agents.byId(override);
    if (forced != null) return forced;
    // ties keep the order of Agents.all, i.e. the more specific agent listed first wins
    final ranked = rank(request, hasAttachments);
    return ranked.isEmpty ? Agents.general : ranked.first.$1;
  }

  /// Agents with at least one hit, best first (stable for ties).
  static List<(AgentDefinition, int)> rank(String request, bool hasAttachments) {
    final text = request.toLowerCase();
    final scored = <(AgentDefinition, int)>[
      for (final agent in Agents.all)
        (
          agent,
          agent.keywords.where(text.contains).length +
              (hasAttachments && identical(agent, Agents.fileAnalysis) ? 2 : 0),
        ),
    ].where((e) => e.$2 > 0).toList();
    // List.sort is not stable, so break ties by position
    final order = {for (var i = 0; i < Agents.all.length; i++) Agents.all[i]: i};
    scored.sort((a, b) {
      final byScore = b.$2.compareTo(a.$2);
      return byScore != 0 ? byScore : order[a.$1]!.compareTo(order[b.$1]!);
    });
    return scored;
  }

  /// The rules are unsure when nothing matched in a real sentence, or when the best two tie.
  /// Short greetings ("こんにちは") are plainly general chat and need no model call.
  static bool isAmbiguous(String request, bool hasAttachments) {
    final ranked = rank(request, hasAttachments);
    if (ranked.isEmpty) return request.trim().length >= 20;
    if (ranked.length >= 2) return ranked[0].$2 == ranked[1].$2;
    return false;
  }
}

typedef AgentClassifier = Future<String?> Function(String prompt, String schema);

/// Final selection by the loaded model (spec §17.1): only when [AgentSelector] is unsure.
/// The model must answer `{"agent": "<id>"}` under a strict JSON grammar, so it cannot invent
/// an agent; any failure or timeout falls back to the rule-based choice.
class AgentRouter {
  AgentRouter(this._classify);

  final AgentClassifier _classify;

  Future<AgentDefinition> select(
    String request,
    bool hasAttachments,
    String? override, {
    required bool useModel,
  }) async {
    final forced = Agents.byId(override);
    if (forced != null) return forced;
    final byRules = AgentSelector.select(request, hasAttachments, null);
    if (!useModel || !AgentSelector.isAmbiguous(request, hasAttachments)) return byRules;
    final String? answer;
    try {
      answer = await _classify(prompt(request, hasAttachments), schema);
    } catch (_) {
      return byRules;
    }
    if (answer == null) return byRules;
    return parse(answer) ?? byRules;
  }

  static final String schema = '{"type":"object","properties":{"agent":{"type":"string","enum":['
      '${Agents.all.map((a) => '"${a.id}"').join(',')}'
      ']}},"required":["agent"],"additionalProperties":false}';

  static String prompt(String request, bool hasAttachments) {
    final b = StringBuffer()
      ..write('<|im_start|>system\n')
      ..write("Pick the one assistant role that fits the user's request best. Roles:\n");
    for (final a in Agents.all) {
      b.write('- ${a.id}: ${a.displayName}. ${a.instructions}\n');
    }
    b
      ..write('Reply only with JSON like {"agent": "general"}.<|im_end|>\n')
      ..write('<|im_start|>user\n');
    if (hasAttachments) b.write('(files attached)\n');
    b
      ..write(request.length > 1000 ? request.substring(0, 1000) : request)
      ..write('<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n');
    return b.toString();
  }

  static AgentDefinition? parse(String answer) {
    final id = RegExp(r'"agent"\s*:\s*"([a-z-]+)"').firstMatch(answer)?.group(1);
    return Agents.byId(id);
  }
}
