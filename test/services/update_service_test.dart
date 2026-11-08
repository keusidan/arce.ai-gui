import 'dart:convert';
import 'dart:io';

import 'package:arce_ai/core/releases.dart';
import 'package:arce_ai/services/settings.dart';
import 'package:arce_ai/services/update_service.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Fakes the GitHub API: a latest release whose assets live behind a redirect to "storage".
MockClient githubWith({required List<int> payload, required String checksum, int status = 200}) {
  final assetName = 'ARCE.AI-v0.5.0-${UpdateService.target?.suffix.substring(1) ?? 'linux-x64.tar.gz'}';
  return MockClient.streaming((request, body) async {
    final url = request.url.toString();
    http.StreamedResponse reply(int code, List<int> bytes, [Map<String, String> headers = const {}]) =>
        http.StreamedResponse(Stream.value(bytes), code, headers: headers, request: request);

    if (url.contains('/releases?')) {
      final prefix = UpdateService.target?.tagPrefix ?? '';
      return reply(status, utf8.encode(jsonEncode([
        {
          'tag_name': '${prefix}v0.5.0',
          'body': 'new things',
          'assets': [
            {'id': 11, 'name': assetName, 'size': payload.length},
            {'id': 12, 'name': '$assetName.sha256', 'size': 90},
          ],
        },
        // another platform's release must never be offered
        {'tag_name': 'other-v9.9.9', 'assets': []},
      ])));
    }
    if (url.contains('/releases/assets/')) {
      // GitHub answers an asset request with a redirect; the token must not follow it
      expect(request.headers.containsKey('Authorization'), isTrue);
      return reply(302, const [], {'location': 'https://storage.example/${url.split('/').last}'});
    }
    if (url.startsWith('https://storage.example/')) {
      expect(request.headers.containsKey('Authorization'), isFalse, reason: 'storage rejects a second credential');
      return url.endsWith('/12') ? reply(200, utf8.encode('$checksum  $assetName\n')) : reply(200, payload);
    }
    return reply(404, const []);
  });
}

Future<(UpdateService, Directory)> serviceFor(MockClient client, {String current = '0.4.0'}) async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsStore(await SharedPreferences.getInstance());
  await settings.setGithubToken('secret'); // sent to the API, never to storage
  final dir = await Directory.systemTemp.createTemp('arce_update_test');
  addTearDown(() => dir.delete(recursive: true));
  final service = UpdateService(
    settings,
    client: client,
    cacheDirectory: () async => dir,
    currentVersion: Version.parse(current),
  );
  addTearDown(service.dispose);
  return (service, dir);
}

void main() {
  final payload = utf8.encode('pretend this is an archive');
  final good = sha256.convert(payload).toString();

  test('finds a newer release, and reports an up-to-date app', () async {
    final (newer, _) = await serviceFor(githubWith(payload: payload, checksum: good));
    await newer.check();
    expect(newer.state, isA<UpdateAvailable>());
    expect((newer.state as UpdateAvailable).release.version, const Version(0, 5, 0));

    final (same, _) = await serviceFor(githubWith(payload: payload, checksum: good), current: '0.5.0');
    await same.check();
    expect(same.state, isA<UpdateUpToDate>());
  }, skip: UpdateService.target == null);

  test('downloads through the redirect and verifies the SHA-256', () async {
    final (service, dir) = await serviceFor(githubWith(payload: payload, checksum: good));
    await service.check();
    await service.download();
    final ready = service.state as UpdateReady;
    expect(await ready.file.readAsBytes(), payload);
    expect(ready.file.parent.path, startsWith(dir.path));
  }, skip: UpdateService.target == null || UpdateService.target == UpdateTarget.ios);

  test('a download that does not match its checksum is discarded', () async {
    final (service, dir) = await serviceFor(githubWith(payload: payload, checksum: 'ab' * 32));
    await service.check();
    await service.download();
    expect(service.state, isA<UpdateFailed>());
    expect(Directory('${dir.path}/updates').listSync(), isEmpty, reason: 'the bad file is deleted');
  }, skip: UpdateService.target == null || UpdateService.target == UpdateTarget.ios);

  test('explains a private repository without a token', () async {
    final (service, _) = await serviceFor(githubWith(payload: payload, checksum: good, status: 404));
    await service.check();
    expect((service.state as UpdateFailed).reason, contains('404'));
  });

  test('a silent check keeps quiet when it fails', () async {
    final (service, _) = await serviceFor(githubWith(payload: payload, checksum: good, status: 500));
    await service.check(silent: true);
    expect(service.state, isA<UpdateIdle>());
  });
}
