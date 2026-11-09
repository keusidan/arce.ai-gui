import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/dangerous_commands.dart';
import 'linux_env.dart' show ShellOutcome;

/// How a command on a PC without a sandbox is let through.
enum HostApproval {
  /// It runs without asking; one that matches the dangerous list is refused (the default).
  auto,

  /// The user approves every command.
  always,

  /// It runs as written, without asking and without the list.
  never,
}

/// What `run_command` does on Windows, macOS and Linux (the PC): either inside a container of Docker or Podman,
/// which sees only the workspace of the app, or straight on the PC with the user's own rights.
class DesktopShellSettings {
  const DesktopShellSettings({
    this.sandbox = true,
    this.engine = 'auto',
    this.image = defaultImage,
    this.container = defaultContainer,
    this.network = true,
    this.approval = HostApproval.auto,
    this.dangerPatterns = DangerousCommands.defaults,
    this.hostShell = '',
  });

  /// Docker Hub's official Ubuntu image: the same system the Android environment has.
  static const defaultImage = 'ubuntu:24.04';
  static const defaultContainer = 'arce-workspace';

  /// Run commands inside the container (true) or on the PC itself (false).
  final bool sandbox;

  /// `auto` (Docker, else Podman), `docker` or `podman`.
  final String engine;
  final String image;

  /// The name of the one container every chat uses: what is installed in it stays until it is made again.
  final String container;

  /// Whether the container may reach the network (apt and pip need it).
  final bool network;

  final HostApproval approval;

  /// One regular expression per entry (see [DangerousCommands]).
  final List<String> dangerPatterns;

  /// The program and arguments a command is handed to on the PC, separated by spaces (the command is the last
  /// argument). Empty: PowerShell on Windows, bash (or sh) elsewhere.
  final String hostShell;
}

/// A started program, as far as [DesktopShell] needs one (a test gives its own).
typedef ProcessStarter = Future<Process> Function(String executable, List<String> arguments, {String? workingDirectory, Map<String, String>? environment});

/// A program that is run to its end, as far as [DesktopShell] needs one.
typedef ProcessRunner = Future<ProcessResult> Function(String executable, List<String> arguments);

Future<Process> _startProcess(String executable, List<String> arguments, {String? workingDirectory, Map<String, String>? environment}) =>
    Process.start(executable, arguments, workingDirectory: workingDirectory, environment: environment);

Future<ProcessResult> _runProcess(String executable, List<String> arguments) => Process.run(executable, arguments);

/// Runs one command on the PC, in the container or on the PC itself, as [DesktopShellSettings] say.
///
/// One command at a time, like the Android environment: the workspace is shared by every chat.
class DesktopShell {
  DesktopShell({required this.workspace, ProcessStarter? start, ProcessRunner? run, bool? windows})
      : _start = start ?? _startProcess,
        _run = run ?? _runProcess,
        _windows = windows ?? Platform.isWindows;

  /// The app's workspace folder on the PC: `/workspace` in the container, the default folder on the PC.
  final Directory workspace;
  final ProcessStarter _start;
  final ProcessRunner _run;
  final bool _windows;

  Future<void> _queue = Future.value();

  /// The engine that answered last time (`docker` / `podman`), so it is not looked for before every command.
  String? _engineFound;

  /// The engine to use, or null with no engine that answers: the one the settings name, or the first that answers.
  Future<String?> engine(DesktopShellSettings s) async {
    final wanted = s.engine.trim().toLowerCase();
    final candidates = wanted == 'docker' || wanted == 'podman' ? [wanted] : const ['docker', 'podman'];
    if (_engineFound != null && candidates.contains(_engineFound)) return _engineFound;
    _notRunning = null;
    for (final name in candidates) {
      try {
        final result = await _run(name, const ['version']);
        if (result.exitCode == 0) return _engineFound = name;
        // the program is there, but its service does not answer (Docker Desktop not started, no daemon)
        _notRunning ??= name;
      } on ProcessException {
        // not installed: try the next
      }
    }
    return null;
  }

  /// An engine that is installed but did not answer the last time one was looked for.
  String? _notRunning;

  String get _noEngine => _notRunning != null
      ? '$_notRunning はありますが、動いていません（Docker Desktop やサービスを起動してください）'
      : 'Docker も Podman も見つかりません';

  /// What the settings screen shows: the engine and its version, and whether the container is there.
  Future<String> describe(DesktopShellSettings s) async {
    if (!s.sandbox) return 'サンドボックス化しません：コマンドは、この PC で、あなたの権限のまま動きます';
    final name = await engine(s);
    if (name == null) return _notRunning != null ? _noEngine : '$_noEngine。どちらかを入れると、コマンドをコンテナの中で動かせます';
    final state = await _containerState(name, s.container);
    return '$name を使います・コンテナ ${s.container}：${switch (state) {
      null => 'まだ作っていません（最初のコマンドで ${s.image} から作ります）',
      true => '動いています',
      false => '止まっています（次のコマンドで動かします）',
    }}';
  }

  /// Removes the container, so the next command makes it again from the image (the workspace stays).
  Future<void> recreate(DesktopShellSettings s) async {
    final name = await engine(s);
    if (name == null) throw StateError(_noEngine);
    await _run(name, ['rm', '-f', s.container]);
  }

  /// Runs [command] and waits for it. [secrets] become environment variables of that name (never on a command line).
  Future<ShellOutcome> run({
    required DesktopShellSettings settings,
    required String command,
    required String cwd,
    required int timeoutSeconds,
    required int maxOutputChars,
    Map<String, String> secrets = const {},
  }) {
    final done = Completer<ShellOutcome>();
    _queue = _queue.then((_) async {
      try {
        done.complete(await (settings.sandbox
            ? _inContainer(settings, command, cwd, timeoutSeconds, maxOutputChars, secrets)
            : _onHost(settings, command, cwd, timeoutSeconds, maxOutputChars, secrets)));
      } catch (e, st) {
        done.completeError(e, st);
      }
    });
    return done.future;
  }

  // ------------------------------------------------------------ in the container

  Future<bool?> _containerState(String engine, String container) async {
    final result = await _run(engine, ['container', 'inspect', '-f', '{{.State.Running}}', container]);
    if (result.exitCode != 0) return null;
    return '${result.stdout}'.trim() == 'true';
  }

  /// The arguments that make the container: the workspace at /workspace and nothing else of the PC, HOME in it,
  /// and a process that only waits (commands come in with `exec`).
  static List<String> createArguments(DesktopShellSettings s, String workspace) => [
        'run',
        '-d',
        '--name',
        s.container,
        '-v',
        '$workspace:/workspace',
        '-w',
        '/workspace',
        '-e',
        'HOME=/workspace/home',
        if (!s.network) ...['--network', 'none'],
        s.image,
        'sleep',
        'infinity',
      ];

  /// The arguments of one command: its folder, the names of its secrets (their values come from the environment of
  /// the engine's own process), and `timeout` inside the container, which stops the command there too.
  static List<String> execArguments(DesktopShellSettings s, String command, String cwd, int timeoutSeconds, Iterable<String> secretNames) => [
        'exec',
        '-i',
        '-w',
        cwd,
        for (final name in secretNames) ...['-e', name],
        s.container,
        'timeout',
        '-s',
        'KILL',
        '$timeoutSeconds',
        'sh',
        '-c',
        command,
      ];

  Future<ShellOutcome> _inContainer(DesktopShellSettings s, String command, String cwd, int seconds, int maxChars, Map<String, String> secrets) async {
    final engine = await this.engine(s);
    if (engine == null) {
      throw StateError('$_noEngine。動かすか入れるか、設定で「サンドボックス化する」をオフにしてください');
    }
    await Directory(p.join(workspace.path, 'home')).create(recursive: true);
    final state = await _containerState(engine, s.container);
    if (state == null) {
      final made = await _run(engine, createArguments(s, workspace.path));
      if (made.exitCode != 0) throw StateError('コンテナを作れませんでした: ${'${made.stderr}'.trim()}');
    } else if (!state) {
      final started = await _run(engine, ['start', s.container]);
      if (started.exitCode != 0) throw StateError('コンテナを動かせませんでした: ${'${started.stderr}'.trim()}');
    }
    final folder = cwd.trim().isEmpty ? '/workspace' : cwd.trim();
    final process = await _start(engine, execArguments(s, command, folder, seconds, secrets.keys), environment: secrets);
    // `timeout` stops the command inside; the engine's own process is stopped a little later if it hangs
    final outcome = await _collect(process, Duration(seconds: seconds + 10), maxChars, killTree: false);
    // 137 is what `timeout -s KILL` leaves
    if (outcome.exit == 137 && outcome.killedBy == null && outcome.elapsedMs >= seconds * 1000) {
      return _withKilled(outcome, 'timeout');
    }
    return outcome;
  }

  // ------------------------------------------------------------ on the PC

  /// The program and arguments that run [command] on the PC.
  List<String> hostInvocation(DesktopShellSettings s, String command) {
    final own = s.hostShell.trim();
    if (own.isNotEmpty) return [...own.split(RegExp(r'\s+')), command];
    if (_windows) return ['powershell.exe', '-NoProfile', '-NonInteractive', '-Command', command];
    final bash = File('/bin/bash').existsSync() ? '/bin/bash' : '/bin/sh';
    return [bash, '-c', command];
  }

  /// The folder on the PC a command starts in: the workspace when none is given, and the workspace for
  /// `/workspace` (what a model used to the container writes); a relative one is taken from the workspace.
  String hostFolder(String cwd) {
    final given = cwd.trim();
    if (given.isEmpty || given == '/workspace') return workspace.path;
    if (given.startsWith('/workspace/')) return p.join(workspace.path, given.substring('/workspace/'.length));
    if (p.isAbsolute(given)) return given;
    return p.join(workspace.path, given);
  }

  Future<ShellOutcome> _onHost(DesktopShellSettings s, String command, String cwd, int seconds, int maxChars, Map<String, String> secrets) async {
    final folder = hostFolder(cwd);
    if (folder == workspace.path) await workspace.create(recursive: true);
    if (!await Directory(folder).exists()) throw StateError('フォルダーがありません: $folder');
    var invocation = hostInvocation(s, command);
    // on Linux the command gets a process group of its own, so that a timeout stops what it started too
    final grouped = !_windows && Platform.isLinux && File('/usr/bin/setsid').existsSync();
    if (grouped) invocation = ['/usr/bin/setsid', ...invocation];
    final process = await _start(invocation.first, invocation.sublist(1), workingDirectory: folder, environment: secrets);
    return _collect(process, Duration(seconds: seconds), maxChars, killTree: true, grouped: grouped);
  }

  // ------------------------------------------------------------ both

  Future<ShellOutcome> _collect(Process process, Duration limit, int maxChars, {required bool killTree, bool grouped = false}) async {
    final watch = Stopwatch()..start();
    final out = StringBuffer();
    final err = StringBuffer();
    // the input is closed at once: a command cannot ask anything
    unawaited(process.stdin.close().catchError((_) {}));
    final reading = Future.wait([
      process.stdout.transform(const Utf8Decoder(allowMalformed: true)).forEach(out.write),
      process.stderr.transform(const Utf8Decoder(allowMalformed: true)).forEach(err.write),
    ]);
    String? killed;
    final exit = await process.exitCode.timeout(limit, onTimeout: () async {
      killed = 'timeout';
      await _kill(process, tree: killTree, grouped: grouped);
      return process.exitCode.timeout(const Duration(seconds: 5), onTimeout: () => -1);
    });
    await reading.timeout(const Duration(seconds: 5), onTimeout: () => const []);
    final (stdout, cutOut) = clip(out.toString(), maxChars);
    final (stderr, cutErr) = clip(err.toString(), maxChars);
    return ShellOutcome(
      exit: exit,
      stdout: stdout,
      stderr: stderr,
      truncated: cutOut || cutErr,
      elapsedMs: watch.elapsedMilliseconds,
      workspaceBytes: 0,
      workspaceLimitBytes: 0,
      killedBy: killed,
    );
  }

  Future<void> _kill(Process process, {required bool tree, required bool grouped}) async {
    try {
      if (tree && _windows) {
        await _run('taskkill', ['/T', '/F', '/PID', '${process.pid}']);
      } else if (tree && grouped) {
        // the group setsid made: the command and everything it started
        await _run('kill', ['-KILL', '--', '-${process.pid}']);
      }
    } catch (_) {
      // the plain kill below still stops the command itself
    }
    process.kill(ProcessSignal.sigkill);
  }

  static ShellOutcome _withKilled(ShellOutcome o, String why) => ShellOutcome(
        exit: o.exit,
        stdout: o.stdout,
        stderr: o.stderr,
        truncated: o.truncated,
        elapsedMs: o.elapsedMs,
        workspaceBytes: o.workspaceBytes,
        workspaceLimitBytes: o.workspaceLimitBytes,
        killedBy: why,
      );

  /// [text] cut to [maxChars], keeping the beginning and the end (where errors and results usually are).
  static (String, bool) clip(String text, int maxChars) {
    if (maxChars <= 0 || text.length <= maxChars) return (text, false);
    final head = maxChars * 2 ~/ 3;
    final tail = maxChars - head;
    return ('${text.substring(0, head)}\n…\n${text.substring(text.length - tail)}', true);
  }
}
