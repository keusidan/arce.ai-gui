import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:arce_ai/core/releases.dart';
import 'package:arce_ai/services/bspatch.dart';
import 'package:arce_ai/services/settings.dart';
import 'package:arce_ai/services/update_service.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'bsdiff_fixture.dart';

/// The name the release workflow gives the asset of this platform,
/// e.g. `ARCE.AI-v0.5.0-linux-x64.tar.gz`.
String assetName() => 'ARCE.AI-v0.5.0-${UpdateService.target?.suffix.substring(1) ?? 'linux-x64.tar.gz'}';

/// A GitHub that serves one release, and a storage that honours a range request, ignores it, or
/// stops in the middle of the stream (as a dropped connection does).
class FakeGitHub {
  FakeGitHub({
    required this.payload,
    required this.checksum,
    this.honourRange = true,
    this.cutOff = false,
    this.dropFirst = 0,
    this.stallFirst = 0,
    this.patch,
  });

  /// The bsdiff patch from 0.4.0 that the release offers next to the APK, when given.
  final List<int>? patch;

  /// How many times the storage was asked for the patch.
  int patchRequests = 0;

  final List<int> payload;
  final String checksum;

  /// Answer a range request with `206` and the rest of the file.
  final bool honourRange;

  /// Stop the stream halfway through.
  final bool cutOff;

  /// Cut the stream of the first this-many downloads halfway through, then behave.
  final int dropFirst;

  /// Make the first this-many downloads go silent halfway through (a frozen connection).
  final int stallFirst;

  /// Every `Range` header the storage received, in order.
  final List<String?> ranges = [];

  MockClient client() => MockClient.streaming((request, body) async {
        final url = request.url.toString();
        http.StreamedResponse reply(int code, Stream<List<int>> bytes, [Map<String, String> headers = const {}]) =>
            http.StreamedResponse(bytes, code, headers: headers, request: request);

        if (url.contains('/releases?')) {
          final prefix = UpdateService.target?.tagPrefix ?? '';
          return reply(
            200,
            Stream.value(utf8.encode(jsonEncode([
              {
                'tag_name': '${prefix}v0.5.0',
                'body': '',
                'assets': [
                  {'id': 11, 'name': assetName(), 'size': payload.length},
                  {'id': 12, 'name': '${assetName()}.sha256', 'size': 90},
                  if (patch != null) {'id': 13, 'name': '${assetName()}.from-0.4.0.patch', 'size': patch!.length},
                ],
              },
            ]))),
          );
        }
        if (url.contains('/releases/assets/')) {
          return reply(302, const Stream.empty(), {'location': 'https://storage.example/${url.split('/').last}'});
        }
        if (url.startsWith('https://storage.example/')) {
          if (url.endsWith('/12')) return reply(200, Stream.value(utf8.encode('$checksum  ${assetName()}\n')));
          if (url.endsWith('/13')) {
            patchRequests++;
            return reply(200, Stream.value(patch!));
          }

          final range = request.headers['Range'];
          ranges.add(range);
          final attempt = ranges.length;
          final from = range == null || !honourRange ? 0 : int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
          final Stream<List<int>> bytes;
          if (cutOff || attempt <= dropFirst) {
            bytes = _half(from, then: () => throw const SocketException('connection lost'));
          } else if (attempt <= dropFirst + stallFirst) {
            // a controller, not a generator: cancelling a generator that waits forever never returns
            final silent = StreamController<List<int>>()..add(_firstHalf(from));
            bytes = silent.stream;
          } else {
            bytes = Stream.value(payload.sublist(from));
          }
          return reply(from > 0 || (range != null && honourRange) ? 206 : 200, bytes);
        }
        return reply(404, const Stream.empty());
      });

  List<int> _firstHalf(int from) {
    final rest = payload.sublist(from);
    return rest.sublist(0, rest.length ~/ 2);
  }

  /// The first half of what is asked for, then [then] (an error).
  Stream<List<int>> _half(int from, {required void Function() then}) async* {
    yield _firstHalf(from);
    then();
  }
}

Future<(UpdateService, Directory)> serviceFor(
  MockClient client, {
  String current = '0.4.0',
  Future<String?> Function()? baseApk,
  bool delta = true,
}) async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsStore(await SharedPreferences.getInstance());
  await settings.setGithubToken('secret');
  if (!delta) await settings.update((s) => s.copyWith(updateUseDelta: false));
  final dir = await Directory.systemTemp.createTemp('arce_update_resume');
  addTearDown(() => dir.delete(recursive: true));
  final service = UpdateService(
    settings,
    client: client,
    cacheDirectory: () async => dir,
    currentVersion: Version.parse(current),
    retryDelay: Duration.zero,
    stallTimeoutOverride: const Duration(milliseconds: 200),
    baseApkOverride: baseApk,
  );
  addTearDown(service.dispose);
  return (service, dir);
}

void main() {
  // large enough that the part file is written in more than one chunk
  final payload = List<int>.generate(40000, (i) => i % 256);
  final good = sha256.convert(payload).toString();
  final canDownload = UpdateService.target != null && UpdateService.target != UpdateTarget.ios;

  Directory updates(Directory root) => Directory('${root.path}${Platform.pathSeparator}updates');

  File partFile(Directory root) =>
      File('${updates(root).path}${Platform.pathSeparator}${assetName()}.part');

  test('ダウンロードが途中で切れても、途中までのファイルを残す', () async {
    final github = FakeGitHub(payload: payload, checksum: good, cutOff: true);
    final (service, dir) = await serviceFor(github.client());

    await service.check();
    await service.download();

    expect(service.state, isA<UpdateFailed>());
    expect(await partFile(dir).exists(), isTrue, reason: 'the next attempt resumes from here');
    final kept = await partFile(dir).length();
    expect(kept, greaterThan(0));
    expect(kept, lessThan(payload.length));
  }, skip: canDownload ? false : 'this platform has no update files');

  test('通信が切れても、続きから自動で取り直して最後まで届ける', () async {
    final github = FakeGitHub(payload: payload, checksum: good, dropFirst: 2);
    final (service, dir) = await serviceFor(github.client());

    await service.check();
    await service.download();

    final ready = service.state as UpdateReady;
    expect(await ready.file.readAsBytes(), payload);
    expect(github.ranges, [null, 'bytes=20000-', 'bytes=30000-'], reason: 'each try continues where the last one stopped');
    expect(await partFile(dir).exists(), isFalse);
  }, skip: canDownload ? false : 'this platform has no update files');

  test('無言になった接続は止まったものとして扱い、続きから取り直す', () async {
    final github = FakeGitHub(payload: payload, checksum: good, stallFirst: 1);
    final (service, _) = await serviceFor(github.client());

    await service.check();
    await service.download();

    final ready = service.state as UpdateReady;
    expect(await ready.file.readAsBytes(), payload);
    expect(github.ranges, [null, 'bytes=20000-']);
  }, skip: canDownload ? false : 'this platform has no update files');

  test('大きなファイルは、複数の接続に分けて取り、同じ中身になる', () async {
    final big = List<int>.generate(9 * 1024 * 1024, (i) => (i * 7 + i ~/ 1000) & 0xff);
    final github = FakeGitHub(payload: big, checksum: sha256.convert(big).toString());
    final (service, dir) = await serviceFor(github.client());

    await service.check();
    await service.download();

    final ready = service.state as UpdateReady;
    expect(await ready.file.readAsBytes(), big);
    expect(github.ranges, hasLength(2), reason: '9 MB is cut into two parts of at least 4 MB');
    expect(github.ranges.every((r) => r != null), isTrue);
    expect(await partFile(dir).exists(), isFalse);
  }, skip: canDownload ? false : 'this platform has no update files');

  group('差分だけのダウンロード', () {
    final base = bsdiffOld;
    final built = BsPatch.apply(base, bsdiffPatch);

    Future<File> baseFile() async {
      final dir = await Directory.systemTemp.createTemp('arce_base');
      addTearDown(() => dir.delete(recursive: true));
      return File('${dir.path}/base.apk')..writeAsBytesSync(base);
    }

    test('差分から新しいファイルを組み立て、全体は取らない', () async {
      final github = FakeGitHub(payload: built, checksum: bsdiffNewSha256, patch: bsdiffPatch);
      final installed = await baseFile();
      final (service, dir) = await serviceFor(github.client(), baseApk: () async => installed.path);

      await service.check();
      await service.download();

      final ready = service.state as UpdateReady;
      expect(await ready.file.readAsBytes(), built);
      expect(github.patchRequests, 1);
      expect(github.ranges, isEmpty, reason: 'the whole file was never asked for');
      expect(await Directory(updates(dir).path).list().map((e) => e.uri.pathSegments.last).toList(), [assetName()],
          reason: 'the patch and the work files are removed');
    }, skip: canDownload ? false : 'this platform has no update files');

    test('土台のファイルが違えば、全体を取り直す', () async {
      final github = FakeGitHub(payload: built, checksum: bsdiffNewSha256, patch: bsdiffPatch);
      final installed = await baseFile();
      installed.writeAsBytesSync(Uint8List.fromList(base)..[10] ^= 0xff);
      final (service, _) = await serviceFor(github.client(), baseApk: () async => installed.path);

      await service.check();
      await service.download();

      final ready = service.state as UpdateReady;
      expect(await ready.file.readAsBytes(), built);
      expect(github.patchRequests, 1);
      expect(github.ranges, hasLength(1), reason: 'the whole file was downloaded after the check failed');
    }, skip: canDownload ? false : 'this platform has no update files');

    test('差分が無いか、土台が分からないときは、全体を取る', () async {
      final noPatch = FakeGitHub(payload: built, checksum: bsdiffNewSha256);
      final installed = await baseFile();
      final (a, _) = await serviceFor(noPatch.client(), baseApk: () async => installed.path);
      await a.check();
      await a.download();
      expect((a.state as UpdateReady).file.readAsBytesSync(), built);
      expect(noPatch.patchRequests, 0);

      final github = FakeGitHub(payload: built, checksum: bsdiffNewSha256, patch: bsdiffPatch);
      final (b, _) = await serviceFor(github.client(), baseApk: () async => null);
      await b.check();
      await b.download();
      expect((b.state as UpdateReady).file.readAsBytesSync(), built);
      expect(github.patchRequests, 0, reason: 'without the installed file the patch is not even downloaded');
    }, skip: canDownload ? false : 'this platform has no update files');

    test('設定で差分をオフにすると、全体を取る', () async {
      final github = FakeGitHub(payload: built, checksum: bsdiffNewSha256, patch: bsdiffPatch);
      final installed = await baseFile();
      final (service, _) = await serviceFor(github.client(), baseApk: () async => installed.path, delta: false);

      await service.check();
      await service.download();

      expect((service.state as UpdateReady).file.readAsBytesSync(), built);
      expect(github.patchRequests, 0);
    }, skip: canDownload ? false : 'this platform has no update files');
  });

  test('切れ続けるときは、決めた回数で諦めて理由を出す', () async {
    final github = FakeGitHub(payload: payload, checksum: good, cutOff: true);
    final (service, _) = await serviceFor(github.client());

    await service.check();
    await service.download();

    expect(github.ranges, hasLength(service.maxAttempts));
    expect((service.state as UpdateFailed).reason, contains('通信が途切れました'));
  }, skip: canDownload ? false : 'this platform has no update files');

  test('残っていた分は Range で続きだけを取り、全体の SHA-256 で検証する', () async {
    final github = FakeGitHub(payload: payload, checksum: good);
    final (service, dir) = await serviceFor(github.client());
    await updates(dir).create(recursive: true);
    await partFile(dir).writeAsBytes(payload.sublist(0, 10000));

    await service.check();
    await service.download();

    final ready = service.state as UpdateReady;
    expect(await ready.file.readAsBytes(), payload);
    expect(github.ranges, ['bytes=10000-'], reason: 'only the rest is asked for');
    expect(await partFile(dir).exists(), isFalse, reason: 'the part file becomes the real one');
  }, skip: canDownload ? false : 'this platform has no update files');

  test('サーバーが Range を無視したら、最初から取り直す', () async {
    final github = FakeGitHub(payload: payload, checksum: good, honourRange: false);
    final (service, dir) = await serviceFor(github.client());
    await updates(dir).create(recursive: true);
    await partFile(dir).writeAsBytes(payload.sublist(0, 10000));

    await service.check();
    await service.download();

    final ready = service.state as UpdateReady;
    expect(await ready.file.readAsBytes(), payload, reason: 'the partial bytes must not be kept twice');
    expect(github.ranges, ['bytes=10000-', null]);
  }, skip: canDownload ? false : 'this platform has no update files');

  test('壊れた途中ファイルは捨てて取り直す', () async {
    final github = FakeGitHub(payload: payload, checksum: good);
    final (service, dir) = await serviceFor(github.client());
    await updates(dir).create(recursive: true);
    // longer than the asset, so it cannot be a prefix of this file
    await partFile(dir).writeAsBytes(List.filled(payload.length + 100, 7));

    await service.check();
    await service.download();

    final ready = service.state as UpdateReady;
    expect(await ready.file.readAsBytes(), payload);
    expect(github.ranges, [null], reason: 'it is a fresh download, not a range request');
  }, skip: canDownload ? false : 'this platform has no update files');

  test('更新後は、いま動いている版のダウンロードを消す', () async {
    final (service, dir) = await serviceFor(
      FakeGitHub(payload: payload, checksum: good).client(),
      current: '0.4.0',
    );
    await updates(dir).create(recursive: true);
    final old = File('${updates(dir).path}${Platform.pathSeparator}ARCE.AI-v0.3.0-old.apk');
    final installed = File('${updates(dir).path}${Platform.pathSeparator}ARCE.AI-v0.4.0-current.apk');
    final next = File('${updates(dir).path}${Platform.pathSeparator}ARCE.AI-v0.5.0-next.apk.part');
    for (final f in [old, installed, next]) {
      await f.writeAsBytes(const [1, 2, 3]);
    }

    await service.removeOldDownloads();

    expect(await old.exists(), isFalse);
    expect(await installed.exists(), isFalse, reason: 'this version is the one now running');
    expect(await next.exists(), isTrue, reason: 'a download that can still be resumed is kept');
  });
}
