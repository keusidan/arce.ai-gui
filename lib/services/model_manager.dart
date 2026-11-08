import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../core/engine.dart';
import '../core/model_catalog.dart';
import '../engine/native_engine.dart';
import 'device_info.dart';
import 'download_errors.dart';
import 'foreground_service.dart';
import 'model_downloader.dart';
import 'segmented_download.dart';
import 'settings.dart';

/// Shown instead of loading when the estimate exceeds free RAM (spec §27, §34).
class MemoryWarning {
  const MemoryWarning(this.file, this.estimatedBytes, this.availableBytes);
  final File file;
  final int estimatedBytes;
  final int availableBytes;
}

sealed class DownloadState {
  const DownloadState();
}

class DownloadIdle extends DownloadState {
  const DownloadIdle();
}

class DownloadRunning extends DownloadState {
  const DownloadRunning(this.done, this.total);
  final int done;
  final int total;
}

/// Stopped by the user or a network error; the partial file is kept for Resume (spec §19).
class DownloadPaused extends DownloadState {
  const DownloadPaused(this.done, this.total, [this.reason]);
  final int done;
  final int total;
  final String? reason;
}

class DownloadVerifying extends DownloadState {
  const DownloadVerifying();
}

class DownloadInstalled extends DownloadState {
  const DownloadInstalled();
}

class DownloadFailed extends DownloadState {
  const DownloadFailed(this.reason);
  final String reason;
}

String formatGb(int bytes) => '${(bytes / 1e9).toStringAsFixed(2)} GB';

/// Models on this device: what is installed, what is loaded, and downloads.
/// Everything here works only where [NativeEngine] exists (Android); other platforms list the
/// catalog but cannot download or load.
class ModelManager extends ChangeNotifier {
  ModelManager._(this.directory, this._engine, this._settings, this._device, this._foreground) {
    _downloader = ModelDownloader(
      directory,
      connections: () => _settings.value.downloadConnections.clamp(1, 16),
      stall: () => Duration(seconds: _settings.value.updateStallSeconds.clamp(5, 600)),
      attempts: () => _settings.value.updateRetryAttempts.clamp(1, 20),
    );
  }

  static Future<ModelManager> create({
    required NativeEngine engine,
    required SettingsStore settings,
    required DeviceInfoService device,
    ForegroundService? foreground,
    Directory? supportDirectory,
  }) async {
    final support = supportDirectory ?? await getApplicationSupportDirectory();
    final dir = Directory('${support.path}${Platform.pathSeparator}models');
    final manager = ModelManager._(dir, engine, settings, device, foreground);
    manager._soc = await device.soc();
    await manager.refresh();
    await manager.restoreDownloads();
    return manager;
  }

  final Directory directory;
  final NativeEngine _engine;
  final SettingsStore _settings;
  final DeviceInfoService _device;

  /// Keeps the process alive while a model is downloaded and the app is not in front (Android).
  final ForegroundService? _foreground;
  late final ModelDownloader _downloader;
  String _soc = '';
  final _cancels = <String, CancelToken>{};

  /// Whether a model can be loaded and run here (Android). Downloading, importing, checking and deleting a model work
  /// on every platform: a PC keeps the files too.
  bool get supported => NativeEngine.isSupportedPlatform;

  List<File> installed = const [];
  String? loadedPath;
  String? loadedName;
  double? loadedParamsB;

  /// What the model in memory was loaded with. The settings may have changed since; a saved KV
  /// cache fits these values, not the current settings.
  LoadParams? loadedWith;
  String? busy;
  String? error;
  MemoryWarning? memoryWarning;
  List<String> gpuDevices = const [];

  /// "llama.cpp" or "LiteRT-LM (GPU)"
  String? backend;
  final Map<String, DownloadState> downloads = {};

  /// NPU builds are offered only on the SoC they were compiled for.
  List<ModelSpec> get catalog => [
        for (final spec in ModelCatalog.all)
          if (spec.npuSoc == null || _soc.toLowerCase().contains(spec.npuSoc!)) spec,
      ];

  ModelSpec get basic => ModelCatalog.basic;

  bool get isLoaded => loadedPath != null;

  Future<void> refresh() async {
    final files = <File>[];
    if (await directory.exists()) {
      await for (final entity in directory.list()) {
        if (entity is File && (entity.path.endsWith('.gguf') || entity.path.endsWith('.litertlm'))) {
          files.add(entity);
        }
      }
    }
    files.sort((a, b) => a.path.compareTo(b.path));
    installed = files;
    if (supported) gpuDevices = (await _engine.devices()).where((d) => !d.startsWith('CPU')).toList();
    notifyListeners();
  }

  /// Estimated RAM for a file: catalog figures when known, otherwise size plus a KV-cache margin.
  Future<int> estimateBytes(File file) async {
    final s = _settings.value;
    final spec = ModelCatalog.byFileName(file.uri.pathSegments.last);
    if (spec != null) return MemoryEstimator.totalBytes(spec, s.contextLength, s.kvCache);
    final length = await file.length();
    return length + length ~/ 5;
  }

  /// Whether a catalog model should be offered (greyed out otherwise, unless Force Execution is on).
  Future<bool> fits(ModelSpec spec) async {
    final memory = await _device.memory();
    if (memory == null) return true;
    final s = _settings.value;
    return MemoryEstimator.fits(spec, s.contextLength, s.kvCache, memory.totalBytes);
  }

  Future<void> load(File file, {bool confirmed = false}) async {
    if (!supported) return;
    final s = _settings.value;
    final estimate = await estimateBytes(file);
    final available = (await _device.memory())?.availableBytes;
    if (available != null && estimate > available && !confirmed) {
      // Never change the user's settings automatically; explain and let them decide.
      memoryWarning = MemoryWarning(file, estimate, available);
      notifyListeners();
      return;
    }
    memoryWarning = null;
    busy = '${file.uri.pathSegments.last} を読み込み中…';
    error = null;
    notifyListeners();
    try {
      final gpu = (await _engine.devices()).where((d) => !d.startsWith('CPU')).toList();
      final params = LoadParams(
        path: file.path,
        contextLength: s.contextLength,
        threads: s.effectiveThreads(_device.cores),
        batchSize: s.batchSize,
        gpuLayers: s.gpuLayers(gpuAvailable: gpu.isNotEmpty),
        kvCache: s.kvCache,
      );
      await _engine.load(params);
      loadedWith = params;
      final name = file.uri.pathSegments.last;
      loadedPath = file.path;
      loadedName = name.contains('.') ? name.substring(0, name.lastIndexOf('.')) : name;
      loadedParamsB = ModelCatalog.byFileName(name)?.paramsB ?? paramsFromFileName(name);
      gpuDevices = gpu;
      backend = _engine.backendName;
      busy = null;
      await _settings.update((v) => v.copyWith(lastModelPath: file.path));
    } on EngineException catch (e) {
      loadedPath = null;
      loadedName = null;
      loadedWith = null;
      busy = null;
      error = e.message;
    }
    notifyListeners();
  }

  void dismissMemoryWarning() {
    memoryWarning = null;
    notifyListeners();
  }

  /// Reloads the model used last time, but only when it fits.
  Future<void> restoreLastModel() async {
    final path = _settings.value.lastModelPath;
    if (!supported || path.isEmpty) return;
    final file = File(path);
    if (!await file.exists()) return;
    final available = (await _device.memory())?.availableBytes;
    if (available == null || await estimateBytes(file) <= available) await load(file);
  }

  Future<void> unload() async {
    await _engine.unload();
    loadedPath = null;
    loadedName = null;
    loadedParamsB = null;
    loadedWith = null;
    backend = null;
    notifyListeners();
  }

  /// Copies a model file the user picked into the model directory, then loads it.
  Future<void> import(String sourcePath) async {
    try {
      await directory.create(recursive: true);
      final source = File(sourcePath);
      final name = source.uri.pathSegments.last;
      final destination = File('${directory.path}${Platform.pathSeparator}$name');
      final total = await source.length();
      var copied = 0;
      final sink = destination.openWrite();
      try {
        await for (final chunk in source.openRead()) {
          sink.add(chunk);
          copied += chunk.length;
          busy = 'コピー中… ${copied ~/ 1000000} / ${total ~/ 1000000} MB';
          notifyListeners();
        }
      } finally {
        await sink.close();
      }
      busy = null;
      await refresh();
      await load(destination);
    } catch (e) {
      busy = null;
      error = '$e';
      notifyListeners();
    }
  }

  Future<void> delete(File file) async {
    if (file.path == loadedPath) return;
    await file.delete();
    final part = File('${file.path}.part');
    if (await part.exists()) await part.delete();
    await SegmentedDownload.deleteSegments(part);
    await refresh();
  }

  /// One tap from an empty app to a working chat: downloads the basic model if needed and
  /// loads it as soon as it is verified.
  Future<void> addBasicModel() async {
    final file = fileOf(basic);
    if (await file.exists()) {
      await load(file);
    } else {
      await startDownload(basic, loadWhenDone: true);
    }
  }

  // --- downloads (spec §19: user-driven pause/resume, capacity check, integrity check) ---

  /// A marker next to the model while its download runs. It is removed when the download ends or is
  /// paused; one that is still there at the next start means the app was closed in the middle of it.
  File _runningMarker(ModelSpec spec) => File('${_downloader.target(spec).path}.running');

  /// Puts back what a closed app left: a partly downloaded model shows as paused (with the bytes it
  /// has), and a download that was running when the app was closed is the ones in [interrupted].
  Future<void> restoreDownloads() async {
    for (final spec in catalog) {
      if (downloads.containsKey(spec.id) || await _downloader.target(spec).exists()) continue;
      final bytes = await _downloader.downloadedBytes(spec);
      final wasRunning = await _runningMarker(spec).exists();
      if (bytes > 0 || wasRunning) {
        downloads[spec.id] = DownloadPaused(bytes, spec.fileBytes);
        if (wasRunning) interrupted.add(spec);
      }
    }
    notifyListeners();
  }

  /// The downloads that were running when the app was last closed (see [restoreDownloads]).
  final interrupted = <ModelSpec>[];

  /// Carries on with the downloads the app was closed in the middle of; each continues from the
  /// bytes it already has.
  void resumeInterrupted() {
    final specs = List.of(interrupted);
    interrupted.clear();
    for (final spec in specs) {
      unawaited(startDownload(spec));
    }
  }

  Future<void> startDownload(ModelSpec spec, {bool loadWhenDone = false}) async {
    if (_cancels.containsKey(spec.id)) return;
    final cancel = _cancels[spec.id] = CancelToken();
    await _foreground?.start(ForegroundReason.modelDownload);
    final marker = _runningMarker(spec);
    try {
      await directory.create(recursive: true);
      await marker.writeAsString('');
    } catch (_) {
      // without the marker the download still runs; it just is not resumed by itself after a close
    }
    try {
      final remote = await _downloader.remote(spec);
      final already = await _downloader.downloadedBytes(spec);
      final free = await _device.freeStorageBytes(directory.path);
      if (free != null && remote.sizeBytes - already > free) {
        _setDownload(spec, DownloadFailed(
          '空き容量が不足しています（必要 ${formatGb(remote.sizeBytes - already)} / 空き ${formatGb(free)}）',
        ));
        return;
      }
      _setDownload(spec, DownloadRunning(already, remote.sizeBytes));
      var lastReport = DateTime.fromMillisecondsSinceEpoch(0);
      final file = await _downloader.download(spec, remote, (done, total) {
        // progress many times a second would only repaint the screen for nothing
        final now = DateTime.now();
        if (now.difference(lastReport) < const Duration(milliseconds: 250)) return;
        lastReport = now;
        _setDownload(spec, DownloadRunning(done, total));
      }, cancel);
      _setDownload(spec, const DownloadVerifying());
      final installedFile = await _downloader.install(spec, remote, file);
      _setDownload(spec, const DownloadInstalled());
      await refresh();
      // Load right away when asked to, or when nothing is loaded yet.
      if (loadWhenDone || loadedPath == null) await load(installedFile);
    } on DownloadCancelled {
      _setDownload(spec, DownloadPaused(await _downloader.downloadedBytes(spec), spec.fileBytes));
    } catch (e) {
      final kept = await _downloader.downloadedBytes(spec);
      final why = DownloadErrors.explain(e);
      _setDownload(spec, kept > 0 ? DownloadPaused(kept, spec.fileBytes, why) : DownloadFailed(why));
    } finally {
      _cancels.remove(spec.id);
      try {
        if (await marker.exists()) await marker.delete();
      } catch (_) {
        // nothing to remove
      }
      if (_cancels.isEmpty) await _foreground?.stop(ForegroundReason.modelDownload);
    }
  }

  /// Pausing keeps the partial file; nothing resumes until the user presses Resume.
  void pauseDownload(ModelSpec spec) => _cancels[spec.id]?.cancel();

  /// Throws away a paused download and returns the model to "not downloaded".
  Future<void> discardPartial(ModelSpec spec) async {
    final part = _downloader.partial(spec);
    if (await part.exists()) await part.delete();
    await SegmentedDownload.deleteSegments(part);
    downloads.remove(spec.id);
    notifyListeners();
  }

  Future<void> verify(ModelSpec spec) async {
    _setDownload(spec, const DownloadVerifying());
    var ok = false;
    try {
      ok = await _downloader.verify(spec, await _downloader.remote(spec));
    } catch (_) {
      ok = false;
    }
    _setDownload(
      spec,
      ok ? const DownloadInstalled() : const DownloadFailed('整合性チェックに失敗（破損の可能性）。削除して再取得してください'),
    );
  }

  DownloadState downloadStateOf(ModelSpec spec) {
    final known = downloads[spec.id];
    if (known != null) return known;
    if (installed.any((f) => f.path == _downloader.target(spec).path)) return const DownloadInstalled();
    return const DownloadIdle();
  }

  File fileOf(ModelSpec spec) => _downloader.target(spec);

  void _setDownload(ModelSpec spec, DownloadState state) {
    downloads[spec.id] = state;
    notifyListeners();
  }

  /// "Qwen3-8B-Q4_K_M.gguf" -> 8.0
  static double? paramsFromFileName(String name) {
    final m = RegExp(r'(\d+(?:\.\d+)?)[bB](?![a-zA-Z])').firstMatch(name);
    return m == null ? null : double.tryParse(m.group(1)!);
  }
}
