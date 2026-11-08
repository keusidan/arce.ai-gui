import 'dart:async';
import 'dart:io';

import 'package:arce_ai/services/model_downloader.dart' show DownloadCancelled;
import 'package:arce_ai/services/segmented_download.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

const _mb = 1024 * 1024;

/// A file of [size] bytes whose content tells where each byte came from.
List<int> _payload(int size) => List.generate(size, (i) => (i * 31 + i ~/ 997) & 0xff);

/// A server that honours `bytes=a-b`, or ignores it when [honour] is false, and can cut a
/// range off halfway through the first [dropFirst] times.
class _Server {
  _Server(this.data, {this.honour = true, this.dropFirst = 0});

  final List<int> data;
  final bool honour;
  int dropFirst;
  final asked = <(int, int)>[];
  var concurrent = 0;
  var peak = 0;

  Future<http.StreamedResponse> open(int from, int to) async {
    asked.add((from, to));
    if (!honour) return http.StreamedResponse(Stream.value(data), 200);
    final slice = data.sublist(from, to + 1);
    if (dropFirst > 0) {
      dropFirst--;
      Stream<List<int>> cut() async* {
        yield slice.sublist(0, slice.length ~/ 2);
        throw const SocketException('connection lost');
      }

      return http.StreamedResponse(cut(), 206);
    }
    Stream<List<int>> chunks() async* {
      concurrent++;
      if (concurrent > peak) peak = concurrent;
      for (var i = 0; i < slice.length; i += 256 * 1024) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
        yield slice.sublist(i, i + 256 * 1024 > slice.length ? slice.length : i + 256 * 1024);
      }
      concurrent--;
    }

    return http.StreamedResponse(chunks(), 206);
  }
}

void main() {
  late Directory dir;
  late File part;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('arce_segmented');
    part = File('${dir.path}/model.gguf.part');
  });
  tearDown(() => dir.delete(recursive: true));

  test('the ranges cover the file exactly, with no gap and no overlap', () {
    for (final (total, count) in [(10 * _mb, 3), (10 * _mb + 7, 4), (8 * _mb, 2)]) {
      final ranges = SegmentedDownload.plan(total, count);
      expect(ranges.first.$1, 0);
      expect(ranges.last.$2, total - 1);
      for (var i = 1; i < ranges.length; i++) {
        expect(ranges[i].$1, ranges[i - 1].$2 + 1);
      }
    }
  });

  test('a small file or one connection is not split', () {
    expect(SegmentedDownload.parts(3 * _mb, 8), 0);
    expect(SegmentedDownload.parts(100 * _mb, 1), 1);
    expect(SegmentedDownload.parts(100 * _mb, 4), 4);
    expect(SegmentedDownload.parts(9 * _mb, 8), 2, reason: 'no part is smaller than 4 MB');
  });

  test('the parts are fetched at the same time and joined in order', () async {
    final data = _payload(12 * _mb + 5);
    final server = _Server(data);
    var last = 0;
    final joined = await SegmentedDownload.run(
      part: part,
      total: data.length,
      connections: 3,
      open: server.open,
      onProgress: (done) => last = done,
    );

    expect(joined, isTrue);
    expect(await part.readAsBytes(), data);
    expect(last, data.length);
    expect(server.asked, hasLength(3));
    expect(server.peak, 3, reason: 'all three connections were open together');
    expect(await SegmentedDownload.segmentFiles(part), isEmpty, reason: 'the part files are removed');
  });

  test('a server that ignores ranges leaves nothing behind and says so', () async {
    final data = _payload(9 * _mb);
    final joined = await SegmentedDownload.run(
      part: part,
      total: data.length,
      connections: 2,
      open: _Server(data, honour: false).open,
      onProgress: (_) {},
    );

    expect(joined, isFalse);
    expect(await part.exists(), isFalse);
    expect(await SegmentedDownload.segmentFiles(part), isEmpty);
  });

  test('after a dropped connection the next run continues from what each part has', () async {
    final data = _payload(12 * _mb);
    final server = _Server(data, dropFirst: 1);
    await expectLater(
      SegmentedDownload.run(part: part, total: data.length, connections: 3, open: server.open, onProgress: (_) {}),
      throwsA(isA<SocketException>()),
    );
    final kept = await SegmentedDownload.storedBytes(part);
    expect(kept, greaterThan(0));

    server.asked.clear();
    final joined = await SegmentedDownload.run(part: part, total: data.length, connections: 3, open: server.open, onProgress: (_) {});
    expect(joined, isTrue);
    expect(await part.readAsBytes(), data);
    // nothing that was already stored is asked for again
    final fetched = server.asked.fold<int>(0, (sum, r) => sum + (r.$2 - r.$1 + 1));
    expect(fetched, data.length - kept);
  });

  test('part files made for another number of parts are not reused', () async {
    final data = _payload(12 * _mb);
    final server = _Server(data, dropFirst: 1);
    await expectLater(
      SegmentedDownload.run(part: part, total: data.length, connections: 3, open: server.open, onProgress: (_) {}),
      throwsA(isA<SocketException>()),
    );

    final joined = await SegmentedDownload.run(part: part, total: data.length, connections: 2, open: _Server(data).open, onProgress: (_) {});
    expect(joined, isTrue);
    expect(await part.readAsBytes(), data);
  });

  test('stopping the download keeps the parts for Resume', () async {
    final data = _payload(12 * _mb);
    var stop = false;
    await expectLater(
      SegmentedDownload.run(
        part: part,
        total: data.length,
        connections: 3,
        open: _Server(data).open,
        onProgress: (done) => stop = done > 2 * _mb,
        cancelled: () => stop,
      ),
      throwsA(isA<DownloadCancelled>()),
    );
    expect(await SegmentedDownload.storedBytes(part), greaterThan(0));
    await SegmentedDownload.deleteSegments(part);
    expect(await SegmentedDownload.storedBytes(part), 0);
  });

  test('a server that sends more than was asked for does not spill into the next part', () async {
    final data = _payload(8 * _mb);
    Future<http.StreamedResponse> generous(int from, int to) async => http.StreamedResponse(Stream.value(data.sublist(from)), 206);
    final joined = await SegmentedDownload.run(part: part, total: data.length, connections: 2, open: generous, onProgress: (_) {});
    expect(joined, isTrue);
    expect(await part.readAsBytes(), data);
  });
}
