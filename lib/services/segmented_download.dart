import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'download_errors.dart' show DownloadCancelled;

/// Opens bytes [from]..[to] (both included) of the file being downloaded.
typedef OpenRange = Future<http.StreamedResponse> Function(int from, int to);

/// The server answered a range request with the whole file (or an error), so it cannot be split.
class RangeNotSupported implements Exception {
  const RangeNotSupported();
}

/// Downloads one file over several connections at once, each asking for its own part of it.
///
/// A single TCP connection slows down a lot when the network loses packets or has a long round
/// trip (a phone on Wi-Fi or mobile data), while a browser's download is often much faster. Several
/// connections each get their own share, so together they use the line. Each part is written to a
/// file of its own (`<part>.seg<i>of<n>`) and the parts are joined at the end, so an interrupted
/// download continues from what every part already has.
abstract final class SegmentedDownload {
  /// A part smaller than this is not worth a connection of its own.
  static const minSegmentBytes = 4 * 1024 * 1024;

  /// How many parts a file of [total] bytes is cut into, at most [connections].
  static int parts(int total, int connections) {
    final byBytes = total ~/ minSegmentBytes;
    return connections < byBytes ? connections : byBytes;
  }

  /// The byte ranges (first and last byte, both included) of [parts] equal parts.
  static List<(int, int)> plan(int total, int parts) => [
        for (var i = 0; i < parts; i++) (total * i ~/ parts, total * (i + 1) ~/ parts - 1),
      ];

  static String _prefix(File part) => '${part.path}.seg';

  /// The file's own name. Parts are told apart by name, not by path: the same folder can be written
  /// with `/` or with `\` (Windows), and a path that was listed need not read like the one it was
  /// made from.
  static String _name(File file) => file.uri.pathSegments.last;

  /// The part files that exist for [part], whatever number of parts they were made for.
  static Future<List<File>> segmentFiles(File part) async {
    final dir = part.parent;
    if (!await dir.exists()) return const [];
    final prefix = '${_name(part)}.seg';
    return [
      await for (final entity in dir.list())
        if (entity is File && _name(entity).startsWith(prefix)) entity,
    ];
  }

  /// Bytes already stored in the part files; what a paused download shows.
  static Future<int> storedBytes(File part) async {
    var sum = 0;
    for (final file in await segmentFiles(part)) {
      sum += await file.length();
    }
    return sum;
  }

  static Future<void> deleteSegments(File part) async {
    for (final file in await segmentFiles(part)) {
      if (await file.exists()) await file.delete();
    }
  }

  /// Fills [part] with the [total] bytes. Returns false, with nothing left on disk, when the server
  /// does not answer range requests; the caller then downloads the file in one piece. A network
  /// error is thrown and the part files stay, so the next call continues. [stall] is how long a
  /// connection may stay silent.
  static Future<bool> run({
    required File part,
    required int total,
    required int connections,
    required OpenRange open,
    required void Function(int done) onProgress,
    bool Function()? cancelled,
    Duration? stall,
  }) async {
    final count = parts(total, connections);
    if (count < 2) return false;

    await part.parent.create(recursive: true);
    final ranges = plan(total, count);
    String pathOf(int i) => '${_prefix(part)}${i}of$count';
    // files made for another number of parts hold other ranges, so they cannot be used
    final names = [for (var i = 0; i < count; i++) '${_name(part)}.seg${i}of$count'];
    for (final file in await segmentFiles(part)) {
      if (!names.contains(_name(file))) await file.delete();
    }

    final stored = List<int>.filled(count, 0);
    var aborted = false;
    Object? failure;
    StackTrace? failureTrace;

    Future<void> worker(int i) async {
      final (first, last) = ranges[i];
      final size = last - first + 1;
      final file = File(pathOf(i));
      var have = await file.exists() ? await file.length() : 0;
      if (have > size) {
        await file.delete();
        have = 0;
      }
      stored[i] = have;
      if (have == size) return;

      final response = await open(first + have, last);
      if (response.statusCode != 206) {
        await response.stream.drain<void>().catchError((_) {});
        throw const RangeNotSupported();
      }
      final sink = file.openWrite(mode: have > 0 ? FileMode.append : FileMode.write);
      try {
        final stream = stall == null ? response.stream : response.stream.timeout(stall);
        await for (final chunk in stream) {
          if (aborted) break;
          if (cancelled?.call() ?? false) throw const DownloadCancelled();
          // a server that sends more than was asked for must not spill into the next part
          final room = size - stored[i];
          final data = chunk.length > room ? chunk.sublist(0, room) : chunk;
          sink.add(data);
          stored[i] += data.length;
          onProgress(stored.fold(0, (a, b) => a + b));
          if (stored[i] >= size) break;
        }
      } finally {
        await sink.close();
      }
      if (!aborted && stored[i] < size) throw const SocketException('connection closed early');
    }

    await Future.wait([
      for (var i = 0; i < count; i++)
        () async {
          try {
            await worker(i);
          } catch (e, s) {
            aborted = true;
            // a server without ranges is the answer, whatever the other parts reported
            if (failure == null || e is RangeNotSupported) {
              failure = e;
              failureTrace = s;
            }
          }
        }(),
    ]);

    if (failure is RangeNotSupported) {
      await deleteSegments(part);
      return false;
    }
    if (failure != null) Error.throwWithStackTrace(failure!, failureTrace!);

    final out = part.openWrite();
    try {
      for (var i = 0; i < count; i++) {
        await out.addStream(File(pathOf(i)).openRead());
      }
    } finally {
      await out.close();
    }
    if (await part.length() != total) {
      await part.delete();
      await deleteSegments(part);
      throw StateError('ダウンロードしたサイズが合いません');
    }
    await deleteSegments(part);
    return true;
  }
}
