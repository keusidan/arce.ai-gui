import 'package:arce_ai/ai/cloud_engine.dart';
import 'package:arce_ai/ai/provider.dart';
import 'package:arce_ai/ai/provider_config.dart';
import 'package:arce_ai/ai/routing_engine.dart';
import 'package:arce_ai/core/engine.dart';
import 'package:arce_ai/core/generation.dart';
import 'package:arce_ai/core/prompt.dart';
import 'package:flutter_test/flutter_test.dart';

/// A provider that answers every request with one word and counts the calls.
class _CountedProvider implements AiProvider {
  _CountedProvider(this.answer);

  final String answer;
  int calls = 0;

  @override
  String get id => 'counted';

  @override
  String get modelId => '';

  @override
  ModelConfig? get modelConfig => null;

  @override
  String get label => '数える';

  @override
  ProviderCapabilities get capabilities => const ProviderCapabilities();

  @override
  Future<void> verify() async {}

  @override
  Stream<Delta> stream(AiRequest request) async* {
    calls++;
    yield TextDelta(answer);
    yield const StopDelta(FinishReason.eog);
  }
}

/// The device model, answering in its own way.
class _LocalEngine implements InferenceEngine {
  int calls = 0;
  int cancels = 0;

  @override
  bool get isLoaded => true;

  @override
  Future<void> load(LoadParams params) async {}

  @override
  Stream<GenerationEvent> generate(GenerateRequest request) async* {
    calls++;
    yield const Piece('端末');
    yield const Finished(FinishReason.eog);
  }

  @override
  void cancel() => cancels++;

  @override
  Future<void> unload() async {}
}

GenerateRequest _request() => const GenerateRequest(
  prompt: '',
  toolCallSchema: null,
  thinking: false,
  maxTokens: 16,
  sampling: SamplingParams(temperature: 0.5, topP: 1, topK: 0, minP: 0),
);

GenerateRequest _chatRequest() => GenerateRequest(
  prompt: ChatMlPromptBuilder.build(
    const [UserTurn('やあ')],
    const [],
    null,
    false,
  ),
  toolCallSchema: null,
  thinking: false,
  maxTokens: 16,
  sampling: const SamplingParams(temperature: 0.5, topP: 1, topK: 0, minP: 0),
);

Future<String> _reply(RoutingEngine engine, GenerateRequest request) async {
  final text = StringBuffer();
  await for (final event in engine.generate(request)) {
    if (event is Piece) text.write(event.text);
  }
  return text.toString();
}

void main() {
  late _LocalEngine local;
  late _CountedProvider provider;
  late RoutingEngine engine;

  setUp(() {
    local = _LocalEngine();
    provider = _CountedProvider('クラウド');
    engine = RoutingEngine(local: local, cloud: CloudEngine(provider));
  });

  test('既定は端末のエンジン', () async {
    expect(engine.isCloud, isFalse);
    expect(await _reply(engine, _request()), '端末');
    expect(local.calls, 1);
    expect(provider.calls, 0);
  });

  test('プロバイダを選ぶと、そちらで答える', () async {
    engine.target = provider;
    expect(engine.isCloud, isTrue);
    expect(engine.cloudProvider, same(provider));
    expect(await _reply(engine, _chatRequest()), 'クラウド');
    expect(provider.calls, 1);
    expect(local.calls, 0);
  });

  test('選んだ側が失敗しても、黙って端末で答え直さない', () async {
    engine.target = provider;
    await expectLater(
      engine.generate(_request()).toList(),
      throwsA(isA<EngineException>()),
    );
    expect(provider.calls, 0);
    expect(local.calls, 0);
  });

  test('端末に戻せる', () async {
    engine.target = provider;
    engine.target = null;
    expect(engine.isCloud, isFalse);
    expect(await _reply(engine, _request()), '端末');
  });

  test('取り消しは動いている側に伝わる', () {
    engine.target = provider;
    engine.cancel();
    expect(local.cancels, 1);
  });
}
