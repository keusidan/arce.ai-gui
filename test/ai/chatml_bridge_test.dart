import 'dart:convert';

import 'package:arce_ai/ai/chatml_bridge.dart';
import 'package:arce_ai/ai/provider.dart';
import 'package:arce_ai/core/engine.dart';
import 'package:arce_ai/core/generation.dart';
import 'package:arce_ai/core/prompt.dart';
import 'package:arce_ai/core/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('プロンプトの分解', () {
    test('システム・履歴・空の返信ブロックを並べる（空の返信は送らない）', () {
      final messages = ChatMlBridge.messages(
        ChatMlPromptBuilder.build(const [UserTurn('こんにちは'), AssistantTurn('やあ')], const [], null, false),
      );
      expect([for (final m in messages) m.role], [AiRole.system, AiRole.user, AiRole.assistant]);
      expect(messages[1].text, 'こんにちは');
      expect(messages[2].text, 'やあ');
      expect(messages.first.text, contains('ARCE.AI'));
    });

    test('口調の指示はシステムメッセージの中に残る', () {
      final messages = ChatMlBridge.messages(
        ChatMlPromptBuilder.build(const [UserTurn('やあ')], const [], 'です・ます調で', false),
      );
      expect(messages.first.text, contains('<tone>です・ます調で</tone>'));
      expect([for (final m in messages) m.role], [AiRole.system, AiRole.user]);
    });

    test('道具の往復はローカルの書き方のまま残す', () {
      final messages = ChatMlBridge.messages(
        ChatMlPromptBuilder.build(
          const [
            UserTurn('いま何時'),
            AssistantTurn('', '{"name": "get_time", "arguments": {}}'),
            ToolResponseTurn('12:00'),
          ],
          const [],
          null,
          false,
        ),
      );
      expect(messages[2].text, contains('<tool_call>'));
      expect(messages[3].text, contains('<tool_response>'));
    });

    test('途中までの返信は、続きを書くよう指示を付けて送る', () {
      final messages = ChatMlBridge.messages(
        ChatMlPromptBuilder.build(const [UserTurn('続きを')], const [], null, false, assistantPrefill: '答えは'),
      );
      expect([for (final m in messages) m.role], [AiRole.system, AiRole.user, AiRole.assistant, AiRole.user]);
      expect(messages[2].text, '答えは');
      expect(messages[3].text, ChatMlBridge.continuationNote);
    });

    test('空の思考ブロックは送らない', () {
      final messages = ChatMlBridge.messages(
        ChatMlPromptBuilder.build(const [UserTurn('x')], const [], null, false, assistantPrefill: '後半'),
      );
      expect(messages[2].text, '後半');
    });

    test('ブロックが無ければ空になる', () {
      expect(ChatMlBridge.messages('ただの文'), isEmpty);
    });
  });

  group('Delta からチャットのイベントへ', () {
    test('本文はそのまま、終わりに理由を返す', () {
      final adapter = CloudEventAdapter();
      expect(adapter.convert(const TextDelta('あ')), [isA<Piece>()]);
      final end = adapter.convert(const StopDelta(FinishReason.length));
      expect(adapter.isFinished, isTrue);
      expect(end.whereType<Finished>().single.reason, FinishReason.length);
    });

    test('思考は思考ブロックで囲み、本文が来たら閉じる', () {
      final adapter = CloudEventAdapter();
      final thinking = adapter.convert(const ReasoningDelta('考える'));
      expect(thinking.whereType<Piece>().map((p) => p.text).join(), contains('考える'));
      expect(adapter.isThinking, isTrue);
      final text = adapter.convert(const TextDelta('答え'));
      expect(adapter.isThinking, isFalse);
      // the thinking block is closed first, then the reply text follows
      expect(text.first, isA<Piece>());
      expect(text.whereType<Piece>().map((p) => p.text).last, '答え');
    });

    test('道具の呼び出しは <tool_call> の本文に戻す', () {
      final adapter = CloudEventAdapter();
      final events = adapter.convert(
        const ToolCallDelta(name: 'web_search', argumentsJson: '{"query": "天気"}'),
      );
      final text = events.whereType<Piece>().map((p) => p.text).join();
      expect(text, contains('<tool_call>'));
      expect(text, contains('"name": "web_search"'));
      expect(text, contains('{"query": "天気"}'));
      expect(text, contains('</tool_call>'));
    });

    test('引数が空の道具呼び出しは {} にする', () {
      final events = CloudEventAdapter().convert(
        const ToolCallDelta(name: 'get_time', argumentsJson: ''),
      );
      expect(events.whereType<Piece>().single.text, contains('"arguments": {}'));
    });

    test('使用量はテキストにしない（使用量の出来事として渡す。キャッシュされた分も）', () {
      final events = CloudEventAdapter().convert(const UsageDelta(promptTokens: 1000, completionTokens: 2, cachedTokens: 800));
      expect(events.whereType<Piece>(), isEmpty);
      final usage = events.single as Usage;
      expect((usage.promptTokens, usage.completionTokens, usage.cachedTokens), (1000, 2, 800));
    });

    test('最後に理由が来なければ、終わりは補える', () {
      final adapter = CloudEventAdapter();
      expect(adapter.isFinished, isFalse);
      final end = adapter.convert(const StopDelta(FinishReason.eog));
      expect(end.whereType<Finished>().single.reason, FinishReason.eog);
    });
  });

  group('ツールの往復（function calling の形）', () {
    const tools = [ToolDefinition(name: 'get_time', description: '時刻', parameters: {'type': 'object'})];
    const call = '{"name": "get_time", "arguments": {"timezone": "Asia/Tokyo"}}';

    List<AiMessage> native(List<ChatMessage> history, {List<String> reasoning = const [], bool replay = false}) => ChatMlBridge.messages(
          ChatMlPromptBuilder.build(history, tools, null, false),
          native: true,
          reasoning: reasoning,
          replayReasoning: replay,
        );

    test('呼び出しは tool_calls、結果は tool メッセージになる。同じ id で結ばれる', () {
      final messages = native(const [
        UserTurn('いま何時'),
        AssistantTurn('調べます', call),
        ToolResponseTurn('12:00'),
        AssistantTurn('正午です'),
      ]);
      expect([for (final m in messages) m.role], [AiRole.system, AiRole.user, AiRole.assistant, AiRole.tool, AiRole.assistant]);
      final assistant = messages[2];
      expect(assistant.text, '調べます', reason: 'the call is not left in the text');
      expect(assistant.toolCalls.single.name, 'get_time');
      expect(jsonDecode(assistant.toolCalls.single.argumentsJson), {'timezone': 'Asia/Tokyo'});
      expect(messages[3].text, '12:00');
      expect(messages[3].toolCallId, assistant.toolCalls.single.id);
      expect(assistant.toolCalls.single.id, isNotEmpty);
    });

    test('2回の呼び出しは、別の id になる', () {
      final messages = native(const [
        UserTurn('x'),
        AssistantTurn('', call),
        ToolResponseTurn('a'),
        AssistantTurn('', call),
        ToolResponseTurn('b'),
      ]);
      final ids = [for (final m in messages) ...[for (final c in m.toolCalls) c.id]];
      expect(ids.toSet(), hasLength(2));
      expect(messages[3].toolCallId, ids.first);
      expect(messages[5].toolCallId, ids.last);
    });

    test('ツールの説明はシステムメッセージから外す（定義は tools で 1 回だけ送る）', () {
      final messages = native(const [UserTurn('x')]);
      expect(messages.first.text, contains('ARCE.AI'));
      expect(messages.first.text, isNot(contains('# Tools')));
      expect(messages.first.text, isNot(contains('<tools>')));
      expect(messages.first.text, isNot(contains('<tool_call>')));
      // the text form keeps them
      final text = ChatMlBridge.messages(ChatMlPromptBuilder.build(const [UserTurn('x')], tools, null, false));
      expect(text.first.text, contains('<tools>'));
    });

    test('口調の指示はツールの説明を外しても残る', () {
      final messages = ChatMlBridge.messages(
        ChatMlPromptBuilder.build(const [UserTurn('x')], tools, 'です・ます調で', false),
        native: true,
      );
      expect(messages.first.text, contains('<tone>です・ます調で</tone>'));
      expect(messages.first.text, isNot(contains('<tools>')));
    });

    test('Gemini 3 の思考署名（extra_content）は、呼び出しといっしょに履歴へ残り、次の送信でそのまま返る', () {
      const extra = {
        'google': {'thought_signature': 'c2ln'},
      };
      // the provider's call is written into the reply as text, with the extra content inside
      final piece = CloudEventAdapter().convert(const ToolCallDelta(id: 'a', name: 'get_time', argumentsJson: '{"timezone":"Asia/Tokyo"}', extraContent: extra));
      final text = (piece.whereType<Piece>().single).text;
      final json = text.replaceAll('<tool_call>', '').replaceAll('</tool_call>', '');
      expect(jsonDecode(json)['extra_content'], extra);
      // the parser that runs the call reads name and arguments, and does not mind the rest
      expect(ToolCallParser.parse(json, tools), isA<ParseOk>());
      // the history keeps that JSON, and the next request carries the extra content again
      final messages = native([const UserTurn('いま何時'), AssistantTurn('', json), const ToolResponseTurn('12:00')]);
      expect(messages[2].toolCalls.single.extraContent, extra);
    });

    test('結果が来なかった呼び出し（途中で止めた会話）は、テキストに戻す。provider は tool_calls に tool の返事を求めるため', () {
      final messages = native(const [UserTurn('x'), AssistantTurn('調べます', call), UserTurn('やっぱりいい')]);
      final assistant = messages[2];
      expect(assistant.toolCalls, isEmpty);
      expect(assistant.text, contains('<tool_call>'));
      expect(assistant.text, startsWith('調べます'));
    });

    test('読めない呼び出しや、対応する呼び出しの無い結果は、ふつうの発言のまま', () {
      final broken = native(const [UserTurn('x'), AssistantTurn('', '{not json'), ToolResponseTurn('r')]);
      expect(broken[2].toolCalls, isEmpty);
      expect(broken[3].role, AiRole.user, reason: 'no call is waiting for this result');
      expect(broken[3].text, contains('<tool_response>'));
    });

    test('過去の思考は、返す設定のときだけ assistant メッセージに付く（順番どおり）', () {
      final history = const [
        UserTurn('x'),
        AssistantTurn('調べます', call, '時刻を知りたい'),
        ToolResponseTurn('12:00'),
        AssistantTurn('正午です', null, '答えられる'),
      ];
      final kept = native(history, reasoning: const ['時刻を知りたい', '答えられる'], replay: true);
      expect([for (final m in kept) m.reasoning], ['', '', '時刻を知りたい', '', '答えられる']);
      final dropped = native(history, reasoning: const ['時刻を知りたい', '答えられる']);
      expect([for (final m in dropped) m.reasoning], everyElement(''));
    });

    test('思考の数が足りなくても落ちない', () {
      final messages = native(const [UserTurn('x'), AssistantTurn('a'), UserTurn('y'), AssistantTurn('b')], reasoning: const ['one'], replay: true);
      expect([for (final m in messages) m.reasoning], ['', '', 'one', '', '']);
    });
  });
}
