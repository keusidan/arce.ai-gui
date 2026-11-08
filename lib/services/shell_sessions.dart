import 'dart:convert';
import 'dart:typed_data';

import '../core/secret_placeholders.dart';
import '../core/shell_secrets.dart';
import '../core/terminal_screen.dart';
import 'linux_env.dart';

/// What the settings allow for a session (read when it is started).
class ShellSessionSettings {
  const ShellSessionSettings({
    this.maxSessions = 3,
    this.idleMinutes = 15,
    this.waitMs = 1500,
    this.maxWaitMs = 30000,
    this.cols = 120,
    this.rows = 40,
    this.scrollback = 500,
    this.bufferKb = 256,
  });

  final int maxSessions;

  /// A session nobody reads or writes for this long is stopped (0: never).
  final int idleMinutes;

  /// How long a start, a send or a read waits for output when the model does not say.
  final int waitMs;
  final int maxWaitMs;
  final int cols;
  final int rows;

  /// Lines that scrolled off the screen and are kept for the next read.
  final int scrollback;

  /// What the Android side keeps of a session's output between two reads.
  final int bufferKb;
}

/// The names a model may use for keys, and the bytes a terminal sends for them.
abstract final class TerminalKeys {
  static const _named = <String, String>{
    'enter': '\r',
    'return': '\r',
    'tab': '\t',
    'esc': '\x1b',
    'escape': '\x1b',
    'space': ' ',
    'backspace': '\x7f',
    'delete': '\x1b[3~',
    'up': '\x1b[A',
    'down': '\x1b[B',
    'right': '\x1b[C',
    'left': '\x1b[D',
    'home': '\x1b[H',
    'end': '\x1b[F',
    'pageup': '\x1b[5~',
    'pagedown': '\x1b[6~',
  };

  /// The bytes of key [name] (`Enter`, `Ctrl-C`, `ctrl+d` ...); null when it is not a key this knows.
  static String? bytesOf(String name) {
    final key = name.trim().toLowerCase().replaceAll('+', '-').replaceAll(' ', '');
    final named = _named[key];
    if (named != null) return named;
    final ctrl = RegExp(r'^(?:ctrl|c)-([a-z])$').firstMatch(key);
    if (ctrl != null) return String.fromCharCode(ctrl.group(1)!.codeUnitAt(0) - 96);
    return null;
  }

  /// What a model typed as text: a line break is the Enter key.
  static String typed(String text) => text.replaceAll('\r\n', '\r').replaceAll('\n', '\r');
}

/// What a model sees of a session after it started, was written to or was read: the screen.
class SessionView {
  const SessionView({
    required this.id,
    required this.command,
    required this.screen,
    required this.scrolled,
    required this.alive,
    required this.cols,
    required this.rows,
    this.exit,
    this.stoppedBy,
    this.lost = false,
  });

  final String id;
  final String command;

  /// The screen as text.
  final String screen;

  /// The lines that scrolled off the screen since the last view.
  final List<String> scrolled;
  final bool alive;
  final int? exit;
  final String? stoppedBy;

  /// The program wrote more than the buffer held between two reads: some of it is gone.
  final bool lost;
  final int cols;
  final int rows;

  String get status {
    if (alive) return 'running';
    final why = switch (stoppedBy) {
      'idle' => 'stopped by the app: nobody used it for too long',
      'workspace' => 'stopped by the app: the workspace is full',
      'removed' => 'stopped by the app: the Linux environment was removed',
      'stopped' => 'stopped',
      _ => null,
    };
    return why ?? 'ended${exit == null ? '' : ' with exit code $exit'}';
  }

  /// The text the model reads.
  String describe() {
    final b = StringBuffer('session $id · $status · ${cols}x$rows\n\$ $command');
    if (lost) b.write('\n(Some output was lost: the program wrote more than could be kept between two reads.)');
    if (scrolled.isNotEmpty) {
      b
        ..write('\n--- scrolled off the screen (${scrolled.length} lines) ---\n')
        ..write(scrolled.join('\n'));
    }
    b
      ..write('\n--- screen ---\n')
      ..write(screen.isEmpty ? '(empty)' : screen);
    return b.toString();
  }
}

/// The sessions of this app run: each is a program under a pseudo terminal on the Android side, and a
/// [TerminalScreen] here that turns what it writes into the screen. Nothing here decides whether a
/// command may run: the caller has done that (the approval card).
class ShellSessionManager {
  factory ShellSessionManager({LinuxBridge bridge = const LinuxBridge()}) => ShellSessionManager._(bridge);

  ShellSessionManager._(this._bridge);

  final LinuxBridge _bridge;
  final _live = <String, _Live>{};

  Future<SessionView> start({
    required String command,
    required String cwd,
    required ShellSessionSettings settings,
    required int workspaceLimitBytes,
    required bool noSeccomp,
    Map<String, String> secrets = const {},
    Map<String, String> idValues = const {},
    String? label,
    int? waitMs,
  }) async {
    // [idValues] (id -> value) are the secrets used by placeholder: their values are taken out of every screen
    // for the life of the session, and the session remembers which ids it has (a line typed into it may
    // name only those: its process has no others). [label] is what the model and the card see of the
    // command (the text as the model wrote it, placeholders and all): [command] is what runs.
    final answer = await _bridge.sessionStart(
      command: command,
      cwd: cwd,
      cols: settings.cols,
      rows: settings.rows,
      maxSessions: settings.maxSessions,
      idleSeconds: settings.idleMinutes * 60,
      bufferKb: settings.bufferKb,
      workspaceLimitBytes: workspaceLimitBytes,
      noSeccomp: noSeccomp,
      secrets: secrets,
    );
    final id = '${answer['id'] ?? ''}';
    if (id.isEmpty) throw StateError('セッションを始められませんでした');
    final live = _Live(
      id: id,
      command: label ?? command,
      secrets: secrets,
      idValues: idValues,
      settings: settings,
      screen: TerminalScreen(cols: settings.cols, rows: settings.rows, maxScrollback: settings.scrollback),
    );
    _live[id] = live;
    return _view(live, await _pull(live, waitMs ?? settings.waitMs));
  }

  /// The ids of the secrets session [id] was started with (by placeholder); empty for one that has none or
  /// does not exist.
  Set<String> idsOf(String id) => _live[id.trim()]?.idValues.keys.toSet() ?? const {};

  /// Types [text] and presses [keys] (in that order), then reads what the program does.
  Future<SessionView> send(String id, {String text = '', List<String> keys = const [], int? waitMs}) async {
    final live = _get(id);
    final bytes = StringBuffer(TerminalKeys.typed(text));
    for (final key in keys) {
      final one = TerminalKeys.bytesOf(key);
      if (one == null) throw ArgumentError('Unknown key: "$key". Use Enter, Tab, Esc, Up, Down, Left, Right, Backspace, Delete, Home, End, PageUp, PageDown, Space or Ctrl-<letter>.');
      bytes.write(one);
    }
    if (bytes.isNotEmpty) await _bridge.sessionWrite(id, Uint8List.fromList(utf8.encode(bytes.toString())));
    return _view(live, await _pull(live, waitMs ?? live.settings.waitMs));
  }

  Future<SessionView> read(String id, {int? waitMs}) async {
    final live = _get(id);
    return _view(live, await _pull(live, waitMs ?? live.settings.waitMs));
  }

  Future<void> stop(String id) async {
    final live = _get(id);
    await _bridge.sessionStop(id);
    live.stopped = true;
  }

  /// One line for each session this run has started.
  Future<String> list() async {
    if (_live.isEmpty) return 'No sessions.';
    final remote = {for (final item in await _bridge.sessionList()) '${item['id']}': item};
    final b = StringBuffer();
    for (final live in _live.values) {
      final item = remote[live.id];
      final alive = item?['alive'] == true;
      b.writeln('- ${live.id}: ${alive ? 'running' : 'ended'} · \$ ${live.command}');
    }
    return b.toString().trimRight();
  }

  _Live _get(String id) {
    final live = _live[id.trim()];
    if (live == null) {
      throw StateError('There is no session "$id". Sessions this run has started: ${_live.isEmpty ? 'none' : _live.keys.join(', ')}.');
    }
    return live;
  }

  /// Reads the new output, waits for it up to [waitMs], and feeds the screen.
  Future<Map<Object?, Object?>> _pull(_Live live, int waitMs) async {
    final cap = live.settings.maxWaitMs;
    final answer = await _bridge.sessionRead(live.id, from: live.offset, waitMs: waitMs.clamp(0, cap));
    final data = answer['data'];
    if (data is Uint8List) {
      live.screen.feed(data);
    } else if (data is List) {
      live.screen.feed(data.cast<int>());
    }
    final next = answer['next'];
    if (next is num) live.offset = next.toInt();
    return answer;
  }

  /// [text] without the values of the secrets of a session: the ones passed under their own name (`[NAME]`)
  /// and the ones used by placeholder (`[secret:id]`, in the forms `SecretRedaction` knows).
  ///
  /// [screen]: the end of the text is where a program is still writing, so the beginning of a value at the very
  /// end is taken out too (the rest of it may come at the next read).
  static String _redact(String text, Map<String, String> secrets, Map<String, String> idValues, {bool screen = false}) =>
      ShellSecrets.redact(SecretRedaction.redact(text, idValues, trimTail: screen), secrets);

  /// What the model gets: the screen and the lines that scrolled off, with the values of the secrets this
  /// session was given taken out (a program may print its environment at any time, not only at the start).
  SessionView _view(_Live live, Map<Object?, Object?> answer) => SessionView(
        id: live.id,
        command: live.command,
        screen: _redact(live.screen.text(), live.secrets, live.idValues, screen: true),
        scrolled: [for (final line in live.screen.takeScrolled()) _redact(line, live.secrets, live.idValues)],
        alive: answer['alive'] == true,
        exit: answer['exit'] is num ? (answer['exit']! as num).toInt() : null,
        stoppedBy: answer['stoppedBy'] is String ? answer['stoppedBy']! as String : null,
        lost: answer['lost'] == true,
        cols: live.screen.cols,
        rows: live.screen.rows,
      );
}

class _Live {
  _Live({required this.id, required this.command, required this.secrets, this.idValues = const {}, required this.settings, required this.screen});

  final String id;
  final String command;

  /// name -> value of the secrets this session was started with.
  final Map<String, String> secrets;

  /// id -> value of the secrets it was given by placeholder.
  final Map<String, String> idValues;
  final ShellSessionSettings settings;
  final TerminalScreen screen;
  int offset = 0;
  bool stopped = false;
}
