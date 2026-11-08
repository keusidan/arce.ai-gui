import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'llm_db.dart';

/// Opens (or creates) the chat history database in the app's support directory.
///
/// Kept apart from `llm_db.dart` so the schema and the queries can be tested without Flutter.
Future<LlmDatabase> openLlmDatabase({Directory? supportDirectory}) async {
  final support = supportDirectory ?? await getApplicationSupportDirectory();
  final dir = Directory('${support.path}${Platform.pathSeparator}llm');
  await dir.create(recursive: true);
  return LlmDatabase.open('${dir.path}${Platform.pathSeparator}arce_llm.db');
}
