import 'dart:io';

import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'file_downloader.dart';

/// A number the channel sent, whatever its width.
int asLong(Object? value) => value is num ? value.toInt() : 0;

/// How the Linux environment is set up, as the settings describe it (the docs (linux_environment)).
///
/// The environment itself is Android only: proot runs as a child process out of the app's native
/// library folder, which the other platforms do not have.
class LinuxConfig {
  const LinuxConfig({
    required this.rootfsUrl,
    required this.rootfsSha256,
    required this.dns,
    required this.workspaceLimitMb,
    this.compatMode = false,
    this.connections = 4,
  });

  /// Where the root file system (Ubuntu Base, aarch64) comes from.
  final String rootfsUrl;

  /// The SHA-256 the file must have; empty skips the comparison (the unpacking still refuses
  /// entries that point outside the folder).
  final String rootfsSha256;

  /// The nameservers written into `/etc/resolv.conf` (proot runs on the device's network).
  final List<String> dns;

  /// The most the shared workspace may hold, in MB. 0 means no limit.
  final int workspaceLimitMb;

  /// Starts proot without its seccomp filter (`PROOT_NO_SECCOMP=1`), for devices that refuse it.
  final bool compatMode;

  /// Connections one download may use (the app's download setting).
  final int connections;

  int get workspaceLimitBytes => workspaceLimitMb <= 0 ? 0 : workspaceLimitMb * 1024 * 1024;

  List<String> get dnsServers => [
        for (final server in dns)
          if (server.trim().isNotEmpty) server.trim(),
      ];
}

/// Where the environment is: not installed, downloading it, unpacking it, usable, or failed.
enum LinuxState { absent, downloading, unpacking, ready, failed }

/// What the Android side says about the environment (`LinuxEnv.status`).
class LinuxStatus {
  const LinuxStatus({
    required this.prootPresent,
    required this.installed,
    required this.workspaceBytes,
    required this.workspaceLimitBytes,
    this.rootfs,
  });

  factory LinuxStatus.fromMap(Map<Object?, Object?> map) => LinuxStatus(
        prootPresent: map['prootPresent'] == true,
        installed: map['installed'] == true,
        workspaceBytes: asLong(map['workspaceBytes']),
        workspaceLimitBytes: asLong(map['workspaceLimitBytes']),
        rootfs: map['rootfs'] is String ? map['rootfs']! as String : null,
      );

  /// Whether `libproot.so` and its loader are in the APK for this device's CPU.
  final bool prootPresent;

  /// Whether the root file system is unpacked and finished.
  final bool installed;

  /// What the marker of the root file system says (an archive name, its SHA-256, the file count).
  final String? rootfs;

  final int workspaceBytes;
  final int workspaceLimitBytes;

  String describe() {
    if (!prootPresent) return 'この版のアプリには proot が入っていません（arm64 向けにビルドされた版でだけ使えます）。';
    if (!installed) return 'Linux 環境はまだ入っていません。';
    return 'Linux 環境は使えます。ワークスペース ${formatBytes(workspaceBytes)}'
        '${workspaceLimitBytes > 0 ? ' / ${formatBytes(workspaceLimitBytes)}' : ''}';
  }
}

/// The answer of one command: what the model is given back (section 19.5, item 4).
class ShellOutcome {
  const ShellOutcome({
    required this.exit,
    required this.stdout,
    required this.stderr,
    required this.truncated,
    required this.elapsedMs,
    required this.workspaceBytes,
    required this.workspaceLimitBytes,
    this.killedBy,
  });

  factory ShellOutcome.fromMap(Map<Object?, Object?> map) => ShellOutcome(
        exit: map['exit'] is num ? (map['exit']! as num).toInt() : -1,
        stdout: '${map['stdout'] ?? ''}',
        stderr: '${map['stderr'] ?? ''}',
        truncated: map['truncated'] == true,
        elapsedMs: asLong(map['elapsedMs']),
        workspaceBytes: asLong(map['workspaceBytes']),
        workspaceLimitBytes: asLong(map['workspaceLimitBytes']),
        killedBy: map['killedBy'] is String ? map['killedBy']! as String : null,
      );

  final int exit;
  final String stdout;
  final String stderr;

  /// The command printed more than the setting allows; the beginning and the end are kept.
  final bool truncated;
  final int elapsedMs;
  final int workspaceBytes;
  final int workspaceLimitBytes;

  /// Why the command was stopped before it ended: `workspace` (over the size limit) or `timeout`.
  final String? killedBy;

  bool get ok => exit == 0 && killedBy == null;

  /// The text the model reads back: the exit code, stdout, stderr, and what was cut or stopped.
  String describe() {
    final buffer = StringBuffer();
    if (killedBy == 'workspace') {
      buffer.writeln('ワークスペースが上限（${formatBytes(workspaceLimitBytes)}）を超えたため、コマンドを止めました。'
          'いまは ${formatBytes(workspaceBytes)} です。減らしてから続けてください。');
    } else if (killedBy == 'timeout') {
      buffer.writeln('時間の上限を過ぎたため、コマンドを止めました。');
    }
    buffer.writeln('exit: $exit');
    if (stdout.trim().isNotEmpty) {
      buffer.writeln('stdout:');
      buffer.writeln(stdout.trimRight());
    }
    if (stderr.trim().isNotEmpty) {
      buffer.writeln('stderr:');
      buffer.writeln(stderr.trimRight());
    }
    if (stdout.trim().isEmpty && stderr.trim().isEmpty) buffer.writeln('（出力はありません）');
    if (truncated) buffer.writeln('（出力が長いため、初めと終わりだけにしました）');
    // a PC does not measure the workspace (both are 0): only the time is said
    buffer.writeln('所要: ${(elapsedMs / 1000).toStringAsFixed(1)}秒'
        '${workspaceBytes == 0 && workspaceLimitBytes == 0 ? '' : '・ワークスペース ${formatBytes(workspaceBytes)}'
            '${workspaceLimitBytes > 0 ? ' / ${formatBytes(workspaceLimitBytes)}' : ''}'}');
    return buffer.toString().trimRight();
  }
}

/// 1000-based, the way a phone shows storage.
String formatBytes(int bytes) {
  if (bytes < 1000) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1000;
  var unit = 0;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit++;
  }
  return '${value.toStringAsFixed(value < 10 ? 1 : 0)} ${units[unit]}';
}

/// The thin crossing to `ai.arce.app/system` (`SystemBridge.kt`). Tests use a subclass instead of
/// the channel, so nothing here touches Android.
class LinuxBridge {
  const LinuxBridge();

  static const MethodChannel _channel = MethodChannel('ai.arce.app/system');

  Future<Map<Object?, Object?>> status({required int workspaceLimitBytes}) async =>
      _map(await _channel.invokeMethod<Map<Object?, Object?>>('linuxStatus', {
        'workspaceLimitBytes': workspaceLimitBytes,
      }));

  Future<Map<Object?, Object?>> install({
    required String path,
    required String sha256,
    required List<String> dns,
    required int maxBytes,
  }) async =>
      _map(await _channel.invokeMethod<Map<Object?, Object?>>('linuxInstall', {
        'path': path,
        'sha256': sha256,
        'dns': dns,
        'maxBytes': maxBytes,
      }));

  Future<Map<Object?, Object?>> run({
    required String command,
    required String cwd,
    required int timeoutSeconds,
    required int maxOutputChars,
    required int workspaceLimitBytes,
    required bool noSeccomp,
    Map<String, String> secrets = const {},
  }) async =>
      _map(await _channel.invokeMethod<Map<Object?, Object?>>('linuxRun', {
        'command': command,
        'cwd': cwd,
        'timeoutSeconds': timeoutSeconds,
        'maxOutputChars': maxOutputChars,
        'workspaceLimitBytes': workspaceLimitBytes,
        'noSeccomp': noSeccomp,
        'secrets': secrets,
      }));

  // ---- sessions: a program that is talked to (a pseudo terminal under proot)

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
  }) async =>
      _map(await _channel.invokeMethod<Map<Object?, Object?>>('linuxSessionStart', {
        'command': command,
        'cwd': cwd,
        'cols': cols,
        'rows': rows,
        'maxSessions': maxSessions,
        'idleSeconds': idleSeconds,
        'bufferKb': bufferKb,
        'workspaceLimitBytes': workspaceLimitBytes,
        'noSeccomp': noSeccomp,
        'secrets': secrets,
      }));

  /// The output of session [id] since byte offset [from], waiting up to [waitMs] for some (and, once it
  /// comes, until the program has been quiet for [settleMs]).
  Future<Map<Object?, Object?>> sessionRead(String id, {required int from, required int waitMs, int settleMs = 300}) async =>
      _map(await _channel.invokeMethod<Map<Object?, Object?>>('linuxSessionRead', {
        'id': id,
        'from': from,
        'waitMs': waitMs,
        'settleMs': settleMs,
      }));

  Future<void> sessionWrite(String id, Uint8List data) => _channel.invokeMethod<void>('linuxSessionWrite', {'id': id, 'data': data});

  Future<void> sessionStop(String id) => _channel.invokeMethod<void>('linuxSessionStop', {'id': id});

  Future<List<Map<Object?, Object?>>> sessionList() async {
    final list = await _channel.invokeMethod<List<Object?>>('linuxSessionList') ?? const [];
    return [for (final item in list) if (item is Map) item.cast<Object?, Object?>()];
  }

  Future<void> remove() => _channel.invokeMethod<void>('linuxRemove');

  Future<void> clearWorkspace() => _channel.invokeMethod<void>('workspaceClear');

  static Map<Object?, Object?> _map(Map<Object?, Object?>? value) => value ?? const {};
}

/// Fills a file from [url]; the app's download (resume, several connections) does the work, and
/// tests replace this with a function that writes a file instead.
typedef RootfsDownload = Future<File> Function(
  String url, {
  required int connections,
  void Function(int done, int total)? onProgress,
});

/// The Linux environment as the app sees it: whether it is there, installing it once, and running
/// one command at a time in it (the Android side serialises them: the workspace is shared).
///
/// It tells its listeners when the state changes, so the settings screen can show the download's
/// progress and the workspace's size without asking again.
class LinuxEnvironment extends ChangeNotifier {
  /// The public way in: it fills in the download and the platform. (A plain constructor cannot
  /// assign the private fields without a lint, and a private field cannot be a named parameter.)
  factory LinuxEnvironment({
    LinuxBridge bridge = const LinuxBridge(),
    RootfsDownload? download,
    bool? android,
  }) =>
      LinuxEnvironment._(bridge, download ?? _downloadRootfs, android ?? Platform.isAndroid);

  LinuxEnvironment._(this._bridge, this._download, this._android);

  final LinuxBridge _bridge;
  final RootfsDownload _download;

  /// Whether this is Android (a test says so for itself).
  final bool _android;

  LinuxState _state = LinuxState.absent;
  double? _progress;
  String? _message;
  LinuxStatus? _status;

  LinuxState get state => _state;

  /// 0..1 while downloading, null when the size is unknown.
  double? get progress => _progress;

  /// Why the last install failed, for the settings screen.
  String? get message => _message;

  LinuxStatus? get status => _status;

  /// Whether a command may be sent: the environment is unpacked and its proot is in this build.
  bool get ready => _state == LinuxState.ready;

  /// False on iOS, Windows, macOS and Linux: proot is Android's.
  static bool get supported => Platform.isAndroid;

  /// Tells the screen that something changed (never from inside a build).
  void _changed() {
    if (_disposed) return;
    notifyListeners();
  }

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// Reads the state from the Android side (cheap: the workspace is measured on a block grid).
  Future<LinuxStatus> refresh(LinuxConfig config) async {
    if (!_android) {
      _state = LinuxState.absent;
      _status = const LinuxStatus(prootPresent: false, installed: false, workspaceBytes: 0, workspaceLimitBytes: 0);
      _changed();
      return _status!;
    }
    try {
      final status = LinuxStatus.fromMap(await _bridge.status(workspaceLimitBytes: config.workspaceLimitBytes));
      _status = status;
      // a running install keeps its state; otherwise the folder decides
      if (_state != LinuxState.downloading && _state != LinuxState.unpacking) {
        _state = status.installed ? LinuxState.ready : LinuxState.absent;
      }
      _changed();
      return status;
    } catch (e) {
      _state = LinuxState.failed;
      _message = '$e';
      _changed();
      rethrow;
    }
  }

  /// Downloads the root file system, checks its SHA-256 and has it unpacked. Its size is not in the
  /// workspace limit: it is the system, not the work.
  Future<LinuxStatus> install(LinuxConfig config) async {
    if (!_android) throw UnsupportedError('the Linux environment is Android only');
    _message = null;
    _progress = 0;
    _state = LinuxState.downloading;
    _changed();
    File? lasting;
    try {
      final archive = await _download(
        config.rootfsUrl,
        connections: config.connections,
        onProgress: (done, total) {
          _progress = total > 0 ? (done / total).clamp(0.0, 1.0).toDouble() : null;
          _changed();
        },
      );
      lasting = archive;
      final want = config.rootfsSha256.trim().toLowerCase();
      if (want.isNotEmpty) {
        final have = (await FileDownloader.sha256Of(archive)).toLowerCase();
        if (have != want) throw StateError('SHA-256 が設定と違います（$have）。');
      }
      _state = LinuxState.unpacking;
      _progress = null;
      _changed();
      await _bridge.install(
        path: archive.path,
        sha256: config.rootfsSha256,
        dns: config.dnsServers,
        // 0 is "no limit": the entries are what Ubuntu Base ships
        maxBytes: 0,
      );
      // the install is over, so the folder decides the state (refresh keeps a running install's)
      _state = LinuxState.absent;
      _changed();
      return await refresh(config);
    } catch (e) {
      _state = LinuxState.failed;
      _message = '$e';
      _changed();
      rethrow;
    } finally {
      _progress = null;
      // the archive is a one-off; the Android side has its own copy of what it needs
      final file = lasting;
      try {
        if (file != null && await file.exists()) await file.delete();
      } catch (_) {
        // a leftover file in the cache folder is not worth an error of its own
      }
    }
  }

  /// Removes the root file system (the workspace stays).
  Future<void> remove() async {
    await _bridge.remove();
    _state = LinuxState.absent;
    _status = null;
    _message = null;
    _changed();
  }

  /// Empties the shared workspace; every chat sees the same folder.
  Future<LinuxStatus> clearWorkspace(LinuxConfig config) async {
    await _bridge.clearWorkspace();
    return refresh(config);
  }

  /// Runs one command in the root file system. [cwd] is a path inside it (`/workspace` by default).
  Future<ShellOutcome> run({
    required LinuxConfig config,
    required String command,
    required String cwd,
    required int timeoutSeconds,
    required int maxOutputChars,
    Map<String, String> secrets = const {},
  }) async {
    if (!ready) throw StateError('Linux 環境がまだ使えません。設定から入れてください。');
    final outcome = ShellOutcome.fromMap(await _bridge.run(
      command: command,
      cwd: cwd,
      timeoutSeconds: timeoutSeconds,
      maxOutputChars: maxOutputChars,
      workspaceLimitBytes: config.workspaceLimitBytes,
      noSeccomp: config.compatMode,
      secrets: secrets,
    ));
    final previous = _status;
    if (previous != null) {
      _status = LinuxStatus(
        prootPresent: previous.prootPresent,
        installed: previous.installed,
        workspaceBytes: outcome.workspaceBytes,
        workspaceLimitBytes: outcome.workspaceLimitBytes,
        rootfs: previous.rootfs,
      );
      _changed();
    }
    return outcome;
  }

  static Future<Directory> _tempFolder() async {
    final base = await getTemporaryDirectory();
    return Directory(p.join(base.path, 'arce-linux')).create(recursive: true);
  }

  /// Downloads the root file system into the cache folder, asking the server for its length first
  /// (a resume needs it) and letting [FileDownloader] do the rest.
  static Future<File> _downloadRootfs(
    String url, {
    required int connections,
    void Function(int done, int total)? onProgress,
  }) async {
    final uri = Uri.parse(url);
    final folder = await _tempFolder();
    final part = File(p.join(folder.path, 'rootfs.part'));
    final client = http.Client();
    try {
      final total = await _length(client, uri);
      if (total <= 0) {
        // no length: one connection, and the file ends where the stream ends
        final file = File(p.join(folder.path, 'rootfs.tar.gz'));
        final response = await client.send(http.Request('GET', uri));
        final sink = file.openWrite();
        var done = 0;
        await for (final chunk in response.stream) {
          sink.add(chunk);
          done += chunk.length;
          onProgress?.call(done, 0);
        }
        await sink.flush();
        await sink.close();
        return file;
      }
      await FileDownloader(
        connections: () => connections,
        stall: () => const Duration(seconds: 30),
        attempts: () => 5,
      ).fetch(
        part: part,
        total: total,
        open: (from, to) async {
          final request = http.Request('GET', uri);
          final range = rangeHeader(from, to);
          if (range != null) request.headers['range'] = range;
          return await client.send(request);
        },
        onProgress: (done) => onProgress?.call(done, total),
      );
      final file = File(p.join(folder.path, 'rootfs.tar.gz'));
      if (await file.exists()) await file.delete();
      return await part.rename(file.path);
    } finally {
      client.close();
    }
  }

  /// The length of [uri]: `HEAD`, and when the server does not answer that with one, a request for
  /// its first two bytes (the answer says where the file ends).
  static Future<int> _length(http.Client client, Uri uri) async {
    try {
      final head = await client.head(uri);
      final length = head.contentLength ?? 0;
      if (length > 0) return length;
    } catch (_) {
      // fall through to the ranged request
    }
    try {
      final request = http.Request('GET', uri)..headers['range'] = 'bytes=0-1';
      final response = await client.send(request);
      await response.stream.drain<void>().catchError((_) {});
      final range = response.headers['content-range'];
      final slash = range?.lastIndexOf('/') ?? -1;
      if (slash >= 0) return int.tryParse(range!.substring(slash + 1)) ?? 0;
      return response.contentLength ?? 0;
    } catch (_) {
      return 0;
    }
  }
}
