import 'package:arce_ai/core/settings_search.dart';
import 'package:flutter_test/flutter_test.dart';

SettingsSearchEntry entry(String title, {String subtitle = '', List<String> keywords = const [], String section = 'basic', String? key}) =>
    SettingsSearchEntry(sectionId: section, title: title, subtitle: subtitle, keywords: keywords, settingKey: key);

List<String> titles(List<SettingsHit> hits) => [for (final h in hits) h.entry.title];

void main() {
  group('normalize', () {
    test('case, full-width letters and digits, and the ideographic space', () {
      expect(SettingsSearch.normalize('Temperature'), 'temperature');
      expect(SettingsSearch.normalize('ｔｅｍｐｅｒａｔｕｒｅ'), 'temperature');
      expect(SettingsSearch.normalize('ＴＯＰ＿Ｐ　０．９５'), 'topp 0.95');
      expect(SettingsSearch.normalize('  a   b　c '), 'a b c');
    });

    test('katakana and hiragana are the same word; the prolonged sound mark stays', () {
      expect(SettingsSearch.normalize('トークン'), 'とーくん');
      expect(SettingsSearch.normalize('とーくん'), SettingsSearch.normalize('トークン'));
      expect(SettingsSearch.normalize('ヴァイオリン'), SettingsSearch.normalize('ゔぁいおりん'));
      expect(SettingsSearch.normalize('とくん'), isNot(SettingsSearch.normalize('トークン')), reason: 'a missing ー is a different word');
    });

    test('half-width katakana become full-width, with their voiced and semi-voiced marks', () {
      expect(SettingsSearch.normalize('ﾄｰｸﾝ'), SettingsSearch.normalize('トークン'));
      expect(SettingsSearch.normalize('ｶﾞｲﾄﾞ'), SettingsSearch.normalize('ガイド'));
      expect(SettingsSearch.normalize('ﾊﾟｽﾜｰﾄﾞ'), SettingsSearch.normalize('パスワード'));
      expect(SettingsSearch.normalize('ｳﾞｪ'), SettingsSearch.normalize('ヴェ'));
    });

    test('separators that only split a name are dropped: top_p, top-p and topp are one word', () {
      expect(SettingsSearch.normalize('top_p'), 'topp');
      expect(SettingsSearch.normalize('top-p'), 'topp');
      expect(SettingsSearch.normalize('top‐p'), 'topp');
      expect(SettingsSearch.normalize('コンテキスト・長'), SettingsSearch.normalize('コンテキスト長'));
    });

    test('what is not a separator stays: dots, slashes and brackets', () {
      expect(SettingsSearch.normalize('Ubuntu 24.04'), 'ubuntu 24.04');
      expect(SettingsSearch.normalize('owner/name'), 'owner/name');
      expect(SettingsSearch.normalize('（Android）'), '(android)');
    });

    test('nothing is nothing', () {
      expect(SettingsSearch.normalize(''), isEmpty);
      expect(SettingsSearch.normalize('   '), isEmpty);
      expect(SettingsSearch.normalize('_-・'), isEmpty);
    });
  });

  group('search', () {
    final entries = [
      entry('temperature', subtitle: '大きいほど表現がばらつきます（0〜2）', keywords: ['温度']),
      entry('最大トークン', subtitle: '1回の返信の長さの基準', keywords: ['max tokens']),
      entry('GitHub トークン', subtitle: '非公開リポジトリのときだけ', keywords: ['token', 'pat']),
      entry('テーマ', subtitle: '画面の明るさ', keywords: ['theme', 'ダーク']),
      entry('文字の大きさ', subtitle: '画面全体の文字', keywords: ['font']),
    ];

    test('an empty query, or one that is only separators, finds nothing', () {
      expect(SettingsSearch.search(entries, ''), isEmpty);
      expect(SettingsSearch.search(entries, '   '), isEmpty);
      expect(SettingsSearch.search(entries, '_-・'), isEmpty);
      expect(SettingsSearch.search(const [], 'x'), isEmpty);
      expect(SettingsSearch.search(entries, 'テーマ', limit: 0), isEmpty);
    });

    test('Japanese: hiragana finds katakana and the other way round', () {
      expect(titles(SettingsSearch.search(entries, 'とーくん')), containsAll(['最大トークン', 'GitHub トークン']));
      expect(titles(SettingsSearch.search(entries, 'トークン')), containsAll(['最大トークン', 'GitHub トークン']));
      expect(titles(SettingsSearch.search(entries, 'てーま')), ['テーマ']);
      expect(SettingsSearch.search(entries, 'とくん'), isEmpty, reason: 'a missing ー is a different word: no fuzziness');
    });

    test('English and full-width English', () {
      expect(titles(SettingsSearch.search(entries, 'temperature')), ['temperature']);
      expect(titles(SettingsSearch.search(entries, 'ｔｅｍｐｅｒａｔｕｒｅ')), ['temperature']);
      expect(titles(SettingsSearch.search(entries, 'TEMPERATURE')), ['temperature']);
      expect(titles(SettingsSearch.search(entries, 'github')), ['GitHub トークン']);
    });

    test('a synonym in the keywords finds the row', () {
      expect(titles(SettingsSearch.search(entries, '温度')), ['temperature']);
      expect(titles(SettingsSearch.search(entries, 'font')), ['文字の大きさ']);
      expect(titles(SettingsSearch.search(entries, 'ダーク')), ['テーマ']);
    });

    test('the note is searched too', () {
      expect(titles(SettingsSearch.search(entries, '明るさ')), ['テーマ']);
      expect(titles(SettingsSearch.search(entries, 'リポジトリ')), ['GitHub トークン']);
    });

    test('every word has to be found (AND), in any of the fields, in any order', () {
      expect(titles(SettingsSearch.search(entries, 'github トークン')), ['GitHub トークン']);
      expect(titles(SettingsSearch.search(entries, 'トークン github')), ['GitHub トークン']);
      expect(titles(SettingsSearch.search(entries, 'github 最大')), isEmpty);
      expect(titles(SettingsSearch.search(entries, 'テーマ 明るさ')), ['テーマ'], reason: 'one word in the title, one in the note');
      expect(titles(SettingsSearch.search(entries, 'テーマ ほげ')), isEmpty);
      expect(titles(SettingsSearch.search(entries, '  トークン　 pat ')), ['GitHub トークン']);
    });

    test('no fuzzy matching: a typo finds nothing', () {
      expect(SettingsSearch.search(entries, 'temprature'), isEmpty);
      expect(SettingsSearch.search(entries, 'githb'), isEmpty);
      expect(SettingsSearch.search(entries, 'てま'), isEmpty, reason: 'テーマ without its ー');
    });

    test('the same word in a different spelling: top_p, top-p, top p', () {
      final list = [entry('top_p'), entry('top_k')];
      expect(titles(SettingsSearch.search(list, 'top-p')), ['top_p']);
      expect(titles(SettingsSearch.search(list, 'topp')), ['top_p']);
      expect(titles(SettingsSearch.search(list, 'TOP_P')), ['top_p']);
      expect(titles(SettingsSearch.search(list, 'top p')), ['top_p', 'top_k'], reason: '"top" and "p" are two words: "p" is in both (top_k has the p of top)');
    });
  });

  group('ranking', () {
    test('a match in the title beats one in the keywords, and that beats one in the note', () {
      final inTitle = entry('トークンの数');
      final inKeywords = entry('別の名前', keywords: ['トークン']);
      final inNote = entry('さらに別の名前', subtitle: 'トークンのこと');
      final hits = SettingsSearch.search([inNote, inKeywords, inTitle], 'トークン');
      expect(titles(hits), ['トークンの数', '別の名前', 'さらに別の名前']);
      expect(hits[0].score, greaterThan(hits[1].score));
      expect(hits[1].score, greaterThan(hits[2].score));
    });

    test('the tier wins over the kind of match: a plain match in the title beats an exact one in the keywords', () {
      final title = entry('あいうtokenえお');
      final keyword = entry('別', keywords: ['token']);
      expect(titles(SettingsSearch.search([keyword, title], 'token')), ['あいうtokenえお', '別']);
    });

    test('inside one field: exact, then the start, then the start of a word, then the middle', () {
      final exact = entry('token');
      final prefix = entry('token limit');
      final word = entry('max token');
      final middle = entry('maxtokenlimit');
      final hits = SettingsSearch.search([middle, word, prefix, exact], 'token');
      expect(titles(hits), ['token', 'token limit', 'max token', 'maxtokenlimit']);
      expect(hits.map((h) => h.score).toSet(), hasLength(4));
    });

    test('inside Japanese text, only a start of the title counts as the start', () {
      final start = entry('テーマの設定');
      final middle = entry('画面のテーマ');
      expect(titles(SettingsSearch.search([middle, start], 'てーま')), ['テーマの設定', '画面のテーマ']);
    });

    test('more words found in better places add up', () {
      final both = entry('最大トークン', keywords: ['max tokens']);
      final one = entry('トークンの話', subtitle: 'max tokens のこと');
      expect(titles(SettingsSearch.search([one, both], 'トークン max')).first, '最大トークン');
    });

    test('equal scores keep the order of the list, whatever the order of the hits', () {
      final list = [for (var i = 0; i < 6; i++) entry('設定 $i')];
      expect(titles(SettingsSearch.search(list, '設定')), ['設定 0', '設定 1', '設定 2', '設定 3', '設定 4', '設定 5']);
      final reversed = list.reversed.toList();
      expect(titles(SettingsSearch.search(reversed, '設定')), ['設定 5', '設定 4', '設定 3', '設定 2', '設定 1', '設定 0']);
      // and the same search twice gives the same answer
      expect(titles(SettingsSearch.search(list, '設定')), titles(SettingsSearch.search(list, '設定')));
    });

    test('the limit keeps the best hits', () {
      final list = [entry('x token'), entry('token'), entry('token 2'), entry('xxtokenxx')];
      expect(titles(SettingsSearch.search(list, 'token', limit: 2)), ['token', 'token 2']);
      expect(SettingsSearch.search(list, 'token'), hasLength(4));
      expect(SettingsSearch.search(list, 'token', limit: 100), hasLength(4));
    });
  });

  group('the entry', () {
    test('keeps what it was given', () {
      const e = SettingsSearchEntry(sectionId: 'local', title: 't', subtitle: 's', keywords: ['k'], settingKey: 'kvCache');
      expect(e.sectionId, 'local');
      expect(e.title, 't');
      expect(e.subtitle, 's');
      expect(e.keywords, ['k']);
      expect(e.settingKey, 'kvCache');
      expect(e.isGroup, isFalse);
      const g = SettingsSearchEntry(sectionId: 'local', title: 'g', isGroup: true);
      expect(g.subtitle, isEmpty);
      expect(g.keywords, isEmpty);
      expect(g.settingKey, isNull);
      expect(g.isGroup, isTrue);
    });
  });
}
