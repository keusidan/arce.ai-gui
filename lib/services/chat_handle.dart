import 'package:flutter/foundation.dart';

import '../core/attachments.dart';
import '../core/chat_controller.dart';

/// The chat the screen shows. It is always the same object, so a widget can listen to it once; what
/// it forwards to is the controller of the conversation on the screen, and changes when the user
/// opens another conversation (the one that was generating goes on in the background).
class ChatHandle extends ChangeNotifier {
  ChatHandle(ChatController first) : _target = first {
    _target.addListener(notifyListeners);
  }

  ChatController _target;

  ChatController get current => _target;

  /// Shows [next] from now on, and tells the listeners.
  void show(ChatController next) {
    if (identical(next, _target)) return;
    _target.removeListener(notifyListeners);
    _target = next..addListener(notifyListeners);
    notifyListeners();
  }

  ChatState get state => _target.state;

  Future<void> send(String text, {List<Attachment> attachments = const []}) => _target.send(text, attachments: attachments);
  Future<void> answer(List<String> selected, String? freeText) => _target.answer(selected, freeText);
  Future<void> regenerate() => _target.regenerate();
  Future<void> continueReply() => _target.continueReply();
  void stop() => _target.stop();
  bool get isRunning => _target.isRunning;
  bool interject(String text) => _target.interject(text);
  bool get canCompact => _target.canCompact;
  Future<String> compactNow() => _target.compactNow();
  void unqueue(int index) => _target.unqueue(index);
  void clear() => _target.clear();
  void restore(ConversationSnapshot snapshot) => _target.restore(snapshot);
  ConversationSnapshot snapshot() => _target.snapshot();

  @override
  void dispose() {
    _target.removeListener(notifyListeners);
    super.dispose();
  }
}
