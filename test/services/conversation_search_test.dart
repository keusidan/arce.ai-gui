import 'package:arce_ai/data/llm_db.dart';
import 'package:arce_ai/services/conversation_database.dart';
import 'package:arce_ai/services/conversation_search.dart';
import 'package:flutter_test/flutter_test.dart';

ConversationMeta meta(String id, String title) => ConversationMeta(
      id: id,
      title: title,
      updatedAt: DateTime(2026, 10, 22),
      messageCount: 2,
      generating: false,
    );

SearchHit hit(String conversation, String snippet, [String message = 'm']) =>
    SearchHit(messageId: message, conversationId: conversation, snippet: snippet);

void main() {
  final all = [meta('a', 'りんごの話'), meta('b', '天気の相談'), meta('c', 'Flutter の質問')];

  test('検索語が空なら、すべての会話を新しい順のまま返す', () {
    final hits = ConversationSearch.run('  ', all, const []);
    expect([for (final h in hits) h.meta.id], ['a', 'b', 'c']);
    expect(hits.every((h) => h.snippet == null), isTrue);
  });

  test('タイトルの一致は、本文に無くても出る（大文字小文字は区別しない）', () {
    final hits = ConversationSearch.run('flutter', all, const []);
    expect([for (final h in hits) h.meta.id], ['c']);
    expect(hits.single.snippet, isNull);
  });

  test('本文の一致は、その会話をスニペットつきで出す', () {
    final hits = ConversationSearch.run('雨', all, [hit('b', '明日は[雨]です')]);
    expect(hits.single.meta.id, 'b');
    expect(hits.single.snippet, '明日は[雨]です');
  });

  test('同じ会話の複数の一致は、最初（いちばん良い）の1つにまとめる', () {
    final hits = ConversationSearch.run('雨', all, [hit('b', '一番目[雨]', 'm1'), hit('b', '二番目[雨]', 'm2')]);
    expect(hits, hasLength(1));
    expect(hits.single.snippet, '一番目[雨]');
  });

  test('タイトルと本文の両方に当たる会話は、1回だけ出てスニペットもつく', () {
    final hits = ConversationSearch.run('りんご', all, [hit('a', '[りんご]を食べた'), hit('b', '赤い[りんご]')]);
    expect([for (final h in hits) h.meta.id], ['a', 'b'], reason: 'the title match comes first');
    expect(hits.first.snippet, '[りんご]を食べた');
  });

  test('一覧にない会話（削除済みなど）の一致は出さない', () {
    expect(ConversationSearch.run('x', all, [hit('gone', '[x]')]), isEmpty);
  });
}
