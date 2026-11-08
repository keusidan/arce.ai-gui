// The model behind [BotModel]: any OpenAI-compatible chat endpoint (the address, the key and the model
// come from the repository's secrets and variables).
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'bot_runner.dart';

class OpenAiChatModel implements BotModel {
  OpenAiChatModel({
    required this.url,
    required this.apiKey,
    required this.model,
    this.extraBody = const {},
    this.maxTokens = 8000,
    this.timeout = const Duration(minutes: 4),
    http.Client? client,
  }) : _client = client ?? http.Client();

  /// The full address of the chat-completions endpoint.
  final String url;
  final String apiKey;
  final String model;

  /// Fields added to the request body (a provider's own switches), from a variable.
  final Map<String, Object?> extraBody;
  final int maxTokens;
  final Duration timeout;
  final http.Client _client;

  @override
  Future<String> ask({required String system, required String user}) async {
    final response = await _client
        .post(
          Uri.parse(url),
          headers: {'Authorization': 'Bearer $apiKey', 'Content-Type': 'application/json'},
          body: jsonEncode({
            'model': model,
            'messages': [
              {'role': 'system', 'content': system},
              {'role': 'user', 'content': user},
            ],
            'temperature': 0.2,
            'max_tokens': maxTokens,
            ...extraBody,
          }),
        )
        .timeout(timeout);
    if (response.statusCode >= 300) {
      final body = utf8.decode(response.bodyBytes);
      throw StateError('the model answered HTTP ${response.statusCode}: ${body.length <= 300 ? body : body.substring(0, 300)}');
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    final choices = decoded is Map ? decoded['choices'] : null;
    final message = choices is List && choices.isNotEmpty && choices.first is Map ? (choices.first as Map)['message'] : null;
    final content = message is Map ? message['content'] : null;
    if (content is! String) throw StateError('the model answered without text');
    return content;
  }
}
