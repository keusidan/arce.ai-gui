import '../core/engine.dart';
import '../core/generation.dart';
import 'chatml_bridge.dart';
import 'fallback.dart';
import 'model_hints.dart';
import 'provider.dart';
import 'provider_config.dart';
import 'thinking_config.dart';
import 'token_budget.dart';

/// Answers through a cloud provider (or a local server that speaks the same protocol) while
/// looking like one more inference engine, so the chat, the agents and the retry policy stay as
/// they are.
///
/// The prompt the chat builds is ChatML; [ChatMlBridge] turns it into the provider's messages, and
/// the reply is turned back into pieces, tool calls included. Sampling settings, the token limit
/// and the tool schemas travel with the request as they do for the local engine.
class CloudEngine implements InferenceEngine {
  CloudEngine(this.provider);

  /// Replaced when the user switches provider; the next request uses the new one.
  AiProvider provider;

  bool _cancelled = false;

  /// Nothing is loaded on the device, so a cloud model is ready as soon as it is selected.
  @override
  bool get isLoaded => true;

  @override
  Future<void> load(LoadParams params) async {}

  @override
  Future<void> unload() async {}

  @override
  void cancel() => _cancelled = true;

  /// Whether tools go as function calling: the model's choice, or whatever the provider offers.
  static bool usesNativeTools(ModelConfig? model, bool providerOffersTools) => switch (model?.toolStyle ?? ToolStyle.auto) {
    ToolStyle.auto => providerOffersTools,
    ToolStyle.native => providerOffersTools,
    ToolStyle.text => false,
  };

  /// Whether the earlier reasoning goes back with the conversation. By default only for the models
  /// whose makers keep it (DeepSeek, GLM) and only while tools are function calls, which is
  /// where their guides keep it
  static bool replaysReasoning(ModelConfig? model, String modelId, bool native) => switch (model?.thinking.replay ?? ReasoningReplay.auto) {
    ReasoningReplay.always => true,
    ReasoningReplay.never => false,
    ReasoningReplay.auto => native && ModelHints.familyOf(modelId) != ModelFamily.other,
  };

  /// The models to try when the one in use fails with a failure another model may not share
  /// (see [FallbackPolicy]); the app sets it from the user's rules. Null: no fallback.
  FallbackPlan? Function(AiProvider primary)? fallbackFor;

  /// Told of each model whose request failed; returns the error to go on with (see [streamWithFallback]).
  /// The app uses it to note the models this key cannot use.
  Object Function(AiProvider provider, Object error)? onProviderFailure;

  /// Told of the model that answered.
  void Function(AiProvider provider)? onProviderSuccess;

  /// Whether to count the request before sending it and refuse one that cannot fit the model's
  /// context window (see [TokenBudget]), and how much of the window the instructions and tool
  /// definitions may take. The app sets both from the settings.
  bool tokenPrecheck = true;
  double overheadRatio = 0.8;

  /// Told when another model took over: which one failed, which answers, and why.
  void Function(AiProvider from, AiProvider to, String reason)? onFallback;

  /// The request for [target]: the conversation in the shape that model takes (images, tools as
  /// function calls or as text, earlier reasoning), and the limits and thinking settings of that
  /// model. Throws when there is nothing to send.
  AiRequest _requestFor(AiProvider target, GenerateRequest request) {
    final model = target.modelConfig;
    final native = usesNativeTools(model, target.capabilities.tools);
    final messages = ChatMlBridge.messages(
      request.prompt,
      images: request.images,
      vision: target.capabilities.vision,
      native: native,
      reasoning: request.assistantReasoning,
      replayReasoning: replaysReasoning(model, target.modelId, native),
    );
    if (messages.isEmpty) {
      throw EngineException('送信する内容を組み立てられませんでした');
    }

    final extraPrompt = model?.prompt.trim() ?? '';
    final allMessages = [
      if (extraPrompt.isNotEmpty) AiMessage(AiRole.system, text: extraPrompt),
      ...messages,
    ];
    // The value that applies, strongest first: the model's own setting, what the user set for
    // online models, the maker's recommendation (DeepSeek V4, GLM-5), the app's default.
    final hint = ModelHints.of(target.modelId);
    return AiRequest(
      abort: request.abort,
      cacheKey: request.conversationKey,
      messages: allMessages,
      model: target.modelId,
      maxTokens: ModelHints.resolveMaxTokens(
        modelSetting: model?.intParam('maxTokens'),
        requestedIsUserSet: request.user.maxTokens != null,
        requested: request.maxTokens,
        hint: hint,
        maxOutput: model?.maxOutputTokens,
        context: model?.contextTokens,
        useModelMax: request.user.useModelMax,
        promptTokens: ModelHints.estimateTokens(
          [for (final m in allMessages) m.text].join('\n') + [for (final t in request.tools) '${t.name}${t.description}${t.parameters}'].join(),
        ),
      ),
      extraBody: ThinkingRequest.fields(
        model?.thinking ?? ThinkingConfig.none,
        appThinking: request.thinking,
        speedAccuracy: request.user.speedAccuracy,
      ),
      temperature: model?.param('temperature') ?? request.user.temperature ?? hint?.temperature ?? request.sampling.temperature,
      topP: model?.param('topP') ?? request.user.topP ?? hint?.topP ?? request.sampling.topP,
      // With function calling the definitions travel here, and the conversation has the matching
      // shape (see [ChatMlBridge]); the text form keeps them in the system prompt instead, so
      // the model is never told about the same tools twice.
      tools: [
        if (native)
          for (final tool in request.tools)
            AiToolSpec(
              name: tool.name,
              description: tool.description,
              parameters: tool.parameters,
            ),
      ],
    );
  }

  static bool _isOpenThinkingContinuation(String prompt) {
    final lastStart = prompt.lastIndexOf('<|im_start|>assistant\n');
    if (lastStart < 0) return false;
    final tail = prompt.substring(lastStart);
    if (tail.contains('<|im_end|>')) return false;
    return tail.contains('<think>') && !tail.contains('</think>');
  }

  @override
  Stream<GenerationEvent> generate(GenerateRequest request) async* {
    _cancelled = false;
    final adapter = CloudEventAdapter(
      startInThinking: _isOpenThinkingContinuation(request.prompt),
    );
    // fail before anything is sent when there is nothing to send, or when it cannot fit
    final first = _requestFor(provider, request);
    if (tokenPrecheck) {
      final check = TokenBudget.check(first, context: provider.modelConfig?.contextTokens, overheadRatio: overheadRatio);
      if (!check.ok) throw EngineException(check.problem!);
    }

    try {
      // takeWhile stops reading as soon as cancel() is called; the request is dropped.
      final deltas = streamWithFallback(
        primary: provider,
        plan: fallbackFor?.call(provider),
        build: (target) => _requestFor(target, request),
        onSwitch: onFallback,
        onFailure: onProviderFailure,
        onSuccess: onProviderSuccess,
      );
      await for (final delta in deltas.takeWhile((_) => !_cancelled)) {
        for (final event in adapter.convert(delta)) {
          yield event;
        }
      }
    } on AiProviderException catch (e) {
      throw EngineException(e.message);
    } on EngineException {
      rethrow;
    } catch (e) {
      throw EngineException('プロバイダとの通信に失敗しました ($e) ');
    }

    // The chat expects a reason at the end, even when the provider sent none.
    if (_cancelled) {
      for (final event in adapter.convert(
        const StopDelta(FinishReason.cancelled),
      )) {
        yield event;
      }
    } else if (!adapter.isFinished) {
      for (final event in adapter.convert(const StopDelta(FinishReason.eog))) {
        yield event;
      }
    }
  }
}
