import 'dart:convert';

import 'package:arce_ai/ai/cloudflare_gateway.dart';
import 'package:arce_ai/ai/openai_compatible.dart';
import 'package:arce_ai/ai/provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const account = '0123456789abcdef0123456789abcdef';

void main() {
  group('the address and the gateway', () {
    test('the base URL is the REST API of the account, and is read back from it', () {
      final base = CloudflareGateway.baseUrl(' $account ');
      expect(base, 'https://api.cloudflare.com/client/v4/accounts/$account/ai/v1');
      expect(CloudflareGateway.accountOf(base), account);
      expect(CloudflareGateway.accountOf('$base/'), account);
      expect(CloudflareGateway.isGateway('https://api.openai.com/v1'), isFalse);
      expect(CloudflareGateway.isGateway('https://gateway.example/client/v4/accounts/$account/ai/v1'), isFalse, reason: 'only Cloudflare\'s own host');
    });

    test('an account ID is letters and digits only: nothing that changes the address gets in', () {
      expect(CloudflareGateway.isAccountId(account), isTrue);
      for (final bad in ['', ' ', 'abc/../x', 'abc?x=1', 'abc def', 'abc#']) {
        expect(CloudflareGateway.isAccountId(bad), isFalse, reason: bad);
      }
    });

    test('the gateway header is always sent (default when empty), replaces an old one, and keeps the other headers', () {
      expect(CloudflareGateway.withGateway(const {}, ''), {'cf-aig-gateway-id': 'default'});
      expect(
        CloudflareGateway.withGateway(const {'CF-AIG-Gateway-ID': 'old', 'cf-aig-skip-cache': 'true'}, ' prod '),
        {'cf-aig-skip-cache': 'true', 'cf-aig-gateway-id': 'prod'},
      );
      expect(CloudflareGateway.gatewayOf(const {'cf-aig-gateway-id': 'prod'}), 'prod');
      expect(CloudflareGateway.gatewayOf(const {}), 'default');
    });
  });

  group('the provider on this address', () {
    OpenAiCompatibleProvider provider(http.Client client) => OpenAiCompatibleProvider(
          id: 'cf',
          label: CloudflareGateway.label,
          baseUrl: CloudflareGateway.baseUrl(account),
          model: 'openai/gpt-4.1',
          apiKey: 'cf-token',
          headers: CloudflareGateway.withGateway(const {}, ''),
          client: client,
        );

    test('a chat goes to {base}/chat/completions with the token, the gateway and the model name as written', () async {
      late http.BaseRequest seen;
      late Map<String, Object?> body;
      final client = MockClient.streaming((request, bodyStream) async {
        seen = request;
        body = jsonDecode(utf8.decode(await bodyStream.expand((b) => b).toList())) as Map<String, Object?>;
        return http.StreamedResponse(
          Stream.value(utf8.encode('data: ${jsonEncode({
                'choices': [
                  {'delta': {'content': 'ok'}, 'finish_reason': 'stop'},
                ],
              })}\n\ndata: [DONE]\n\n')),
          200,
          headers: const {'content-type': 'text/event-stream'},
          request: request,
        );
      });
      await provider(client).stream(const AiRequest(messages: [AiMessage(AiRole.user, text: 'hi')])).toList();
      expect(seen.url.toString(), 'https://api.cloudflare.com/client/v4/accounts/$account/ai/v1/chat/completions');
      expect(seen.headers['Authorization'], 'Bearer cf-token');
      expect(seen.headers['cf-aig-gateway-id'], 'default');
      expect(body['model'], 'openai/gpt-4.1');
    });

    test('the connection check asks Cloudflare\'s token check, not a model list', () async {
      Uri? seen;
      final client = MockClient((request) async {
        seen = request.url;
        return http.Response('{"result":{"status":"active"},"success":true}', 200);
      });
      await provider(client).verify();
      expect(seen.toString(), 'https://api.cloudflare.com/client/v4/user/tokens/verify');
    });

    test('there is no model list to read: it says how to add a model, without a request', () async {
      var asked = false;
      final client = MockClient((request) async {
        asked = true;
        return http.Response('{}', 404);
      });
      await expectLater(
        provider(client).fetchModelInfos(),
        throwsA(isA<AiProviderException>().having((e) => e.message, 'message', contains('openai/gpt-4.1'))),
      );
      expect(asked, isFalse);
    });

    test('a refused token (401) is told which permission it needs', () async {
      final client = MockClient((request) async => http.Response('{"errors":[{"code":10000,"message":"Authentication error"}]}', 401));
      await expectLater(
        provider(client).verify(),
        throwsA(isA<AiProviderException>().having((e) => e.message, 'message', contains('Workers AI > Read'))),
      );
    });
  });
}
