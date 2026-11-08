import 'dart:async';
import 'dart:io';

import 'package:arce_ai/ai/cloud_engine.dart';
import 'package:arce_ai/ai/fallback.dart';
import 'package:arce_ai/ai/provider.dart';
import 'package:arce_ai/ai/provider_config.dart';
import 'package:arce_ai/core/engine.dart';
import 'package:arce_ai/core/generation.dart';
import 'package:arce_ai/core/prompt.dart';
import 'package:flutter_test/flutter_test.dart';

/// A provider that fails (with [error], before or after [before] deltas) or streams [deltas].
class _Fake implements AiProvider {
  _Fake(this.id, this.modelId, {this.deltas = const [], this.error, this.after = false});

  @override
  final String id;
  @override
  final String modelId;
  final List<Delta> deltas;
  final Object? error;

  /// Fail after the deltas were sent instead of before.
  final bool after;
  final requests = <AiRequest>[];

  @override
  String get label => id;
  @override
  ModelConfig? get modelConfig => null;
  @override
  ProviderCapabilities get capabilities => const ProviderCapabilities(tools: true);
  @override
  Future<void> verify() async {}

  @override
  Stream<Delta> stream(AiRequest request) async* {
    requests.add(request);
    if (error != null && !after) throw error!;
    for (final d in deltas) {
      yield d;
    }
    if (error != null && after) throw error!;
  }
}

AiRequest _build(AiProvider p) => AiRequest(messages: const [AiMessage(AiRole.user, text: 'hi')], model: p.modelId);

const _forbidden = AiProviderException('APIキーが受け付けられませんでした（HTTP 403）', statusCode: 403);

void main() {
  group('ルール', () {
    test('モデルを名指ししたものが、提供元全体のものに、さらに全体のものに勝つ', () {
      const rules = [
        FallbackRule(from: '*', targets: ['d|x']),
        FallbackRule(from: 'orca|*', targets: ['d|y']),
        FallbackRule(from: 'orca|free-model', targets: ['d|z']),
      ];
      expect(FallbackPolicy.ruleFor(rules, 'orca', 'free-model')!.targets, ['d|z']);
      expect(FallbackPolicy.ruleFor(rules, 'orca', 'other')!.targets, ['d|y']);
      expect(FallbackPolicy.ruleFor(rules, 'groq', 'any')!.targets, ['d|x']);
      expect(FallbackPolicy.ruleFor(const [FallbackRule(from: 'orca|a', targets: ['d|x'])], 'orca', 'b'), isNull);
    });

    test('書き出して読み戻せる。使えない項目は捨てる', () {
      const rule = FallbackRule(from: 'orca|free', targets: ['deepinfra|deepseek-ai/DeepSeek-V3'], statuses: {429, 403});
      final back = FallbackRule.fromJson(rule.toJson())!;
      expect(back.from, 'orca|free');
      expect(back.targets, ['deepinfra|deepseek-ai/DeepSeek-V3']);
      expect(back.statuses, {403, 429});
      expect(FallbackRule.fromJson({'from': 'a|b', 'targets': ['no-bar']}), isNull);
      expect(FallbackRule.fromJson({'from': 5, 'targets': ['a|b']}), isNull);
      expect(FallbackRule.fromJson({'from': 'a|b', 'targets': ['a|b'], 'statuses': [99, 700, 'x', 429]})!.statuses, {429});
      expect(FallbackRule.decodeList('nope'), isEmpty);
    });
  });

  group('どの失敗で次へ行くか', () {
    test('既定は 401・403・404・408・429 と、すべての 5xx、接続の失敗。400 は行かない', () {
      const d = FallbackPolicy.defaultStatuses;
      for (final code in [401, 403, 404, 408, 429, 500, 502, 503]) {
        expect(FallbackPolicy.accepts(AiProviderException('x', statusCode: code), d), isTrue, reason: '$code');
      }
      expect(FallbackPolicy.accepts(const AiProviderException('x', statusCode: 400), d), isFalse);
      expect(FallbackPolicy.accepts(const AiProviderException('読み取れませんでした'), d), isFalse);
      expect(FallbackPolicy.accepts(const SocketException('no route'), d), isTrue);
      expect(FallbackPolicy.accepts(TimeoutException('slow'), d), isTrue);
      expect(FallbackPolicy.accepts(StateError('bug'), d), isFalse);
    });

    test('ルールに書いた番号だけにもできる（5xx は常に行く）', () {
      expect(FallbackPolicy.accepts(const AiProviderException('x', statusCode: 403), {429}), isFalse);
      expect(FallbackPolicy.accepts(const AiProviderException('x', statusCode: 429), {429}), isTrue);
      expect(FallbackPolicy.accepts(const AiProviderException('x', statusCode: 503), {429}), isTrue);
    });
  });

  group('streamWithFallback', () {
    final text = [const TextDelta('代わりの答え'), const StopDelta(FinishReason.eog)];

    test('使えないモデルの代わりに、次のモデルが答える。そのモデルの設定でリクエストを作り、切り替えを知らせる', () async {
      final primary = _Fake('orca', 'free-model', error: _forbidden);
      final backup = _Fake('deepinfra', 'deepseek', deltas: text);
      final switches = <String>[];
      final deltas = await streamWithFallback(
        primary: primary,
        plan: FallbackPlan(targets: [backup], statuses: FallbackPolicy.defaultStatuses),
        build: _build,
        onSwitch: (from, to, reason) => switches.add('${from.id}→${to.id}: $reason'),
      ).toList();
      expect([for (final d in deltas) if (d is TextDelta) d.text], ['代わりの答え']);
      expect(switches, ['orca→deepinfra: HTTP 403']);
      expect(backup.requests.single.model, 'deepseek');
    });

    test('最初のモデルが答えられたら、次は呼ばない', () async {
      final primary = _Fake('a', 'm', deltas: text);
      final backup = _Fake('b', 'n', deltas: text);
      await streamWithFallback(
        primary: primary,
        plan: FallbackPlan(targets: [backup], statuses: FallbackPolicy.defaultStatuses),
        build: _build,
      ).toList();
      expect(backup.requests, isEmpty);
    });

    test('途中まで答えたあとの失敗は隠さない（返信はもうそのモデルが書き始めている）', () async {
      final primary = _Fake('a', 'm', deltas: [const TextDelta('途中')], error: _forbidden, after: true);
      final backup = _Fake('b', 'n', deltas: text);
      await expectLater(
        streamWithFallback(
          primary: primary,
          plan: FallbackPlan(targets: [backup], statuses: FallbackPolicy.defaultStatuses),
          build: _build,
        ).toList(),
        throwsA(isA<AiProviderException>()),
      );
      expect(backup.requests, isEmpty);
    });

    test('代わりにならない失敗（400 など）は、そのまま返す', () async {
      final primary = _Fake('a', 'm', error: const AiProviderException('bad request', statusCode: 400));
      final backup = _Fake('b', 'n', deltas: text);
      await expectLater(
        streamWithFallback(
          primary: primary,
          plan: FallbackPlan(targets: [backup], statuses: FallbackPolicy.defaultStatuses),
          build: _build,
        ).toList(),
        throwsA(isA<AiProviderException>().having((e) => e.statusCode, 'status', 400)),
      );
      expect(backup.requests, isEmpty);
    });

    test('順に試し、最後まで失敗したら最後の失敗を返す', () async {
      final a = _Fake('a', 'm', error: _forbidden);
      final b = _Fake('b', 'n', error: const AiProviderException('busy', statusCode: 503));
      final c = _Fake('c', 'o', error: const AiProviderException('limit', statusCode: 429));
      final switches = <String>[];
      await expectLater(
        streamWithFallback(
          primary: a,
          plan: FallbackPlan(targets: [b, c], statuses: FallbackPolicy.defaultStatuses),
          build: _build,
          onSwitch: (f, t, r) => switches.add('${f.id}→${t.id}'),
        ).toList(),
        throwsA(isA<AiProviderException>().having((e) => e.statusCode, 'status', 429)),
      );
      expect(switches, ['a→b', 'b→c']);
    });

    test('プランが無ければ、これまでどおり失敗をそのまま返す', () async {
      await expectLater(
        streamWithFallback(primary: _Fake('a', 'm', error: _forbidden), plan: null, build: _build).toList(),
        throwsA(isA<AiProviderException>()),
      );
    });
  });

  group('CloudEngine', () {
    GenerateRequest request() => GenerateRequest(
          prompt: ChatMlPromptBuilder.build(const [UserTurn('こんにちは')], const [], null, false),
          toolCallSchema: null,
          thinking: false,
          maxTokens: 256,
          sampling: const SamplingParams(temperature: 0.3, topP: 0.9, topK: 20, minP: 0),
        );

    test('403 のとき、ルールの次のモデルで答え、切り替えを知らせる', () async {
      final primary = _Fake('orca', 'free', error: _forbidden);
      final backup = _Fake('deepinfra', 'deepseek', deltas: [const TextDelta('こんにちは！'), const StopDelta(FinishReason.eog)]);
      final engine = CloudEngine(primary)
        ..fallbackFor = ((p) => FallbackPlan(targets: [backup], statuses: FallbackPolicy.defaultStatuses));
      AiProvider? took;
      engine.onFallback = (from, to, reason) => took = to;
      final events = await engine.generate(request()).toList();
      expect(events.whereType<Piece>().map((e) => e.text).join(), contains('こんにちは！'));
      expect(took, same(backup));
    });

    test('ルールが無ければ、失敗はそのまま EngineException になる', () async {
      final engine = CloudEngine(_Fake('orca', 'free', error: _forbidden));
      await expectLater(engine.generate(request()).toList(), throwsA(isA<EngineException>()));
    });
  });
}
