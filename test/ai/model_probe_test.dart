import 'dart:async';

import 'package:arce_ai/ai/model_availability.dart';
import 'package:arce_ai/ai/model_probe.dart';
import 'package:arce_ai/ai/provider.dart';
import 'package:arce_ai/ai/provider_config.dart';
import 'package:arce_ai/core/generation.dart';
import 'package:flutter_test/flutter_test.dart';

/// A provider that answers (or fails) per model, and records what it was asked.
class FakeProvider implements AiProvider {
  FakeProvider(this.modelId, this.script, this.requests);

  @override
  final String modelId;
  final Stream<Delta> Function(AiRequest request) script;
  final List<AiRequest> requests;

  @override
  String get id => 'fake';
  @override
  String get label => 'Fake';
  @override
  ModelConfig? get modelConfig => null;
  @override
  ProviderCapabilities get capabilities => const ProviderCapabilities();
  @override
  Stream<Delta> stream(AiRequest request) {
    requests.add(request);
    return script(request);
  }

  @override
  Future<void> verify() async {}
}

void main() {
  group('the probe', () {
    test('asks every model once, in the order given, and reports what each said', () async {
      final asked = <String>[];
      final report = await ModelProbe.run(
        modelIds: ['a', 'b', 'c'],
        concurrency: 1,
        ask: (id) async {
          asked.add(id);
          if (id == 'b') throw const AiProviderException('x', statusCode: 429, body: 'limit: 0');
          if (id == 'c') throw const AiProviderException('x', statusCode: 503);
        },
      );
      expect(asked, ['a', 'b', 'c']);
      expect([for (final o in report.outcomes) (o.modelId, o.verdict.availability)], [
        ('a', ModelAvailability.usable),
        ('b', ModelAvailability.blocked),
        ('c', ModelAvailability.temporary),
      ]);
      expect(report.notRun, 0);
      expect(report.keyRejected, isFalse);
      expect(report.summary(), '3 個を確かめました：使える 1・使えない 1・一時的な失敗 1（あとでもう一度）');
    });

    test('a model given twice is asked once', () async {
      final asked = <String>[];
      await ModelProbe.run(modelIds: ['a', 'a', 'b'], ask: (id) async => asked.add(id));
      expect(asked.toSet().length, 2);
      expect(asked, hasLength(2));
    });

    test('never more questions on their way than the setting allows, and all of them are asked', () async {
      for (final limit in [1, 2, 3, 5]) {
        var running = 0;
        var most = 0;
        final report = await ModelProbe.run(
          modelIds: [for (var i = 0; i < 12; i++) 'm$i'],
          concurrency: limit,
          ask: (id) async {
            running++;
            if (running > most) most = running;
            await Future<void>.delayed(const Duration(milliseconds: 5));
            running--;
          },
        );
        expect(most, limit, reason: 'concurrency $limit');
        expect(report.outcomes, hasLength(12));
      }
    });

    test('a concurrency below 1 still asks (one at a time); more than there are models is fine', () async {
      final r0 = await ModelProbe.run(modelIds: ['a', 'b'], concurrency: 0, ask: (_) async {});
      expect(r0.outcomes, hasLength(2));
      final r9 = await ModelProbe.run(modelIds: ['a', 'b'], concurrency: 9, ask: (_) async {});
      expect(r9.outcomes, hasLength(2));
      final none = await ModelProbe.run(modelIds: const [], ask: (_) async => fail('nothing to ask'));
      expect(none.outcomes, isEmpty);
    });

    test('stops asking when the key is refused: that is the key, not the models', () async {
      final asked = <String>[];
      final report = await ModelProbe.run(
        modelIds: [for (var i = 0; i < 10; i++) 'm$i'],
        concurrency: 1,
        ask: (id) async {
          asked.add(id);
          if (id == 'm2') throw const AiProviderException('x', statusCode: 401);
        },
      );
      expect(asked, ['m0', 'm1', 'm2'], reason: 'nothing after the refused one is asked');
      expect(report.keyRejected, isTrue);
      expect(report.notRun, 7);
      expect(report.summary(), contains('APIキーが受け付けられなかった'));
      expect(report.summary(), contains('モデルのことは分かっていません'));
    });

    test('with several on their way, the ones already asked finish and nothing new is started', () async {
      final started = <String>[];
      final report = await ModelProbe.run(
        modelIds: [for (var i = 0; i < 20; i++) 'm$i'],
        concurrency: 3,
        ask: (id) async {
          started.add(id);
          await Future<void>.delayed(const Duration(milliseconds: 5));
          if (id == 'm0') throw const AiProviderException('x', statusCode: 401);
        },
      );
      expect(started.length, lessThanOrEqualTo(3 + 2), reason: 'a few on their way when the refusal came');
      expect(report.keyRejected, isTrue);
      expect(report.outcomes.length + report.notRun, 20);
    });

    test('a question that takes too long is a time out (it will pass), not a mark', () async {
      final report = await ModelProbe.run(
        modelIds: ['slow', 'fast'],
        concurrency: 2,
        timeout: const Duration(milliseconds: 20),
        ask: (id) async {
          if (id == 'slow') await Completer<void>().future;
        },
      );
      final byId = {for (final o in report.outcomes) o.modelId: o.verdict.availability};
      expect(byId['slow'], ModelAvailability.temporary);
      expect(byId['fast'], ModelAvailability.usable);
    });

    test('can be cancelled: what was started finishes, the rest is not asked', () async {
      var stop = false;
      final asked = <String>[];
      final report = await ModelProbe.run(
        modelIds: [for (var i = 0; i < 10; i++) 'm$i'],
        concurrency: 1,
        cancelled: () => stop,
        ask: (id) async {
          asked.add(id);
          if (id == 'm1') stop = true;
        },
      );
      expect(asked, ['m0', 'm1']);
      expect(report.cancelled, isTrue);
      expect(report.notRun, 8);
      expect(report.summary(), contains('途中でやめました（残り 8 個）'));
    });

    test('tells the screen after each answer', () async {
      final seen = <String>[];
      await ModelProbe.run(
        modelIds: ['a', 'b', 'c'],
        concurrency: 1,
        ask: (_) async {},
        onOutcome: (outcome, done, total) => seen.add('${outcome.modelId} $done/$total'),
      );
      expect(seen, ['a 1/3', 'b 2/3', 'c 3/3']);
    });

    test('an error of any kind is a verdict, never an exception of the probe', () async {
      final report = await ModelProbe.run(modelIds: ['a'], ask: (_) async => throw StateError('boom'));
      expect(report.outcomes.single.verdict.availability, ModelAvailability.unknown);
    });
  });

  group('the question', () {
    test('is one word, no tools, the smallest reply, no randomness', () async {
      final requests = <AiRequest>[];
      final provider = FakeProvider('gemini-2.5-flash', (_) => Stream.fromIterable(const [TextDelta('h'), StopDelta(FinishReason.eog)]), requests);
      await ModelProbe.askOnce(provider);
      final request = requests.single;
      expect(request.model, 'gemini-2.5-flash');
      expect(request.maxTokens, 1);
      expect(request.tools, isEmpty);
      expect(request.messages, hasLength(1));
      expect(request.messages.single.role, AiRole.user);
      expect(request.messages.single.text, 'hi');
      expect(request.temperature, 0);
    });

    test('returns at the first sign of an answer (text, thinking, a tool call, or the end)', () async {
      for (final first in <Delta>[const TextDelta('x'), const ReasoningDelta('x'), const ToolCallDelta(name: 'n', argumentsJson: '{}'), const StopDelta(FinishReason.length)]) {
        var rest = false;
        final provider = FakeProvider('m', (_) async* {
          yield first;
          rest = true;
          yield const TextDelta('more');
        }, []);
        await ModelProbe.askOnce(provider);
        expect(rest, isFalse, reason: '$first: the rest of the reply is not read');
      }
    });

    test('an answer that ends without a word still counts: the model was reached', () async {
      final provider = FakeProvider('m', (_) => const Stream<Delta>.empty(), []);
      await ModelProbe.askOnce(provider);
    });

    test('a failure is thrown as the provider threw it, so the verdict can be read from it', () async {
      final provider = FakeProvider('m', (_) => Stream<Delta>.error(const AiProviderException('x', statusCode: 429, body: 'limit: 0')), []);
      await expectLater(ModelProbe.askOnce(provider), throwsA(isA<AiProviderException>()));
      try {
        await ModelProbe.askOnce(provider);
      } catch (e) {
        expect(AvailabilityClassifier.classifyError(e).availability, ModelAvailability.blocked);
      }
    });

    test('a request that was dropped after the time (the provider says cancelled) is a time out', () async {
      final provider = FakeProvider('m', (request) async* {
        await request.abort;
        yield const StopDelta(FinishReason.cancelled);
      }, []);
      await expectLater(ModelProbe.askOnce(provider, abortAfter: const Duration(milliseconds: 10)), throwsA(isA<TimeoutException>()));
    });

    test('the pieces together: a provider that fails per model gives the right marks', () async {
      Stream<Delta> answer(String model) => switch (model) {
            'free-ok' => Stream.fromIterable(const [TextDelta('h'), StopDelta(FinishReason.eog)]),
            'paid-only' => Stream.error(const AiProviderException('x', statusCode: 429, body: '{"error":{"message":"limit: 0, model: paid-only"}}')),
            'gone' => Stream.error(const AiProviderException('x', statusCode: 404, body: '{"error":{"message":"models/gone is not found"}}')),
            _ => Stream.error(const AiProviderException('x', statusCode: 503)),
          };
      final report = await ModelProbe.run(
        modelIds: ['free-ok', 'paid-only', 'gone', 'busy'],
        concurrency: 2,
        ask: (id) => ModelProbe.askOnce(FakeProvider(id, (_) => answer(id), [])),
      );
      expect({for (final o in report.outcomes) o.modelId: o.verdict.availability}, {
        'free-ok': ModelAvailability.usable,
        'paid-only': ModelAvailability.blocked,
        'gone': ModelAvailability.blocked,
        'busy': ModelAvailability.temporary,
      });
    });
  });
}
