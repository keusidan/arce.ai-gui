import 'dart:io';

import 'package:arce_ai/core/engine.dart';
import 'package:arce_ai/data/llm_db.dart';
import 'package:arce_ai/services/conversation_database.dart';
import 'package:arce_ai/services/kv_snapshots.dart';
import 'package:flutter_test/flutter_test.dart';

/// An engine that "saves" a file of a chosen size and records what it was asked.
class FakeKvEngine implements KvStatePersistence {
  int size = 1000;
  int restoredTokens = 800;
  bool refuse = false;
  final saves = <({String path, int minTokens})>[];
  final loads = <String>[];

  @override
  Future<int> saveKvState(String path, {required int minTokens}) async {
    saves.add((path: path, minTokens: minTokens));
    if (refuse) return 0;
    await File(path).writeAsBytes(List.filled(size, 7));
    return size;
  }

  @override
  Future<int> loadKvState(String path) async {
    loads.add(path);
    return restoredTokens;
  }
}

void main() {
  late Directory dir;
  late ConversationDatabase database;
  late FakeKvEngine engine;
  late KvSnapshotConfig config;
  late KvSnapshotService service;
  const fp = 'aaaaaaaaaaaa';

  /// A conversation row, so an asset may point at it.
  String conversation() => database.store.save(null, {
        'messages': [
          {'id': 0, 'role': 'user', 'text': 'こんにちは', 'thinking': '', 'question': null, 'finish': null, 'activities': const [], 'agent': null, 'attachments': const [], 'time': 1700000000000},
        ],
        'history': [
          {'type': 'user', 'text': 'こんにちは', 'toolCallJson': null},
        ],
        'nextId': 1,
      }, generating: false, providerId: 'local', modelId: '');

  File fileOf(String relPath) => File('${dir.path}/$relPath');

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('arce_kv_test');
    database = await ConversationDatabase.open(supportDirectory: dir);
    engine = FakeKvEngine();
    config = const KvSnapshotConfig(enabled: true, maxBytes: 10000, minTokens: 300);
    service = KvSnapshotService(database: database, engine: engine, config: () => config);
  });

  tearDown(() async {
    database.close();
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // the system cleans the temp folder
    }
  });

  test('保存すると kv/ にファイルができ、索引は assets の1行になる', () async {
    final id = conversation();
    expect(await service.save(id, fp), isTrue);

    final rel = KvSnapshotService.relPath(id, fp);
    expect(await fileOf(rel).length(), 1000);
    final rows = database.kvAssets();
    expect(rows, hasLength(1));
    expect(rows.single.relPath, rel);
    expect(rows.single.byteSize, 1000);
    expect(rows.single.mime, LlmDatabase.kvMime);
    expect(rows.single.conversationId, id);
    expect(engine.saves.single.minTokens, 300, reason: 'the limit is passed to the engine');
    expect(await Directory('${dir.path}/kv').list().toList(), hasLength(1), reason: 'no .tmp is left behind');
  });

  test('オフのとき・短いとき・保存できなかったときは、何も作らない', () async {
    final id = conversation();
    config = const KvSnapshotConfig(enabled: false);
    expect(await service.save(id, fp), isFalse);
    expect(engine.saves, isEmpty, reason: 'off: the engine is not even asked');

    config = const KvSnapshotConfig(enabled: true, maxBytes: 10000, minTokens: 300);
    engine.refuse = true; // too short, or a model whose state cannot be kept
    expect(await service.save(id, fp), isFalse);
    expect(database.kvAssets(), isEmpty);
    expect(await Directory('${dir.path}/kv').list().toList(), isEmpty);
  });

  test('1つの会話には1つだけ。保存し直すと古いもの（別の指紋も）は消える', () async {
    final id = conversation();
    await service.save(id, 'oldfingerprt');
    await service.save(id, fp);

    expect([for (final a in database.kvAssets()) a.relPath], [KvSnapshotService.relPath(id, fp)]);
    expect(fileOf(KvSnapshotService.relPath(id, 'oldfingerprt')).existsSync(), isFalse);
  });

  test('合計が上限を超えたら、いちばん長く使っていないものから消す', () async {
    final a = conversation();
    final b = conversation();
    final c = conversation();
    engine.size = 4000;
    await service.save(a, fp);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await service.save(b, fp);
    // a is used again: b is now the one used longest ago
    database.touchAsset(database.kvAssets().firstWhere((x) => x.conversationId == a).id);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await service.save(c, fp); // 12000 > 10000

    final kept = {for (final x in database.kvAssets()) x.conversationId};
    expect(kept, {a, c});
    expect(fileOf(KvSnapshotService.relPath(b, fp)).existsSync(), isFalse, reason: 'the file goes with the row');
    expect(service.totalBytes, 8000);
  });

  test('1つで上限を超えるものは保存しない', () async {
    final id = conversation();
    engine.size = 20000;
    expect(await service.save(id, fp), isFalse);
    expect(database.kvAssets(), isEmpty);
    expect(await Directory('${dir.path}/kv').list().toList(), isEmpty);
  });

  test('復元：指紋が合うものだけをエンジンに渡す', () async {
    final id = conversation();
    await service.save(id, fp);

    expect(await service.restore(id, 'bbbbbbbbbbbb'), isFalse, reason: 'another model or setup');
    expect(engine.loads, isEmpty, reason: 'the engine is never given a file made for something else');

    expect(await service.restore(id, fp), isTrue);
    expect(engine.loads.single, endsWith('$id.$fp.kv'));
  });

  test('復元すると「最後に使った時刻」が新しくなる（上限で消えにくくなる）', () async {
    final id = conversation();
    await service.save(id, fp);
    final before = database.kvAssets().single.createdAt;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await service.restore(id, fp);
    expect(database.kvAssets().single.createdAt, greaterThan(before));
  });

  test('エンジンが拒んだ・壊れたファイルは、二度と読まないように消す', () async {
    final id = conversation();
    await service.save(id, fp);
    engine.restoredTokens = 0; // llama.cpp refused the file
    expect(await service.restore(id, fp), isFalse);
    expect(database.kvAssets(), isEmpty);
    expect(fileOf(KvSnapshotService.relPath(id, fp)).existsSync(), isFalse);

    // a file whose size is not what was recorded (cut short, or replaced) is not loaded at all
    engine.restoredTokens = 800;
    await service.save(id, fp);
    await fileOf(KvSnapshotService.relPath(id, fp)).writeAsBytes([1, 2, 3]);
    engine.loads.clear();
    expect(await service.restore(id, fp), isFalse);
    expect(engine.loads, isEmpty);
    expect(database.kvAssets(), isEmpty);
  });

  test('復元の直前に「もう要らない」と分かったら、エンジンには触らない', () async {
    final id = conversation();
    await service.save(id, fp);
    expect(await service.restore(id, fp, stillWanted: () => false), isFalse);
    expect(engine.loads, isEmpty);
    expect(database.kvAssets(), hasLength(1), reason: 'the cache itself is still good');
  });

  test('会話を消すと、キャッシュの行もファイルも消える', () async {
    final id = conversation();
    await service.save(id, fp);
    await database.delete(id);
    expect(database.kvAssets(), isEmpty);
    expect(fileOf(KvSnapshotService.relPath(id, fp)).existsSync(), isFalse);
  });

  test('行のないファイルと、ファイルのない行は片付ける', () async {
    final id = conversation();
    await service.save(id, fp);
    await File('${dir.path}/kv/stray.kv').writeAsBytes([1]);
    await File('${dir.path}/kv/half.kv.tmp').writeAsBytes([1]);
    final other = conversation();
    await service.save(other, fp);
    await fileOf(KvSnapshotService.relPath(id, fp)).delete(); // a row whose file is gone

    final third = conversation();
    await service.save(third, fp); // any save sweeps

    expect({for (final x in database.kvAssets()) x.conversationId}, {other, third});
    final names = [for (final f in await Directory('${dir.path}/kv').list().toList()) f.uri.pathSegments.last];
    expect(names, hasLength(2));
    expect(names, isNot(contains('stray.kv')));
  });

  test('すべて削除', () async {
    await service.save(conversation(), fp);
    await service.save(conversation(), fp);
    await service.clear();
    expect(database.kvAssets(), isEmpty);
    expect(await Directory('${dir.path}/kv').list().toList(), isEmpty);
  });

  test('指紋は、モデル・文脈の長さ・KVの型・アプリの版のどれが違っても変わる', () {
    String f({String model = 'm.gguf', int bytes = 100, int ctx = 4096, KvCacheType kv = KvCacheType.f16, String app = '0.8.1'}) =>
        KvSnapshotService.fingerprint(modelName: model, modelBytes: bytes, contextLength: ctx, kvCache: kv, appVersion: app);
    final base = f();
    expect(f(), base, reason: 'the same setup, the same fingerprint');
    expect({base, f(model: 'n.gguf'), f(bytes: 101), f(ctx: 8192), f(kv: KvCacheType.q8_0), f(app: '0.9.0')}, hasLength(6));
    expect(base, hasLength(12));
  });
}
