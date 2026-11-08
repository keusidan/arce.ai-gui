import 'dart:io';

import 'package:arce_ai/core/model_catalog.dart';
import 'package:arce_ai/engine/native_engine.dart';
import 'package:arce_ai/services/device_info.dart';
import 'package:arce_ai/services/foreground_service.dart';
import 'package:arce_ai/services/model_manager.dart';
import 'package:arce_ai/services/segmented_download.dart';
import 'package:arce_ai/services/settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory support;
  final spec = ModelCatalog.basic;

  setUp(() async => support = await Directory.systemTemp.createTemp('arce_restore'));
  tearDown(() => support.delete(recursive: true));

  Future<ModelManager> open() async {
    SharedPreferences.setMockInitialValues({});
    return ModelManager.create(
      engine: NativeEngine(),
      settings: await SettingsStore.load(),
      device: DeviceInfoService(),
      foreground: ForegroundService(),
      supportDirectory: support,
    );
  }

  File target(String suffix) => File('${support.path}/models/${spec.fileName}$suffix');

  test('a model that was left half downloaded shows as paused with its bytes', () async {
    await target('.part').create(recursive: true);
    await target('.part').writeAsBytes(List.filled(1234, 1));

    final manager = await open();

    final state = manager.downloadStateOf(spec);
    expect(state, isA<DownloadPaused>());
    expect((state as DownloadPaused).done, 1234);
    expect(manager.interrupted, isEmpty, reason: 'no marker: it was paused, not cut off');
  });

  test('the parts of a download over several connections count too', () async {
    await target('.part.seg0of2').create(recursive: true);
    await target('.part.seg0of2').writeAsBytes(List.filled(500, 1));
    await target('.part.seg1of2').writeAsBytes(List.filled(300, 1));
    expect(await SegmentedDownload.storedBytes(target('.part')), 800);

    final manager = await open();

    expect((manager.downloadStateOf(spec) as DownloadPaused).done, 800);
  });

  test('a download that was running when the app closed is listed to be resumed', () async {
    await target('.running').create(recursive: true);

    final manager = await open();

    expect(manager.interrupted.map((s) => s.id), [spec.id]);
    expect(manager.downloadStateOf(spec), isA<DownloadPaused>());
  });

  test('an installed model, and a model with nothing on disk, are left alone', () async {
    await target('').create(recursive: true);
    await target('').writeAsBytes([1, 2, 3]);
    await target('.running').writeAsString('');

    final manager = await open();
    expect(manager.interrupted, isEmpty);
    expect(manager.downloadStateOf(spec), isA<DownloadInstalled>());

    await target('').delete();
    await target('.running').delete();
    final empty = await open();
    expect(empty.downloadStateOf(spec), isA<DownloadIdle>());
  });

  test('the notification kind of a model download is the one the service knows', () {
    expect(ForegroundReason.modelDownload.name, 'modelDownload');
  });
}
