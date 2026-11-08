import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:arce_ai/core/protocol.dart';
import 'package:arce_ai/core/settings_spec.dart';

void main() {
  final tools = [Protocol.updateSettings];

  ParseResult parse(Object arguments, {List<ToolDefinition>? with_}) => ToolCallParser.parse(
        jsonEncode({'name': 'update_settings', 'arguments': arguments}),
        with_ ?? tools,
      );

  test('設定の変更を読み取る', () {
    final result = parse({
      'changes': [
        {'key': 'thinking', 'value': false},
        {'key': 'theme', 'value': 'dark'},
      ],
    });

    final call = (result as ParseOk).call as UpdateSettings;
    expect(call.changes, hasLength(2));
    expect(call.changes.first.key, 'thinking');
    expect(call.changes.first.value, isFalse);
    expect(call.changes.last.value, 'dark');
  });

  test('エージェントに許可されていなければ拒否する', () {
    final result = parse({
      'changes': [
        {'key': 'thinking', 'value': false},
      ],
    }, with_: [Protocol.askUser]);

    expect(result, isA<ParseInvalid>());
    expect((result as ParseInvalid).reason, contains('not allowed'));
  });

  test('触れない設定は拒否する', () {
    final result = parse({
      'changes': [
        {'key': 'updateRepo', 'value': 'evil/repo'},
      ],
    });

    expect(result, isA<ParseInvalid>());
    expect((result as ParseInvalid).reason, contains('チャットからは変更できません'));
  });

  test('範囲外の値は理由つきで拒否する', () {
    final result = parse({
      'changes': [
        {'key': 'maxTokens', 'value': 2000000},
      ],
    });

    expect(result, isA<ParseInvalid>());
    expect((result as ParseInvalid).reason, contains('最大トークン'));
  });

  test('形が違う引数は拒否する', () {
    expect(parse({'changes': <Object?>[]}), isA<ParseInvalid>());
    expect(parse({'nope': 1}), isA<ParseInvalid>());
    expect(parse('x'), isA<ParseInvalid>());
  });

  test('スキーマには変更できるキーだけが並ぶ', () {
    final schema = Protocol.toolCallSchema(tools);
    final variant = (schema['oneOf']! as List).single as Map;
    final args = (variant['properties'] as Map)['arguments'] as Map;
    final props = args['properties'] as Map;
    final items = (props['changes'] as Map)['items'] as Map;
    final key = (items['properties'] as Map)['key'] as Map;

    expect(key['enum'], AgentSettings.keys);
    expect((key['enum'] as List), isNot(contains('updateRepo')));
    expect((key['enum'] as List), isNot(contains('lastModelPath')));
  });

  test('プロトコルの版が上がっている', () {
    // 5: run_command and ci_status joined the tools (0.12.0); 6: delegate got ids and depends_on (0.12.4);
    // 7: run_command takes secrets and mcp_find / mcp_describe / mcp_call exist (0.12.8)
    expect(Protocol.schemaVersion, 7);
  });

  test('既存の道具はそのまま動く', () {
    final ask = ToolCallParser.parse(
      jsonEncode({
        'name': 'ask_user',
        'arguments': {
          'title': 'どれ？',
          'options': ['A', 'B'],
        },
      }),
      [Protocol.askUser],
    );
    expect((ask as ParseOk).call, isA<AskUser>());

    final time = ToolCallParser.parse(
      jsonEncode({'name': 'get_time', 'arguments': <String, Object?>{}}),
      [Protocol.getTime],
    );
    expect((time as ParseOk).call, isA<GetTime>());
  });
}
