import 'dart:convert';

import 'package:arce_ai/services/shell_sessions.dart';
import 'package:flutter_test/flutter_test.dart';

import 'linux_env_test.dart' show FakeBridge;

List<int> bytes(String text) => utf8.encode(text);

void main() {
  late FakeBridge bridge;
  late ShellSessionManager manager;
  const settings = ShellSessionSettings(cols: 40, rows: 6, maxSessions: 2, idleMinutes: 10, waitMs: 1500, maxWaitMs: 5000, bufferKb: 64);

  setUp(() {
    bridge = FakeBridge();
    manager = ShellSessionManager(bridge: bridge);
  });

  Future<SessionView> start({String command = 'python3', Map<String, String> secrets = const {}, int? waitMs}) => manager.start(
        command: command,
        cwd: '/workspace',
        settings: settings,
        workspaceLimitBytes: 1000,
        noSeccomp: false,
        secrets: secrets,
        waitMs: waitMs,
      );

  group('keys', () {
    test('the names a model uses become the bytes a terminal sends', () {
      expect(TerminalKeys.bytesOf('Enter'), '\r');
      expect(TerminalKeys.bytesOf('ctrl-c'), '\x03');
      expect(TerminalKeys.bytesOf('Ctrl+D'), '\x04');
      expect(TerminalKeys.bytesOf('C-z'), '\x1a');
      expect(TerminalKeys.bytesOf('Up'), '\x1b[A');
      expect(TerminalKeys.bytesOf(' page down '), '\x1b[6~');
      expect(TerminalKeys.bytesOf('Esc'), '\x1b');
      expect(TerminalKeys.bytesOf('Hyper-Q'), isNull);
      expect(TerminalKeys.bytesOf(''), isNull);
    });

    test('typed text: a line break is the Enter key', () {
      expect(TerminalKeys.typed('print(1)\nprint(2)\r\n'), 'print(1)\rprint(2)\r');
    });
  });

  group('a session', () {
    test('starts with the settings, and answers with the screen the program drew', () async {
      bridge.sessionOutput.add(bytes('Python 3.12\r\n>>> '));
      final view = await start();
      expect(bridge.sessionStarts.single, containsPair('cols', 40));
      expect(bridge.sessionStarts.single, containsPair('idleSeconds', 600));
      expect(bridge.sessionStarts.single, containsPair('maxSessions', 2));
      expect(bridge.sessionStarts.single, containsPair('bufferKb', 64));
      expect(view.id, 's1');
      expect(view.screen, 'Python 3.12\n>>>');
      expect(view.alive, isTrue);
      final text = view.describe();
      expect(text, contains('session s1 · running · 40x6'));
      expect(text, contains('\$ python3'));
      expect(text, contains('--- screen ---\nPython 3.12\n>>>'));
    });

    test('what is typed and the keys go to the program, in that order, and the next read starts where the last stopped', () async {
      bridge.sessionOutput.add(bytes('>>> '));
      await start();
      bridge.sessionOutput.add(bytes('1+1\r\n2\r\n>>> '));
      final view = await manager.send('s1', text: '1+1\n', keys: ['Enter']);
      expect(utf8.decode(bridge.sessionWrites.single), '1+1\r\r');
      expect(bridge.sessionReads.last['from'], 4, reason: 'the 4 bytes of the first read are not read again');
      expect(view.screen, contains('2'));
      expect(bridge.sessionNext, 4 + bytes('1+1\r\n2\r\n>>> ').length);
    });

    test('a key that is not known is refused before anything is typed', () async {
      bridge.sessionOutput.add(bytes('x'));
      await start();
      await expectLater(manager.send('s1', text: 'a', keys: ['Hyper-Q']), throwsA(isA<ArgumentError>()));
      expect(bridge.sessionWrites, isEmpty);
    });

    test('a session that does not exist is said, with the ones that do', () async {
      await expectLater(manager.read('s9'), throwsA(isA<StateError>().having((e) => e.message, 'message', contains('none'))));
      bridge.sessionOutput.add(bytes('x'));
      await start();
      await expectLater(manager.read('s9'), throwsA(isA<StateError>().having((e) => e.message, 'message', contains('s1'))));
    });

    test('lines that scrolled off are handed out once', () async {
      bridge.sessionOutput.add(bytes(List.generate(10, (i) => 'line$i').join('\r\n')));
      final first = await start();
      expect(first.scrolled, ['line0', 'line1', 'line2', 'line3']);
      expect(first.screen, 'line4\nline5\nline6\nline7\nline8\nline9');
      expect(first.describe(), contains('scrolled off the screen (4 lines)'));
      bridge.sessionOutput.add(bytes('\r\nline10'));
      final second = await manager.read('s1');
      expect(second.scrolled, ['line4']);
    });

    test('the wait is what the model asked for, never more than the setting allows', () async {
      bridge.sessionOutput.add(bytes('x'));
      await start(waitMs: 999999);
      expect(bridge.sessionReads.last['waitMs'], 5000);
      await manager.read('s1', waitMs: 200);
      expect(bridge.sessionReads.last['waitMs'], 200);
      await manager.read('s1');
      expect(bridge.sessionReads.last['waitMs'], 1500, reason: 'the setting, when the model says nothing');
    });

    test('an ended session says how it ended; one stopped by the app says why; lost output is said', () async {
      bridge.sessionOutput.add(bytes('bye\r\n'));
      await start();
      bridge.sessionAlive = false;
      bridge.sessionExit = 3;
      expect((await manager.read('s1')).describe(), contains('ended with exit code 3'));
      bridge.sessionExit = null;
      bridge.sessionStoppedBy = 'idle';
      expect((await manager.read('s1')).describe(), contains('nobody used it for too long'));
      bridge.sessionStoppedBy = 'workspace';
      expect((await manager.read('s1')).describe(), contains('the workspace is full'));
      bridge.sessionLost = true;
      expect((await manager.read('s1')).describe(), contains('Some output was lost'));
    });

    test('stop is passed on, and list says which sessions exist', () async {
      expect(await manager.list(), 'No sessions.');
      bridge.sessionOutput.add(bytes('x'));
      await start(command: 'node');
      bridge.sessionOutput.add(bytes('y'));
      await start(command: 'bash');
      expect(await manager.list(), allOf(contains('s1: running · \$ node'), contains('s2: running · \$ bash')));
      await manager.stop('s1');
      expect(bridge.calls, contains('sessionStop'));
      expect(await manager.list(), contains('ended'));
    });

    test('the values of the secrets it was given never reach the model, at the start or later', () async {
      const token = 'ghp_ExampleTokenValue123';
      bridge.sessionOutput.add(bytes('token is $token\r\n'));
      final view = await start(secrets: {'GITHUB_TOKEN': token});
      expect(bridge.sessionStarts.single['secrets'], {'GITHUB_TOKEN': token});
      expect(view.screen, 'token is [GITHUB_TOKEN]');
      bridge.sessionOutput.add(bytes('again $token\r\n'));
      final later = await manager.read('s1');
      expect(later.describe(), isNot(contains(token)));
      expect(later.describe(), contains('again [GITHUB_TOKEN]'));
    });

    test('Japanese output that the network cut in the middle of a character is put together', () async {
      final all = bytes('こんにちは');
      bridge.sessionOutput.add(all.sublist(0, 7));
      await start();
      bridge.sessionOutput.add(all.sublist(7));
      final view = await manager.read('s1');
      expect(view.screen, 'こんにちは');
    });
  });
}
