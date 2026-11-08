import 'package:arce_ai/core/markdown_lite.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('bold spans', () {
    expect(MarkdownLite.spans('これは**重要**です'), [
      const Span('これは', bold: false),
      const Span('重要', bold: true),
      const Span('です', bold: false),
    ]);
  });

  test('an unmatched marker stays literal while streaming', () {
    expect(MarkdownLite.spans('a **b'), [const Span('a **b', bold: false)]);
  });

  test('text and a closed code block', () {
    final blocks = MarkdownLite.parse('例:\n```html\n<p>hi</p>\n```\n以上');
    expect(blocks, hasLength(3));
    expect((blocks[0] as Paragraph).spans, [const Span('例:', bold: false)]);
    final code = blocks[1] as CodeBlock;
    expect((code.language, code.code, code.closed), ('html', '<p>hi</p>', true));
    expect((blocks[2] as Paragraph).spans, [const Span('以上', bold: false)]);
  });

  test('a code block still being streamed is open', () {
    final open = MarkdownLite.parse('```kotlin\nfun main() {').single as CodeBlock;
    expect((open.language, open.code, open.closed), ('kotlin', 'fun main() {', false));
    final header = MarkdownLite.parse('```py').single as CodeBlock;
    expect((header.language, header.code, header.closed), ('py', '', false));
  });

  group('見出し・区切り線・引用', () {
    test('見出しは # の数で段階が決まり、末尾の # は外れる', () {
      final blocks = MarkdownLite.parse('## 結論から\n### 小見出し ##\n#ハッシュだけは見出しではない');
      expect((blocks[0] as Heading).level, 2);
      expect((blocks[0] as Heading).spans, [const Span('結論から')]);
      expect((blocks[1] as Heading).level, 3);
      expect((blocks[1] as Heading).spans, [const Span('小見出し')]);
      expect(blocks[2], isA<Paragraph>());
    });

    test('--- と *** は区切り線。直前の段落とは別のブロック', () {
      final blocks = MarkdownLite.parse('前\n\n---\n\n後\n***');
      expect(blocks.map((b) => b.runtimeType), [Paragraph, Rule, Paragraph, Rule]);
    });

    test('引用は中身をもう一度ブロックとして読む', () {
      final quote = MarkdownLite.parse('> **注意**\n> - 一つ目\n> - 二つ目').single as Quote;
      expect(quote.blocks.map((b) => b.runtimeType), [Paragraph, ListBlock]);
      expect((quote.blocks[0] as Paragraph).spans.first, const Span('注意', bold: true));
      expect((quote.blocks[1] as ListBlock).items, hasLength(2));
    });

    test('引用は、> を外した元の文章も持つ（コピーボタンが写すもの）', () {
      final quote = MarkdownLite.parse('> 次の指示に従ってください。\n> - 一つ目\n> - 二つ目\n>\n> 以上').single as Quote;
      expect(quote.raw, '次の指示に従ってください。\n- 一つ目\n- 二つ目\n\n以上');
    });
  });

  group('リスト', () {
    test('箇条書きと番号つきと、字下げの入れ子', () {
      final list = MarkdownLite.parse('- 親\n  - 子\n    - 孫\n- 次\n\n1. 一\n2. 二').first as ListBlock;
      expect(list.items.map((i) => i.depth), [0, 1, 2, 0]);
      expect(list.items.every((i) => i.number == null), isTrue);
      final numbered = MarkdownLite.parse('1. 一\n2. 二\n10) 十').single as ListBlock;
      expect(numbered.items.map((i) => i.number), [1, 2, 10]);
    });

    test('項目の下に字下げした文は、その項目の続きになる', () {
      final list = MarkdownLite.parse('- 項目\n  続き\n- 次').single as ListBlock;
      expect(list.items, hasLength(2));
      expect(list.items.first.spans.map((s) => s.text).join(), '項目\n続き');
    });

    test('空行が 1 つ入っても、続く項目があればひと続きのリスト', () {
      final blocks = MarkdownLite.parse('- a\n\n- b');
      expect(blocks, hasLength(1));
      expect((blocks.single as ListBlock).items, hasLength(2));
    });

    test('タスクリスト', () {
      final list = MarkdownLite.parse('- [x] 済み\n- [ ] 未').single as ListBlock;
      expect(list.items.map((i) => i.checked), [true, false]);
      expect(list.items.first.spans, [const Span('済み')]);
    });

    test('**太字**で始まる行や、「2 * 3」はリストにならない', () {
      expect(MarkdownLite.parse('**太字** です').single, isA<Paragraph>());
      expect(MarkdownLite.parse('2 * 3 = 6').single, isA<Paragraph>());
    });
  });

  group('表', () {
    const sample = '| 形態 | 課金 | spot的か |\n|---|:---:|--:|\n| Serverless | トークン課金 | ✗ |\n| **Preemptible** | 遊休の GPU | ✓ |';

    test('見出し行・揃え・本文の行を読む', () {
      final table = MarkdownLite.parse(sample).single as TableBlock;
      expect(table.header.map((c) => c.first.text), ['形態', '課金', 'spot的か']);
      expect(table.aligns, [ColumnAlign.left, ColumnAlign.center, ColumnAlign.right]);
      expect(table.rows, hasLength(2));
      expect(table.rows[1][0].single, const Span('Preemptible', bold: true));
    });

    test('セルが足りない行は空で埋め、多い行は切る', () {
      final table = MarkdownLite.parse('| a | b |\n|---|---|\n| 1 |\n| 1 | 2 | 3 |').single as TableBlock;
      expect(table.rows[0][1], isEmpty);
      expect(table.rows[1], hasLength(2));
    });

    test('パイプは \\| と `code` の中ではセルの区切りにならない', () {
      final table = MarkdownLite.parse('| a | b |\n|---|---|\n| x \\| y | `a|b` |').single as TableBlock;
      expect(table.rows.single[0].single.text, 'x | y');
      expect(table.rows.single[1].single, const Span('a|b', code: true));
    });

    test('区切りの行がまだ届いていなければ表ではなく段落。届けば表になる', () {
      expect(MarkdownLite.parse('| a | b |').single, isA<Paragraph>());
      expect(MarkdownLite.parse('| a | b |\n|--').single, isA<Paragraph>());
      expect(MarkdownLite.parse('| a | b |\n|---|---|').single, isA<TableBlock>());
    });

    test('表のあとの文章は別の段落', () {
      final blocks = MarkdownLite.parse('$sample\n\n表のあと');
      expect(blocks.map((b) => b.runtimeType), [TableBlock, Paragraph]);
    });
  });

  group('文中の記法', () {
    test('斜体・取り消し線・インラインコード', () {
      expect(MarkdownLite.spans('a *b* ~~c~~ `d`'), [
        const Span('a '),
        const Span('b', italic: true),
        const Span(' '),
        const Span('c', strike: true),
        const Span(' '),
        const Span('d', code: true),
      ]);
    });

    test('太字の中の斜体・コード・リンク', () {
      expect(MarkdownLite.spans('**強い *斜め* と `x`**'), [
        const Span('強い ', bold: true),
        const Span('斜め', bold: true, italic: true),
        const Span(' と ', bold: true),
        const Span('x', bold: true, code: true),
      ]);
    });

    test('コードの中の記号は、そのまま', () {
      expect(MarkdownLite.spans('`**a**` と `x_y_z`'), [const Span('**a**', code: true), const Span(' と '), const Span('x_y_z', code: true)]);
    });

    test('単語の中の _ と、空白に挟まれた * は記法ではない', () {
      expect(MarkdownLite.spans('snake_case_name と a * b * c'), [const Span('snake_case_name と a * b * c')]);
      expect(MarkdownLite.spans('_斜め_ です'), [const Span('斜め', italic: true), const Span(' です')]);
    });

    test('リンクと、文の途中のアドレス（日本語の直前で終わる）', () {
      expect(MarkdownLite.spans('[公式](https://docs.fireworks.ai/guides) を見る'), [
        const Span('公式', link: 'https://docs.fireworks.ai/guides'),
        const Span(' を見る'),
      ]);
      expect(MarkdownLite.spans('詳しくは https://fireworks.ai/pricing。確認してください'), [
        const Span('詳しくは '),
        const Span('https://fireworks.ai/pricing', link: 'https://fireworks.ai/pricing'),
        const Span('。確認してください'),
      ]);
      expect(MarkdownLite.spans('(https://a.example/x)').map((s) => s.link), [null, 'https://a.example/x', null]);
    });

    test('http(s) と mailto 以外のリンクは、リンクにしない（javascript: など）', () {
      expect(MarkdownLite.spans('[x](javascript:alert(1))'), [const Span('[x](javascript:alert(1))')]);
    });

    test('途中までのストリームでは、記号がそのまま見え、閉じたら記法になる', () {
      expect(MarkdownLite.spans('**太'), [const Span('**太')]);
      expect(MarkdownLite.spans('`co'), [const Span('`co')]);
      expect(MarkdownLite.spans('[公式](https://exa'), [const Span('[公式](')] + [const Span('https://exa', link: 'https://exa')]);
    });

    test('バックスラッシュで記号をそのまま出す。<br> は改行', () {
      expect(MarkdownLite.spans(r'\*a\* と 1\. b'), [const Span('*a* と 1. b')]);
      expect(MarkdownLite.spans('a<br>b'), [const Span('a\nb')]);
    });
  });

  test('Fireworks の回答のような、見出し・表・太字・リンクが混ざった返信', () {
    const reply = '## 結論から\n\nFireworks.ai には **「spot モデル」という製品カテゴリは存在しません**。\n\n'
        '| 形態 | 課金 |\n|---|---|\n| Serverless | トークン課金 |\n\n'
        '- **容量モデル**：アイドル状態の GPU を借りる\n- 作成方法：`firectl deployment create` に `--preemptible`\n\n'
        '---\n\n([docs](https://docs.fireworks.ai/guides/ondemand-deployments))\n\n```bash\nfirectl deployment create --preemptible\n```';
    final blocks = MarkdownLite.parse(reply);
    expect(blocks.map((b) => b.runtimeType), [Heading, Paragraph, TableBlock, ListBlock, Rule, Paragraph, CodeBlock]);
    expect((blocks[1] as Paragraph).spans[1].bold, isTrue);
    expect((blocks[3] as ListBlock).items[1].spans[1], const Span('firectl deployment create', code: true));
    expect((blocks[5] as Paragraph).spans.any((s) => s.link == 'https://docs.fireworks.ai/guides/ondemand-deployments'), isTrue);
    expect((blocks[6] as CodeBlock).closed, isTrue);
  });
}
