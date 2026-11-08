import 'dart:convert';

import 'package:arce_ai/ai/cloud_engine.dart';
import 'package:arce_ai/ai/provider.dart';
import 'package:arce_ai/ai/provider_config.dart';
import 'package:arce_ai/ai/thinking_config.dart';
import 'package:arce_ai/core/engine.dart';
import 'package:arce_ai/core/generation.dart';
import 'package:arce_ai/core/prompt.dart';
import 'package:arce_ai/core/protocol.dart';
import 'package:arce_ai/core/stream_segmenter.dart' hide ToolCallDelta;
import 'package:flutter_test/flutter_test.dart';

const _sampling = SamplingParams(
  temperature: 0.3,
  topP: 0.9,
  topK: 20,
  minP: 0,
);

GenerateRequest _request({int maxTokens = 256}) => GenerateRequest(
  prompt: ChatMlPromptBuilder.build(
    const [UserTurn('こんにちは')],
    const [],
    null,
    false,
  ),
  toolCallSchema: null,
  thinking: false,
  maxTokens: maxTokens,
  sampling: _sampling,
);

/// A provider that streams a fixed list and remembers the request it was given.
class _FixedProvider implements AiProvider {
  _FixedProvider(this.deltas);

  final List<Delta> deltas;
  AiRequest? last;

  @override
  String get id => 'fixed';

  @override
  String get modelId => '';

  @override
  ModelConfig? get modelConfig => null;

  @override
  String get label => '固定';

  @override
  ProviderCapabilities get capabilities =>
      const ProviderCapabilities(tools: true);

  @override
  Future<void> verify() async {}

  @override
  Stream<Delta> stream(AiRequest request) async* {
    last = request;
    for (final delta in deltas) {
      yield delta;
    }
  }
}

/// A provider with a given model and model settings, that remembers the request.
class _ModelProvider implements AiProvider {
  _ModelProvider(this.modelId, this.modelConfig, {this.tools = false});

  final bool tools;

  @override
  final String modelId;
  @override
  final ModelConfig? modelConfig;
  AiRequest? last;

  @override
  String get id => 'model';
  @override
  String get label => 'モデル';
  @override
  ProviderCapabilities get capabilities => ProviderCapabilities(tools: tools);
  @override
  Future<void> verify() async {}

  @override
  Stream<Delta> stream(AiRequest request) async* {
    last = request;
    yield const StopDelta(FinishReason.eog);
  }
}

/// A provider whose endpoint or key is wrong.
class _FailingProvider implements AiProvider {
  @override
  String get id => 'failing';

  @override
  String get modelId => '';

  @override
  ModelConfig? get modelConfig => null;

  @override
  String get label => '失敗';

  @override
  ProviderCapabilities get capabilities => const ProviderCapabilities();

  @override
  Future<void> verify() async =>
      throw const AiProviderException('APIキーが受け付けられませんでした（HTTP 401）');

  @override
  Stream<Delta> stream(AiRequest request) async* {
    throw const AiProviderException('APIキーが受け付けられませんでした（HTTP 401）');
  }
}

void main() {
  test('本文を順に流し、最後に理由を返す', () async {
    final engine = CloudEngine(
      _FixedProvider(const [
        TextDelta('こん'),
        TextDelta('にちは'),
        StopDelta(FinishReason.eog),
      ]),
    );
    final events = await engine.generate(_request()).toList();
    expect(events.whereType<Piece>().map((p) => p.text).join(), 'こんにちは');
    expect((events.last as Finished).reason, FinishReason.eog);
  });

  test('プロンプトはシステムとユーザーのメッセージになり、設定がそのまま渡る', () async {
    final provider = _FixedProvider(const [
      TextDelta('ok'),
      StopDelta(FinishReason.eog),
    ]);
    await CloudEngine(provider).generate(_request(maxTokens: 128)).toList();

    final sent = provider.last!;
    expect(sent.messages.first.role, AiRole.system);
    expect(sent.messages.last.role, AiRole.user);
    expect(sent.messages.last.text, 'こんにちは');
    expect(sent.maxTokens, 128);
    expect(sent.temperature, 0.3);
    expect(sent.topP, 0.9);
  });

  test('思考はセグメンタが思考として読む', () async {
    final engine = CloudEngine(
      _FixedProvider(const [
        ReasoningDelta('考え中'),
        TextDelta('答え'),
        StopDelta(FinishReason.eog),
      ]),
    );
    final thinking = StringBuffer();
    final answer = StringBuffer();
    final segmenter = StreamSegmenter();
    for (final event in segmenter.feed(await _piecesOf(engine))) {
      switch (event) {
        case ThinkingText(:final text):
          thinking.write(text);
        case PlainText(:final text):
          answer.write(text);
        default:
          break;
      }
    }
    for (final event in segmenter.finish()) {
      if (event is ThinkingText) thinking.write(event.text);
      if (event is PlainText) answer.write(event.text);
    }
    expect(thinking.toString(), '考え中');
    expect(answer.toString(), '答え');
  });

  test('道具の呼び出しは、既存の解析でそのまま読める', () async {
    final engine = CloudEngine(
      _FixedProvider(const [
        ToolCallDelta(
          id: 'call_1',
          name: 'web_search',
          argumentsJson: '{"query": "天気"}',
        ),
        StopDelta(FinishReason.eog),
      ]),
    );
    final segmenter = StreamSegmenter();
    final bodies = <String>[];
    for (final event in segmenter.feed(await _piecesOf(engine))) {
      if (event is ToolCallEnd) bodies.add(event.json);
    }
    expect(bodies, hasLength(1));
    final body = jsonDecode(bodies.single) as Map<String, Object?>;
    expect(body['name'], 'web_search');
    expect(body['arguments'], {'query': '天気'});
  });

  test('理由を送らずに終わるプロバイダでも、終わりは eog になる', () async {
    final events = await CloudEngine(_FixedProvider(const [TextDelta('途中')]))
        .generate(_request())
        .toList();
    expect((events.last as Finished).reason, FinishReason.eog);
  });

  test('プロバイダの失敗は、その文言のままエンジンのエラーになる', () async {
    await expectLater(
      CloudEngine(_FailingProvider()).generate(_request()).toList(),
      throwsA(
        isA<EngineException>().having(
          (e) => e.message,
          'message',
          contains('APIキー'),
        ),
      ),
    );
  });

  test('何も組み立てられないプロンプトは送らない', () async {
    final provider = _FixedProvider(const []);
    final request = GenerateRequest(
      prompt: 'ChatML ではない文',
      toolCallSchema: null,
      thinking: false,
      maxTokens: 16,
      sampling: _sampling,
    );
    await expectLater(
      CloudEngine(provider).generate(request).toList(),
      throwsA(isA<EngineException>()),
    );
    expect(provider.last, isNull);
  });

  group('送る値の優先順位', () {
    GenerateRequest request({UserSampling user = const UserSampling(), int maxTokens = 2048}) => GenerateRequest(
          prompt: ChatMlPromptBuilder.build(const [UserTurn('こんにちは')], const [], null, false),
          toolCallSchema: null,
          thinking: false,
          maxTokens: maxTokens,
          sampling: _sampling,
          user: user,
        );

    Future<AiRequest> sent(String modelId, ModelConfig? config, GenerateRequest r) async {
      final provider = _ModelProvider(modelId, config);
      await CloudEngine(provider).generate(r).toList();
      return provider.last!;
    }

    test('設定が何もない DeepSeek V4 は、公式の推奨（temperature 1.0・top_p 1.0・最大256K）で送る', () async {
      final r = await sent('deepseek-ai/DeepSeek-V4.1-Flash-1017', null, request());
      expect(r.temperature, 1.0);
      expect(r.topP, 1.0);
      expect(r.maxTokens, 262144, reason: 'not the 2048 default that cut the answers short');
    });

    test('推奨のないモデルは、これまでどおりアプリの既定値', () async {
      final r = await sent('gpt-4o', null, request());
      expect(r.temperature, 0.3);
      expect(r.topP, 0.9);
      expect(r.maxTokens, 2048);
    });

    test('詳細設定でユーザーが決めた値は、推奨より強い', () async {
      final r = await sent(
        'deepseek-v4-flash',
        null,
        request(user: const UserSampling(temperature: 0.5, topP: 0.8, maxTokens: 9000), maxTokens: 9000),
      );
      expect(r.temperature, 0.5);
      expect(r.topP, 0.8);
      expect(r.maxTokens, 9000);
    });

    test('モデルごとの設定は、いちばん強い', () async {
      final config = const ModelConfig(id: 'deepseek-v4-flash', name: 'x', params: {'temperature': 0.2, 'topP': 0.7, 'maxTokens': 12345});
      final r = await sent('deepseek-v4-flash', config, request(user: const UserSampling(temperature: 0.5, maxTokens: 9000), maxTokens: 9000));
      expect(r.temperature, 0.2);
      expect(r.topP, 0.7);
      expect(r.maxTokens, 12345);
    });

    test('思考の送り方を選んだモデルにだけ、思考の項目が付く。チャットのスイッチと速度⇔精度に従う', () async {
      const plain = ModelConfig(id: 'zai-org/GLM-5.3', name: 'x');
      expect((await sent('zai-org/GLM-5.3', plain, request())).extraBody, isEmpty, reason: 'nothing chosen, nothing sent');

      const glm = ModelConfig(
        id: 'zai-org/GLM-5.3',
        name: 'x',
        thinking: ThinkingConfig(format: ThinkingFormat.zaiApi, clearThinking: true),
      );
      GenerateRequest withThinking(bool on, double accuracy) => GenerateRequest(
            prompt: ChatMlPromptBuilder.build(const [UserTurn('こんにちは')], const [], null, false),
            toolCallSchema: null,
            thinking: on,
            maxTokens: 2048,
            sampling: _sampling,
            user: UserSampling(speedAccuracy: accuracy),
          );
      final on = await sent('zai-org/GLM-5.3', glm, withThinking(true, 0.9));
      expect(on.extraBody['thinking'], {'type': 'enabled', 'clear_thinking': true});
      expect(on.extraBody['reasoning_effort'], 'max');
      final off = await sent('zai-org/GLM-5.3', glm, withThinking(false, 0.9));
      expect(off.extraBody['thinking'], {'type': 'disabled', 'clear_thinking': true});
      expect(off.extraBody.containsKey('reasoning_effort'), isFalse);
    });

    test('最大トークンは、モデルの最大出力と、文脈に残った分に収める', () async {
      final limited = const ModelConfig(id: 'deepseek-v4-flash', name: 'x', maxOutputTokens: 65536);
      expect((await sent('deepseek-v4-flash', limited, request())).maxTokens, 65536);

      final small = const ModelConfig(id: 'tiny', name: 'x', params: {'maxTokens': 100000}, contextTokens: 8192);
      final r = await sent('tiny', small, request());
      expect(r.maxTokens, lessThan(8192), reason: 'the prompt and the reply must fit the window');
      expect(r.maxTokens, greaterThan(7000));
    });
  });

  group('ツールの会話の形', () {
    const getTime = ToolDefinition(name: 'get_time', description: '時刻', parameters: {'type': 'object'});
    const call = '{"name": "get_time", "arguments": {}}';

    GenerateRequest request() => GenerateRequest(
          prompt: ChatMlPromptBuilder.build(
            const [UserTurn('いま何時'), AssistantTurn('調べます', call, '時刻を知りたい'), ToolResponseTurn('12:00')],
            const [getTime],
            null,
            false,
          ),
          toolCallSchema: '{}',
          tools: const [getTime],
          thinking: false,
          maxTokens: 256,
          sampling: _sampling,
          assistantReasoning: const ['時刻を知りたい'],
        );

    Future<AiRequest> sent(String modelId, ModelConfig? config, {bool tools = true}) async {
      final provider = _ModelProvider(modelId, config, tools: tools);
      await CloudEngine(provider).generate(request()).toList();
      return provider.last!;
    }

    test('既定は function calling：tools に 1 回、会話は tool_calls と tool メッセージ、本文にツールの説明は無い', () async {
      final r = await sent('gpt-4o', null);
      expect(r.tools.map((t) => t.name), ['get_time']);
      expect([for (final m in r.messages) m.role], [AiRole.system, AiRole.user, AiRole.assistant, AiRole.tool]);
      expect(r.messages.first.text, isNot(contains('<tools>')));
      expect(r.messages[2].toolCalls.single.name, 'get_time');
    });

    test('提供元がツールに対応していなければ、テキスト形式（説明は本文に、tools は送らない）', () async {
      final r = await sent('gpt-4o', null, tools: false);
      expect(r.tools, isEmpty);
      expect(r.messages.first.text, contains('<tools>'));
      expect(r.messages[2].text, contains('<tool_call>'));
    });

    test('「テキスト形式」を選んだモデルは、対応している提供元でもテキスト形式。tools と本文で二重にならない', () async {
      final r = await sent('gpt-4o', const ModelConfig(id: 'gpt-4o', name: 'x', toolStyle: ToolStyle.text));
      expect(r.tools, isEmpty);
      expect(r.messages.first.text, contains('<tools>'));
      expect(r.messages[3].role, AiRole.user);
    });

    test('過去の思考：DeepSeek と GLM は自動で返し、他のモデルは返さない', () async {
      final deepseek = await sent('deepseek-v4-flash', null);
      expect(deepseek.messages[2].reasoning, '時刻を知りたい');
      final glm = await sent('zai-org/GLM-5.3', null);
      expect(glm.messages[2].reasoning, '時刻を知りたい');
      final other = await sent('gpt-4o', null);
      expect(other.messages[2].reasoning, isEmpty);
    });

    test('テキスト形式のあいだは、自動では思考を返さない（ツールが function calling のときの決まりのため）', () async {
      final r = await sent('deepseek-v4-flash', const ModelConfig(id: 'deepseek-v4-flash', name: 'x', toolStyle: ToolStyle.text));
      expect([for (final m in r.messages) m.reasoning], everyElement(''));
    });

    test('「常に返す」「返さない」は、モデルの種類より強い', () async {
      final always = await sent(
        'gpt-4o',
        const ModelConfig(id: 'gpt-4o', name: 'x', thinking: ThinkingConfig(replay: ReasoningReplay.always)),
      );
      expect(always.messages[2].reasoning, '時刻を知りたい');
      final never = await sent(
        'deepseek-v4-flash',
        const ModelConfig(id: 'deepseek-v4-flash', name: 'x', thinking: ThinkingConfig(replay: ReasoningReplay.never)),
      );
      expect(never.messages[2].reasoning, isEmpty);
    });
  });
}

/// The reply text of [engine] as one piece, so the segmenter sees a normal stream.
Future<String> _piecesOf(CloudEngine engine) async {
  final text = StringBuffer();
  await for (final event in engine.generate(_request())) {
    if (event is Piece) text.write(event.text);
  }
  return text.toString();
}
