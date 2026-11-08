import 'dart:convert';
import 'dart:io';

import 'package:arce_ai/services/preview_server.dart';
import 'package:flutter_test/flutter_test.dart';

Future<(int, String, HttpHeaders)> get(Uri uri, {String? host, String method = 'GET'}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(method, uri);
    if (host != null) request.headers.host = host;
    final response = await request.close();
    final body = await utf8.decodeStream(response);
    return (response.statusCode, body, response.headers);
  } finally {
    client.close(force: true);
  }
}

void main() {
  late PreviewServer server;
  setUp(() => server = PreviewServer());
  tearDown(() => server.dispose());

  test('a page is served at an address nobody can guess, with the headers that keep it in its own box', () async {
    final uri = await server.publish('<h1>こんにちは</h1>');
    expect(RegExp(r'^/p/[0-9a-f]{32}$').hasMatch(uri.path), isTrue, reason: '128 random bits, not a counter');
    final (status, body, headers) = await get(uri);
    expect(status, 200);
    expect(body, '<h1>こんにちは</h1>');
    expect(headers.value('content-security-policy'), startsWith('sandbox '));
    expect(headers.value('content-security-policy'), isNot(contains('allow-same-origin')));
    expect(headers.value('cache-control'), 'no-store');
    expect(headers.value('referrer-policy'), 'no-referrer');
    expect(headers.value('x-content-type-options'), 'nosniff');
  });

  test('walking through the old counter addresses finds nothing, and the addresses of two pages differ', () async {
    final a = await server.publish('A');
    final b = await server.publish('B');
    expect(a.path, isNot(b.path));
    for (final guess in ['0', '1', '2', 'a', '../p/0']) {
      final (status, _, _) = await get(a.replace(path: '/p/$guess'));
      expect(status, 404, reason: guess);
    }
    expect((await get(a.replace(path: '/')) ).$1, 404);
    expect((await get(a, method: 'POST')).$1, 404, reason: 'only GET');
  });

  test('a request that names another host (a web page pointing its own name at 127.0.0.1) is refused', () async {
    final uri = await server.publish('secret');
    final (status, body, _) = await get(uri, host: 'evil.example');
    expect(status, 404);
    expect(body, isNot(contains('secret')));
  });

  test('only the newest pages are kept', () async {
    server.maxPages = 2;
    final first = await server.publish('1');
    final second = await server.publish('2');
    final third = await server.publish('3');
    expect((await get(first)).$1, 404, reason: 'the oldest is gone');
    expect((await get(second)).$2, '2');
    expect((await get(third)).$2, '3');
  });

  group('a folder of the workspace', () {
    late Directory base;
    late Directory site;

    setUp(() async {
      base = await Directory.systemTemp.createTemp('arce_folder_test');
      site = Directory('${base.path}/site')..createSync();
      File('${site.path}/index.html').writeAsStringSync('<link rel=stylesheet href=a.css><img src=img/p.png>');
      File('${site.path}/a.css').writeAsStringSync('body{color:red}');
      Directory('${site.path}/img').createSync();
      File('${site.path}/img/p.png').writeAsStringSync('png-bytes'); // the helper reads text
      File('${site.path}/data.json').writeAsStringSync('{"a":1}');
      File('${site.path}/.env').writeAsStringSync('TOKEN=secret');
      Directory('${site.path}/.git').createSync();
      File('${site.path}/.git/config').writeAsStringSync('[core]');
      File('${base.path}/secret.txt').writeAsStringSync('outside');
      addTearDown(() => base.delete(recursive: true));
    });

    test('the entry, and what it asks for next, are served with their own types, from the folder only', () async {
      final entry = await server.publishFolder(site, 'index.html');
      expect(RegExp(r'^/w/[0-9a-f]{32}/index\.html$').hasMatch(entry.path), isTrue, reason: '128 random bits again');
      final (status, body, headers) = await get(entry);
      expect((status, body), (200, '<link rel=stylesheet href=a.css><img src=img/p.png>'));
      expect(headers.contentType.toString(), startsWith('text/html'));
      expect(headers.value('content-security-policy'), allOf(startsWith('sandbox '), isNot(contains('allow-same-origin'))));
      final base = entry.replace(path: entry.path.replaceFirst('index.html', ''));
      final css = await get(base.resolve('a.css'));
      expect((css.$1, css.$2, css.$3.value('content-type')), (200, 'body{color:red}', 'text/css; charset=utf-8'));
      expect((await get(base.resolve('img/p.png'))).$3.value('content-type'), 'image/png');
      expect((await get(base.resolve('data.json'))).$3.value('content-type'), 'application/json; charset=utf-8');
      expect((await get(base)).$2, contains('stylesheet'), reason: 'the folder itself is its index.html');
    });

    test('nothing outside the folder, nothing hidden, no other method, no other host, and the token is the key', () async {
      final entry = await server.publishFolder(site, 'index.html');
      final root = entry.replace(path: entry.path.replaceFirst('index.html', ''));
      for (final path in ['../secret.txt', '..%2Fsecret.txt', '%2e%2e/secret.txt', 'img/../../secret.txt', '.env', '.git/config', 'img/.', 'nothing.txt']) {
        final (status, body, _) = await get(Uri.parse('${root.toString()}$path'));
        expect(status, 404, reason: path);
        expect(body, isNot(anyOf(contains('outside'), contains('secret'), contains('[core]'))), reason: path);
      }
      expect((await get(entry, method: 'POST')).$1, 404);
      expect((await get(entry, host: 'evil.example')).$1, 404);
      final wrongToken = entry.replace(path: '/w/${'0' * 32}/index.html');
      expect((await get(wrongToken)).$1, 404);
      expect((await get(entry.replace(path: '/w/${entry.pathSegments[1]}'))).$1, 404, reason: 'no file named');
    });

    test('a link that leads out of the folder is not followed, and a file larger than the limit is not served', () async {
      Link('${site.path}/leak.txt').createSync('${base.path}/secret.txt');
      Link('${site.path}/leakdir').createSync(base.path);
      final entry = await server.publishFolder(site, 'index.html');
      final root = entry.replace(path: entry.path.replaceFirst('index.html', ''));
      expect((await get(root.resolve('leak.txt'))).$1, 404);
      expect((await get(root.resolve('leakdir/secret.txt'))).$1, 404);
      server.maxFileBytes = 10;
      expect((await get(root.resolve('data.json'))).$1, 200, reason: '7 bytes');
      expect((await get(entry)).$1, 404, reason: 'larger than 10 bytes');
    });

    test('the newest folders are kept, like the pages', () async {
      server.maxPages = 1;
      final first = await server.publishFolder(site, 'index.html');
      final second = await server.publishFolder(site, 'index.html');
      expect((await get(first)).$1, 404);
      expect((await get(second)).$1, 200);
    });
  });
}
