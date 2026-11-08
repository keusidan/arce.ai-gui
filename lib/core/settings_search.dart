/// Search over the settings screen: what a person types, matched against the titles, notes and
/// synonyms of every setting. Pure text work (no Flutter, no I/O), so every rule is tested.
///
/// The text is folded before it is compared: full-width letters and digits become half-width,
/// half-width katakana become full-width, katakana become hiragana (so "トークン" and "とーくん" are the
/// same word), case is ignored, and the separators that only split a name (`_ - ・`) are dropped
/// (so "top_p", "top-p" and "topp" are the same word). Nothing fuzzier than that: a typo finds nothing.
library;

/// One searchable place of the settings screen: a row, a switch, a card or a whole group.
class SettingsSearchEntry {
  const SettingsSearchEntry({
    required this.sectionId,
    required this.title,
    this.subtitle = '',
    this.keywords = const [],
    this.settingKey,
    this.isGroup = false,
  });

  /// `SettingsSection.<name>.name`: the group of the settings screen the entry is in.
  final String sectionId;

  /// The row's own title, as it is shown.
  final String title;

  /// The note under the title, as it is shown ('' when the row has none).
  final String subtitle;

  /// Words a person would type for it that the title does not contain (synonyms, English names).
  final List<String> keywords;

  /// The JSON key of the setting the row changes (`AppSettings.toJson`), when it changes one.
  final String? settingKey;

  /// The entry stands for a whole group (its title and note), not for a row in it.
  final bool isGroup;
}

/// An entry that matched, with how well.
class SettingsHit {
  const SettingsHit(this.entry, this.score);

  final SettingsSearchEntry entry;

  /// Higher is better. Only meaningful for comparing hits of one search.
  final int score;
}

abstract final class SettingsSearch {
  // A match in the title is worth more than one in the keywords, and that more than one in the
  // note, whatever the kind of match inside the field (the bonus never reaches the next tier).
  static const _titleTier = 300;
  static const _keywordTier = 200;
  static const _subtitleTier = 100;
  static const _exact = 40;
  static const _prefix = 30;
  static const _wordStart = 20;
  static const _contains = 0;

  static const _halfKana = '｡｢｣､･ｦｧｨｩｪｫｬｭｮｯｰｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃﾄﾅﾆﾇﾈﾉﾊﾋﾌﾍﾎﾏﾐﾑﾒﾓﾔﾕﾖﾗﾘﾙﾚﾛﾜﾝ';
  static const _fullKana = '。「」、・ヲァィゥェォャュョッーアイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワン';
  static const _voiced = {
    'カ': 'ガ', 'キ': 'ギ', 'ク': 'グ', 'ケ': 'ゲ', 'コ': 'ゴ',
    'サ': 'ザ', 'シ': 'ジ', 'ス': 'ズ', 'セ': 'ゼ', 'ソ': 'ゾ',
    'タ': 'ダ', 'チ': 'ヂ', 'ツ': 'ヅ', 'テ': 'デ', 'ト': 'ド',
    'ハ': 'バ', 'ヒ': 'ビ', 'フ': 'ブ', 'ヘ': 'ベ', 'ホ': 'ボ',
    'ウ': 'ヴ',
  };
  static const _semiVoiced = {'ハ': 'パ', 'ヒ': 'ピ', 'フ': 'プ', 'ヘ': 'ペ', 'ホ': 'ポ'};

  /// Characters that only split a name: dropped, so "top_p" and "top-p" are "topp".
  static final _dropped = RegExp('[_\\-‐‑‒–—・･]');

  /// What the comparison sees: [text] folded as the library comment says, whitespace made single, trimmed.
  static String normalize(String text) {
    final out = StringBuffer();
    final runes = text.runes.toList();
    for (var i = 0; i < runes.length; i++) {
      var ch = runes[i];
      // full-width ASCII (！ … ～) and the ideographic space
      if (ch >= 0xFF01 && ch <= 0xFF5E) ch -= 0xFEE0;
      if (ch == 0x3000) ch = 0x20;
      // half-width katakana -> full-width, joined with a following voiced / semi-voiced mark
      final half = _halfKana.indexOf(String.fromCharCode(ch));
      if (ch >= 0xFF61 && ch <= 0xFF9F && half >= 0) {
        var kana = _fullKana[half];
        if (i + 1 < runes.length) {
          if (runes[i + 1] == 0xFF9E && _voiced.containsKey(kana)) {
            kana = _voiced[kana]!;
            i++;
          } else if (runes[i + 1] == 0xFF9F && _semiVoiced.containsKey(kana)) {
            kana = _semiVoiced[kana]!;
            i++;
          }
        }
        ch = kana.codeUnitAt(0);
      }
      // katakana -> hiragana (ァ … ヶ -> ぁ … ゖ; the prolonged sound mark ー stays)
      if (ch >= 0x30A1 && ch <= 0x30F6) ch -= 0x60;
      out.writeCharCode(ch);
    }
    return out
        .toString()
        .toLowerCase()
        .replaceAll(_dropped, '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// The entries that match [query], best first; at most [limit]. [query] is split on whitespace and
  /// EVERY word has to be found in the title, the note or the keywords of an entry. An empty query
  /// (or one that is only separators) matches nothing. Entries of equal score keep their order in
  /// [entries].
  static List<SettingsHit> search(List<SettingsSearchEntry> entries, String query, {int limit = 50}) {
    final terms = normalize(query).split(' ').where((t) => t.isNotEmpty).toList();
    if (terms.isEmpty || limit <= 0) return const [];
    final hits = <(SettingsHit, int)>[];
    for (var index = 0; index < entries.length; index++) {
      final entry = entries[index];
      final title = normalize(entry.title);
      final subtitle = normalize(entry.subtitle);
      final keywords = [for (final k in entry.keywords) normalize(k)];
      var total = 0;
      var all = true;
      for (final term in terms) {
        final score = _termScore(term, title, subtitle, keywords);
        if (score == null) {
          all = false;
          break;
        }
        total += score;
      }
      if (all) hits.add((SettingsHit(entry, total), index));
    }
    hits.sort((a, b) {
      final byScore = b.$1.score.compareTo(a.$1.score);
      return byScore != 0 ? byScore : a.$2.compareTo(b.$2);
    });
    return [for (final (hit, _) in hits.take(limit)) hit];
  }

  /// How well [term] is found in one entry, or null when it is not found anywhere.
  static int? _termScore(String term, String title, String subtitle, List<String> keywords) {
    int? best;
    void take(int? score) {
      if (score != null && (best == null || score > best!)) best = score;
    }

    take(_fieldScore(term, title, _titleTier));
    for (final keyword in keywords) {
      take(_fieldScore(term, keyword, _keywordTier));
    }
    take(_fieldScore(term, subtitle, _subtitleTier));
    return best;
  }

  /// [tier] plus the bonus of the best match of [term] in [field]; null when it is not in it.
  static int? _fieldScore(String term, String field, int tier) {
    if (field.isEmpty) return null;
    if (field == term) return tier + _exact;
    if (field.startsWith(term)) return tier + _prefix;
    var at = field.indexOf(term);
    if (at < 0) return null;
    // the start of a word: after a space or a symbol, not in the middle of a run of letters
    while (at >= 0) {
      if (_startsWord(field, at)) return tier + _wordStart;
      at = field.indexOf(term, at + 1);
    }
    return tier + _contains;
  }

  static bool _startsWord(String field, int at) {
    if (at == 0) return true;
    final before = field.codeUnitAt(at - 1);
    final isAsciiWord = (before >= 0x30 && before <= 0x39) || (before >= 0x61 && before <= 0x7A);
    // Japanese has no spaces: a character after another is the middle of the word, so only a space,
    // a bracket or a symbol before it makes it a word start
    final isJapanese = (before >= 0x3040 && before <= 0x30FF) || (before >= 0x4E00 && before <= 0x9FFF) || before == 0x30FC;
    return !isAsciiWord && !isJapanese;
  }
}
