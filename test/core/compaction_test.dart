import 'package:arce_ai/core/chat_controller.dart';
import 'package:arce_ai/core/compaction.dart';
import 'package:arce_ai/core/generation.dart';
import 'package:arce_ai/core/prompt.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chat_controller_test.dart' show ScriptedEngine;

void main() {
  List<ChatMessage> talk(int exchanges) => [
        for (var i = 1; i <= exchanges; i++) ...[UserTurn('質問$i'), AssistantTurn('答え$i')],
      ];

  group('where to cut', () {
    test('the kept part starts at the n-th last message of the user; what is before it is summarized', () {
      final history = talk(5);
      expect(Compaction.cutIndex(history, 2), 6, reason: 'u4 is at index 6');
      expect(Compaction.cutIndex(history, 1), 8);
      expect(Compaction.cutIndex(history, 5), isNull, reason: 'the first message is the start: nothing before it');
      expect(Compaction.cutIndex(history, 9), isNull);
      expect(Compaction.cutIndex(history, 0), 8, reason: 'at least one message is kept');
    });

    test('a tool call and its answer are never split, and the app\'s own notes do not count as messages of the user', () {
      final history = <ChatMessage>[
        const UserTurn('調べて'),
        const AssistantTurn('', '{"name":"web_search","arguments":{"query":"q"}}'),
        const ToolResponseTurn('結果'),
        const UserTurn('[from the app] Your last tool call could not be used: x'),
        const AssistantTurn('答え'),
        const UserTurn('次'),
        const AssistantTurn('はい'),
      ];
      expect(Compaction.cutIndex(history, 1), 5);
      expect(Compaction.cutIndex(history, 2), isNull, reason: 'the note is not a message of the user, so only one remains');
      final cut = Compaction.cutIndex(talk(2) + history, 2)!;
      expect(history.isNotEmpty && (talk(2) + history)[cut] is UserTurn, isTrue);
    });
  });

  group('cutting old tool answers', () {
    test('only the answers before the line, only the long ones; the start stays and the cut is said', () {
      final long = 'x' * 5000;
      final history = <ChatMessage>[
        const UserTurn('a'),
        ToolResponseTurn(long),
        const ToolResponseTurn('short'),
        ToolResponseTurn(long),
      ];
      final out = Compaction.clipToolResults(history, 3, 1000);
      expect((out[1] as ToolResponseTurn).text, startsWith('x' * 1000));
      expect((out[1] as ToolResponseTurn).text, contains('4000 characters left out'));
      expect((out[2] as ToolResponseTurn).text, 'short');
      expect((out[3] as ToolResponseTurn).text.length, 5000, reason: 'after the line: untouched');
      expect(identical(Compaction.clipToolResults(talk(2), 4, 1000), talk(2)), isFalse, reason: 'a new list each time');
      final same = talk(2);
      expect(identical(Compaction.clipToolResults(same, 4, 1000), same), isTrue, reason: 'nothing long: the same list');
    });
  });

  group('what the summarizing model reads', () {
    test('the turns as plain lines; a tool call is one short line; a long answer is cut', () {
      final lines = Compaction.lines([
        const UserTurn('こんにちは'),
        const AssistantTurn('調べます', '{"name":"web_search","arguments":{"query":"q"}}'),
        ToolResponseTurn('y' * 4000),
        const AssistantTurn(''),
      ], toolChars: 100);
      expect(lines[0], 'User: こんにちは');
      expect(lines[1], startsWith('Assistant: 調べます [called a tool: {"name":"web_search"'));
      expect(lines[2], 'Tool result: ${'y' * 100} […]');
      expect(lines, hasLength(3), reason: 'an empty assistant turn says nothing');
    });

    test('groups are as large as allowed, and a conversation is written one group after another', () {
      final groups = Compaction.chunks(['a' * 10, 'b' * 10, 'c' * 10], 25);
      expect(groups, ['${'a' * 10}\n${'b' * 10}', 'c' * 10]);
      expect(Compaction.chunks(['z' * 100], 25), ['z' * 100], reason: 'a line that is too long is a group of its own');
      expect(Compaction.chunks(const [], 25), isEmpty);
    });

    test('the request carries the summary so far and the length limit', () {
      final text = Compaction.request('User: a', before: '前の要約', maxChars: 500);
      expect(text, contains('Summary so far:\n前の要約'));
      expect(text, contains('User: a'));
      expect(text, contains('At most 500 characters'));
      expect(Compaction.request('User: a', maxChars: 500), isNot(contains('Summary so far')));
    });

    test('a model\'s answer is the summary; its thinking is not, and nothing is nothing', () {
      expect(Compaction.clean('<think>うーん</think>\n  要点です \n'), '要点です');
      expect(Compaction.clean('<think>考えただけ</think>'), isNull);
      expect(Compaction.clean('   '), isNull);
    });
  });

  group('putting the summary back', () {
    test('it goes into the first message that is kept, so the turns still alternate', () {
      final history = talk(4);
      final out = Compaction.replace(history, 4, '  これまでの要点  ');
      expect(out, hasLength(4));
      final first = out.first as UserTurn;
      expect(first.text, startsWith(Compaction.summaryHeader));
      expect(first.text, contains('これまでの要点'));
      expect(first.text, endsWith('${Compaction.currentMessageHeader}\n質問3'));
      expect((out[1] as AssistantTurn).text, '答え3');
      expect(out.whereType<UserTurn>(), hasLength(2));
    });
  });

  group('in a conversation', () {
    int? context;
    late ScriptedEngine engine;
    late ChatController chat;

    Future<void> setUpChat(List<(String, FinishReason)> replies, {CompactionSettings settings = const CompactionSettings(keepTurns: 2)}) async {
      context = null;
      engine = ScriptedEngine(replies);
      chat = ChatController(
        engine,
        settings: () => GenerationSettings(compaction: settings),
        contextTokens: () => context,
      );
    }

    test('when the request would not fit, the first half is summarized by the model, and the request that follows carries the summary', () async {
      await setUpChat([
        ('答え1', FinishReason.eog),
        ('答え2', FinishReason.eog),
        ('答え3', FinishReason.eog),
        ('<think>まとめる</think>最初の三つの話のまとめ', FinishReason.eog),
        ('答え4', FinishReason.eog),
      ]);
      await chat.send('質問1' * 40);
      await chat.send('質問2' * 40);
      await chat.send('質問3');
      expect(engine.requests, hasLength(3), reason: 'the context is not known: nothing is made shorter');

      context = 600; // the app's own instructions alone are most of this
      await chat.send('質問4');

      expect(engine.requests, hasLength(5), reason: 'one request for the summary, then the answer');
      final ask = engine.requests[3].prompt;
      expect(ask, contains('Conversation to add to the summary'));
      expect(ask, contains('User: ${'質問1' * 40}'));
      expect(ask, isNot(contains('質問3')), reason: 'the kept part is not summarized');
      expect(engine.requests[3].toolCallSchema, isNull);
      expect(engine.requests[3].tools, isEmpty);

      final last = engine.requests.last.prompt;
      expect(last, contains('最初の三つの話のまとめ'));
      expect(last, contains(Compaction.summaryHeader));
      expect(last, isNot(contains('質問1' * 40)));
      expect(last, contains('質問3'));
      expect(last, contains('質問4'));
      expect(last, isNot(contains('まとめる')), reason: 'the thinking is not part of the summary');

      final note = chat.state.messages.last.activities.map((a) => a.summary).join('\n');
      expect(note, contains('会話の前半'));
      expect(note, contains('要約しました'));
      expect(chat.state.messages.map((m) => m.text).where((t) => t.startsWith('質問')), hasLength(4), reason: 'the screen keeps every message');
      expect(chat.state.task, TaskState.completed);
    });

    test('the button: summarizes at once, whatever the context says, and the next request carries the summary', () async {
      await setUpChat([
        ('答え1', FinishReason.eog),
        ('答え2', FinishReason.eog),
        ('答え3', FinishReason.eog),
        ('二つの話のまとめ', FinishReason.eog),
        ('答え4', FinishReason.eog),
      ]);
      await chat.send('質問1');
      expect(chat.canCompact, isFalse, reason: 'one message is not more than the two that are kept');
      expect(await chat.compactNow(), contains('要約する前半がありません'));
      await chat.send('質問2');
      await chat.send('質問3');
      expect(chat.canCompact, isTrue);
      expect(engine.requests, hasLength(3));

      expect(await chat.compactNow(), contains('要約しました'));
      expect(engine.requests, hasLength(4));
      expect(chat.canCompact, isFalse, reason: 'it is done: the summary and the two kept messages');
      expect(chat.isRunning, isFalse);

      await chat.send('質問4');
      expect(engine.requests.last.prompt, contains('二つの話のまとめ'));
      expect(engine.requests.last.prompt, isNot(contains('質問1')));
    });

    test('with the setting off, or without a context size, nothing is touched', () async {
      await setUpChat([('答え1', FinishReason.eog), ('答え2', FinishReason.eog), ('答え3', FinishReason.eog)], settings: const CompactionSettings(enabled: false, keepTurns: 1));
      context = 100;
      await chat.send('質問1' * 40);
      await chat.send('質問2' * 40);
      await chat.send('質問3');
      expect(engine.requests, hasLength(3));
      expect(engine.requests.last.prompt, contains('質問1' * 40));
    });

    test('a model that gives no summary leaves the conversation as it is', () async {
      await setUpChat([
        ('答え1', FinishReason.eog),
        ('答え2', FinishReason.eog),
        ('<think>だめだった</think>', FinishReason.eog),
        ('答え3', FinishReason.eog),
      ], settings: const CompactionSettings(keepTurns: 1));
      await chat.send('質問1' * 40);
      await chat.send('質問2');
      context = 300;
      await chat.send('質問3');
      expect(engine.requests, hasLength(4));
      expect(engine.requests.last.prompt, contains('質問1' * 40), reason: 'nothing was replaced');
      expect(chat.state.task, TaskState.completed);
    });

    test('old tool answers are cut first; when that is enough, no summary is asked for', () async {
      await setUpChat([('答え', FinishReason.eog)], settings: const CompactionSettings(keepTurns: 1, toolResultChars: 200));
      // the long tool answer is put into the history by hand
      chat.restore(ConversationSnapshot(
        messages: const [],
        history: [
          const UserTurn('調べて'),
          const AssistantTurn('', '{"name":"web_search","arguments":{"query":"q"}}'),
          ToolResponseTurn('長い結果' * 2000),
          const AssistantTurn('答え0'),
        ],
        nextId: 0,
      ));
      context = 6000;
      await chat.send('次の質問');
      expect(engine.requests, hasLength(1), reason: 'no request for a summary');
      expect(engine.requests.single.prompt, contains('characters left out'));
      expect(engine.requests.single.prompt, isNot(contains('長い結果' * 2000)));
      expect(chat.state.messages.last.activities.map((a) => a.summary).join(), contains('古い道具の結果を切り詰めました'));
    });
  });
}
