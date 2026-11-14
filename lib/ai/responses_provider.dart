import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/generation.dart';
import 'openai_compatible.dart';
import 'provider.dart';

/// A provider communicating with OpenAI Responses API (`/responses`), including optional
/// asynchronous `background: true` execution (`HTTP 202` + `GET /responses/{id}` polling and
/// `POST /responses/{id}/cancel` on user abort) and Flex routing (`metadata.completion_window`).
class OpenAiResponsesProvider extends OpenAiCompatibleProvider {
  OpenAiResponsesProvider({
    required super.id,
    required super.label,
    required super.baseUrl,
    required super.model,
    super.modelConfig,
    super.apiKey,
    super.headers,
    super.body,
    super.supportsTools,
    super.promptCache,
    super.promptCacheField,
    super.onCacheRefused,
    super.client,
    super.timeout = const Duration(seconds: 900),
    this.useBackground = false,
    this.pollInterval = const Duration(seconds: 2),
  });

  final bool useBackground;
  final Duration pollInterval;

  static const _maxTransientPollErrors = 3;

  Map<String, String> get _jsonHeaders => {
    ...requestHeaders,
    'Accept': 'application/json',
  };

  @override
  Stream<Delta> stream(AiRequest request) async* {
    var aborted = false;
    request.abort?.then((_) => aborted = true);

    final clock = Stopwatch()..start();
    Duration remainingTimeout() {
      final remaining = timeout - clock.elapsed;
      return remaining.isNegative ? Duration.zero : remaining;
    }

    var withCache = !cacheRefused;
    http.StreamedResponse response;
    var text = '';

    Future<http.StreamedResponse> postResponses(bool sendCache) {
      final rem = remainingTimeout();
      if (rem == Duration.zero) {
        throw const AiProviderException(
          '応答がタイムアウトしました（HTTP 408）',
          statusCode: 408,
        );
      }
      final msg = http.AbortableRequest(
        'POST',
        endpointUri('responses'),
        abortTrigger: request.abort,
      )
        ..headers.addAll(_jsonHeaders)
        ..body = jsonEncode(_responsesBody(request, withCache: sendCache));
      return httpClient.send(msg).timeout(rem);
    }

    try {
      response = await postResponses(withCache);
      text = await response.stream.bytesToString().timeout(remainingTimeout());
    } on http.RequestAbortedException {
      yield const StopDelta(FinishReason.cancelled);
      return;
    } on TimeoutException {
      throw const AiProviderException(
        '応答がタイムアウトしました（HTTP 408）',
        statusCode: 408,
      );
    }

    if ((response.statusCode == 400 || response.statusCode == 422) &&
        withCache &&
        sendsCache(request) &&
        text.toLowerCase().contains(promptCacheField.toLowerCase())) {
      markCacheRefused();
      withCache = false;
      onCacheRefused?.call(
        'このプロバイダは、キャッシュ用の項目「$promptCacheField」を受け付けませんでした（HTTP ${response.statusCode}）。'
        'キャッシュの送信をオフにして、もう一度送りました',
      );
      try {
        response = await postResponses(false);
        text = await response.stream.bytesToString().timeout(remainingTimeout());
      } on http.RequestAbortedException {
        yield const StopDelta(FinishReason.cancelled);
        return;
      } on TimeoutException {
        throw const AiProviderException(
          '応答がタイムアウトしました（HTTP 408）',
          statusCode: 408,
        );
      }
    }

    if (response.statusCode != 200 &&
        response.statusCode != 201 &&
        response.statusCode != 202) {
      throw AiProviderException(
        failureMessage(response.statusCode, text),
        statusCode: response.statusCode,
        body: text,
      );
    }

    final initialData = _decodeMap(text);
    if (initialData == null) {
      throw const AiProviderException('プロバイダの応答を読み取れませんでした');
    }
    Map<String, Object?> data = initialData;

    final responseId = data['id'] is String ? data['id']! as String : null;
    var status = data['status'] is String ? data['status']! as String : '';
    var transientErrors = 0;

    while (status == 'queued' || status == 'in_progress') {
      if (aborted) {
        await _cancelRemote(responseId);
        yield const StopDelta(FinishReason.cancelled);
        return;
      }
      if ((responseId ?? '').trim().isEmpty) {
        throw const AiProviderException('バックグラウンド応答の ID が返されませんでした');
      }
      final remBeforeWait = remainingTimeout();
      if (remBeforeWait == Duration.zero) {
        await _cancelRemote(responseId);
        throw const AiProviderException(
          '応答がタイムアウトしました（HTTP 408）',
          statusCode: 408,
        );
      }

      final wait = pollInterval < remBeforeWait ? pollInterval : remBeforeWait;
      await _sleepAbortable(wait, request.abort);

      if (aborted) {
        await _cancelRemote(responseId);
        yield const StopDelta(FinishReason.cancelled);
        return;
      }
      final rem = remainingTimeout();
      if (rem == Duration.zero) {
        await _cancelRemote(responseId);
        throw const AiProviderException(
          '応答がタイムアウトしました（HTTP 408）',
          statusCode: 408,
        );
      }

      http.StreamedResponse pollResponse;
      String pollBody;
      try {
        final req = http.AbortableRequest(
          'GET',
          endpointUri('responses/$responseId'),
          abortTrigger: request.abort,
        )..headers.addAll(_jsonHeaders);
        pollResponse = await httpClient.send(req).timeout(rem);
        pollBody = await pollResponse.stream.bytesToString().timeout(
          remainingTimeout(),
        );
      } on http.RequestAbortedException {
        await _cancelRemote(responseId);
        yield const StopDelta(FinishReason.cancelled);
        return;
      } on TimeoutException {
        await _cancelRemote(responseId);
        throw const AiProviderException(
          '応答がタイムアウトしました（HTTP 408）',
          statusCode: 408,
        );
      }

      if (pollResponse.statusCode == 429 ||
          (pollResponse.statusCode >= 500 && pollResponse.statusCode <= 599)) {
        transientErrors++;
        if (transientErrors > _maxTransientPollErrors) {
          throw AiProviderException(
            failureMessage(pollResponse.statusCode, pollBody),
            statusCode: pollResponse.statusCode,
            body: pollBody,
          );
        }
        continue;
      }
      if (pollResponse.statusCode < 200 || pollResponse.statusCode > 299) {
        throw AiProviderException(
          failureMessage(pollResponse.statusCode, pollBody),
          statusCode: pollResponse.statusCode,
          body: pollBody,
        );
      }

      transientErrors = 0;
      final next = _decodeMap(pollBody);
      if (next == null) {
        throw const AiProviderException('プロバイダの応答を読み取れませんでした');
      }
      data = next;
      status = data['status'] is String ? data['status']! as String : '';
    }

    if (aborted || status == 'cancelled') {
      yield const StopDelta(FinishReason.cancelled);
      return;
    }

    if (status == 'failed') {
      throw AiProviderException(_responseError(data));
    }

    final usage = data['usage'];
    if (usage is Map) {
      final promptTokens = OpenAiCompatibleProvider.parseInt(
        usage['input_tokens'] ?? usage['prompt_tokens'],
      );
      final completionTokens = OpenAiCompatibleProvider.parseInt(
        usage['output_tokens'] ?? usage['completion_tokens'],
      );
      final inputDetails = usage['input_tokens_details'];
      final cachedTokens = inputDetails is Map
          ? OpenAiCompatibleProvider.parseInt(inputDetails['cached_tokens'])
          : OpenAiCompatibleProvider.cachedTokensOf(usage);
      if (promptTokens != null ||
          completionTokens != null ||
          cachedTokens != null) {
        yield UsageDelta(
          promptTokens: promptTokens,
          completionTokens: completionTokens,
          cachedTokens: cachedTokens,
        );
      }
    }

    var emittedText = false;
    final output = data['output'];
    if (output is List) {
      for (final item in output) {
        if (item is! Map) continue;
        final type = item['type'];
        if (type == 'reasoning') {
          final reasoning = _extractReasoningText(item);
          if (reasoning.isNotEmpty) yield ReasoningDelta(reasoning);
        } else if (type == 'message') {
          final messageText = _extractMessageText(item);
          if (messageText.isNotEmpty) {
            emittedText = true;
            yield TextDelta(messageText);
          }
        } else if (type == 'function_call') {
          final name = item['name'];
          if (name is! String || name.trim().isEmpty) continue;
          final rawCallId = item['call_id'];
          final rawId = item['id'];
          final callId = rawCallId is String && rawCallId.isNotEmpty
              ? rawCallId
              : (rawId is String ? rawId : '');
          final args = item['arguments'];
          final argsJson = args is String
              ? (args.trim().isEmpty ? '{}' : args)
              : (args is Map ? jsonEncode(args) : '{}');
          yield ToolCallDelta(
            id: callId,
            name: name.trim(),
            argumentsJson: argsJson,
          );
        }
      }
    }
    if (!emittedText && data['output_text'] is String) {
      final fallback = data['output_text']! as String;
      if (fallback.isNotEmpty) yield TextDelta(fallback);
    }

    yield StopDelta(
      status == 'incomplete' ? FinishReason.length : FinishReason.eog,
    );
  }

  Future<void> _sleepAbortable(Duration duration, Future<void>? abort) {
    if (duration <= Duration.zero) return Future.value();
    final delay = Future<void>.delayed(duration);
    return abort == null ? delay : Future.any<void>([delay, abort]);
  }

  Future<void> _cancelRemote(String? responseId) async {
    if ((responseId ?? '').trim().isEmpty) return;
    try {
      final req = http.Request('POST', endpointUri('responses/$responseId/cancel'))
        ..headers.addAll(_jsonHeaders);
      await httpClient.send(req).timeout(const Duration(seconds: 5));
    } catch (_) {
      // Best-effort remote cancellation on abort or timeout.
    }
  }

  Map<String, Object?> _responsesBody(
    AiRequest request, {
    required bool withCache,
  }) {
    final isFlex = modelConfig?.isFlex ?? false;
    final sendBackground = useBackground || isFlex;
    final mergedMetadata = <String, Object?>{
      if (request.extraBody['metadata'] is Map)
        ...(request.extraBody['metadata']! as Map).cast<String, Object?>(),
      if (body['metadata'] is Map)
        ...(body['metadata']! as Map).cast<String, Object?>(),
    };
    if (isFlex) {
      mergedMetadata.putIfAbsent('completion_window', () => 'flex');
    }

    return {
      'model': request.model.trim().isEmpty ? model : request.model,
      'input': _responsesInput(request.messages),
      'max_output_tokens': request.maxTokens,
      'temperature': request.temperature,
      'top_p': request.topP,
      if (request.tools.isNotEmpty && supportsTools)
        'tools': [
          for (final tool in request.tools)
            {
              'type': 'function',
              'name': tool.name,
              'description': tool.description,
              'parameters': tool.parameters,
            },
        ],
      if (withCache && sendsCache(request)) promptCacheField: request.cacheKey,
      if (sendBackground) 'background': true,
      ...request.extraBody,
      ...body,
      if (mergedMetadata.isNotEmpty) 'metadata': mergedMetadata,
    };
  }

  static List<Map<String, Object?>> _responsesInput(List<AiMessage> messages) {
    final out = <Map<String, Object?>>[];
    final sentCallIds = <String>{};
    var generatedCall = 0;

    for (final message in messages) {
      switch (message.role) {
        case AiRole.system:
          out.add({'role': 'system', 'content': message.text});
        case AiRole.user:
          if (message.images.isEmpty) {
            out.add({'role': 'user', 'content': message.text});
          } else {
            out.add({
              'role': 'user',
              'content': [
                if (message.text.isNotEmpty)
                  {'type': 'input_text', 'text': message.text},
                for (final image in message.images)
                  {'type': 'input_image', 'image_url': image.dataUrl},
              ],
            });
          }
        case AiRole.assistant:
          if (message.text.trim().isNotEmpty) {
            out.add({'role': 'assistant', 'content': message.text});
          }
          for (final call in message.toolCalls) {
            final cleanName = call.name.trim();
            if (cleanName.isEmpty) continue;
            final callId = call.id.trim().isNotEmpty
                ? call.id.trim()
                : 'call_${generatedCall++}';
            sentCallIds.add(callId);
            out.add({
              'type': 'function_call',
              'call_id': callId,
              'name': cleanName,
              'arguments': call.argumentsJson,
            });
          }
        case AiRole.tool:
          if (message.toolCallId.trim().isNotEmpty &&
              sentCallIds.remove(message.toolCallId.trim())) {
            out.add({
              'type': 'function_call_output',
              'call_id': message.toolCallId.trim(),
              'output': message.text,
            });
          } else {
            out.add({
              'role': 'user',
              'content': '<tool_response>\n${message.text}\n</tool_response>',
            });
          }
      }
    }
    return out;
  }

  static Map<String, Object?>? _decodeMap(String text) {
    try {
      final decoded = jsonDecode(text);
      return decoded is Map ? decoded.cast<String, Object?>() : null;
    } catch (_) {
      return null;
    }
  }

  static String _responseError(Map<String, Object?> data) {
    final error = data['error'];
    if (error is Map && error['message'] is String) {
      return 'プロバイダが失敗しました: ${error['message']}';
    }
    if (error is String && error.trim().isNotEmpty) {
      return 'プロバイダが失敗しました: $error';
    }
    return 'プロバイダが失敗しました';
  }

  static String _extractReasoningText(Map item) {
    final parts = <String>[];
    final summary = item['summary'];
    if (summary is List) {
      for (final s in summary) {
        if (s is Map && s['text'] is String && (s['text']! as String).isNotEmpty) {
          parts.add(s['text']! as String);
        }
      }
    }
    final content = item['content'];
    if (content is List) {
      for (final part in content) {
        if (part is Map &&
            part['text'] is String &&
            (part['text']! as String).isNotEmpty) {
          parts.add(part['text']! as String);
        }
      }
    } else if (content is String && content.isNotEmpty) {
      parts.add(content);
    }
    if (parts.isEmpty && item['text'] is String) {
      return item['text']! as String;
    }
    return parts.join('\n');
  }

  static String _extractMessageText(Map item) {
    final content = item['content'];
    if (content is String) return content;
    if (content is List) {
      final b = StringBuffer();
      for (final part in content) {
        if (part is! Map) continue;
        final type = part['type'];
        if ((type == 'output_text' || type == 'text') &&
            part['text'] is String) {
          b.write(part['text']! as String);
        }
      }
      return b.toString();
    }
    return item['text'] is String ? item['text']! as String : '';
  }
}
