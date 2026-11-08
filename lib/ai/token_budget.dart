import 'dart:convert';

import 'model_hints.dart';
import 'provider.dart';

/// The result of [TokenBudget.check]: null [problem] means the request fits.
class TokenCheck {
  const TokenCheck({this.problem, required this.overhead, required this.prompt, required this.context});

  /// What to tell the user, or null when the request fits.
  final String? problem;

  /// What every request carries before the conversation: the instructions and the tool definitions.
  final int overhead;

  /// Everything that is sent: [overhead] and the conversation.
  final int prompt;
  final int? context;

  bool get ok => problem == null;
}

/// Counts what a request is about to cost in tokens, before it is sent, and says so when it cannot
/// fit into the model's context window.
///
/// Tool definitions are the usual surprise: one MCP server can describe dozens of tools, and every
/// request carries all of them. A provider answers a request that is too long with a short error
/// of its own, after the user has waited; the app can tell them what to change at once.
///
/// The count is an estimate ([ModelHints.estimateTokens]: a third of the UTF-8 bytes), meant to
/// catch the clear cases, not to decide a close one.
abstract final class TokenBudget {
  static int estimate(String text) => ModelHints.estimateTokens(text);

  static int toolTokens(AiToolSpec tool) => estimate('${tool.name}${tool.description}${jsonEncode(tool.parameters)}');

  /// The tokens of the tools of each MCP server (`mcp_<server>__<tool>`), largest first.
  static List<MapEntry<String, int>> toolsByServer(List<AiToolSpec> tools) {
    final sums = <String, int>{};
    for (final tool in tools) {
      final match = RegExp(r'^mcp_(.+?)__').firstMatch(tool.name);
      final key = match?.group(1) ?? '';
      if (key.isEmpty) continue;
      sums[key] = (sums[key] ?? 0) + toolTokens(tool);
    }
    return sums.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  }

  /// Checks [request] against [context] (null: not known, so nothing is checked).
  ///
  /// [overheadRatio] is how much of the context the instructions and tool definitions may take;
  /// [minReply] is the room the reply needs after the whole prompt.
  static TokenCheck check(AiRequest request, {required int? context, double overheadRatio = 0.8, int minReply = 256}) {
    final system = request.messages.where((m) => m.role == AiRole.system).map((m) => estimate(m.text)).fold(0, (a, b) => a + b);
    final tools = request.tools.map(toolTokens).fold(0, (a, b) => a + b);
    final overhead = system + tools;
    final conversation = request.messages.where((m) => m.role != AiRole.system).map((m) => estimate(m.text)).fold(0, (a, b) => a + b);
    final prompt = overhead + conversation;
    if (context == null || context <= 0) return TokenCheck(overhead: overhead, prompt: prompt, context: context);

    if (overhead > context * overheadRatio) {
      final servers = toolsByServer(request.tools);
      final where = servers.isEmpty
          ? ''
          : '（MCP サーバーごと: ${servers.take(3).map((e) => '${e.key} 約 ${_n(e.value)}').join('、')}）';
      return TokenCheck(
        problem: '指示とツールの定義だけで約 ${_n(overhead)} トークンあり、このモデルの文脈（${_n(context)}）の'
            '${(overheadRatio * 100).round()}% を超えます$where。'
            'MCP サーバーを減らすか、文脈の大きいモデルを選んでください',
        overhead: overhead,
        prompt: prompt,
        context: context,
      );
    }
    if (prompt + minReply > context) {
      return TokenCheck(
        problem: '会話が長すぎて、返信の分が残りません（約 ${_n(prompt)} トークン、このモデルの文脈は ${_n(context)}）。'
            '新しい会話を始めるか、文脈の大きいモデルを選んでください',
        overhead: overhead,
        prompt: prompt,
        context: context,
      );
    }
    return TokenCheck(overhead: overhead, prompt: prompt, context: context);
  }

  static String _n(int value) {
    final digits = value.toString();
    final out = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
      out.write(digits[i]);
    }
    return out.toString();
  }
}
