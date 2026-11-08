import 'dart:async';
import 'dart:io';

import 'package:arce_ai/core/model_catalog.dart';
import 'package:arce_ai/services/download_errors.dart';
import 'package:arce_ai/services/file_downloader.dart';
import 'package:arce_ai/services/model_downloader.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

List<int> _data(int n) => List.generate(n, (i) => (i * 13 + i ~/ 7) & 0xff);

void main() {
  late Directory dir;
  final spec = ModelCatalog.basic;
  final data = _data(50000);
  final remote = RemoteFile(sizeBytes: data.length, sha256: sha256.convert(data).toString());

  setUp(() async => dir = await Directory.systemTemp.createTemp('arce_model_dl'));
  tearDown(() => dir.delete(recursive: true));

  ModelDownloader downloader(MockClient client, {int attempts = 1}) =>
      ModelDownloader(dir, client: client, attempts: () => attempts, retryDelay: Duration.zero);

  http.StreamedResponse ok(http.BaseRequest request, List<int> body, [int code = 200]) =>
      http.StreamedResponse(Stream.value(body), code, request: request);

  test('a part file that already has every byte is not asked for again', () async {
    var requests = 0;
    final d = downloader(MockClient.streaming((request, _) async {
      requests++;
      return ok(request, data);
    }));
    await d.partial(spec).create(recursive: true);
    await d.partial(spec).writeAsBytes(data);

    final file = await d.download(spec, remote, (_, _) {}, CancelToken());

    expect(requests, 0, reason: 'asking for the rest of a complete file is answered with HTTP 416');
    expect(await file.readAsBytes(), data);
    expect((await d.install(spec, remote, file)).path, d.target(spec).path);
  });

  test('a part file longer than the model is thrown away and the model is fetched again', () async {
    final d = downloader(MockClient.streaming((request, _) async {
      expect(request.headers.containsKey('Range'), isFalse);
      return ok(request, data);
    }));
    await d.partial(spec).create(recursive: true);
    await d.partial(spec).writeAsBytes([..._data(60000)]);

    final file = await d.download(spec, remote, (_, _) {}, CancelToken());
    expect(await file.readAsBytes(), data);
  });

  test('HTTP 416 on a resume starts again from the beginning instead of failing', () async {
    final ranges = <String?>[];
    final d = downloader(MockClient.streaming((request, _) async {
      ranges.add(request.headers['Range']);
      return request.headers.containsKey('Range') ? ok(request, const [], 416) : ok(request, data);
    }));
    await d.partial(spec).create(recursive: true);
    await d.partial(spec).writeAsBytes(data.sublist(0, 1000));

    final file = await d.download(spec, remote, (_, _) {}, CancelToken());

    expect(ranges, ['bytes=1000-', null]);
    expect(await file.readAsBytes(), data);
  });

  test('a dropped connection is tried again and continues from what is on disk', () async {
    final ranges = <String?>[];
    final d = downloader(
      MockClient.streaming((request, _) async {
        ranges.add(request.headers['Range']);
        if (ranges.length == 1) {
          Stream<List<int>> cut() async* {
            yield data.sublist(0, 20000);
            throw http.ClientException('Connection closed while receiving data');
          }

          return http.StreamedResponse(cut(), 200, request: request);
        }
        final from = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(request.headers['Range']!)!.group(1)!);
        return ok(request, data.sublist(from), 206);
      }),
      attempts: 3,
    );

    final file = await d.download(spec, remote, (_, _) {}, CancelToken());

    expect(ranges, [null, 'bytes=20000-']);
    expect(await file.readAsBytes(), data);
  });

  test('after the last try the error is thrown, and a stop is never tried again', () async {
    var requests = 0;
    final failing = downloader(
      MockClient.streaming((request, _) async {
        requests++;
        throw const SocketException('network is down');
      }),
      attempts: 3,
    );
    await expectLater(failing.download(spec, remote, (_, _) {}, CancelToken()), throwsA(isA<SocketException>()));
    expect(requests, 3);

    requests = 0;
    final stopped = CancelToken()..cancel();
    final pausing = downloader(
      MockClient.streaming((request, _) async {
        requests++;
        return http.StreamedResponse(Stream.fromIterable([data.sublist(0, 100)]), 200, request: request);
      }),
      attempts: 3,
    );
    await expectLater(pausing.download(spec, remote, (_, _) {}, stopped), throwsA(isA<DownloadCancelled>()));
    expect(requests, 1);
  });

  test('which errors are worth trying again', () {
    expect(DownloadErrors.isTransient(const SocketException('x')), isTrue);
    expect(DownloadErrors.isTransient(TimeoutException('x')), isTrue);
    expect(DownloadErrors.isTransient(http.ClientException('x')), isTrue);
    expect(DownloadErrors.isTransient(const HttpException('HTTP 503')), isTrue);
    expect(DownloadErrors.isTransient(const HttpException('HTTP 429')), isTrue);
    expect(DownloadErrors.isTransient(const HttpException('HTTP 404')), isFalse);
    expect(DownloadErrors.isTransient(const HttpException('HTTP 403')), isFalse);
    expect(DownloadErrors.isTransient(StateError('x')), isFalse);
  });

  test('an error message never carries the signed link of the CDN', () {
    final signed = 'https://us.aws.cdn.hf.co/xet-bridge-us/68/0765?X-Amz-Signature=${'a' * 400}&Key-Pair-Id=K01';
    final closed = DownloadErrors.explain(http.ClientException('Connection closed while receiving data', Uri.parse(signed)));
    expect(closed, contains('通信が途切れました'));
    expect(closed, isNot(contains('http')));
    expect(closed.length, lessThan(100));

    final other = DownloadErrors.explain(StateError('failed at $signed after a while'));
    expect(other, isNot(contains('Signature')));
    expect(other, contains('（URL）'));
  });

  test('the checksum is worked out for a file', () async {
    final file = File('${dir.path}/x.bin')..writeAsBytesSync(data);
    expect(await FileDownloader.sha256Of(file), sha256.convert(data).toString());
  });
}
