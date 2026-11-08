import 'dart:io';

import 'package:flutter/services.dart';

import '../core/reply_event.dart';

/// Tells the user, with a system notification, that a reply waits for them, is finished or failed.
///
/// Android only (`NotifyBridge.kt`); on the other systems every call does nothing, and [supported]
/// says so. Tests use a subclass instead of the channel.
class ReplyNotifier {
  const ReplyNotifier();

  static const _channel = MethodChannel('ai.arce.app/notify');

  bool get supported => Platform.isAndroid;

  /// Whether a notification would be shown now (the permission is given and the user has not turned
  /// the app's notifications off).
  Future<bool> allowed() async {
    if (!supported) return false;
    try {
      return await _channel.invokeMethod<bool>('allowed') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Asks for the permission to notify (Android 13 and later show a question; before that it is
  /// already given). The answer is whether notifications can be shown now.
  Future<bool> request() async {
    if (!supported) return false;
    try {
      return await _channel.invokeMethod<bool>('request') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Shows [event]; a later event of the same [group] (one conversation) replaces the earlier one.
  Future<void> show(ReplyEvent event, {String group = ''}) async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<void>('show', {
        'kind': event.kind.name,
        'title': event.title,
        'body': event.body,
        'group': group,
      });
    } catch (_) {
      // a notification that cannot be shown must not break the chat
    }
  }
}
