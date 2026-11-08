import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../core/engine.dart';
import '../data/llm_db.dart';
import 'conversation_database.dart';

/// What the user decided about saved KV caches (settings).
class KvSnapshotConfig {
  const KvSnapshotConfig({this.enabled = false, this.maxBytes = 1024 * 1024 * 1024, this.minTokens = 512});

  final bool enabled;

  /// All saved caches together stay under this; the one used longest ago goes first.
  final int maxBytes;

  /// A prompt shorter than this is not worth a file: evaluating it again takes moments.
  final int minTokens;
}

/// Keeps the engine's KV cache of a conversation in a file, so opening that conversation again
/// does not evaluate its whole history from the start.
///
/// The cache is a big tensor read and written as one block, so it does not belong in the
/// database; the file lives in `kv/` and only its index (conversation, size, last use) is a row of
/// the `assets` table. That gives what a file alone lacks: the file goes with its conversation,
/// and the total size can be capped by last use.
///
/// A file is only valid for the model, context size, KV type and app build it was made with. These
/// are folded into [fingerprint] and into the file name, so another setup never reads it (and
/// llama.cpp refuses a file whose layout does not match anyway: a refused file is deleted).
class KvSnapshotService {
  KvSnapshotService({required this.database, required this.engine, required this.config});

  final ConversationDatabase database;
  final KvStatePersistence engine;
  final KvSnapshotConfig Function() config;

  static const folder = 'kv';
  static const _format = 'v1';

  /// Identifies the setup a saved cache is valid for.
  static String fingerprint({
    required String modelName,
    required int modelBytes,
    required int contextLength,
    required KvCacheType kvCache,
    required String appVersion,
  }) {
    final text = [_format, modelName, modelBytes, contextLength, kvCache.name, appVersion].join('|');
    return sha256.convert(utf8.encode(text)).toString().substring(0, 12);
  }

  /// Saves and loads run one after the other: both touch the same engine and the same files.
  Future<void> _tail = Future.value();

  Future<T> _serialize<T>(Future<T> Function() job) {
    final run = _tail.then((_) => job());
    _tail = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  static String relPath(String conversationId, String fingerprint) => '$folder/$conversationId.$fingerprint.kv';

  File _file(String relPath) =>
      File('${database.supportDirectory.path}${Platform.pathSeparator}${relPath.replaceAll('/', Platform.pathSeparator)}');

  /// Total size of the saved caches.
  int get totalBytes => database.kvAssets().fold(0, (sum, a) => sum + a.byteSize);

  /// Saves what the engine holds for [conversationId]. False when nothing was kept: the feature
  /// is off, the prompt is short, or the engine cannot save this model's state.
  Future<bool> save(String conversationId, String fingerprint) => _serialize(() async {
        final c = config();
        if (!c.enabled || c.maxBytes <= 0) return false;
        final rel = relPath(conversationId, fingerprint);
        final file = _file(rel);
        final temporary = File('${file.path}.tmp');
        try {
          await file.parent.create(recursive: true);
          // written beside the final name and renamed, so a crash never leaves half a cache there
          final written = await engine.saveKvState(temporary.path, minTokens: c.minTokens);
          if (written <= 0 || !await temporary.exists()) return false;
          final size = await temporary.length();
          if (size > c.maxBytes) return false; // one cache bigger than the whole limit is not kept
          await temporary.rename(file.path);

          // one cache per conversation: the older ones (another model, an earlier prompt) go
          for (final asset in database.kvAssets()) {
            if (asset.conversationId != conversationId) continue;
            database.deleteAsset(asset.id);
            if (asset.relPath != rel) await _delete(_file(asset.relPath));
          }
          database.addKvAsset(relPath: rel, byteSize: size, conversationId: conversationId);
          await _enforce(c.maxBytes);
          return true;
        } catch (e) {
          // a file that cannot be written, a conversation deleted in the meantime: the cache is
          // only an optimisation, so it is "not saved", never an error for the chat
          debugPrint('could not save the KV cache: $e');
          return false;
        } finally {
          await _delete(temporary);
        }
      });

  /// Gives the engine the saved cache of [conversationId], if one fits the current setup.
  ///
  /// [stillWanted] is asked just before the engine is touched: when the user has already started
  /// typing to the model, loading would throw away the work the new prompt just did.
  Future<bool> restore(String conversationId, String fingerprint, {bool Function()? stillWanted}) =>
      _serialize(() async {
        if (!config().enabled) return false;
        final rel = relPath(conversationId, fingerprint);
        AssetRow? row;
        for (final asset in database.kvAssets()) {
          if (asset.conversationId == conversationId && asset.relPath == rel) row = asset;
        }
        if (row == null) return false;

        final file = _file(rel);
        try {
          if (!await file.exists() || await file.length() != row.byteSize) {
            database.deleteAsset(row.id);
            await _delete(file);
            return false;
          }
          if (stillWanted != null && !stillWanted()) return false;
          final tokens = await engine.loadKvState(file.path);
          if (tokens <= 0) {
            // refused (another llama.cpp build, damage): it will never load, so it goes
            database.deleteAsset(row.id);
            await _delete(file);
            return false;
          }
          database.touchAsset(row.id);
          return true;
        } catch (e) {
          debugPrint('could not read the KV cache: $e');
          return false;
        }
      });

  /// Removes every saved cache (the settings screen's button, or the feature being turned off).
  Future<void> clear() => _serialize(() async {
        for (final asset in database.kvAssets()) {
          database.deleteAsset(asset.id);
          await _delete(_file(asset.relPath));
        }
        await _sweep(const {});
      });

  /// Keeps the total under [limit] (the one used longest ago first), drops rows whose file is
  /// gone, and deletes files no row knows (a crash between the rename and the row).
  Future<void> _enforce(int limit) async {
    var total = 0;
    final known = <String>{};
    final live = <AssetRow>[];
    for (final asset in database.kvAssets()) {
      if (await _file(asset.relPath).exists()) {
        live.add(asset);
        total += asset.byteSize;
      } else {
        database.deleteAsset(asset.id);
      }
    }
    for (final asset in live) {
      // oldest first; the one just saved is the newest, so it goes last
      if (total > limit) {
        database.deleteAsset(asset.id);
        await _delete(_file(asset.relPath));
        total -= asset.byteSize;
      } else {
        known.add(asset.relPath);
      }
    }
    await _sweep(known);
  }

  Future<void> _sweep(Set<String> knownRelPaths) async {
    final dir = Directory('${database.supportDirectory.path}${Platform.pathSeparator}$folder');
    if (!await dir.exists()) return;
    final names = {for (final rel in knownRelPaths) rel.split('/').last};
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      if (!names.contains(entity.uri.pathSegments.last)) await _delete(entity);
    }
  }

  Future<void> _delete(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // a file that cannot be removed now is swept the next time
    }
  }
}
