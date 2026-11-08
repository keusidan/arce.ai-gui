import 'dart:io';

import 'package:flutter/services.dart';

import 'proot_check.dart';

class MemoryInfo {
  const MemoryInfo({required this.totalBytes, required this.availableBytes, this.lowMemory = false});
  final int totalBytes;
  final int availableBytes;
  final bool lowMemory;
}

/// Hardware facts used by the model list, settings and the memory check (spec §30).
/// Android answers through the native side; Linux reads /proc; elsewhere unknown values stay null.
class DeviceInfoService {
  static const _channel = MethodChannel('ai.arce.app/system');

  int get cores => Platform.numberOfProcessors;

  Future<MemoryInfo?> memory() async {
    try {
      if (Platform.isAndroid) {
        final m = await _channel.invokeMapMethod<String, Object?>('memory');
        if (m == null) return null;
        return MemoryInfo(
          totalBytes: (m['total'] as num).toInt(),
          availableBytes: (m['available'] as num).toInt(),
          lowMemory: m['low'] as bool? ?? false,
        );
      }
      if (Platform.isLinux) {
        final text = await File('/proc/meminfo').readAsString();
        int kb(String key) {
          final match = RegExp('^$key:\\s+(\\d+) kB', multiLine: true).firstMatch(text);
          return match == null ? 0 : int.parse(match.group(1)!) * 1024;
        }

        final total = kb('MemTotal');
        if (total == 0) return null;
        return MemoryInfo(totalBytes: total, availableBytes: kb('MemAvailable'));
      }
    } catch (_) {
      // fall through: unknown
    }
    return null;
  }

  Future<int?> freeStorageBytes(String path) async {
    try {
      if (Platform.isAndroid) {
        final v = await _channel.invokeMethod<num>('freeStorage', {'path': path});
        return v?.toInt();
      }
      if (Platform.isLinux || Platform.isMacOS) {
        final result = await Process.run('df', ['-Pk', path]);
        if (result.exitCode == 0) {
          final lines = (result.stdout as String).trim().split('\n');
          if (lines.length >= 2) return int.parse(lines.last.split(RegExp(r'\s+'))[3]) * 1024;
        }
      }
    } catch (_) {
      // unknown
    }
    return null;
  }

  /// Starts the packaged proot on this device and reports what happened (Android only; else null).
  Future<ProotReport?> prootCheck() async {
    if (!Platform.isAndroid) return null;
    try {
      final map = await _channel.invokeMapMethod<Object?, Object?>('prootCheck');
      return map == null ? null : ProotReport.fromMap(map);
    } catch (e) {
      return ProotReport(present: false, directory: '', files: const [], steps: const [], error: '$e');
    }
  }

  /// "Manufacturer Model" of the SoC (Android 12+), used to offer NPU builds only where they run.
  Future<String> soc() async {
    if (!Platform.isAndroid) return '';
    try {
      return await _channel.invokeMethod<String>('soc') ?? '';
    } catch (_) {
      return '';
    }
  }
}
