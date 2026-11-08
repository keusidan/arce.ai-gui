import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../core/model_catalog.dart';
import 'download_errors.dart';
import 'file_downloader.dart';
import 'segmented_download.dart';

export 'download_errors.dart' show CancelToken, DownloadCancelled;

class RemoteFile {
  const RemoteFile({required this.sizeBytes, this.sha256});
  final int sizeBytes;
  final String? sha256;
}

/// Downloads a model file from Hugging Face into the model directory.
///
/// The transfer itself (several connections, resuming, trying again) is [FileDownloader]'s, the
/// same one the app update uses. This class knows where a model lives on Hugging Face, how big it
/// is and what its SHA-256 is.
class ModelDownloader {
  ModelDownloader(
    this.directory, {
    http.Client? client,
    int Function()? connections,
    Duration Function()? stall,
    int Function()? attempts,
    Duration retryDelay = const Duration(seconds: 2),
  })  : _client = client ?? http.Client(),
        _fetcher = FileDownloader(connections: connections, stall: stall, attempts: attempts, retryDelay: retryDelay);

  final Directory directory;
  final http.Client _client;
  final FileDownloader _fetcher;

  File target(ModelSpec spec) => File('${directory.path}${Platform.pathSeparator}${spec.fileName}');
  File partial(ModelSpec spec) => File('${target(spec).path}.part');

  /// Bytes of [spec] already on disk: the partial file, or the parts of a download over several connections.
  Future<int> downloadedBytes(ModelSpec spec) async {
    final part = partial(spec);
    final single = await part.exists() ? await part.length() : 0;
    return single > 0 ? single : await SegmentedDownload.storedBytes(part);
  }

  /// Size and checksum from the Hugging Face tree API.
  Future<RemoteFile> remote(ModelSpec spec) async {
    final response = await _client
        .get(Uri.parse('https://huggingface.co/api/models/${spec.hfRepo}/tree/main'), headers: _headers)
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) throw HttpException('HTTP ${response.statusCode}');
    final entries = jsonDecode(response.body) as List;
    final entry = entries.cast<Map>().firstWhere(
          (e) => e['path'] == spec.fileName,
          orElse: () => throw StateError('${spec.fileName} not found in ${spec.hfRepo}'),
        );
    final lfs = entry['lfs'] as Map?;
    return RemoteFile(
      sizeBytes: ((lfs?['size'] ?? entry['size']) as num?)?.toInt() ?? spec.fileBytes,
      sha256: lfs?['oid'] as String?,
    );
  }

  /// Downloads (or continues) [spec]. Throws the last error after the tries, and [DownloadCancelled]
  /// when the user stops it; what was fetched stays so the download can resume.
  Future<File> download(
    ModelSpec spec,
    RemoteFile remote,
    void Function(int done, int total) onProgress,
    CancelToken cancel,
  ) async {
    final part = partial(spec);
    final url = Uri.parse('https://huggingface.co/${spec.hfRepo}/resolve/main/${spec.fileName}');
    await _fetcher.fetch(
      part: part,
      total: remote.sizeBytes,
      onProgress: (done) => onProgress(done, remote.sizeBytes),
      cancelled: () => cancel.isCancelled,
      open: (from, to) {
        final range = rangeHeader(from, to);
        return _client
            .send(http.Request('GET', url)..headers.addAll({..._headers, 'Range': ?range}))
            .timeout(const Duration(seconds: 30));
      },
    );
    return part;
  }

  /// Checks the SHA-256 and moves the file into place; deletes it when corrupt.
  Future<File> install(ModelSpec spec, RemoteFile remote, File part) async {
    final expected = remote.sha256;
    if (expected != null) {
      final actual = await FileDownloader.sha256Of(part);
      if (actual.toLowerCase() != expected.toLowerCase()) {
        await part.delete();
        throw StateError('SHA-256 mismatch (file corrupted); downloaded file removed');
      }
    }
    return part.rename(target(spec).path);
  }

  /// Integrity check of an installed model (spec §19 整合性確認).
  Future<bool> verify(ModelSpec spec, RemoteFile remote) async {
    final file = target(spec);
    if (!await file.exists() || await file.length() != remote.sizeBytes) return false;
    final expected = remote.sha256;
    return expected == null || (await FileDownloader.sha256Of(file)).toLowerCase() == expected.toLowerCase();
  }

  static Map<String, String> get _headers => const {'User-Agent': 'ARCE.AI'};
}
