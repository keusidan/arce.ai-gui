import 'dart:io';

import 'package:flutter/services.dart';

/// What the foreground service is being kept alive for. It decides the text of the notification.
enum ForegroundReason { generation, update, modelDownload }

/// Android's foreground service while the app has work that must survive leaving the screen:
/// a reply being generated, an update being downloaded, or a model being downloaded.
///
/// The service only keeps the process alive and shows a notification; the work itself is the
/// same stream as before. Both kinds of work share one service, so it stops only when the last
/// of them is done. On other platforms these calls do nothing.
class ForegroundService {
  static const _channel = MethodChannel('ai.arce.app/system');

  /// Insertion order is the order the work started; the newest decides the notification.
  final _reasons = <ForegroundReason>[];

  bool get isRunning => _reasons.isNotEmpty;

  Future<void> start([ForegroundReason reason = ForegroundReason.generation]) async {
    if (!Platform.isAndroid || _reasons.contains(reason)) return;
    _reasons.add(reason);
    await _show(reason);
  }

  Future<void> stop([ForegroundReason reason = ForegroundReason.generation]) async {
    if (!Platform.isAndroid || !_reasons.remove(reason)) return;
    try {
      if (_reasons.isEmpty) {
        await _channel.invokeMethod<void>('stopForeground');
      } else {
        // the other work is still running: put its text back in the notification
        await _show(_reasons.last);
      }
    } catch (_) {
      // already gone
    }
  }

  Future<void> _show(ForegroundReason reason) async {
    try {
      await _channel.invokeMethod<void>('startForeground', {'kind': reason.name});
    } catch (_) {
      // no service in this build: the work still goes on while the app is in front
      _reasons.remove(reason);
    }
  }
}
