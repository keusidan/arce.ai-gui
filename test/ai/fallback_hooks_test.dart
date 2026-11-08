import 'package:arce_ai/ai/fallback.dart';
import 'package:arce_ai/ai/provider.dart';
import 'package:arce_ai/ai/provider_config.dart';
import 'package:arce_ai/core/generation.dart';
import 'package:flutter_test/flutter_test.dart';

class P implements AiProvider {
  P(this.modelId, this.script);

  @override
  final String modelId;
  final Stream<Delta> Function() script;

  @override
  String get id => 'p';
  @override
  String get label => 'P';
  @override
  ModelConfig? get modelConfig => null;
  @override
  ProviderCapabilities get capabilities => const ProviderCapabilities();
  @override
  Stream<Delta> stream(AiRequest request) => script();
  @override
  Future<void> verify() async {}
}

Stream<Delta> fails(int status) => Stream.error(AiProviderException('failed', statusCode: status, body: 'limit: 0'));
Stream<Delta> answers() => Stream.fromIterable(const [TextDelta('ok'), StopDelta(FinishReason.eog)]);

AiRequest request(AiProvider provider) => const AiRequest(messages: []);

void main() {
  test('the failure hook hears of every model that failed, and the error it returns is the one thrown', () async {
    final heard = <String>[];
    final stream = streamWithFallback(
      primary: P('a', () => fails(429)),
      plan: null,
      build: request,
      onFailure: (provider, error) {
        heard.add(provider.modelId);
        return AiProviderException('decorated', statusCode: (error as AiProviderException).statusCode, body: error.body);
      },
    );
    await expectLater(stream.toList(), throwsA(isA<AiProviderException>().having((e) => e.message, 'message', 'decorated').having((e) => e.statusCode, 'status', 429)));
    expect(heard, ['a']);
  });

  test('the fallback still reads the original error: a decorated message does not change which failures switch', () async {
    final heard = <String>[];
    final switched = <String>[];
    final plan = FallbackPlan(targets: [P('b', answers)], statuses: FallbackPolicy.defaultStatuses);
    final deltas = await streamWithFallback(
      primary: P('a', () => fails(429)),
      plan: plan,
      build: request,
      onSwitch: (from, to, reason) => switched.add('${from.modelId}>${to.modelId}'),
      onFailure: (provider, error) {
        heard.add(provider.modelId);
        return StateError('decorated');
      },
      onSuccess: (provider) => heard.add('ok:${provider.modelId}'),
    ).toList();
    expect(switched, ['a>b']);
    expect(heard, ['a', 'ok:b'], reason: 'the model that failed is told, then the one that answered');
    expect(deltas.whereType<TextDelta>().single.text, 'ok');
  });

  test('every model of a failing chain is told, and the last error is thrown with the hook\'s text', () async {
    final heard = <String>[];
    final plan = FallbackPlan(targets: [P('b', () => fails(404))], statuses: FallbackPolicy.defaultStatuses);
    await expectLater(
      streamWithFallback(
        primary: P('a', () => fails(429)),
        plan: plan,
        build: request,
        onFailure: (provider, error) {
          heard.add(provider.modelId);
          return AiProviderException('from ${provider.modelId}', statusCode: (error as AiProviderException).statusCode);
        },
      ).toList(),
      throwsA(isA<AiProviderException>().having((e) => e.message, 'message', 'from b')),
    );
    expect(heard, ['a', 'b']);
  });

  test('the success hook is told once, of the model that answered; nothing is told when there are no hooks', () async {
    final told = <String>[];
    await streamWithFallback(primary: P('a', answers), plan: null, build: request, onSuccess: (p) => told.add(p.modelId)).toList();
    expect(told, ['a']);
    await streamWithFallback(primary: P('a', answers), plan: null, build: request).toList();
    await expectLater(streamWithFallback(primary: P('a', () => fails(500)), plan: null, build: request).toList(), throwsA(isA<AiProviderException>().having((e) => e.message, 'message', 'failed')));
  });

  test('a failure after something was sent is not hidden, and is still told', () async {
    final heard = <String>[];
    final plan = FallbackPlan(targets: [P('b', answers)], statuses: FallbackPolicy.defaultStatuses);
    final half = P('a', () async* {
      yield const TextDelta('half');
      throw const AiProviderException('cut', statusCode: 503);
    });
    await expectLater(
      streamWithFallback(primary: half, plan: plan, build: request, onFailure: (p, e) {
        heard.add(p.modelId);
        return e;
      }).toList(),
      throwsA(isA<AiProviderException>()),
    );
    expect(heard, ['a']);
  });
}
