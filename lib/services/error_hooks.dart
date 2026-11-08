import 'package:flutter/foundation.dart';

/// Hands the errors nobody caught to [report]: the Flutter framework's (a widget that failed to
/// build or to lay out) and the asynchronous ones (a future that failed with no one listening).
/// What was there before keeps running: the error still goes to the console.
void installErrorHooks(void Function(Object error, StackTrace? stack) report) {
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    if (previous != null) {
      previous(details);
    } else {
      FlutterError.presentError(details);
    }
    report(details.exception, details.stack);
  };
  final previousAsync = PlatformDispatcher.instance.onError;
  PlatformDispatcher.instance.onError = (error, stack) {
    report(error, stack);
    // false: the platform's own handling goes on as it did
    return previousAsync?.call(error, stack) ?? false;
  };
}
