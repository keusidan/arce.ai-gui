import 'dart:async';

import '../core/engine.dart';
import 'fallback.dart';
import 'model_hints.dart';
import 'provider.dart';
import 'thinking_config.dart';

/// One model that can be given a job: an online provider's model, or the model on the device.
abstract interface class RoleModel {
  /// What the reply says about who did the work.
  String get label;

  /// How many requests may run at once. The device model runs one; an online one several.
  int get maxParallel;

  /// Whether it runs on the device, which only one chat at a time can use.
  bool get usesDevice;

  /// Sends [messages] and returns the whole answer. [cancelled] is checked while it streams.
  /// [maxTokens] 0 means "decide": the model's own setting, the maker's recommendation, then
  /// [autoTokens].
  Future<String> ask(
    List<AiMessage> messages, {
    required int maxTokens,
    required bool Function() cancelled,
    double temperature = 0.3,
    int autoTokens = 4096,
  });

  /// Stops whatever is running on this model.
  void cancel();
}

/// An online model, asked through its provider.
class ProviderRole implements RoleModel {
  ProviderRole(this.provider, {this.maxParallel = 4, this.fallback, this.onFallback});

  final AiProvider provider;

  @override
  final int maxParallel;

  @override
  bool get usesDevice => false;

  /// The models to try when this one fails in a way another model may not share.
  final FallbackPlan? fallback;
  final void Function(AiProvider from, AiProvider to, String reason)? onFallback;

  @override
  String get label => '${provider.label} · ${provider.modelId}';

  AiRequest _requestFor(
    AiProvider target,
    List<AiMessage> messages, {
    required int maxTokens,
    required double temperature,
    required int autoTokens,
  }) {
    final model = target.modelConfig;
    final hint = ModelHints.of(target.modelId);
    return AiRequest(
      messages: messages,
      model: target.modelId,
      // a number typed in the coding settings is the user's; 0 leaves it to the model
      maxTokens: ModelHints.resolveMaxTokens(
        modelSetting: maxTokens > 0 ? maxTokens : model?.intParam('maxTokens'),
        requestedIsUserSet: false,
        requested: autoTokens,
        hint: hint,
        maxOutput: model?.maxOutputTokens,
        context: model?.contextTokens,
        promptTokens: ModelHints.estimateTokens([for (final m in messages) m.text].join('\n')),
      ),
      // the maker's recommended sampling replaces the role's own (a reasoning model does not
      // want the low temperature that suits a plain one)
      temperature: model?.param('temperature') ?? hint?.temperature ?? temperature,
      topP: model?.param('topP') ?? hint?.topP ?? 0.95,
      // a role has no thinking switch of its own: "auto" means thinking on, at the middle of the slider
      extraBody: ThinkingRequest.fields(model?.thinking ?? ThinkingConfig.none, appThinking: true, speedAccuracy: 0.6),
    );
  }

  @override
  Future<String> ask(
    List<AiMessage> messages, {
    required int maxTokens,
    required bool Function() cancelled,
    double temperature = 0.3,
    int autoTokens = 4096,
  }) async {
    final out = StringBuffer();
    try {
      final deltas = streamWithFallback(
        primary: provider,
        plan: fallback,
        build: (target) => _requestFor(target, messages, maxTokens: maxTokens, temperature: temperature, autoTokens: autoTokens),
        onSwitch: onFallback,
      );
      await for (final delta in deltas.takeWhile((_) => !cancelled())) {
        if (delta is TextDelta) out.write(delta.text);
      }
    } on AiProviderException catch (e) {
      throw EngineException(e.message);
    }
    return out.toString();
  }

  /// The request is dropped when [ask] sees `cancelled()`; there is nothing else to stop.
  @override
  void cancel() {}
}

/// The model on the device. One request at a time, and it answers without a thinking block.
class LocalRole implements RoleModel {
  LocalRole(this.engine, {this.name = 'ローカルモデル'});

  final InferenceEngine engine;
  final String name;

  @override
  int get maxParallel => 1;

  @override
  bool get usesDevice => true;

  @override
  String get label => name;

  @override
  Future<String> ask(
    List<AiMessage> messages, {
    required int maxTokens,
    required bool Function() cancelled,
    double temperature = 0.3,
    int autoTokens = 4096,
  }) async {
    final out = StringBuffer();
    final request = GenerateRequest(
      prompt: chatMl(messages),
      toolCallSchema: null,
      thinking: false,
      maxTokens: maxTokens > 0 ? maxTokens : autoTokens,
      sampling: SamplingParams(temperature: temperature, topP: 0.8, topK: 20, minP: 0),
    );
    await for (final event in engine.generate(request)) {
      if (cancelled()) break;
      if (event is Piece) out.write(event.text);
    }
    return out.toString();
  }

  @override
  void cancel() => engine.cancel();

  /// The ChatML prompt of [messages], ending where the model starts its answer (with the thinking
  /// block already closed, as the chat does when thinking is off).
  static String chatMl(List<AiMessage> messages) {
    final b = StringBuffer();
    for (final m in messages) {
      final role = switch (m.role) {
        AiRole.system => 'system',
        AiRole.assistant => 'assistant',
        _ => 'user',
      };
      b.write('<|im_start|>$role\n${m.text}<|im_end|>\n');
    }
    b.write('<|im_start|>assistant\n<think>\n\n</think>\n\n');
    return b.toString();
  }
}

/// Lets only [n] jobs run at once; the others wait their turn.
class ConcurrencyGate {
  ConcurrencyGate(this.n);
  final int n;
  int _running = 0;
  final _waiting = <Completer<void>>[];

  Future<T> run<T>(Future<T> Function() job) async {
    if (_running >= n) {
      final turn = Completer<void>();
      _waiting.add(turn);
      await turn.future;
    } else {
      _running++;
    }
    try {
      return await job();
    } finally {
      if (_waiting.isEmpty) {
        _running--;
      } else {
        _waiting.removeAt(0).complete();
      }
    }
  }
}
