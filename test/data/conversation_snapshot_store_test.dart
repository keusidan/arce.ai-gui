import 'package:flutter_test/flutter_test.dart';

import 'package:arce_ai/data/conversation_snapshot_store.dart';
import 'package:arce_ai/data/llm_db.dart';

/// One turn as the chat screen hands it over: a question, a tool result and an attachment.
Map<String, Object?> snapshot({String text = 'こんにちは'}) => {
      'messages': [
        {
          'id': 0,
          'role': 'user',
          'text': text,
          'thinking': '',
          'question': null,
          'finish': null,
          'activities': const [],
          'agent': null,
          'attachments': const ['memo.txt'],
          'time': 1700000000000,
        },
        {
          'id': 1,
          'role': 'assistant',
          'text': '答え',
          'thinking': '考える',
          'question': {'question': 'どちらにしますか', 'options': ['A', 'B']},
          'finish': 'eog',
          'activities': [
            {'tool': 'web_search', 'summary': '3件'},
          ],
          'agent': 'General Chat',
          'attachments': const [],
          'time': 1700000005000,
        },
      ],
      'history': [
        {'type': 'user', 'text': text, 'toolCallJson': null},
        {'type': 'assistant', 'text': '答え', 'toolCallJson': '{"name": "ask_user"}', 'reasoning': '考えた'},
        {'type': 'tool', 'text': 'A', 'toolCallJson': null},
      ],
      'nextId': 2,
    };

void main() {
  late LlmDatabase db;
  late ConversationSnapshotStore store;

  setUp(() {
    db = LlmDatabase.memory();
    store = ConversationSnapshotStore(db);
  });
  tearDown(() => db.close());

  test('思考の長さ（ミリ秒）も、思考の本文といっしょに保存して読み戻せる。長さを持たない古い保存は 0', () {
    final withMs = snapshot();
    ((withMs['messages']! as List)[1] as Map<String, Object?>)['thinkingMs'] = 12345;
    final id = store.save(null, withMs, generating: false);
    expect((store.read(id)!['messages']! as List)[1]['thinkingMs'], 12345);
    expect((store.read(id)!['messages']! as List)[1]['thinking'], '考える');

    final old = store.save(null, snapshot(), generating: false); // no thinkingMs in it
    expect((store.read(old)!['messages']! as List)[1]['thinkingMs'], 0);
  });

  group('保存', () {
    test('会話を新しく作り、一覧に出る', () {
      final id = store.save(null, snapshot(), generating: false);

      final list = store.list();
      expect(list, hasLength(1));
      expect(list.single.id, id);
      expect(list.single.title, 'こんにちは');
      expect(list.single.messageCount, 2);
      expect(list.single.generating, isFalse);
    });

    test('タイトルは最初のユーザー発言を40文字までにする', () {
      final id = store.save(null, snapshot(text: 'あ' * 60), generating: false);
      expect(db.conversation(id)!.title, 'あ' * 40);
    });

    test('同じ会話を保存し直しても増えない', () {
      final id = store.save(null, snapshot(), generating: false);
      final again = store.save(id, snapshot(text: '二度目'), generating: false);

      expect(again, id);
      expect(store.list(), hasLength(1));
      expect(db.messagesOf(id), hasLength(2), reason: 'appending would keep the old rows too');
      expect(db.messagesOf(id).first.createdAt, 1700000000000);
    });

    test('生成中に保存すると、その会話が再開対象として印を付けられる', () {
      final id = store.save(null, snapshot(), generating: true);
      expect(store.list().single.generating, isTrue);

      store.clearGenerating(id);
      expect(store.list().single.generating, isFalse);
    });

    test('会話の行が消えていても、保存し直すと書き戻す', () {
      final id = store.save(null, snapshot(), generating: false);
      db.deleteConversation(id);

      final again = store.save(id, snapshot(), generating: false);
      expect(again, id);
      expect(store.list(), hasLength(1));
    });

    test('メッセージが無いスナップショットは書かない', () {
      expect(
        () => store.save(null, {'messages': const [], 'history': const [], 'nextId': 0}, generating: false),
        throwsArgumentError,
      );
      expect(store.list(), isEmpty);
    });

    test('会話の更新時刻は最後のメッセージの時刻になる', () {
      final id = store.save(null, snapshot(), generating: false);
      expect(db.conversation(id)!.updatedAt, 1700000005000);
    });
  });

  group('読み出し', () {
    test('画面に出す内容がそのまま戻る', () {
      final id = store.save(null, snapshot(), generating: false);
      final read = store.read(id)!;
      final messages = (read['messages'] as List).cast<Map<String, Object?>>();

      expect(messages, hasLength(2));
      expect(read['nextId'], 2);
      expect(messages[0]['id'], 0);
      expect(messages[0]['role'], 'user');
      expect(messages[0]['text'], 'こんにちは');
      expect(messages[0]['attachments'], ['memo.txt']);
      expect(messages[0]['time'], 1700000000000);

      expect(messages[1]['role'], 'assistant');
      expect(messages[1]['text'], '答え');
      expect(messages[1]['thinking'], '考える');
      expect(messages[1]['finish'], 'eog');
      expect(messages[1]['agent'], 'General Chat');
      expect(messages[1]['question'], {'question': 'どちらにしますか', 'options': ['A', 'B']});
      expect(messages[1]['activities'], [
        {'tool': 'web_search', 'summary': '3件'},
      ]);
    });

    test('モデルに渡す履歴も戻る', () {
      final id = store.save(null, snapshot(), generating: false);
      final history = (store.read(id)!['history'] as List).cast<Map<String, Object?>>();

      expect([for (final t in history) t['type']], ['user', 'assistant', 'tool']);
      expect(history[1]['toolCallJson'], '{"name": "ask_user"}');
      expect(history[1]['reasoning'], '考えた', reason: 'a reopened conversation can send its reasoning back');
      expect(history[0].containsKey('reasoning'), isFalse);
    });

    test('生成中の印は cancelled として読む（続行できる状態）', () {
      final id = store.save(null, snapshot(), generating: true);
      final messages = (store.read(id)!['messages'] as List).cast<Map<String, Object?>>();

      expect(messages.last['finish'], 'cancelled');
    });

    test('知らない終了理由は null にする', () {
      final id = db.startConversation(title: 't', agentId: '', providerId: 'local', modelId: '');
      db.addMessage(
        id,
        const NewMessage(MessageRole.assistant, [NewPart(PartKind.text, text: '本文')], finishReason: 'unknown'),
      );
      final messages = (store.read(id)!['messages'] as List).cast<Map<String, Object?>>();
      expect(messages.single['finish'], isNull);
    });

    test('壊れた JSON の質問や道具の結果は捨てる', () {
      final id = db.startConversation(title: 't', agentId: '', providerId: 'local', modelId: '');
      db.addMessage(
        id,
        const NewMessage(MessageRole.assistant, [
          NewPart(PartKind.text, text: '本文'),
          NewPart(PartKind.question, payload: '{壊れた'),
          NewPart(PartKind.toolResult, payload: ''),
        ]),
      );
      final messages = (store.read(id)!['messages'] as List).cast<Map<String, Object?>>();
      expect(messages.single['question'], isNull);
      expect(messages.single['activities'], isEmpty);
    });

    test('無い会話は null', () {
      expect(store.read('missing'), isNull);
    });

    test('保存していない会話は、まだ空の履歴として扱える', () {
      final id = db.startConversation(title: '空', agentId: '', providerId: 'local', modelId: '');
      final read = store.read(id)!;
      expect(read['messages'], isEmpty);
      expect(read['nextId'], 0);
    });
  });

  group('検索と削除', () {
    test('本文を横断して探せる', () {
      store.save(null, snapshot(text: 'りんごの話'), generating: false);
      store.save(null, snapshot(text: 'みかんの話'), generating: false);

      expect(store.search('りんご'), hasLength(1));
      expect(store.search('話'), hasLength(2), reason: 'one character falls back to instr()');
      expect(store.search('ぶどう'), isEmpty);
    });

    test('削除すると一覧から消える', () {
      final id = store.save(null, snapshot(), generating: false);
      expect(store.delete(id), isEmpty);
      expect(store.list(), isEmpty);
      expect(store.read(id), isNull);
    });
  });
}
