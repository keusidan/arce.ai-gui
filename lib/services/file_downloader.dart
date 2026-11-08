import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'download_errors.dart';
import 'segmented_download.dart';

/// Opens bytes [from]..[to] (both included) of the file; a null [to] is "to the end", and 0 with a
/// null [to] is the whole file (no range at all). The answer is returned as it is, whatever its
/// status: [FileDownloader] reads the status.
typedef OpenFile = Future<http.StreamedResponse> Function(int from, int? to);

/// The `Range` header value of a request for [from]..[to], or null for the whole file.
String? rangeHeader(int from, int? to) => from == 0 && to == null ? null : 'bytes=$from-${to ?? ''}';

/// The download that the model download and the app update share: it fills one file from a source
/// that can answer range requests, over several connections when the file is large, continues from
/// what an earlier try left on disk, and tries again after a failure of the connection.
///
/// What differs between the two — where the bytes come from (Hugging Face, or GitHub with its
/// redirect to signed storage), the check of the finished file and what is shown — stays with them.
class FileDownloader {
  FileDownloader({
    int Function()? connections,
    this.stall,
    int Function()? attempts,
    this.retryDelay = const Duration(seconds: 2),
  })  : _connections = connections ?? (() => 1),
        _attempts = attempts ?? (() => 1);

  final int Function() _connections;

  /// How long a connection may stay silent, asked on every download; null waits for ever.
  final Duration Function()? stall;

  /// How many times a download is tried before it is reported as failed (asked on every download);
  /// every try after the first continues from what is on disk.
  final int Function() _attempts;

  /// The wait before try *n* is `retryDelay * n`.
  final Duration retryDelay;

  /// Runs [action], and when the connection fails tries again up to the number of attempts.
  /// [cancelled] ends the waiting between tries.
  Future<T> retrying<T>(Future<T> Function() action, {bool Function()? cancelled}) async {
    final attempts = _attempts().clamp(1, 20);
    for (var attempt = 1;; attempt++) {
      try {
        return await action();
      } on DownloadCancelled {
        rethrow;
      } catch (e) {
        if (!DownloadErrors.isTransient(e) || attempt >= attempts) rethrow;
        await Future<void>.delayed(retryDelay * attempt);
        if (cancelled?.call() ?? false) throw const DownloadCancelled();
      }
    }
  }

  /// Fills [part] with the [total] bytes of the file that [open] gives. When this returns, [part] is
  /// complete; checking it and putting it in place is the caller's. [onProgress] gets the bytes
  /// stored so far (as often as the data comes: the caller thins it out).
  Future<void> fetch({
    required File part,
    required int total,
    required OpenFile open,
    required void Function(int done) onProgress,
    bool Function()? cancelled,
  }) => retrying(() => _once(part, total, open, onProgress, cancelled), cancelled: cancelled);

  Future<void> _once(File part, int total, OpenFile open, void Function(int) onProgress, bool Function()? cancelled) async {
    await part.parent.create(recursive: true);
    var have = await part.exists() ? await part.length() : 0;
    // A file as long as the original is all of it (the app stopped before it was checked): asking
    // for the rest would be answered with 416. A longer one cannot be a part of it.
    if (have == total) return;
    if (have > total) {
      await part.delete();
      have = 0;
    }

    // A fresh download over several connections; a part file from one connection is finished the
    // way it was started.
    final connections = _connections().clamp(1, 16);
    if (have == 0 && SegmentedDownload.parts(total, connections) >= 2) {
      final joined = await SegmentedDownload.run(
        part: part,
        total: total,
        connections: connections,
        open: (from, to) => open(from, to),
        onProgress: onProgress,
        cancelled: cancelled,
        stall: stall?.call(),
      );
      if (joined) return;
    }

    var response = await open(have, null);
    if (have > 0 && response.statusCode != 206) {
      if (response.statusCode != 200 && response.statusCode != 416) {
        await response.stream.drain<void>().catchError((_) {});
        throw HttpException('HTTP ${response.statusCode}');
      }
      // the server ignored the range (200), or the part file is not of this file (416): the part
      // file is dropped and the file is fetched from the beginning
      await response.stream.drain<void>().catchError((_) {});
      await part.delete();
      have = 0;
      response = await open(0, null);
    }
    if (response.statusCode != 200 && response.statusCode != 206) {
      await response.stream.drain<void>().catchError((_) {});
      throw HttpException('HTTP ${response.statusCode}');
    }

    final sink = part.openWrite(mode: have > 0 ? FileMode.append : FileMode.write);
    var done = have;
    onProgress(done);
    try {
      final timeout = stall?.call();
      final stream = timeout == null ? response.stream : response.stream.timeout(timeout);
      await for (final chunk in stream) {
        if (cancelled?.call() ?? false) throw const DownloadCancelled();
        sink.add(chunk);
        done += chunk.length;
        onProgress(done);
      }
    } finally {
      // the part file stays on disk even when the stream fails, so the next try continues
      await sink.flush();
      await sink.close();
    }
    if (done < total) throw const SocketException('connection closed early');
  }

  /// The SHA-256 of [file], worked out in another isolate: a model is gigabytes, and the screen
  /// must keep moving meanwhile.
  static Future<String> sha256Of(File file) {
    final path = file.path;
    return Isolate.run(() async => (await sha256.bind(File(path).openRead()).first).toString());
  }
}
