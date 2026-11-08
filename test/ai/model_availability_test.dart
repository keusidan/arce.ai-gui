import 'dart:async';
import 'dart:io';

import 'package:arce_ai/ai/model_availability.dart';
import 'package:arce_ai/ai/provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

AvailabilityVerdict v(int? status, [String body = '']) => AvailabilityClassifier.classify(status: status, body: body);

void main() {
  group('the classifier: status first, then the words every service uses', () {
    // (what the case is, status, body, expected). The bodies are written in the shape the services use;
    // none of them is a quote of a live reply (see docs): what the code depends on is the status and a
    // few general words.
    final table = <(String, int?, String, ModelAvailability)>[
      ('answered', 200, '', ModelAvailability.usable),
      ('answered (any 2xx)', 204, '', ModelAvailability.usable),

      // ---- Gemini through its OpenAI-compatible endpoint
      (
        'Gemini free tier: this model has no quota (limit: 0)',
        429,
        '[{"error":{"code":429,"message":"You exceeded your current quota, please check your plan and billing details. * Quota exceeded for metric: generativelanguage.googleapis.com/generate_content_free_tier_requests, limit: 0, model: gemini-2.5-pro Please retry in 40.5s.","status":"RESOURCE_EXHAUSTED"}}]',
        ModelAvailability.blocked,
      ),
      (
        'Gemini: the limit of the minute (limit is not 0)',
        429,
        '[{"error":{"code":429,"message":"You exceeded your current quota, please check your plan and billing details. * Quota exceeded for metric: generativelanguage.googleapis.com/generate_content_free_tier_requests, limit: 5, model: gemini-2.5-flash Please retry in 12s.","status":"RESOURCE_EXHAUSTED"}}]',
        ModelAvailability.temporary,
      ),
      (
        'Gemini: the limit of the day (it comes back tomorrow)',
        429,
        '{"error":{"code":429,"message":"Quota exceeded for metric: generate_content_free_tier_requests, limit: 20","status":"RESOURCE_EXHAUSTED","details":[{"quotaId":"GenerateRequestsPerDayPerProjectPerModel-FreeTier"}]}}',
        ModelAvailability.temporary,
      ),
      (
        'Gemini: a bad key comes back as 400 INVALID_ARGUMENT',
        400,
        '[{"error":{"code":400,"message":"API key not valid. Please pass a valid API key.","status":"INVALID_ARGUMENT","details":[{"reason":"API_KEY_INVALID"}]}}]',
        ModelAvailability.keyRejected,
      ),
      (
        'Gemini: the model is not there (404)',
        404,
        '[{"error":{"code":404,"message":"models/gemini-1.0-pro is not found for API version v1beta, or is not supported for generateContent.","status":"NOT_FOUND"}}]',
        ModelAvailability.blocked,
      ),
      (
        'Gemini: permission denied for this model',
        403,
        '{"error":{"code":403,"message":"Permission denied on resource model gemini-ultra","status":"PERMISSION_DENIED"}}',
        ModelAvailability.blocked,
      ),
      (
        'Gemini: the model does not take a system instruction (a shape problem, not the key)',
        400,
        '{"error":{"code":400,"message":"Developer instruction is not enabled for models/gemma-3-27b-it","status":"INVALID_ARGUMENT"}}',
        ModelAvailability.unknown,
      ),
      (
        'Gemini: not on the free tier (words)',
        403,
        '{"error":{"message":"This model is not available on the free tier. Enable billing to use it."}}',
        ModelAvailability.blocked,
      ),

      // ---- OpenAI
      (
        'OpenAI: no credit left (insufficient_quota)',
        429,
        '{"error":{"message":"You exceeded your current quota, please check your plan and billing details.","type":"insufficient_quota","param":null,"code":"insufficient_quota"}}',
        ModelAvailability.blocked,
      ),
      (
        'OpenAI: a rate limit that passes',
        429,
        '{"error":{"message":"Rate limit reached for gpt-4o in organization org-x on tokens per min (TPM): Limit 30000, Used 29000. Please try again in 6s.","type":"tokens","code":"rate_limit_exceeded"}}',
        ModelAvailability.temporary,
      ),
      (
        'OpenAI: model_not_found',
        404,
        '{"error":{"message":"The model `gpt-5-pro` does not exist or you do not have access to it.","type":"invalid_request_error","param":null,"code":"model_not_found"}}',
        ModelAvailability.blocked,
      ),
      (
        'OpenAI: the project has no access to the model',
        403,
        '{"error":{"message":"Project `proj_x` does not have access to model `o3-pro`","type":"invalid_request_error","code":"model_not_found"}}',
        ModelAvailability.blocked,
      ),
      (
        'OpenAI: a wrong key',
        401,
        '{"error":{"message":"Incorrect API key provided: sk-xxxx. You can find your API key at https://platform.openai.com/account/api-keys.","type":"invalid_request_error","code":"invalid_api_key"}}',
        ModelAvailability.keyRejected,
      ),
      (
        'OpenAI: a parameter this model does not take (not about the key)',
        400,
        '{"error":{"message":"Unsupported parameter: \'max_tokens\' is not supported with this model. Use \'max_completion_tokens\' instead.","type":"invalid_request_error"}}',
        ModelAvailability.unknown,
      ),
      (
        'a prompt that is too long (not about the key)',
        400,
        '{"error":{"message":"This model\'s maximum context length is 8192 tokens. However, your messages resulted in 9000 tokens."}}',
        ModelAvailability.unknown,
      ),
      (
        'the provider says the model name is not valid',
        400,
        '{"error":{"message":"Invalid model: foo-bar","type":"invalid_request_error"}}',
        ModelAvailability.blocked,
      ),
      (
        'the model is decommissioned',
        400,
        '{"error":{"message":"The model `llama2-70b` has been decommissioned and is no longer available.","code":"model_decommissioned"}}',
        ModelAvailability.blocked,
      ),

      // ---- routers and others
      (
        'OpenRouter: no credit (402)',
        402,
        '{"error":{"message":"Insufficient credits. Add more using https://openrouter.ai/credits","code":402}}',
        ModelAvailability.blocked,
      ),
      (
        'OpenRouter: the free models of the day are used up',
        429,
        '{"error":{"message":"Rate limit exceeded: free-models-per-day. Add 10 credits to unlock 1000 free model requests per day","code":429}}',
        ModelAvailability.temporary,
      ),
      (
        'OpenRouter: no endpoint for the model',
        404,
        '{"error":{"message":"No endpoints found for deepseek/deepseek-r1:free.","code":404}}',
        ModelAvailability.blocked,
      ),
      (
        'DeepSeek: no balance',
        402,
        '{"error":{"message":"Insufficient Balance","type":"unknown_error","code":"invalid_request_error"}}',
        ModelAvailability.blocked,
      ),
      ('Ollama: the model was not pulled', 404, '{"error":"model \'foo\' not found, try pulling it first"}', ModelAvailability.blocked),
      ('a wrong address (404 without a word about a model)', 404, '404 page not found', ModelAvailability.unknown),
      ('a wrong address (an HTML page)', 404, '<html><body>Not Found</body></html>', ModelAvailability.unknown),

      // ---- what passes, and what says nothing
      ('a busy server', 503, '{"error":{"message":"The model is overloaded. Please try again later."}}', ModelAvailability.temporary),
      ('a server error', 500, '', ModelAvailability.temporary),
      ('a bad gateway', 502, '<html>Bad Gateway</html>', ModelAvailability.temporary),
      ('a request timeout', 408, '', ModelAvailability.temporary),
      ('a plain 429', 429, '', ModelAvailability.temporary),
      ('no status (no connection)', null, '', ModelAvailability.temporary),
      ('a 403 with nothing to read', 403, '', ModelAvailability.unknown),
      ('a 418', 418, 'I am a teapot', ModelAvailability.unknown),
      ('a 400 with nothing to read', 400, '', ModelAvailability.unknown),
      ('a 401 whatever the body says', 401, '{"error":{"message":"model not found"}}', ModelAvailability.keyRejected),
    ];

    for (final (name, status, body, expected) in table) {
      test(name, () {
        final verdict = v(status, body);
        expect(verdict.availability, expected, reason: '$status $body -> $verdict');
        expect(verdict.reason.isEmpty, expected == ModelAvailability.usable, reason: 'only an answered request has no reason');
      });
    }

    test('a reason is a short line of Japanese that can be shown as it is', () {
      for (final (_, status, body, expected) in table) {
        final verdict = v(status, body);
        if (expected == ModelAvailability.usable) continue;
        expect(verdict.reason, isNot(contains('\n')));
        expect(verdict.reason.length, lessThan(80));
        // Japanese: at least one kana or kanji
        expect(RegExp(r'[ぁ-んァ-ン一-龥]').hasMatch(verdict.reason), isTrue, reason: verdict.reason);
      }
    });

    test('upper and lower case do not matter', () {
      expect(v(429, 'QUOTA EXCEEDED, LIMIT: 0, MODEL: X').availability, ModelAvailability.blocked);
      expect(v(404, 'MODEL NOT FOUND').availability, ModelAvailability.blocked);
    });

    test('"limit: 0" is told from limits that only look like it', () {
      expect(v(429, 'limit: 0').availability, ModelAvailability.blocked);
      expect(v(429, '"limit": 0,').availability, ModelAvailability.blocked);
      expect(v(429, 'limit: 0, model: x').availability, ModelAvailability.blocked);
      expect(v(429, 'limit: 10').availability, ModelAvailability.temporary);
      expect(v(429, 'Limit 30000, Used 0').availability, ModelAvailability.temporary);
      expect(v(429, 'limit: 100, remaining: 0').availability, ModelAvailability.temporary);
    });

    test('only a verdict that stays true is worth remembering', () {
      expect(AvailabilityVerdict.usable.isRemembered, isTrue);
      expect(v(404, 'model not found').isRemembered, isTrue);
      for (final status in [429, 500, 401, 418]) {
        expect(v(status, 'limit: 5').isRemembered, isFalse, reason: '$status');
      }
    });
  });

  group('from a thrown error', () {
    test('a failure of the provider carries its status and body', () {
      const blocked = AiProviderException('x', statusCode: 429, body: 'limit: 0');
      expect(AvailabilityClassifier.classifyError(blocked).availability, ModelAvailability.blocked);
      const key = AiProviderException('x', statusCode: 401);
      expect(AvailabilityClassifier.classifyError(key).availability, ModelAvailability.keyRejected);
    });

    test('without a body the message is read (an error that was made by hand)', () {
      const hand = AiProviderException('model not found', statusCode: 404);
      expect(AvailabilityClassifier.classifyError(hand).availability, ModelAvailability.blocked);
    });

    test('an error without a status says nothing; a time out or no connection will pass', () {
      expect(AvailabilityClassifier.classifyError(const AiProviderException('モデル一覧を読み取れませんでした')).availability, ModelAvailability.unknown);
      expect(AvailabilityClassifier.classifyError(TimeoutException('t')).availability, ModelAvailability.temporary);
      expect(AvailabilityClassifier.classifyError(const SocketException('no route')).availability, ModelAvailability.temporary);
      expect(AvailabilityClassifier.classifyError(http.ClientException('closed')).availability, ModelAvailability.temporary);
      expect(AvailabilityClassifier.classifyError(StateError('x')).availability, ModelAvailability.unknown);
    });
  });

  group('the message of a real request that failed', () {
    test('says which model, why, what to do, and what the provider said', () {
      final verdict = v(429, 'limit: 0');
      final message = AvailabilityClassifier.blockedMessage(providerLabel: 'Gemini', modelId: 'gemini-2.5-pro', verdict: verdict, original: '回数制限です');
      expect(message, contains('Gemini の gemini-2.5-pro'));
      expect(message, contains(verdict.reason));
      expect(message, contains('別のモデルを選んでください'));
      expect(message, contains('印が付きました'));
      expect(message, contains('回数制限です'));
      final unmarked = AvailabilityClassifier.blockedMessage(providerLabel: 'G', modelId: 'm', verdict: verdict, original: 'x', marked: false);
      expect(unmarked, isNot(contains('印が付きました')));
    });
  });

  group('what the provider said', () {
    test('the message of the error, also from the list Gemini wraps it in, one line, cut', () {
      expect(AvailabilityClassifier.providerMessage('{"error":{"message":"No access to model x"}}'), 'No access to model x');
      expect(AvailabilityClassifier.providerMessage('[{"error":{"code":429,"message":"Quota exceeded\\n* limit: 0"}}]'), 'Quota exceeded * limit: 0');
      expect(AvailabilityClassifier.providerMessage('{"error":"model not found"}'), 'model not found');
      expect(AvailabilityClassifier.providerMessage('{"message":"plain"}'), 'plain');
      final long = AvailabilityClassifier.providerMessage('{"error":{"message":"${'x' * 500}"}}', max: 50)!;
      expect(long.length, 51);
      expect(long, endsWith('…'));
    });

    test('nothing when there is nothing to quote', () {
      for (final body in ['', 'plain text', '<html></html>', '{}', '{"error":{}}', '[]', '{"error":{"message":"  "}}']) {
        expect(AvailabilityClassifier.providerMessage(body), isNull, reason: body);
      }
    });
  });

  group('which models are asked', () {
    test('embedding, speech, image and moderation models are not chat models', () {
      for (final id in [
        'text-embedding-004',
        'gemini-embedding-001',
        'text-embedding-3-small',
        'whisper-1',
        'gpt-4o-mini-tts',
        'gpt-4o-transcribe',
        'imagen-4.0-generate-001',
        'veo-3.0-generate-preview',
        'dall-e-3',
        'gpt-image-1',
        'gemini-2.5-flash-image',
        'omni-moderation-latest',
        'aqa',
        'rerank-v3',
        'meta-llama/llama-guard-4-12b',
      ]) {
        expect(AvailabilityClassifier.looksLikeChatModel(id), isFalse, reason: id);
      }
    });

    test('chat models are', () {
      for (final id in ['gpt-4o', 'gpt-5-mini', 'o3', 'gemini-2.5-pro', 'gemini-2.5-flash', 'claude-sonnet-4-5', 'openai/gpt-oss-120b', 'deepseek-chat', 'qwen3:8b', 'llama-3.3-70b-versatile']) {
        expect(AvailabilityClassifier.looksLikeChatModel(id), isTrue, reason: id);
      }
    });
  });

  group('a record', () {
    test('is believed for a number of days, and no longer', () {
      const day = Duration.millisecondsPerDay;
      const record = AvailabilityRecord(ModelAvailability.blocked, 'r', 1000);
      expect(record.isFresh(1000, 7), isTrue);
      expect(record.isFresh(1000 + 7 * day, 7), isTrue, reason: 'the seventh day is still inside');
      expect(record.isFresh(1000 + 7 * day + 1, 7), isFalse);
      expect(record.isBlocked, isTrue);
      expect(record.isUsable, isFalse);
    });

    test('the marks look results up, and "none" knows nothing', () {
      expect(ModelMarks.none.of('p', 'm'), isNull);
      const found = AvailabilityRecord(ModelAvailability.usable, '', 1);
      final marks = ModelMarks(lookup: (p, m) => p == 'p' && m == 'm' ? found : null);
      expect(marks.of('p', 'm'), same(found));
      expect(marks.of('p', 'other'), isNull);
      expect(marks.hideBlocked, isFalse);
    });
  });
}
