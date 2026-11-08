import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../core/chat_controller.dart';
import '../data/conversation_snapshot_store.dart';
import '../data/legacy_import.dart';
import '../data/llm_db.dart';
import '../data/llm_db_io.dart';

/// One row of the history list.
class ConversationMeta {
  const ConversationMeta({
    required this.id,
    required this.title,
    required this.updatedAt,
    required this.messageCount,
    required this.generating,
  });

  final String id;
  final String title;
  final DateTime updatedAt;
  final int messageCount;

  /// A generation was still running when the app last stopped, so it can be resumed.
  final bool generating;
}

/// The app's chat history: the LLM database, plus the one-time import of the old JSON files.
///
/// Settings, provider definitions and keys are deliberately not here; they stay in the settings
/// JSON and the secure storage.
class ConversationDatabase {
  ConversationDatabase._(this._db, this.store, this._support);

  final LlmDatabase _db;
  final ConversationSnapshotStore store;
  final Directory _support;

  /// The app's data folder; the paths in the `assets` table are relative to it.
  Directory get supportDirectory => _support;

  /// The saved KV caches (see `KvSnapshotService`), oldest use first.
  List<AssetRow> kvAssets() => _db.assetsByMime(LlmDatabase.kvMime);

  String addKvAsset({required String relPath, required int byteSize, required String conversationId}) =>
      _db.addAsset(
        relPath: relPath,
        mime: LlmDatabase.kvMime,
        byteSize: byteSize,
        // a KV cache is checked by the engine when it is loaded, not by a hash of its bytes
        sha256: '',
        conversationId: conversationId,
      );

  void deleteAsset(String id) => _db.deleteAsset(id);

  void touchAsset(String id) => _db.touchAsset(id);

  /// [supportDirectory] replaces the platform's app-data folder (tests use a temporary one).
  static Future<ConversationDatabase> open({Directory? supportDirectory}) async {
    final support = supportDirectory ?? await getApplicationSupportDirectory();
    final db = await openLlmDatabase(supportDirectory: support);
    final database = ConversationDatabase._(db, ConversationSnapshotStore(db), support);
    await database.importLegacy();
    return database;
  }

  /// Carries the old `conversations/*.json` files over to the database. Safe to run on every
  /// launch: a conversation that is already there is skipped, not duplicated.
  Future<LegacyImportSummary> importLegacy() async {
    final dir = Directory('${_support.path}${Platform.pathSeparator}conversations');
    if (!await dir.exists()) return const LegacyImportSummary(0, 0, 0);

    final files = <Map<String, Object?>>[];
    await for (final entity in dir.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        files.add((jsonDecode(await entity.readAsString()) as Map).cast<String, Object?>());
      } catch (e) {
        debugPrint('could not read ${entity.path}: $e');
      }
    }
    final summary = importLegacyAll(_db, files);
    if (summary.imported > 0 || summary.failed > 0) {
      debugPrint('legacy conversations: $summary');
    }
    return summary;
  }

  Future<List<ConversationMeta>> list() async => [
        for (final c in store.list())
          ConversationMeta(
            id: c.id,
            title: c.title,
            updatedAt: c.updatedAt,
            messageCount: c.messageCount,
            generating: c.generating,
          ),
      ];

  /// Saves the whole conversation; returns the id it was stored under.
  ///
  /// [providerId] and [modelId] record who answered, so a conversation keeps saying which engine
  /// wrote it even after the user switches to another one.
  Future<String> save(
    String? id,
    ConversationSnapshot snapshot, {
    required bool generating,
    String providerId = 'local',
    String modelId = '',
  }) async =>
      store.save(
        id,
        snapshot.toJson(),
        generating: generating,
        providerId: providerId,
        modelId: modelId,
      );

  Future<ConversationSnapshot?> get(String id) async {
    final json = store.read(id);
    if (json == null) return null;
    try {
      return ConversationSnapshot.fromJson(json);
    } catch (e) {
      // one damaged conversation must not take the history list down with it
      debugPrint('could not read conversation $id: $e');
      return null;
    }
  }

  Future<void> delete(String id) async {
    for (final relPath in store.delete(id)) {
      try {
        final file = File('${_support.path}${Platform.pathSeparator}$relPath');
        if (await file.exists()) await file.delete();
      } catch (e) {
        debugPrint('could not delete $relPath: $e');
      }
    }
  }

  Future<void> clearGenerating(String id) async => store.clearGenerating(id);

  /// Replaces the title of conversation [id].
  Future<void> rename(String id, String title) async => store.rename(id, title);

  /// Message text across every conversation.
  List<SearchHit> search(String query, {int limit = 50}) => store.search(query, limit: limit);

  void close() => _db.close();
}
