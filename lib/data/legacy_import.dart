import 'dart:convert';

import 'llm_db.dart';

/// What happened to one conversation file from the old JSON store.
enum LegacyImportResult {
  /// Written to the database.
  imported,

  /// Already there; importing twice does not duplicate anything.
  skipped,

  /// Not a conversation file this version understands.
  failed,
}

class LegacyImportSummary {
  const LegacyImportSummary(this.imported, this.skipped, this.failed);

  final int imported;
  final int skipped;
  final int failed;

  int get total => imported + skipped + failed;

  @override
  String toString() => 'LegacyImportSummary(imported: $imported, skipped: $skipped, failed: $failed)';
}

/// The prefix that marks a conversation carried over from the old store, so that importing the
/// same file twice lands on the same row instead of making a second copy.
const _legacyPrefix = 'legacy-';

/// Whether [conversationId] came from the old JSON store.
bool isLegacyConversation(String conversationId) => conversationId.startsWith(_legacyPrefix);

/// Reads one decoded `conversations/<id>.json` and writes it to [db].
///
/// The old files hold the screen messages (text, thinking, attachments, tool activities and a
/// question tile) plus the model history; only the former is carried over, because the history
/// is rebuilt from the messages when a conversation is opened again.
LegacyImportResult importLegacyConversation(LlmDatabase db, Map<String, Object?> json) {
  final legacyId = json['id'];
  if (legacyId is! int) return LegacyImportResult.failed;
  final snapshot = json['snapshot'];
  if (snapshot is! Map) return LegacyImportResult.failed;

  final conversationId = '$_legacyPrefix$legacyId';
  if (db.conversation(conversationId) != null) return LegacyImportResult.skipped;

  final messages = snapshot['messages'];
  final rows = messages is List ? messages.whereType<Map>().toList() : const <Map>[];

  final updatedAt = _millis(json['updatedAt']) ?? DateTime.now();
  final startedAt = _millis(rows.isEmpty ? null : rows.first['time']) ?? updatedAt;
  final title = (json['title'] as String?)?.trim();
  final agent = rows
      .map((m) => m['agent'])
      .whereType<String>()
      .where((a) => a.isNotEmpty)
      .firstOrNull;

  db.startConversation(
    id: conversationId,
    title: title == null || title.isEmpty ? '新しい会話' : title,
    agentId: agent ?? '',
    providerId: 'local',
    modelId: 'legacy',
    now: startedAt,
  );

  final generating = json['generating'] == true;
  for (var i = 0; i < rows.length; i++) {
    final row = rows[i];
    final role = row['role'] as String? ?? MessageRole.user;
    final last = i == rows.length - 1;
    db.addMessage(
      conversationId,
      NewMessage(
        role,
        _partsOf(row),
        agentId: row['agent'] as String?,
        providerId: 'local',
        modelId: 'legacy',
        createdAt: _millis(row['time']) ?? updatedAt,
        // A generation was still running when the app last stopped; keep it resumable.
        finishReason: generating && last && role == MessageRole.assistant
            ? interruptedFinishReason
            : row['finish'] as String?,
      ),
    );
  }

  // addMessage moves the conversation to the newest message; restore the file's own time.
  db.setUpdatedAt(conversationId, updatedAt);
  return LegacyImportResult.imported;
}

/// Imports every decoded file; safe to run on every launch.
LegacyImportSummary importLegacyAll(LlmDatabase db, Iterable<Map<String, Object?>> files) {
  var imported = 0, skipped = 0, failed = 0;
  for (final file in files) {
    try {
      switch (importLegacyConversation(db, file)) {
        case LegacyImportResult.imported:
          imported++;
        case LegacyImportResult.skipped:
          skipped++;
        case LegacyImportResult.failed:
          failed++;
      }
    } catch (_) {
      // One unreadable file must not stop the rest.
      failed++;
    }
  }
  return LegacyImportSummary(imported, skipped, failed);
}

List<NewPart> _partsOf(Map row) {
  final parts = <NewPart>[];

  final thinking = row['thinking'] as String? ?? '';
  if (thinking.trim().isNotEmpty) parts.add(NewPart(PartKind.reasoning, text: thinking));

  final text = row['text'] as String? ?? '';
  if (text.isNotEmpty) parts.add(NewPart(PartKind.text, text: text));

  for (final name in (row['attachments'] as List? ?? const [])) {
    if (name is String) parts.add(NewPart(PartKind.attachment, text: name));
  }

  for (final activity in (row['activities'] as List? ?? const [])) {
    if (activity is! Map) continue;
    parts.add(NewPart(
      PartKind.toolResult,
      text: activity['summary'] as String?,
      toolName: activity['tool'] as String?,
      payload: jsonEncode(activity),
    ));
  }

  final question = row['question'];
  if (question is Map) {
    parts.add(NewPart(PartKind.question, payload: jsonEncode(question)));
  }

  return parts;
}

DateTime? _millis(Object? value) =>
    value is int ? DateTime.fromMillisecondsSinceEpoch(value) : null;
