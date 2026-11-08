import 'package:arce_ai/ai/provider.dart';
import 'package:arce_ai/ai/token_budget.dart';
import 'package:flutter_test/flutter_test.dart';

AiToolSpec tool(String name, {int words = 10}) => AiToolSpec(
      name: name,
      description: List.filled(words, 'description').join(' '),
      parameters: const {'type': 'object', 'properties': {}},
    );

void main() {
  test('文脈が分からないモデルは調べない', () {
    final check = TokenBudget.check(
      AiRequest(messages: const [AiMessage(AiRole.user, text: 'こんにちは')], tools: [tool('mcp_x__a', words: 100000)]),
      context: null,
    );
    expect(check.ok, isTrue);
    expect(check.overhead, greaterThan(100000));
  });

  test('収まる依頼は通す', () {
    final check = TokenBudget.check(
      AiRequest(messages: const [AiMessage(AiRole.system, text: 'あなたは助手です。'), AiMessage(AiRole.user, text: 'こんにちは')], tools: [tool('web_search')]),
      context: 8192,
    );
    expect(check.ok, isTrue);
    expect(check.prompt, lessThan(1000));
  });

  test('指示とツールの定義だけで文脈の大半を使うなら、MCP サーバーごとの大きさを添えて断る', () {
    final tools = [
      for (var i = 0; i < 40; i++) tool('mcp_github__tool$i', words: 200),
      for (var i = 0; i < 5; i++) tool('mcp_kaggle__tool$i', words: 50),
      tool('web_search'),
    ];
    final check = TokenBudget.check(
      AiRequest(messages: const [AiMessage(AiRole.user, text: 'こんにちは')], tools: tools),
      context: 8192,
    );
    expect(check.ok, isFalse);
    expect(check.problem, contains('MCP サーバーごと'));
    expect(check.problem, contains('github 約'));
    // the biggest server is named first
    expect(check.problem!.indexOf('github'), lessThan(check.problem!.indexOf('kaggle')));
    expect(check.problem, contains('80%'));
  });

  test('割合は設定で変えられる', () {
    final request = AiRequest(
      messages: const [AiMessage(AiRole.user, text: 'こんにちは')],
      tools: [for (var i = 0; i < 10; i++) tool('mcp_a__t$i', words: 100)],
    );
    final overhead = TokenBudget.check(request, context: null).overhead;
    final context = (overhead / 0.5).round();
    expect(TokenBudget.check(request, context: context, overheadRatio: 0.8).ok, isTrue);
    expect(TokenBudget.check(request, context: context, overheadRatio: 0.4).ok, isFalse);
  });

  test('会話が長くて返信の分が残らないときも断る', () {
    final check = TokenBudget.check(
      AiRequest(messages: [AiMessage(AiRole.user, text: List.filled(5000, 'あ').join())]),
      context: 4096,
    );
    expect(check.ok, isFalse);
    expect(check.problem, contains('会話が長すぎ'));
    expect(check.problem, contains('4,096'));
  });

  test('MCP でないツールは、サーバーごとの内訳に出さない', () {
    expect(TokenBudget.toolsByServer([tool('web_search'), tool('get_time')]), isEmpty);
    final by = TokenBudget.toolsByServer([tool('mcp_a__x'), tool('mcp_a__y'), tool('mcp_b__z')]);
    expect([for (final e in by) e.key], ['a', 'b']);
  });
}
