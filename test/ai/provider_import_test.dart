import 'dart:convert';

import 'package:arce_ai/ai/provider_config.dart';
import 'package:arce_ai/ai/provider_import.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const existing = [ProviderConfig(id: 'openai', label: 'OpenAI', baseUrl: 'https://api.openai.com/v1')];

  test('the app\'s own form and the usual other names, one or many, each with a new id of its own', () {
    final read = ProviderImport.parse(jsonEncode({
      'providers': [
        {'name': 'OpenAI', 'base_url': 'https://api.openai.com/v1/chat/completions', 'models': ['gpt-5-mini'], 'api_key': 'sk-1'},
        {
          'label': 'Groq',
          'baseUrl': 'https://api.groq.com/openai/v1/',
          'models': [
            {'id': 'openai/gpt-oss-120b', 'name': 'oss', 'service_tier': 'flex'},
          ],
          'headers': {'Authorization': 'Bearer gsk-2', 'X-Title': 'arce'},
          'extra_body': {'reasoning_effort': 'low'},
          'supportsTools': false,
        },
      ],
    }), existing);
    expect(read, hasLength(2));
    final (openai, groq) = (read[0], read[1]);
    expect(openai.config.id, 'openai-2', reason: 'openai is taken');
    expect(openai.config.baseUrl, 'https://api.openai.com/v1', reason: '/chat/completions is cut off');
    expect(openai.config.models.single.id, 'gpt-5-mini');
    expect(openai.key, 'sk-1');
    expect(groq.config.baseUrl, 'https://api.groq.com/openai/v1');
    expect(groq.config.models.single.serviceTier, 'flex');
    expect(groq.config.headers, {'X-Title': 'arce'}, reason: 'Authorization became the key');
    expect(groq.key, 'gsk-2');
    expect(groq.config.body, {'reasoning_effort': 'low'});
    expect(groq.config.supportsTools, isFalse);
    expect(jsonEncode(groq.config.toJson()), isNot(contains('gsk-2')), reason: 'a key is never in the settings');
  });

  test('Cloudflare by account and gateway; a list of one model; a key in another header is refused', () {
    final cf = ProviderImport.parse('{"type":"cloudflare","name":"CF","account_id":"abc123","gateway_id":"prod","model":"openai/gpt-4.1","apiKey":"cf-token"}', const []).single;
    expect(cf.config.baseUrl, 'https://api.cloudflare.com/client/v4/accounts/abc123/ai/v1');
    expect(cf.config.headers, {'cf-aig-gateway-id': 'prod'});
    expect(cf.config.autoFetchModels, isFalse);
    expect(cf.config.models.single.id, 'openai/gpt-4.1');
    expect(cf.key, 'cf-token');
    expect(
      () => ProviderImport.parse('{"name":"x","baseUrl":"https://x.example/v1","headers":{"x-api-key":"k"}}', const []),
      throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('機密情報'))),
    );
  });

  test('what cannot be used is said, and nothing is made of it', () {
    for (final (text, says) in [
      ('not json', 'JSON として読めません'),
      ('[]', '1 つもありません'),
      ('{"name":"x"}', 'baseUrl'),
      ('{"name":"x","baseUrl":"ftp://x/v1"}', 'baseUrl'),
      ('{"type":"cloudflare","account_id":"a/../b"}', 'account_id'),
      ('{"name":"x","baseUrl":"https://x.example","headers":{"Authorization":"Basic abc"}}', 'Bearer'),
      ('42', 'オブジェクト'),
    ]) {
      expect(() => ProviderImport.parse(text, const []), throwsA(isA<FormatException>().having((e) => e.message, 'message', contains(says))), reason: text);
    }
  });

  test('editing keeps the id, and the copy has no id, no list and no key, and reads back as the same provider', () {
    const config = ProviderConfig(
      id: 'mine',
      label: 'Mine',
      baseUrl: 'https://llm.example/v1',
      models: [ModelConfig(id: 'm1', name: 'one', serviceTier: 'flex')],
      headers: {'X-Org': '1'},
    );
    final copy = ProviderImport.export(config);
    expect(copy, isNot(contains('"id": "mine"')));
    final back = ProviderImport.parse(copy, const [], keepId: 'mine').single.config;
    expect(back.id, 'mine');
    expect(back.toJson(), config.toJson());
    expect(() => ProviderImport.parse('[$copy,$copy]', const [], keepId: 'mine'), throwsA(isA<FormatException>()));
  });
}
