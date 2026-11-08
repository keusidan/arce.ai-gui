import 'package:arce_ai/core/http_get.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('the timeout is asked on every call, so a changed setting applies at once', () async {
    final client = MockClient((request) async {
      await Future<void>.delayed(const Duration(milliseconds: 80));
      return http.Response('ok', 200);
    });
    var timeout = const Duration(milliseconds: 10);
    final get = packageHttpGet(client: client, timeoutOf: () => timeout);

    await expectLater(get('https://x.example/a', const {}), throwsA(isA<Exception>()));
    timeout = const Duration(seconds: 2);
    expect(await get('https://x.example/a', const {}), 'ok');
  });
}
