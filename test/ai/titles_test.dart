import 'dart:async';

import 'package:arce_ai/ai/provider.dart';
import 'package:arce_ai/ai/provider_config.dart';
import 'package:arce_ai/ai/thinking_config.dart';
import 'package:arce_ai/ai/titles.dart';
import 'package:flutter_test/flutter_test.dart';

class _Titler implements AiProvider {
  _Titler(this.answer, {ModelConfig? model}) : modelConfig = model;
  final Object Function() answer; // a String, or throws
  final requests = <AiRequest>[];

  @override
  final ModelConfig? modelConfig;
  @override
  String get id => 't';
  @override
  String get label => 'T';
  @override
  String get modelId => 'm';
  @override
  ProviderCapabilities get capabilities => const ProviderCapabilities();
  @override
  Future<void> verify() async {}

  @override
  Stream<Delta> stream(AiRequest request) async* {
    requests.add(request);
    final a = answer();
    for (var i = 0; i < '$a'.length; i += 3) {
      yield TextDelta('$a'.substring(i, i + 3 > '$a'.length ? '$a'.length : i + 3));
    }
  }
}

void main() {
  group('モデルの答えからタイトルを取り出す', () {
    String? clean(String s, {int max = 30}) => TitleMaker.clean(s, maxChars: max);

    test('1 行目だけ。引用符・かぎ括弧・「タイトル:」・Markdown の印・末尾の句点は外す', () {
      expect(clean('「Link-Cut Tree の実装」'), 'Link-Cut Tree の実装');
      expect(clean('"Dynamic MST"\n\n説明です'), 'Dynamic MST');
      expect(clean('タイトル：天気の質問'), '天気の質問');
      expect(clean('Title: Weather question.'), 'Weather question');
      expect(clean('## **画像の作り方**。'), '画像の作り方');
      expect(clean('『「二重」』'), '二重');
    });

    test('思考のブロックは読まない。空なら null', () {
      expect(clean('<think>考え中…\nいろいろ</think>\n競技プログラミング'), '競技プログラミング');
      expect(clean('   \n  '), isNull);
      expect(clean('「」'), isNull);
    });

    test('最大文字数で切る（サロゲートペアを割らない）', () {
      expect(clean('あいうえおかきくけこ', max: 5), 'あいうえお');
      expect(clean('😀😀😀😀', max: 2), '😀😀');
    });
  });

  test('make: 最初の質問と答えを渡し、思考を切る指定を付け、きれいにしたタイトルを返す', () async {
    final provider = _Titler(() => '「Link-Cut Tree の相談」', model: const ModelConfig(id: 'm', name: 'm', thinking: ThinkingConfig(format: ThinkingFormat.deepseekApi)));
    final title = await TitleMaker.make(provider, question: 'LCT を実装して', answer: 'はい、こうです…', maxChars: 20);
    expect(title, 'Link-Cut Tree の相談');
    final request = provider.requests.single;
    expect(request.messages.first.text, allOf(contains('At most 20 characters'), contains('title only')));
    expect(request.messages.last.text, allOf(contains('LCT を実装して'), contains('はい、こうです')));
    expect(request.extraBody['thinking'], {'type': 'disabled'}, reason: 'a title does not need thinking');
  });

  test('make: 長い質問と答えは、頭の部分だけを渡す', () async {
    final provider = _Titler(() => 'x');
    await TitleMaker.make(provider, question: 'あ' * 5000, answer: 'い' * 5000);
    expect(provider.requests.single.messages.last.text.length, lessThan(1300));
  });

  test('make: 失敗しても投げず、null を返す（タイトルは無くても会話は困らない）', () async {
    expect(await TitleMaker.make(_Titler(() => throw StateError('boom')), question: 'q', answer: 'a'), isNull);
    expect(await TitleMaker.make(_Titler(() => ''), question: 'q', answer: 'a'), isNull);
  });
}
