import '../core/attachments.dart';
import '../core/generation.dart';
import 'provider_config.dart';

/// One piece of what a model sends back while it writes.
///
/// Providers differ in how they report thinking, tool calls and token usage; every adapter turns
/// them into these five kinds, so the chat pipeline never has to know which provider it talks to.
sealed class Delta {
  const Delta();
}

class TextDelta extends Delta {
  const TextDelta(this.text);
  final String text;
}

/// The model's thinking, shown folded in the chat. Providers that do not send it simply omit it.
class ReasoningDelta extends Delta {
  const ReasoningDelta(this.text);
  final String text;
}

/// A tool call the model wants to make. Adapters send it only once it is complete, with the
/// arguments as JSON text, so the existing tool-call parser reads it exactly like a local call.
class ToolCallDelta extends Delta {
  const ToolCallDelta({
    required this.name,
    required this.argumentsJson,
    this.id = '',
    this.extraContent,
  });
  final String id;
  final String name;
  final String argumentsJson;

  /// What the provider attached to the call besides the standard fields (`extra_content`: Gemini 3
  /// puts an encrypted thought signature there). The provider refuses the next request of the
  /// conversation unless it comes back unchanged, so it is kept as it arrived and sent back as it is.
  final Map<String, Object?>? extraContent;
}

/// Token usage for one request, sent at the end by providers that report it.
class UsageDelta extends Delta {
  const UsageDelta({this.promptTokens, this.completionTokens, this.cachedTokens});
  final int? promptTokens;
  final int? completionTokens;

  /// The part of the prompt the provider served from its cache (`prompt_tokens_details.cached_tokens`,
  /// or `prompt_cache_hit_tokens`); null when the response does not say.
  final int? cachedTokens;
}

/// Why the model stopped. Always the last delta of a reply.
class StopDelta extends Delta {
  const StopDelta(this.reason);
  final FinishReason reason;
}

enum AiRole { system, user, assistant, tool }

/// One message of the conversation as the provider expects it.
class AiMessage {
  const AiMessage(
    this.role, {
    this.text = '',
    this.toolCalls = const [],
    this.toolCallId = '',
    this.images = const [],
    this.reasoning = '',
  });

  final AiRole role;
  final String text;

  /// What the model thought before this assistant message. Sent back only when the model is set
  /// to receive its earlier reasoning (`reasoning_content`); empty for every other message.
  final String reasoning;

  /// Pictures sent with a user message. Only set for a provider that can see them.
  final List<ImageData> images;

  /// Calls the assistant made in this turn, kept so the provider sees its own request again.
  final List<ToolCallDelta> toolCalls;

  /// Which call a `tool` message answers.
  final String toolCallId;
}

/// A tool the model may call, in provider-neutral form.
class AiToolSpec {
  const AiToolSpec({
    required this.name,
    required this.description,
    required this.parameters,
  });

  final String name;
  final String description;

  /// JSON Schema of the arguments, as the provider's function calling expects it.
  final Map<String, Object?> parameters;
}

class AiRequest {
  const AiRequest({
    required this.messages,
    this.model = '',
    this.tools = const [],
    this.maxTokens = 2048,
    this.temperature = 0.7,
    this.topP = 0.95,
    this.extraBody = const {},
    this.abort,
    this.cacheKey,
  });

  final List<AiMessage> messages;

  /// Names the conversation this request belongs to, the same for every request of it, so a provider
  /// that takes a hint for its prompt cache (`prompt_cache_key`) can route them together. Null when
  /// the request belongs to none (the app's own short requests). Only sent when the provider's switch
  /// for it is on.
  final String? cacheKey;

  /// Completes when the user stops the reply: the provider drops the request (the connection is
  /// closed) and ends the stream, whether or not the model has sent anything lately.
  final Future<void>? abort;

  /// The model to ask for; empty keeps the one the provider was built with.
  final String model;
  final List<AiToolSpec> tools;
  final int maxTokens;
  final double temperature;
  final double topP;

  /// Fields the model needs in the request body (its thinking settings), merged in after the
  /// generated ones and before the provider's own override.
  final Map<String, Object?> extraBody;
}

/// What a provider can do, so the screen can show only what works (a text-only model cannot take
/// an image, a provider that reports no usage cannot show a cost).
class ProviderCapabilities {
  const ProviderCapabilities({
    this.tools = false,
    this.reasoning = false,
    this.vision = false,
    this.usage = false,
  });

  final bool tools;
  final bool reasoning;
  final bool vision;

  /// Reports token counts, which the history stores next to the message.
  final bool usage;
}

/// A model endpoint: a cloud API or a local server that speaks the same protocol.
abstract interface class AiProvider {
  /// Stable id, also stored in the database (`conversations.provider_id`).
  String get id;

  /// What the settings screen shows.
  String get label;

  /// The model this provider was built for; empty when none was chosen.
  String get modelId;

  /// The per-model settings (sampling overrides, extra prompt), when known.
  ModelConfig? get modelConfig;

  ProviderCapabilities get capabilities;

  /// Streams one reply. Cancelling the subscription stops the request.
  Stream<Delta> stream(AiRequest request);

  /// Fails when the endpoint or the key is wrong; used by the connection check.
  Future<void> verify();
}

/// A failed request, with a message that can be shown as it is.
class AiProviderException implements Exception {
  const AiProviderException(this.message, {this.statusCode, this.body = ''});
  final String message;

  /// The HTTP status the provider answered with, when it answered; the fallback mode reads it.
  final int? statusCode;

  /// What the provider answered with (an error body, not anything of the user's chat): read by
  /// [AvailabilityClassifier] to tell a model this key cannot use from a failure that will pass. It is
  /// never shown or stored as it is.
  final String body;

  @override
  String toString() => message;
}
