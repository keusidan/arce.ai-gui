import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/releases.dart';
import '../core/safe_url.dart';
import 'desktop_installer.dart';
import 'bspatch.dart';
import 'download_errors.dart';
import 'file_downloader.dart';
import 'foreground_service.dart';
import 'settings.dart';

sealed class UpdateState {
  const UpdateState();
}

class UpdateIdle extends UpdateState {
  const UpdateIdle();
}

class UpdateChecking extends UpdateState {
  const UpdateChecking();
}

class UpdateUpToDate extends UpdateState {
  const UpdateUpToDate();
}

class UpdateAvailable extends UpdateState {
  const UpdateAvailable(this.release);
  final Release release;
}

class UpdateDownloading extends UpdateState {
  const UpdateDownloading(this.release, this.done, this.total);
  final Release release;
  final int done;
  final int total;
}

class UpdateReady extends UpdateState {
  const UpdateReady(this.release, this.file);
  final Release release;
  final File file;
}

class UpdateFailed extends UpdateState {
  const UpdateFailed(this.reason);
  final String reason;
}

/// Updates from the GitHub releases of the repository: check, then download only after the
/// user approves, verify the published SHA-256, and install the build for this platform.
///
/// Android installs through PackageInstaller (the APK must carry the same signature as the
/// installed app). Windows, macOS and Linux replace their own files and restart. iOS cannot
/// install outside the App Store, so it opens the release page.
class UpdateService extends ChangeNotifier {
  UpdateService(
    this._settings, {
    http.Client? client,
    Future<Directory> Function()? cacheDirectory,
    this.currentVersion,
    this.foreground,
    this.retryDelay = const Duration(seconds: 2),
    this.stallTimeoutOverride,
    this.maxAttemptsOverride,
    this.baseApkOverride,
  })  : _client = client ?? http.Client(),
        _cacheDirectory = cacheDirectory ?? getApplicationCacheDirectory;

  static const _system = MethodChannel('ai.arce.app/system');

  /// Fixed values for tests; the settings decide when these are null.
  final int? maxAttemptsOverride;
  final Duration? stallTimeoutOverride;

  /// Where the installed build's APK is, for tests; on Android the system says.
  final Future<String?> Function()? baseApkOverride;

  /// How many times a download is tried before it is reported as failed (a setting). Every try
  /// after the first continues from the part file, so a connection that dropped (the app was in
  /// the background, the network switched) costs only the time it was down.
  int get maxAttempts => (maxAttemptsOverride ?? _settings.value.updateRetryAttempts).clamp(1, 20);

  final SettingsStore _settings;
  final http.Client _client;
  final Future<Directory> Function() _cacheDirectory;

  /// Kept running while a download is in progress, so Android does not freeze the process (and
  /// the connection with it) when another app is opened. Null where there is no such service.
  final ForegroundService? foreground;

  /// Wait before try *n* is `retryDelay * n`.
  final Duration retryDelay;

  /// A response that sends nothing for this long is treated as a dropped connection (a setting).
  Duration get stallTimeout =>
      stallTimeoutOverride ?? Duration(seconds: _settings.value.updateStallSeconds.clamp(5, 600));

  UpdateState _state = const UpdateIdle();
  UpdateState get state => _state;

  Version? currentVersion;
  Timer? _timer;

  /// The release found by the last successful check; [download] works from it.
  Release? _release;

  static UpdateTarget? get target {
    if (kIsWeb) return null;
    if (Platform.isAndroid) return UpdateTarget.android;
    if (Platform.isIOS) return UpdateTarget.ios;
    if (Platform.isWindows) return UpdateTarget.windows;
    if (Platform.isMacOS) return UpdateTarget.macos;
    if (Platform.isLinux) return UpdateTarget.linux;
    return null;
  }

  Future<void> init() async {
    if (currentVersion == null) {
      final info = await PackageInfo.fromPlatform();
      currentVersion = Version.parse(info.version);
    }
    notifyListeners();
    _schedule();
    _settings.addListener(_schedule);
    if (_settings.value.autoUpdateCheck) unawaited(_autoCheck());
    // the build we are now running has been installed, so its download is no longer needed
    unawaited(removeOldDownloads());
  }

  void _schedule() {
    _timer?.cancel();
    final s = _settings.value;
    if (!s.autoUpdateCheck) return;
    _timer = Timer.periodic(Duration(hours: s.updateIntervalHours.clamp(1, 168)), (_) => _autoCheck());
  }

  /// The check that runs by itself (at start and on the timer). When the user asked for automatic
  /// updates, a newer build is downloaded and the installer is opened without waiting for a tap.
  /// A manual check stays manual: the screen offers 「ダウンロード」 as before.
  Future<void> _autoCheck() async {
    await check(silent: true);
    if (_state is UpdateAvailable &&
        _settings.value.autoInstallUpdate &&
        target != UpdateTarget.ios) {
      await _downloadAndInstall();
    }
  }

  void _set(UpdateState state) {
    _state = state;
    notifyListeners();
  }

  bool isNewer(Release release) => currentVersion == null || release.version > currentVersion!;

  /// [silent] keeps quiet when there is nothing new or the check fails (automatic checks).
  Future<void> check({bool silent = false}) async {
    if (_state is UpdateChecking || _state is UpdateDownloading) return;
    if (!silent) _set(const UpdateChecking());
    try {
      final release = await latest();
      if (isNewer(release)) {
        _release = release;
        _set(UpdateAvailable(release));
      } else if (!silent) {
        _set(const UpdateUpToDate());
      }
    } catch (e) {
      if (!silent) _set(UpdateFailed(_explain(e)));
    }
  }

  /// Downloads the release found by [check] and opens the installer as soon as the file is
  /// verified. Nothing is forced: the same states the screen shows drive both steps, so a failure
  /// stops here and the user still sees what happened.
  Future<void> _downloadAndInstall() async {
    if (_state is! UpdateAvailable) return;
    await download();
    if (_state is UpdateReady) await install();
  }

  /// The newest release made for this platform. Every platform has its own releases, so the list is read
  /// instead of "latest" (which is whichever platform was published last).
  Future<Release> latest() async {
    final platform = target;
    if (platform == null) throw StateError('このOSには更新ファイルがありません');
    final repo = _settings.value.updateRepo;
    final response = await _client
        .get(
          Uri.parse('https://api.github.com/repos/$repo/releases?per_page=50'),
          headers: _headers('application/vnd.github+json', withToken: true),
        )
        .timeout(const Duration(seconds: 20));
    switch (response.statusCode) {
      case 200:
        return ReleaseParser.latestFor(response.body, platform) ??
            (throw StateError('この端末（${platform.name}）向けのリリースがまだありません'));
      case 401 || 403:
        throw StateError('GitHub がトークンを受け付けませんでした（HTTP ${response.statusCode}）。設定のトークンを確認してください');
      case 404:
        throw StateError('リリースが見つかりません（HTTP 404）。非公開リポジトリには Contents: read のトークンが必要です');
      default:
        throw StateError('GitHub HTTP ${response.statusCode}');
    }
  }

  String _explain(Object e) {
    if (e is StateError) return e.message;
    if (e is FormatException) return e.message;
    return DownloadErrors.explain(e, resume: '「更新を確認」から、続きの位置からやり直せます');
  }

  /// The transfer that the model download shares: several connections, resuming from the part file,
  /// trying again. Its settings are asked on every download, so a changed setting applies at once.
  late final FileDownloader _fetcher = FileDownloader(
    connections: () => _settings.value.downloadConnections,
    stall: () => stallTimeout,
    attempts: () => maxAttempts,
    retryDelay: retryDelay,
  );

  Map<String, String> _headers(String accept, {required bool withToken}) => {
        'Accept': accept,
        'User-Agent': 'ARCE.AI/${currentVersion ?? '0'}',
        'X-GitHub-Api-Version': '2022-11-28',
        if (withToken && _settings.githubToken.isNotEmpty) 'Authorization': 'Bearer ${_settings.githubToken}',
      };

  /// Downloads the asset for this platform and checks it against the release's `.sha256` asset.
  Future<void> download() async {
    final release = _release;
    if (release == null || _state is UpdateDownloading) return;
    final t = target;
    final asset = t == null ? null : release.assetFor(t);
    if (asset == null) {
      _set(UpdateFailed('${release.tag} にこの端末向けのビルドがありません'));
      return;
    }
    if (t == UpdateTarget.ios) {
      await openReleasePage(release);
      return;
    }
    final checksum = release.checksumFor(asset);
    if (checksum == null) {
      _set(UpdateFailed('${release.tag} に ${asset.name}.sha256 がありません'));
      return;
    }
    _set(UpdateDownloading(release, 0, asset.sizeBytes));
    await foreground?.start(ForegroundReason.update);
    try {
      final expected = ReleaseParser.parseChecksum(utf8Text(await _fetcher.retrying(() => _assetBytes(checksum))));
      if (expected == null) throw StateError('チェックサムファイルを読み取れません');
      final cache = await _cacheDirectory();
      final dir = Directory('${cache.path}${Platform.pathSeparator}updates');
      await dir.create(recursive: true);
      // Only this download is kept: other files are a build that is no longer needed, or a
      // half-finished file of another version.
      final wanted = {asset.name, '${asset.name}.part'};
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = entity.path.split(Platform.pathSeparator).last;
        // the parts of a download over several connections are kept so it can continue
        if (!wanted.contains(name) && !name.startsWith('${asset.name}.part.seg')) await entity.delete();
      }
      final file = File('${dir.path}${Platform.pathSeparator}${asset.name}');
      final part = File('${file.path}.part');
      if (await _tryDelta(release, asset, file, expected, dir)) {
        _set(UpdateReady(release, file));
        return;
      }
      final digest = await _fetchAsset(asset, file, part, (done) => _set(UpdateDownloading(release, done, asset.sizeBytes)));
      if (digest.toLowerCase() != expected.toLowerCase()) {
        for (final f in [file, part]) {
          if (await f.exists()) await f.delete();
        }
        throw StateError('SHA-256 が一致しません。ダウンロードを破棄しました');
      }
      _set(UpdateReady(release, file));
    } catch (e) {
      _set(UpdateFailed(_explain(e)));
    } finally {
      await foreground?.stop(ForegroundReason.update);
    }
  }

  /// Android: when the release has the difference between the installed build and the new one,
  /// downloads just that and puts the new APK together from the installed one. True when [file]
  /// is the new APK and its SHA-256 is [expected]; in every other case nothing is left behind and
  /// the caller downloads the whole file.
  Future<bool> _tryDelta(Release release, ReleaseAsset asset, File file, String expected, Directory dir) async {
    final from = currentVersion;
    if (from == null || !_settings.value.updateUseDelta) return false;
    final patch = release.patchFor(asset, from);
    // a difference that is not much smaller than the file is not worth putting together
    if (patch == null || patch.sizeBytes <= 0 || patch.sizeBytes * 2 > asset.sizeBytes) return false;
    final base = await _baseApk();
    if (base == null || !await File(base).exists()) return false;

    final patchFile = File('${dir.path}${Platform.pathSeparator}${patch.name}');
    final patchPart = File('${patchFile.path}.part');
    final built = File('${file.path}.new');
    try {
      await _fetchAsset(patch, patchFile, patchPart, (done) => _set(UpdateDownloading(release, done, patch.sizeBytes)));
      await BsPatch.applyFiles(base, patchFile.path, built.path);
      final digest = (await sha256.bind(built.openRead()).first).toString();
      if (digest.toLowerCase() != expected.toLowerCase()) {
        debugPrint('the patched file does not match the published SHA-256; downloading the whole file');
        return false;
      }
      if (await file.exists()) await file.delete();
      await built.rename(file.path);
      return true;
    } catch (e) {
      debugPrint('delta update failed ($e); downloading the whole file');
      return false;
    } finally {
      for (final f in [patchFile, patchPart, built]) {
        if (await f.exists()) await f.delete();
      }
    }
  }

  Future<String?> _baseApk() async {
    final override = baseApkOverride;
    if (override != null) return override();
    if (target != UpdateTarget.android) return null;
    try {
      return await _system.invokeMethod<String>('baseApk');
    } catch (_) {
      return null;
    }
  }

  static String utf8Text(List<int> bytes) => String.fromCharCodes(bytes);

  /// Asset downloads answer with a redirect to signed storage. The GitHub token must not be
  /// sent there (the storage rejects a second credential), so the redirect is followed by hand.
  ///
  /// [from] asks for the rest of a download that stopped earlier; the storage honours it with
  /// `206 Partial Content`, and the range is repeated on the redirected request.
  Future<http.StreamedResponse> _openAsset(ReleaseAsset asset, {int from = 0, int? to}) async {
    final header = rangeHeader(from, to);
    final range = header == null ? null : {'Range': header};
    final repo = _settings.value.updateRepo;
    final api = http.Request('GET', Uri.parse('https://api.github.com/repos/$repo/releases/assets/${asset.id}'))
      ..followRedirects = false
      ..headers.addAll(_headers('application/octet-stream', withToken: true));
    if (range != null) api.headers.addAll(range);
    final first = await _client.send(api).timeout(const Duration(seconds: 30));
    if (first.statusCode >= 300 && first.statusCode < 400) {
      final location = first.headers['location'];
      await first.stream.drain<void>();
      if (location == null) throw StateError('リダイレクト先がありません');
      final storage = http.Request('GET', Uri.parse(location))..headers.addAll(_headers('application/octet-stream', withToken: false));
      if (range != null) storage.headers.addAll(range);
      return _client.send(storage).timeout(const Duration(seconds: 30));
    }
    return first;
  }

  Future<List<int>> _assetBytes(ReleaseAsset asset) async {
    final response = await _openAsset(asset);
    if (response.statusCode < 200 || response.statusCode > 299) {
      await response.stream.drain<void>().catchError((_) {});
      throw HttpException('HTTP ${response.statusCode}');
    }
    final bytes = <int>[];
    await for (final chunk in response.stream.timeout(stallTimeout)) {
      bytes.addAll(chunk);
    }
    return bytes;
  }

  /// Fetches the asset into [part] with the shared downloader (it continues from what a stopped
  /// download already wrote, so an interrupted update does not start over), then moves the finished
  /// file to [file] and returns its SHA-256.
  Future<String> _fetchAsset(
    ReleaseAsset asset,
    File file,
    File part,
    void Function(int done) onProgress,
  ) async {
    var lastReport = DateTime.fromMillisecondsSinceEpoch(0);
    await _fetcher.fetch(
      part: part,
      total: asset.sizeBytes,
      open: (from, to) => _openAsset(asset, from: from, to: to),
      onProgress: (done) {
        final now = DateTime.now();
        if (now.difference(lastReport) > const Duration(milliseconds: 200)) {
          lastReport = now;
          onProgress(done);
        }
      },
    );
    final digest = await FileDownloader.sha256Of(part);
    if (await file.exists()) await file.delete();
    await part.rename(file.path);
    onProgress(asset.sizeBytes);
    return digest;
  }

  /// Deletes update files this app no longer needs: the build it is already running (the update
  /// is installed) and halves of other versions. A newer file is kept, so a download that was
  /// interrupted can still resume.
  Future<void> removeOldDownloads() async {
    try {
      final cache = await _cacheDirectory();
      final dir = Directory('${cache.path}${Platform.pathSeparator}updates');
      if (!await dir.exists()) return;
      final current = currentVersion;
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final version = _versionIn(entity.path);
        final keep = version != null && current != null && version > current;
        if (!keep) await entity.delete();
      }
    } catch (e) {
      debugPrint('could not clean the update folder: $e');
    }
  }

  /// The `0.5.0` of `ARCE.AI-v0.5.0-android.apk.part`, when the file name has one.
  static Version? _versionIn(String path) {
    final name = path.split(Platform.pathSeparator).last;
    final match = RegExp(r'(\d+\.\d+\.\d+)').firstMatch(name);
    return match == null ? null : Version.parse(match.group(1)!);
  }

  Future<bool> canInstall() async {
    if (!Platform.isAndroid) return true;
    return await _system.invokeMethod<bool>('canInstall') ?? false;
  }

  /// Opens the system screen where the user allows ARCE.AI to install apps (first time only).
  Future<void> requestInstallPermission() => _system.invokeMethod<void>('requestInstall');

  Future<void> install() async {
    final current = _state;
    if (current is! UpdateReady) return;
    try {
      if (Platform.isAndroid) {
        // 初回だけは利用者がシステムの画面で許可する必要がある。許可待ちのあいだも、
        // 検証済みのファイルは残るので、許可後に「インストール」を押せばそのまま入る。
        if (!await canInstall()) {
          await requestInstallPermission();
          return;
        }
        await _system.invokeMethod<void>('install', {'path': current.file.path});
      } else {
        await DesktopInstaller.apply(current.file);
      }
    } catch (e) {
      _set(UpdateFailed(_explain(e)));
    }
  }

  Future<void> openReleasePage(Release release) async {
    final url = release.htmlUrl ?? 'https://github.com/${_settings.value.updateRepo}/releases/tag/${release.tag}';
    final uri = safeWebUri(url);
    if (uri != null) await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  void dismiss() => _set(const UpdateIdle());

  @override
  void dispose() {
    _timer?.cancel();
    _settings.removeListener(_schedule);
    super.dispose();
  }
}

/// Collects the single digest produced by a chunked conversion.
class AccumulatorSink<T> implements Sink<T> {
  final events = <T>[];

  @override
  void add(T data) => events.add(data);

  @override
  void close() {}
}
