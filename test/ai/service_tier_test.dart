import 'dart:convert';

import 'package:arce_ai/ai/openai_compatible.dart';
import 'package:arce_ai/ai/provider.dart';
import 'package:arce_ai/ai/provider_config.dart';
import 'package:arce_ai/ai/responses_provider.dart';
import 'package:arce_ai/services/provider_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('a model\'s service_tier is kept, read from either spelling, and only a plain word is taken', () {
    const flex = ModelConfig(id: 'openai/gpt-5-mini', name: 'flex', serviceTier: 'flex');
    expect(ModelConfig.fromJson(flex.toJson()).serviceTier, 'flex');
    expect(ModelConfig.fromJson({'id': 'm', 'service_tier': 'Priority'}).serviceTier, 'priority');
    expect(ModelConfig.fromJson({'id': 'm', 'serviceTier': 'flex"; drop'}).serviceTier, '');
    expect(const ModelConfig(id: 'm', name: 'm').toJson(), isNot(contains('serviceTier')));
    expect(flex.copyWith(name: 'x').serviceTier, 'flex');
  });

  test('the request carries service_tier for that model, and the provider\'s own body still wins', () async {
    Map<String, Object?>? sent;
    final client = MockClient.streaming((request, body) async {
      sent = jsonDecode(utf8.decode(await body.expand((b) => b).toList())) as Map<String, Object?>;
      return http.StreamedResponse(Stream.value(utf8.encode('data: [DONE]\n\n')), 200, headers: const {'content-type': 'text/event-stream'}, request: request);
    });
    OpenAiCompatibleProvider make(String tier, {Map<String, Object?> body = const {}}) => OpenAiCompatibleProvider(
          id: 'p',
          label: 'p',
          baseUrl: 'https://api.example/v1',
          model: 'gpt-5-mini',
          modelConfig: ModelConfig(id: 'gpt-5-mini', name: 'g', serviceTier: tier),
          body: body,
          client: client,
        );
    const request = AiRequest(messages: [AiMessage(AiRole.user, text: 'hi')]);
    await make('flex').stream(request).toList();
    expect(sent!['service_tier'], 'flex');
    await make('').stream(request).toList();
    expect(sent!.containsKey('service_tier'), isFalse);
    await make('flex', body: {'service_tier': 'default'}).stream(request).toList();
    expect(sent!['service_tier'], 'default', reason: 'the provider\'s extra fields come last');
  });

  test('a flex model waits as long as the flex setting says; the others as long as the usual one', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await ProviderStore.load();
    store
      ..requestTimeout = const Duration(seconds: 120)
      ..flexTimeout = const Duration(seconds: 900);
    const config = ProviderConfig(id: 'p', label: 'p', baseUrl: 'https://api.example/v1', models: [
      ModelConfig(id: 'a', name: 'a'),
      ModelConfig(id: 'b', name: 'b', serviceTier: 'flex'),
    ]);
    final plain = store.build(config, model: config.models[0]) as OpenAiCompatibleProvider;
    final flex = store.build(config, model: config.models[1]) as OpenAiCompatibleProvider;
    expect(plain.timeout, const Duration(seconds: 120));
    expect(flex.timeout, const Duration(seconds: 900));
  });

  test('Responses API と background 設定に応じて OpenAiResponsesProvider とタイムアウトが選ばれる', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await ProviderStore.load();
    store
      ..requestTimeout = const Duration(seconds: 120)
      ..flexTimeout = const Duration(seconds: 900);
    const bgConfig = ProviderConfig(
      id: 'sail',
      label: 'Sail Research',
      baseUrl: 'https://api.sailresearch.example/v1',
      api: ProviderApi.responses,
      background: true,
      models: [ModelConfig(id: 'sail-large', name: 'sail-large')],
    );
    const syncConfig = ProviderConfig(
      id: 'sync',
      label: 'Sync',
      baseUrl: 'https://api.example/v1',
      api: ProviderApi.responses,
      background: false,
      models: [
        ModelConfig(id: 'std', name: 'std'),
        ModelConfig(id: 'flex-m', name: 'flex-m', serviceTier: 'flex'),
      ],
    );

    final bgProvider = store.build(bgConfig) as OpenAiResponsesProvider;
    expect(bgProvider.useBackground, isTrue);
    expect(bgProvider.timeout, const Duration(seconds: 900));

    final syncPlain = store.build(syncConfig, model: syncConfig.models[0]) as OpenAiResponsesProvider;
    final syncFlex = store.build(syncConfig, model: syncConfig.models[1]) as OpenAiResponsesProvider;
    expect(syncPlain.useBackground, isFalse);
    expect(syncPlain.timeout, const Duration(seconds: 120));
    expect(syncFlex.timeout, const Duration(seconds: 900));
  });
}
