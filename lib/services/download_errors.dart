import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Lets the user stop a download; what was fetched is kept for Resume.
class CancelToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

class DownloadCancelled implements Exception {
  const DownloadCancelled();
}

/// How a download failure is told apart and told to the user; shared by the model download and the
/// app update, which used to each have their own.
abstract final class DownloadErrors {
  /// A failure of the connection itself (or a server that is busy), as opposed to an answer that
  /// trying again cannot change. Only these are tried again.
  static bool isTransient(Object e) {
    if (e is SocketException || e is TimeoutException || e is http.ClientException || e is TlsException) return true;
    if (e is HttpException) {
      final status = int.tryParse(RegExp(r'HTTP (\d+)').firstMatch(e.message)?.group(1) ?? '');
      return status != null && (status >= 500 || status == 429);
    }
    return false;
  }

  /// What the screen shows for a failed download; [resume] says how to carry on. The text of the
  /// exceptions of the HTTP client carries the whole address, and that of a CDN is a signed link
  /// several hundred characters long, so addresses are cut out.
  static String explain(Object e, {String resume = '「再開」で続きから取ります'}) {
    if (e is http.ClientException && e.message.toLowerCase().contains('connection closed')) {
      return '通信が途切れました（サーバーが接続を閉じました）。$resume';
    }
    if (e is TimeoutException) return '応答がありません。$resume';
    if (e is SocketException) return '通信が途切れました（${e.osError?.message ?? e.message}）。$resume';
    if (e is HttpException) return 'ダウンロードに失敗しました（${e.message}）';
    final text = '$e'.replaceAll(RegExp(r',? ?uri=\S+'), '').replaceAll(RegExp(r'https?://\S+'), '（URL）');
    return text.length > 200 ? '${text.substring(0, 200)}…' : text;
  }
}
