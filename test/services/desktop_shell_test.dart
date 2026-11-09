import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:arce_ai/services/desktop_shell.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// A program that prints [stdout] and ends with [exit].
class FakeProcess implements Process {
  FakeProcess({String stdout = '', String stderr = '', int exit = 0})
      : _out = Stream.value(utf8.encode(stdout)),
        _err = Stream.value(utf8.encode(stderr)),
        _exit = Future.value(exit);

  final Stream<List<int>> _out;
  final Stream<List<int>> _err;
  final Future<int> _exit;

  @override
  Stream<List<int>> get stdout => _out;
  @override
  Stream<List<int>> get stderr => _err;
  @override
  Future<int> get exitCode => _exit;
  @override
  IOSink get stdin => IOSink(StreamController<List<int>>().sink);
  @override
  int get pid => 4242;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;
}

void main() {
  late Directory workspace;
  setUp(() => workspace = Directory.systemTemp.createTempSync('arce_desktop_ws'));
  tearDown(() {
    try {
      workspace.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows may hold a file a moment longer; the system cleans its temp folder
    }
  });

  group('in the container', () {
    test('it is made with the workspace at /workspace and nothing else of the PC, and without a network when off', () {
      final args = DesktopShell.createArguments(const DesktopShellSettings(), '/home/me/ws');
      expect(args, containsAllInOrder(['run', '-d', '--name', 'arce-workspace', '-v', '/home/me/ws:/workspace', '-w', '/workspace']));
      expect(args.where((a) => a == '-v'), hasLength(1), reason: 'one folder of the PC only');
      expect(args, isNot(contains('--network')));
      expect(args.sublist(args.length - 3), ['ubuntu:24.04', 'sleep', 'infinity']);
      expect(DesktopShell.createArguments(const DesktopShellSettings(network: false), '/w'), containsAllInOrder(['--network', 'none']));
    });

    test('a command names its secrets but never their values, and is stopped inside by timeout', () {
      final args = DesktopShell.execArguments(const DesktopShellSettings(), 'echo hi', '/workspace/app', 30, ['GH_TOKEN']);
      expect(args, containsAllInOrder(['exec', '-i', '-w', '/workspace/app', '-e', 'GH_TOKEN', 'arce-workspace', 'timeout', '-s', 'KILL', '30', 'sh', '-c', 'echo hi']));
    });

    test('the engine is found, the container is made the first time, and the value of a secret goes in the environment only', () async {
      final ran = <List<String>>[];
      final started = <(List<String>, Map<String, String>?)>[];
      final shell = DesktopShell(
        workspace: workspace,
        run: (exe, args) async {
          ran.add([exe, ...args]);
          if (exe == 'docker' && args.first == 'version') return ProcessResult(1, 0, '', '');
          if (args.first == 'container') return ProcessResult(1, 1, '', 'no such container');
          return ProcessResult(1, 0, 'id', '');
        },
        start: (exe, args, {workingDirectory, environment}) async {
          started.add(([exe, ...args], environment));
          return FakeProcess(stdout: 'hello\n');
        },
      );
      final outcome = await shell.run(
        settings: const DesktopShellSettings(),
        command: r'echo $GH_TOKEN',
        cwd: '/workspace',
        timeoutSeconds: 20,
        maxOutputChars: 1000,
        secrets: const {'GH_TOKEN': 'ghp_secret'},
      );
      expect(outcome.stdout, 'hello\n');
      expect(outcome.ok, isTrue);
      expect(ran.map((r) => r.take(2).join(' ')), containsAllInOrder(['docker version', 'docker container', 'docker run']));
      final (command, environment) = started.single;
      expect(command.first, 'docker');
      expect(command.join(' '), isNot(contains('ghp_secret')), reason: 'a value is never on a command line');
      expect(environment, {'GH_TOKEN': 'ghp_secret'});
      expect(Directory(p.join(workspace.path, 'home')).existsSync(), isTrue, reason: 'HOME is made in the workspace');
    });

    test('without Docker and Podman it says what to do', () async {
      final shell = DesktopShell(workspace: workspace, run: (exe, args) async => throw ProcessException(exe, args));
      await expectLater(
        shell.run(settings: const DesktopShellSettings(), command: 'ls', cwd: '', timeoutSeconds: 5, maxOutputChars: 100),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('Docker も Podman も'))),
      );
      expect(await shell.describe(const DesktopShellSettings()), contains('見つかりません'));
    });

    test('an engine that is installed but whose service does not answer is named as not running', () async {
      final shell = DesktopShell(workspace: workspace, run: (exe, args) async => ProcessResult(1, exe == 'docker' ? 1 : 0, '', 'cannot connect'), start: (exe, args, {workingDirectory, environment}) async => FakeProcess());
      expect(await shell.engine(const DesktopShellSettings(engine: 'docker')), isNull);
      expect(await shell.describe(const DesktopShellSettings(engine: 'docker')), contains('docker はありますが、動いていません'));
      expect(await shell.engine(const DesktopShellSettings()), 'podman', reason: 'auto takes the one that answers');
    });
  });

  group('on the PC', () {
    test('the folder: the workspace by default and for /workspace, a relative one inside it, an absolute one as it is', () {
      final shell = DesktopShell(workspace: workspace);
      expect(shell.hostFolder(''), workspace.path);
      expect(shell.hostFolder('/workspace'), workspace.path);
      expect(shell.hostFolder('/workspace/app'), p.join(workspace.path, 'app'));
      expect(shell.hostFolder('app'), p.join(workspace.path, 'app'));
      final absolute = p.join(Directory.systemTemp.path, 'x');
      expect(shell.hostFolder(absolute), absolute);
    });

    test('the program: PowerShell on Windows, bash or sh elsewhere, or the one the user set', () {
      final windows = DesktopShell(workspace: workspace, windows: true);
      expect(windows.hostInvocation(const DesktopShellSettings(), 'dir'), ['powershell.exe', '-NoProfile', '-NonInteractive', '-Command', 'dir']);
      final unix = DesktopShell(workspace: workspace, windows: false).hostInvocation(const DesktopShellSettings(), 'ls');
      expect(unix.sublist(1), ['-c', 'ls']);
      expect(unix.first, anyOf('/bin/bash', '/bin/sh'));
      expect(windows.hostInvocation(const DesktopShellSettings(hostShell: 'zsh -lc'), 'ls'), ['zsh', '-lc', 'ls']);
    });

    test('a real command runs in the workspace and its output comes back', () async {
      final shell = DesktopShell(workspace: workspace);
      final outcome = await shell.run(
        settings: const DesktopShellSettings(sandbox: false),
        command: 'echo hello',
        cwd: '',
        timeoutSeconds: 30,
        maxOutputChars: 1000,
      );
      expect(outcome.exit, 0, reason: outcome.stderr);
      expect(outcome.stdout.trim(), 'hello');
    });

    test('a secret reaches the command as a variable, and a command that runs too long is stopped', () async {
      final shell = DesktopShell(workspace: workspace);
      final secret = await shell.run(
        settings: const DesktopShellSettings(sandbox: false),
        command: r'echo "$ARCE_TEST_SECRET"',
        cwd: '',
        timeoutSeconds: 30,
        maxOutputChars: 1000,
        secrets: const {'ARCE_TEST_SECRET': 'value-1'},
      );
      expect(secret.stdout.trim(), 'value-1');
      final slow = await shell.run(
        settings: const DesktopShellSettings(sandbox: false),
        command: 'sleep 20',
        cwd: '',
        timeoutSeconds: 1,
        maxOutputChars: 1000,
      );
      expect(slow.killedBy, 'timeout');
      expect(slow.elapsedMs, lessThan(15000));
    }, skip: Platform.isWindows ? 'sh syntax' : false);
  });

  test('long output keeps its beginning and its end', () {
    final (text, cut) = DesktopShell.clip('a' * 100 + 'END', 30);
    expect(cut, isTrue);
    expect(text, startsWith('aaaa'));
    expect(text, endsWith('END'));
    expect(DesktopShell.clip('short', 30), ('short', false));
  });
}
