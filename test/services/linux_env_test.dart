import 'dart:io';
import 'dart:typed_data';

import 'package:arce_ai/services/file_downloader.dart';
import 'package:arce_ai/services/linux_env.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stands in for the Android side: answers like `LinuxEnv.kt` and records what it was asked.
class FakeBridge extends LinuxBridge {
  FakeBridge();

  var installed = false;
  var workspaceBytes = 0;
  final calls = <String>[];
  Object? failInstall;
  Map<Object?, Object?> runAnswer = const {'exit': 0, 'stdout': 'ok\n', 'stderr': '', 'elapsedMs': 1500};
  Map<String, Object?>? lastInstall;
  Map<String, Object?>? lastRun;

  @override
  Future<Map<Object?, Object?>> status({required int workspaceLimitBytes}) async {
    calls.add('status');
    return {
      'prootPresent': true,
      'installed': installed,
      'rootfs': installed ? '{"archive":"x"}' : null,
      'workspaceBytes': workspaceBytes,
      'workspaceLimitBytes': workspaceLimitBytes,
    };
  }

  @override
  Future<Map<Object?, Object?>> install({
    required String path,
    required String sha256,
    required List<String> dns,
    required int maxBytes,
  }) async {
    calls.add('install');
    lastInstall = {'path': path, 'sha256': sha256, 'dns': dns, 'maxBytes': maxBytes};
    if (failInstall != null) throw failInstall!;
    installed = true;
    return const {};
  }

  @override
  Future<Map<Object?, Object?>> run({
    required String command,
    required String cwd,
    required int timeoutSeconds,
    required int maxOutputChars,
    required int workspaceLimitBytes,
    required bool noSeccomp,
    Map<String, String> secrets = const {},
  }) async {
    calls.add('run');
    lastRun = {
      'command': command,
      'cwd': cwd,
      'timeoutSeconds': timeoutSeconds,
      'maxOutputChars': maxOutputChars,
      'workspaceLimitBytes': workspaceLimitBytes,
      'noSeccomp': noSeccomp,
      'secrets': secrets,
    };
    return runAnswer;
  }

  // ---- sessions: scripted. Each read answers with the next piece of output in [sessionOutput].
  final sessionOutput = <List<int>>[];
  var sessionAlive = true;
  int? sessionExit;
  String? sessionStoppedBy;
  var sessionLost = false;
  var sessionNext = 0;
  final sessionStarts = <Map<String, Object?>>[];
  final sessionReads = <Map<String, Object?>>[];
  final sessionWrites = <List<int>>[];

  @override
  Future<Map<Object?, Object?>> sessionStart({
    required String command,
    required String cwd,
    required int cols,
    required int rows,
    required int maxSessions,
    required int idleSeconds,
    required int bufferKb,
    required int workspaceLimitBytes,
    required bool noSeccomp,
    Map<String, String> secrets = const {},
  }) async {
    calls.add('sessionStart');
    sessionStarts.add({
      'command': command,
      'cwd': cwd,
      'cols': cols,
      'rows': rows,
      'maxSessions': maxSessions,
      'idleSeconds': idleSeconds,
      'bufferKb': bufferKb,
      'secrets': secrets,
    });
    return {'id': 's${sessionStarts.length}'};
  }

  @override
  Future<Map<Object?, Object?>> sessionRead(String id, {required int from, required int waitMs, int settleMs = 300}) async {
    calls.add('sessionRead');
    sessionReads.add({'id': id, 'from': from, 'waitMs': waitMs});
    final data = sessionOutput.isEmpty ? <int>[] : sessionOutput.removeAt(0);
    sessionNext = from + data.length;
    return {
      'data': Uint8List.fromList(data),
      'next': sessionNext,
      'lost': sessionLost,
      'alive': sessionAlive,
      'exit': sessionExit,
      'stoppedBy': sessionStoppedBy,
    };
  }

  @override
  Future<void> sessionWrite(String id, Uint8List data) async {
    calls.add('sessionWrite');
    sessionWrites.add(data.toList());
  }

  @override
  Future<void> sessionStop(String id) async {
    calls.add('sessionStop');
    sessionAlive = false;
    sessionStoppedBy = 'stopped';
  }

  @override
  Future<List<Map<Object?, Object?>>> sessionList() async => [
        for (var i = 1; i <= sessionStarts.length; i++) {'id': 's$i', 'alive': sessionAlive},
      ];

  @override
  Future<void> remove() async {
    calls.add('remove');
    installed = false;
  }

  @override
  Future<void> clearWorkspace() async {
    calls.add('clear');
    workspaceBytes = 0;
  }
}

void main() {
  late Directory dir;
  late File archive;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('linux_env_test');
    archive = File('${dir.path}${Platform.pathSeparator}rootfs.tar.gz')..writeAsStringSync('not really a tar');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  LinuxConfig config({String sha = '', List<String> dns = const ['1.1.1.1', ' ', '8.8.8.8'], int limitMb = 2048, bool compat = false}) => LinuxConfig(
        rootfsUrl: 'https://example.test/rootfs.tar.gz',
        rootfsSha256: sha,
        dns: dns,
        workspaceLimitMb: limitMb,
        compatMode: compat,
      );

  LinuxEnvironment make(FakeBridge bridge, {List<int>? progress}) => LinuxEnvironment(
        bridge: bridge,
        android: true,
        download: (url, {required connections, onProgress}) async {
          onProgress?.call(50, 100);
          progress?.add(50);
          onProgress?.call(100, 100);
          return archive;
        },
      );

  test('the workspace limit is in MB in the settings and in bytes on the way (0 = no limit)', () {
    expect(config(limitMb: 2048).workspaceLimitBytes, 2048 * 1024 * 1024);
    expect(config(limitMb: 0).workspaceLimitBytes, 0);
    expect(config().dnsServers, ['1.1.1.1', '8.8.8.8'], reason: 'blank entries are dropped');
  });

  test('not Android: nothing is asked of the other side, and nothing can be installed', () async {
    final bridge = FakeBridge();
    final env = LinuxEnvironment(bridge: bridge, android: false);
    final status = await env.refresh(config());
    expect(status.installed, isFalse);
    expect(env.ready, isFalse);
    expect(bridge.calls, isEmpty);
    expect(() => env.install(config()), throwsUnsupportedError);
  });

  test('refresh reads the folder; install downloads, checks, unpacks with no byte limit, and is ready', () async {
    final bridge = FakeBridge();
    final env = make(bridge);
    expect((await env.refresh(config())).installed, isFalse);
    expect(env.state, LinuxState.absent);

    final seen = <LinuxState>[];
    // the state while the Android side unpacks is "unpacking"
    final sha = await FileDownloader.sha256Of(archive);
    final done = env.install(config(sha: sha.toUpperCase()));
    seen.add(env.state);
    await done;
    expect(seen.single, LinuxState.downloading);
    expect(env.state, LinuxState.ready);
    expect(env.ready, isTrue);
    expect(bridge.lastInstall!['maxBytes'], 0, reason: '0 is "no limit" on the Android side (LinuxEnv.install)');
    expect(bridge.lastInstall!['dns'], ['1.1.1.1', '8.8.8.8']);
    expect(await archive.exists(), isFalse, reason: 'the downloaded archive is a one-off');
  });

  test('a SHA-256 that is not the one in the settings stops before anything is unpacked', () async {
    archive.writeAsStringSync('something else');
    final bridge = FakeBridge();
    final env = make(bridge);
    await expectLater(env.install(config(sha: '00' * 32)), throwsA(isA<StateError>()));
    expect(env.state, LinuxState.failed);
    expect(env.message, contains('SHA-256'));
    expect(bridge.calls, isNot(contains('install')));
    expect(await archive.exists(), isFalse);
  });

  test('a failure on the Android side is kept as the reason, and the state is failed', () async {
    final bridge = FakeBridge()..failInstall = StateError('the archive is damaged');
    final env = make(bridge);
    await expectLater(env.install(config()), throwsA(isA<StateError>()));
    expect(env.state, LinuxState.failed);
    expect(env.message, contains('damaged'));
    // the next refresh follows the folder again; the reason stays to be read
    final status = await env.refresh(config());
    expect(status.installed, isFalse);
    expect(env.state, LinuxState.absent);
    expect(env.message, contains('damaged'));
  });

  test('a command goes to the Android side with the settings, and the model reads exit, output and the workspace', () async {
    final bridge = FakeBridge()
      ..installed = true
      ..workspaceBytes = 5 * 1000 * 1000;
    final env = make(bridge);
    await env.refresh(config());
    final outcome = await env.run(
      config: config(limitMb: 100, compat: true),
      command: 'echo ok',
      cwd: '/workspace',
      timeoutSeconds: 30,
      maxOutputChars: 4000,
    );
    expect(bridge.lastRun, {
      'command': 'echo ok',
      'cwd': '/workspace',
      'timeoutSeconds': 30,
      'maxOutputChars': 4000,
      'workspaceLimitBytes': 100 * 1024 * 1024,
      'noSeccomp': true,
      'secrets': <String, String>{},
    });
    expect(outcome.ok, isTrue);
    expect(outcome.describe(), allOf(contains('exit: 0'), contains('stdout:\nok'), contains('所要: 1.5秒')));
  });

  test('a command is refused until the environment is ready', () async {
    final env = make(FakeBridge());
    await expectLater(
      env.run(config: config(), command: 'ls', cwd: '/workspace', timeoutSeconds: 5, maxOutputChars: 100),
      throwsA(isA<StateError>()),
    );
  });

  test('what the model reads says why a command was stopped, and what was cut', () {
    const base = {'exit': -1, 'stdout': 'a', 'stderr': 'b', 'truncated': true, 'elapsedMs': 2000, 'workspaceBytes': 3000000000, 'workspaceLimitBytes': 2147483648};
    final quota = ShellOutcome.fromMap({...base, 'killedBy': 'workspace'}).describe();
    expect(quota, allOf(contains('上限（2.1 GB）を超えた'), contains('いまは 3.0 GB'), contains('stderr:\nb'), contains('初めと終わりだけ')));
    expect(ShellOutcome.fromMap({...base, 'killedBy': 'timeout'}).describe(), contains('時間の上限を過ぎた'));
    final silent = ShellOutcome.fromMap({'exit': 0, 'stdout': '', 'stderr': '  ', 'elapsedMs': 10}).describe();
    expect(silent, contains('（出力はありません）'));
  });

  test('remove and clearWorkspace go through, and the state follows', () async {
    final bridge = FakeBridge()
      ..installed = true
      ..workspaceBytes = 123456;
    final env = make(bridge);
    await env.refresh(config());
    expect(env.ready, isTrue);
    final cleared = await env.clearWorkspace(config());
    expect(cleared.workspaceBytes, 0);
    expect(env.ready, isTrue, reason: 'the system stays');
    await env.remove();
    expect(env.state, LinuxState.absent);
    expect(bridge.calls, containsAllInOrder(['status', 'clear', 'status', 'remove']));
  });

  test('sizes are written the way a phone writes storage', () {
    expect(formatBytes(999), '999 B');
    expect(formatBytes(1500), '1.5 KB');
    expect(formatBytes(2147483648), '2.1 GB');
    expect(formatBytes(30000000), '30 MB');
  });
}
