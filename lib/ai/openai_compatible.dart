import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/generation.dart';
import 'cloudflare_gateway.dart';
import 'model_info.dart';
import 'model_list_check.dart';
import 'provider.dart';
import 'provider_config.dart';

/// A provider that speaks the OpenAI chat-completions protocol, which is what almost every cloud
/// API and local server (Ollama, LM Studio, LMDeploy, vLLM, OpenRouter, ...) offers as well.
///
/// Differences between services are handled by the two overrides: extra [headers] and extra
/// [body] fields, which are sent last so they win over the generated ones.
///
/// The adapter owns the SSE details (events split across chunks, tool-call arguments arriving in
/// fragments) and emits one [ToolCallDelta] per call only when it is complete.
class OpenAiCompatibleProvider implements AiProvider {
  OpenAiCompatibleProvider({
    required this.id,
    required this.label,
    required this.baseUrl,
    required this.model,
    this.modelConfig,
    this.apiKey = '',
    this.headers = const {},
    this.body = const {},
    this.supportsTools = true,
    this.promptCache = false,
    this.promptCacheField = ProviderConfig.defaultPromptCacheField,
    this.onCacheRefused,
    http.Client? client,
    this.timeout = const Duration(seconds: 120),
  }) : _client = client ?? http.Client();

  @override
  final String id;

  @override
  final String label;

  @override
  String get modelId => model;

  @override
  final ModelConfig? modelConfig;

  /// Everything before `/chat/completions`, e.g. `https://api.openai.com/v1`.
  final String baseUrl;
  final String model;


  final String apiKey;
  final Map<String, String> headers;
  final Map<String, Object?> body;
  final Duration timeout;

  /// Whether the endpoint offers function calling. A model without tools still answers; it just
  /// cannot call one.
  final bool supportsTools;

  /// Send [promptCacheField] with the conversation's key on every request (see [ProviderConfig.promptCache]).
  /// Off sends nothing for the cache.
  final bool promptCache;
  final String promptCacheField;

  /// Told once when the server refused the request because of the cache field and the request went
  /// through again without it. The app turns the provider's switch off then, and says why.
  final void Function(String reason)? onCacheRefused;

  /// The server refused the cache field: it is left out from then on, for this provider object.
  bool _cacheRefused = false;

  /// The server rejected `extra_content` on historical tool calls (e.g., Cerebras rejecting
  /// signature metadata from another provider); omitted from subsequent requests on this instance.
  bool _extraContentRefused = false;

  final http.Client _client;

  http.Client get httpClient => _client;
  Uri endpointUri(String path) => _uri(path);
  Map<String, String> get requestHeaders => _requestHeaders;
  bool sendsCache(AiRequest request) => _sendsCache(request);
  bool get cacheRefused => _cacheRefused;
  void markCacheRefused() => _cacheRefused = true;
  bool get extraContentRefused => _extraContentRefused;
  String failureMessage(int status, String body) => _failure(status, body);
  static int? parseInt(Object? value) => _int(value);

  @override
  ProviderCapabilities get capabilities =>
      ProviderCapabilities(
        tools: supportsTools,
        reasoning: true,
        vision: modelConfig?.supportsImages ?? ModelConfig.guessVision(model),
        usage: true,
      );

  Uri _uri(String path) =>
      Uri.parse('${baseUrl.replaceAll(RegExp(r'/+$'), '')}/$path');

  Map<String, String> get _requestHeaders => {
    'Content-Type': 'application/json',
    'Accept': 'text/event-stream',
    if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
    ...headers,
  };

  @override
  Stream<Delta> stream(AiRequest request) async* {
    var effectiveRequest = request;
    var withCache = true;
    var withExtraContent = !_extraContentRefused;
    var strippedUnsignedTools = false;
    var strippedAllTools = false;

    http.StreamedResponse response;
    try {
      response = await _send(
        effectiveRequest,
        withCache: withCache,
        withExtraContent: withExtraContent,
      );
    } on http.RequestAbortedException {
      yield const StopDelta(FinishReason.cancelled);
      return;
    }

    while (response.statusCode < 200 || response.statusCode > 299) {
      final text = await response.stream.bytesToString();
      final isBadRequest =
          response.statusCode == 400 || response.statusCode == 422;
      final lower = text.toLowerCase();
      final field = promptCacheField;

      if (isBadRequest &&
          withCache &&
          _sendsCache(effectiveRequest) &&
          lower.contains(field.toLowerCase())) {
        // The server does not know the cache field and says so: retry once without it and inform the app.
        _cacheRefused = true;
        withCache = false;
        onCacheRefused?.call(
          'このプロバイダは、キャッシュ用の項目「$field」を受け付けませんでした（HTTP ${response.statusCode}）。'
          'キャッシュの送信をオフにして、もう一度送りました',
        );
      } else if (isBadRequest &&
          withExtraContent &&
          _hasExtraContent(effectiveRequest.messages) &&
          lower.contains('extra_content')) {
        // Another provider's tool_call signature metadata (extra_content) is rejected by this endpoint.
        _extraContentRefused = true;
        withExtraContent = false;
      } else if (isBadRequest &&
          !strippedUnsignedTools &&
          _hasUnsignedToolCalls(effectiveRequest.messages) &&
          lower.contains('thought_signature')) {
        // Historical tool calls created without a signature are converted to text so Gemini accepts the turn.
        strippedUnsignedTools = true;
        effectiveRequest = _copyWithMessages(
          effectiveRequest,
          _withoutToolCalls(effectiveRequest.messages, onlyUnsigned: true),
        );
      } else if (isBadRequest &&
          !strippedAllTools &&
          _hasToolMessages(effectiveRequest.messages) &&
          lower.contains('function_response')) {
        strippedAllTools = true;
        effectiveRequest = _copyWithMessages(
          effectiveRequest,
          _withoutToolCalls(effectiveRequest.messages, onlyUnsigned: false),
        );
      } else {
        throw AiProviderException(
          _failure(response.statusCode, text),
          statusCode: response.statusCode,
          body: text,
        );
      }

      try {
        response = await _send(
          effectiveRequest,
          withCache: withCache,
          withExtraContent: withExtraContent,
        );
      } on http.RequestAbortedException {
        yield const StopDelta(FinishReason.cancelled);
        return;
      }
    }

    final calls = <int, _PartialCall>{};
    final slotOf = <int, int>{}; // the index a provider wrote -> the call it is for
    var finish = FinishReason.eog;
    var pending = '';

    // The decoder of a stream keeps the bytes of a character that a network chunk cut in two until
    // the rest arrives (Japanese text is three bytes a character, so this happens all the time).
    // Converting each chunk on its own failed with "Unfinished UTF-8 octet sequence".
    try {
      await for (final text in response.stream.transform(const Utf8Decoder(allowMalformed: true))) {
        pending += text;
        // events end with a blank line; keep the last unfinished line for the next chunk
        final lines = pending.split('\n');
        pending = lines.removeLast();
        for (final raw in lines) {
          final line = raw.trimRight();
          if (line.isEmpty || line.startsWith(':')) continue;
          if (!line.startsWith('data:')) continue;
          final data = line.substring(5).trim();
          if (data.isEmpty) continue;
          if (data == '[DONE]') break;

          final Object? decoded;
          try {
            decoded = jsonDecode(data);
          } catch (_) {
            continue; // a keep-alive or a provider-specific event
          }
          if (decoded is! Map) continue;

          final usage = decoded['usage'];
          if (usage is Map) {
            final prompt = _int(usage['prompt_tokens']);
            final completion = _int(usage['completion_tokens']);
            if (prompt != null || completion != null) {
              yield UsageDelta(
                promptTokens: prompt,
                completionTokens: completion,
                cachedTokens: cachedTokensOf(usage),
              );
            }
          }

          final choices = decoded['choices'];
          final choice = choices is List && choices.isNotEmpty
              ? choices.first
              : null;
          if (choice is! Map) continue;

          final delta = choice['delta'];
          if (delta is Map) {
            final reasoning = delta['reasoning_content'] ?? delta['reasoning'];
            if (reasoning is String && reasoning.isNotEmpty) {
              yield ReasoningDelta(reasoning);
            }
            final text = delta['content'];
            if (text is String && text.isNotEmpty) yield TextDelta(text);
            for (final call in (delta['tool_calls'] as List? ?? const [])) {
              if (call is! Map) continue;
              final wireIndex = _int(call['index']) ?? 0;
              final id = call['id'] is String ? call['id'] as String : '';
              // Gemini's OpenAI-compatible endpoint numbers every call 0 and tells them apart by id; taking
              // them as one call glued their arguments into `{...}{...}` ("not JSON: Unexpected character")
              var slot = slotOf[wireIndex];
              final current = slot == null ? null : calls[slot];
              if (current == null || (id.isNotEmpty && current.id.isNotEmpty && id != current.id)) {
                slot = calls.length;
                slotOf[wireIndex] = slot;
                calls[slot] = _PartialCall()..wireIndex = wireIndex;
              }
              final partial = calls[slot]!;
              if (id.isNotEmpty) partial.id = id;
              final extra = call['extra_content'];
              if (extra is Map) partial.extraContent = Map<String, Object?>.from(extra);
              final function = call['function'];
              if (function is Map) {
                final name = function['name'];
                if (name is String && name.isNotEmpty) partial.name = name;
                final arguments = function['arguments'];
                // arguments arrive in fragments and can be cut anywhere inside a string
                if (arguments is String) partial.arguments.write(arguments);
              }
            }
          }

          final reason = choice['finish_reason'];
          if (reason is String) finish = _finishOf(reason);
        }
      }
    } on http.RequestAbortedException {
      // the user stopped the reply while the model was thinking
      yield const StopDelta(FinishReason.cancelled);
      return;
    }

    // in the order the provider numbered them; calls that share a number keep the order they came in
    final order = calls.keys.toList()
      ..sort((a, b) => calls[a]!.wireIndex != calls[b]!.wireIndex ? calls[a]!.wireIndex.compareTo(calls[b]!.wireIndex) : a.compareTo(b));
    for (final index in order) {
      final call = calls[index]!;
      final name = call.name.trim();
      if (name.isEmpty) continue;
      final arguments = call.arguments.isEmpty ? '{}' : call.arguments.toString();
      // several calls of one name that arrived as one (no ids to tell them apart): `{...}{...}`
      final objects = splitObjects(arguments);
      if (objects.length > 1) {
        for (var n = 0; n < objects.length; n++) {
          yield ToolCallDelta(id: call.id.isEmpty ? '' : '${call.id}_$n', name: name, argumentsJson: objects[n], extraContent: n == 0 ? call.extraContent : null);
        }
        continue;
      }
      yield ToolCallDelta(id: call.id, name: name, argumentsJson: arguments, extraContent: call.extraContent);
    }
    yield StopDelta(finish);
  }

  /// How many prompt tokens the provider read from its cache, from a `usage` object: OpenAI's
  /// `prompt_tokens_details.cached_tokens`, or DeepSeek's `prompt_cache_hit_tokens`. Null when the
  /// object has neither (a provider that does no prompt caching, or does not report it).
  static int? cachedTokensOf(Map usage) {
    final details = usage['prompt_tokens_details'];
    if (details is Map) {
      final cached = _int(details['cached_tokens']);
      if (cached != null) return cached;
    }
    return _int(usage['prompt_cache_hit_tokens']);
  }

  /// One request to the server. An abortable request: when the user stops, the connection is closed and
  /// the wait for the next word ends (cancelling a stream that is waiting cannot do that).
  Future<http.StreamedResponse> _send(
    AiRequest request, {
    required bool withCache,
    bool withExtraContent = true,
  }) {
    final message = http.AbortableRequest('POST', _uri('chat/completions'), abortTrigger: request.abort)
      ..headers.addAll(_requestHeaders)
      ..body = jsonEncode(_body(request, withCache: withCache, withExtraContent: withExtraContent));
    return _client.send(message).timeout(timeout);
  }

  /// Whether the body of [request] carries the cache hint: the switch is on, the request belongs to a
  /// conversation, the server has not refused it, and the user's own body override does not set the field
  /// (then it is theirs, and not what the app sent).
  bool _sendsCache(AiRequest request) =>
      promptCache &&
      !_cacheRefused &&
      (request.cacheKey ?? '').isNotEmpty &&
      ProviderConfig.isValidCacheField(promptCacheField) &&
      !body.containsKey(promptCacheField) &&
      !request.extraBody.containsKey(promptCacheField);

  Map<String, Object?> _body(
    AiRequest request, {
    bool withCache = true,
    bool withExtraContent = true,
  }) => {
    'model': request.model.trim().isEmpty ? model : request.model,
    'messages': [
      for (final message in request.messages)
        _message(message, withExtraContent: withExtraContent),
    ],
    'stream': true,
    'stream_options': {'include_usage': true},
    'max_tokens': request.maxTokens,
    'temperature': request.temperature,
    'top_p': request.topP,
    if (request.tools.isNotEmpty && supportsTools)
      'tools': [
        for (final tool in request.tools)
          {
            'type': 'function',
            'function': {
              'name': tool.name,
              'description': tool.description,
              'parameters': tool.parameters,
            },
          },
      ],
    // the hint for the provider's prompt cache: only with the switch on, and never a thing for the cache
    // when it is off
    if (withCache && _sendsCache(request)) promptCacheField: request.cacheKey,
    // the processing tier the user chose for this model (flex: cheaper and slower)
    if ((modelConfig?.serviceTier ?? '').isNotEmpty) 'service_tier': modelConfig!.serviceTier,
    // what the model needs (its thinking settings) goes before the provider's own override
    ...request.extraBody,
    // the user's overrides come last, so a provider that needs different field names wins
    ...body,
  };

  static bool _hasExtraContent(List<AiMessage> messages) =>
      messages.any((m) => m.toolCalls.any((c) => c.extraContent != null));

  static bool _hasUnsignedToolCalls(List<AiMessage> messages) =>
      messages.any((m) => m.toolCalls.any((c) => c.extraContent == null));

  static bool _hasToolMessages(List<AiMessage> messages) =>
      messages.any((m) => m.role == AiRole.tool || m.toolCalls.isNotEmpty);

  static AiRequest _copyWithMessages(AiRequest request, List<AiMessage> messages) =>
      AiRequest(
        messages: messages,
        model: request.model,
        tools: request.tools,
        maxTokens: request.maxTokens,
        temperature: request.temperature,
        topP: request.topP,
        extraBody: request.extraBody,
        abort: request.abort,
        cacheKey: request.cacheKey,
      );

  static List<AiMessage> _withoutToolCalls(
    List<AiMessage> messages, {
    required bool onlyUnsigned,
  }) {
    final out = <AiMessage>[];
    final convertedIds = <String>{};
    for (final message in messages) {
      if (message.role == AiRole.assistant && message.toolCalls.isNotEmpty) {
        final convertAll = !onlyUnsigned ||
            message.toolCalls.any(
              (c) => c.extraContent == null || c.name.trim().isEmpty,
            );
        if (!convertAll) {
          out.add(message);
          continue;
        }
        for (final call in message.toolCalls) {
          if (call.id.isNotEmpty) convertedIds.add(call.id);
        }
        final text = [
          if (message.text.trim().isNotEmpty) message.text.trim(),
          for (final call in message.toolCalls)
            '<tool_call>{"name": ${jsonEncode(call.name)}, "arguments": ${call.argumentsJson}}</tool_call>',
        ].join('\n');
        out.add(
          AiMessage(
            AiRole.assistant,
            text: text,
            reasoning: message.reasoning,
          ),
        );
      } else if (message.role == AiRole.tool) {
        if (!onlyUnsigned ||
            message.toolCallId.trim().isEmpty ||
            convertedIds.contains(message.toolCallId)) {
          out.add(
            AiMessage(
              AiRole.user,
              text: '<tool_response>\n${message.text}\n</tool_response>',
            ),
          );
        } else {
          out.add(message);
        }
      } else {
        out.add(message);
      }
    }
    return out;
  }

  static Map<String, Object?> _message(
    AiMessage message, {
    bool withExtraContent = true,
  }) {
    switch (message.role) {
      case AiRole.tool:
        return {
          'role': 'tool',
          'content': message.text,
          'tool_call_id': message.toolCallId,
        };
      case AiRole.system:
        return {'role': 'system', 'content': message.text};
      case AiRole.user:
        if (message.images.isEmpty) return {'role': 'user', 'content': message.text};
        return {
          'role': 'user',
          'content': [
            if (message.text.isNotEmpty) {'type': 'text', 'text': message.text},
            for (final image in message.images)
              {
                'type': 'image_url',
                'image_url': {'url': image.dataUrl},
              },
          ],
        };
      case AiRole.assistant:
        final reasoning = message.reasoning.trim().isEmpty ? null : message.reasoning;
        if (message.toolCalls.isEmpty) {
          return {'role': 'assistant', 'content': message.text, 'reasoning_content': ?reasoning};
        }
        return {
          'role': 'assistant',
          'content': message.text,
          'reasoning_content': ?reasoning,
          'tool_calls': [
            for (final call in message.toolCalls)
              {
                'id': call.id,
                'type': 'function',
                'function': {
                  'name': call.name,
                  'arguments': call.argumentsJson,
                },
                if (withExtraContent && call.extraContent != null)
                  'extra_content': call.extraContent,
              },
          ],
        };
    }
  }

  /// The model names the endpoint offers, for the settings screen's "取得" button.
  Future<List<String>> listModels() async => [for (final info in await fetchModelInfos()) info.id];

  /// The models the endpoint offers, with whatever it says about each one's limits and abilities
  /// (see [ModelInfoParser] for the fields that are read). Sorted by id.
  Future<List<ModelInfo>> fetchModelInfos() async {
    // Gemini's OpenAI-style list has only ids; its own list has each model's token limits
    if (GeminiModels.isGemini(baseUrl)) return _fetchGeminiModels();
    // Cloudflare's REST API documents no model list: asking would only bring a 404 that says nothing
    if (CloudflareGateway.isGateway(baseUrl)) throw const AiProviderException(CloudflareGateway.noModelList);
    final response = await _client
        .get(
          _uri('models'),
          headers: {..._requestHeaders, 'Accept': 'application/json'},
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode > 299) {
      throw AiProviderException(_failure(response.statusCode, response.body), statusCode: response.statusCode, body: response.body);
    }
    try {
      return ModelInfoParser.parseList(jsonDecode(response.body))..sort((a, b) => a.id.compareTo(b.id));
    } catch (_) {
      throw const AiProviderException('モデル一覧を読み取れませんでした');
    }
  }

  /// The models this key can see, to judge a model without asking it (see `ModelListCheck`). For Gemini's
  /// endpoint it is Gemini's own list (`models.list`, which says which methods each model supports, with the
  /// key in the `x-goog-api-key` header), read page by page; for any other it is the OpenAI-style list.
  Future<List<ModelInfo>> fetchKeyModels() => fetchModelInfos();

  Future<List<ModelInfo>> _fetchGeminiModels() async {
    final all = <ModelInfo>[];
    String? token;
    // pageSize is 1000: a second page is rare, and a loop that never ends is worse than a short list
    for (var page = 0; page < 10; page++) {
      final uri = GeminiModels.listUri(baseUrl, pageToken: token)!;
      final response = await _client
          .get(uri, headers: {'Accept': 'application/json', if (apiKey.isNotEmpty) 'x-goog-api-key': apiKey, ...headers})
          .timeout(const Duration(seconds: 20));
      if (response.statusCode < 200 || response.statusCode > 299) {
        throw AiProviderException(_failure(response.statusCode, response.body), statusCode: response.statusCode, body: response.body);
      }
      final Object? decoded;
      try {
        decoded = jsonDecode(utf8.decode(response.bodyBytes));
      } catch (_) {
        throw const AiProviderException('モデル一覧を読み取れませんでした');
      }
      all.addAll(ModelInfoParser.parseList(decoded));
      final next = decoded is Map ? decoded['nextPageToken'] : null;
      if (next is! String || next.isEmpty) break;
      token = next;
    }
    return all..sort((a, b) => a.id.compareTo(b.id));
  }

  @override
  Future<void> verify() async {
    // Cloudflare has no model list to read; its own check of the token is the one it documents
    final cloudflare = CloudflareGateway.isGateway(baseUrl);
    final response = await _client
        .get(
          cloudflare ? CloudflareGateway.verifyUri : _uri('models'),
          headers: {..._requestHeaders, 'Accept': 'application/json'},
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode > 299) {
      throw AiProviderException(_failure(response.statusCode, response.body), statusCode: response.statusCode, body: response.body);
    }
  }

  String _failure(int status, String body) {
    final message = _errorMessage(body);
    final hint = CloudflareGateway.isGateway(baseUrl) ? CloudflareGateway.refusedHint(status) : '';
    final detail = '${message == null ? '' : ': $message'}${hint.isEmpty ? '' : '\n$hint'}';
    return switch (status) {
      401 || 403 => 'APIキーが受け付けられませんでした（HTTP $status）$detail',
      404 => '接続先が見つかりません（HTTP 404）。URL とモデル名を確認してください$detail',
      429 => '回数制限に達しました（HTTP 429）。少し待ってからやり直してください$detail',
      _ => 'プロバイダが失敗しました（HTTP $status）$detail',
    };
  }

  /// The `error.message` of a failed request, when the service sends one.
  static String? _errorMessage(String body) {
    try {
      var decoded = jsonDecode(body);
      // Gemini wraps an error in a list: [{"error": {...}}]
      if (decoded is List && decoded.isNotEmpty) decoded = decoded.first;
      if (decoded is Map) {
        final error = decoded['error'];
        if (error is Map && error['message'] is String) {
          return error['message'] as String;
        }
        if (error is String) return error;
        if (decoded['message'] is String) return decoded['message'] as String;
      }
      // JSON, but not in a shape that is known: the start of it is better than nothing
      final text = body.trim();
      if (text.isNotEmpty) return text.length > 300 ? '${text.substring(0, 300)}…' : text;
    } catch (_) {
      // not JSON: show the start of the body instead
      final text = body.trim();
      if (text.isNotEmpty) {
        return text.length > 200 ? text.substring(0, 200) : text;
      }
    }
    return null;
  }

  static FinishReason _finishOf(String reason) => switch (reason) {
    'length' => FinishReason.length,
    'content_filter' => FinishReason.error,
    _ => FinishReason.eog,
  };

  static int? _int(Object? value) =>
      value is int ? value : (value is num ? value.toInt() : null);
}

/// One tool call while its name and arguments are still arriving.
/// The top-level JSON objects written one after the other in [text] (`{"a":1}{"b":2}`), when there are
/// two or more and each one is valid; otherwise the text as the only element. Braces inside strings
/// do not count.
List<String> splitObjects(String text) {
  final found = <String>[];
  var depth = 0;
  var start = 0;
  var inString = false;
  var escaped = false;
  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (ch == '\\') {
        escaped = true;
      } else if (ch == '"') {
        inString = false;
      }
      continue;
    }
    if (ch == '"') {
      inString = true;
    } else if (ch == '{') {
      if (depth == 0) start = i;
      depth++;
    } else if (ch == '}') {
      depth--;
      if (depth < 0) return [text];
      if (depth == 0) found.add(text.substring(start, i + 1));
    } else if (depth == 0 && ch.trim().isNotEmpty) {
      return [text]; // something other than objects between or around them
    }
  }
  if (depth != 0 || found.length < 2) return [text];
  try {
    for (final object in found) {
      if (jsonDecode(object) is! Map) return [text];
    }
  } on FormatException {
    return [text];
  }
  return found;
}

class _PartialCall {
  int wireIndex = 0;
  Map<String, Object?>? extraContent;
  String id = '';
  String name = '';
  final StringBuffer arguments = StringBuffer();
}
