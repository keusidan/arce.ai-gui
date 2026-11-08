import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/model_catalog.dart';
import '../services/app_controller.dart';
import '../services/model_manager.dart';
import 'app_scope.dart';
import 'chat_widgets.dart';
import 'svg_icons.dart';
import 'theme.dart';
import 'widgets.dart';

class ModelsPage extends StatefulWidget {
  const ModelsPage({super.key});

  @override
  State<ModelsPage> createState() => _ModelsPageState();
}

class _ModelsPageState extends State<ModelsPage> {
  final _fits = <String, bool>{};
  AppController? _app;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = ArceScope.of(context);
    if (_app != app) {
      _app = app;
      _checkFits();
    }
  }

  Future<void> _checkFits() async {
    final app = _app!;
    for (final spec in app.models.catalog) {
      final ok = await app.models.fits(spec);
      if (!mounted) return;
      setState(() => _fits[spec.id] = ok);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = ArceScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([app.models, app.settings]),
      builder: (context, _) {
        final models = app.models;
        final c = context.c;
        final loaded = models.isLoaded;
        final forced = app.settings.value.forceExecution;
        final extras = [
          for (final f in models.installed)
            if (ModelCatalog.byFileName(f.uri.pathSegments.last) == null) f,
        ];
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(14, 16, 14, 24),
          child: PageColumn(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const PageHeading('モデル管理', '端末で使うローカルAIモデルを選択します。'),
              if (!models.supported)
                _Alert(
                  title: 'このOSでは、モデルを読み込めません',
                  text: 'ローカルモデルのダウンロード・ファイルからの追加・整合性の確認・削除はできます。読み込み（推論）は Android 版だけです。このOSの会話は、オンラインモデルかデモ応答です。',
                  tone: BannerTone.info,
                )
              else if (!loaded && models.busy == null)
                _Alert(
                  title: 'モデルが読み込まれていません',
                  text: '「基本モデルを追加」で小さなモデルを取得して、すぐに会話を始められます。',
                  tone: BannerTone.info,
                ),
              ArceCard(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    _Cube(),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('現在の実行状態', style: ts(context, 12, weight: FontWeight.w700)),
                        const SizedBox(height: 4),
                        Text(
                          loaded
                              ? '${models.loadedName} · ${models.backend ?? ''}'
                              : 'ローカルモデル未導入 · デモ応答のみ',
                          style: ts(context, 10, color: c.muted),
                        ),
                      ]),
                    ),
                    StatusLabel(loaded ? '接続済み' : '未接続', color: loaded ? c.green : c.muted, background: loaded ? c.greenSoft : c.surface2),
                  ]),
                  if (models.busy != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Row(children: [
                        const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                        const SizedBox(width: 8),
                        Expanded(child: Text(models.busy!, style: ts(context, 10.5, color: c.muted))),
                      ]),
                    ),
                  if (models.error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(models.error!, style: ts(context, 10.5, color: c.red, height: 1.5)),
                    ),
                  if (!loaded && models.busy == null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: PrimaryButton(
                        label: '${models.supported ? '基本モデルを追加' : '基本モデルをダウンロード'}（${models.basic.displayName}・約${formatGb(models.basic.fileBytes)}）',
                        svg: ArceSvg.bolt,
                        height: 40,
                        onTap: models.addBasicModel,
                      ),
                    ),
                  if (loaded)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Align(alignment: Alignment.centerLeft, child: SoftButton(label: 'モデルを解放', onTap: models.unload)),
                    ),
                ]),
              ),
              if (models.memoryWarning != null) _MemoryWarningCard(models: models),
              Padding(
                padding: const EdgeInsets.fromLTRB(2, 18, 2, 9),
                child: Row(children: [
                  Text('対応モデル', style: ts(context, 12, weight: FontWeight.w700)),
                  const SizedBox(width: 10),
                  Expanded(child: Text('Qwen3 · GGUF / LiteRT-LM', textAlign: TextAlign.end, style: ts(context, 10, color: c.muted))),
                ]),
              ),
              for (final spec in models.catalog)
                _ModelCard(
                  models: models,
                  spec: spec,
                  fits: forced || (_fits[spec.id] ?? true),
                ),
              for (final file in extras) _ImportedCard(models: models, file: file),
              Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 10),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: SoftButton(
                      label: 'ファイルから追加（.gguf / .litertlm）',
                      svg: ArceSvg.plus,
                      onTap: () async {
                        final file = await FilePicker.pickFile(type: FileType.any);
                        final path = file?.path;
                        if (path == null) return;
                        if (!path.endsWith('.gguf') && !path.endsWith('.litertlm')) {
                          app.showToast('.gguf または .litertlm のファイルを選んでください');
                          return;
                        }
                        await models.import(path);
                      },
                    ),
                  ),
                ),
              const InfoBox('モデルのサイズ・RAM使用量は量子化方式や設定によって変わります。ダウンロードしたモデルはこの端末に保存され、アプリをアンインストールすると消えます。'),
            ]),
          ),
        );
      },
    );
  }
}

class _Cube extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(color: context.c.accentSoft, borderRadius: BorderRadius.circular(13)),
        alignment: Alignment.center,
        child: ArceIcon(ArceSvg.cube, size: 23, color: context.c.accent),
      );
}

class _Alert extends StatelessWidget {
  const _Alert({required this.title, required this.text, this.tone = BannerTone.warning});
  final String title;
  final String text;
  final BannerTone tone;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final (bg, fg) = tone == BannerTone.warning ? (c.amberSoft, c.amber) : (c.accentSoft, c.accent);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(13)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.only(top: 1), child: ArceIcon(ArceSvg.alert, size: 18, color: fg)),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: ts(context, 11, weight: FontWeight.w700, color: fg)),
            const SizedBox(height: 3),
            Text(text, style: ts(context, 10, color: fg.withValues(alpha: .9), height: 1.6)),
          ]),
        ),
      ]),
    );
  }
}

class _MemoryWarningCard extends StatelessWidget {
  const _MemoryWarningCard({required this.models});
  final ModelManager models;

  @override
  Widget build(BuildContext context) {
    final w = models.memoryWarning!;
    final c = context.c;
    return ArceCard(
      color: c.amberSoft,
      borderColor: Colors.transparent,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('メモリが足りない可能性があります', style: ts(context, 12, weight: FontWeight.w700, color: c.amber)),
        const SizedBox(height: 6),
        Text(
          '${w.file.uri.pathSegments.last} の推定使用量は ${formatGb(w.estimatedBytes)}、空きメモリは ${formatGb(w.availableBytes)} です。'
          '設定は自動では変更しません。続けるか、コンテキスト長などを下げてからやり直してください。',
          style: ts(context, 10.5, color: c.amber, height: 1.6),
        ),
        const SizedBox(height: 10),
        Row(children: [
          SoftButton(label: 'キャンセル', onTap: models.dismissMemoryWarning),
          const SizedBox(width: 8),
          PrimaryButton(label: 'このまま読み込む', onTap: () => models.load(w.file, confirmed: true)),
        ]),
      ]),
    );
  }
}

class _ModelCard extends StatelessWidget {
  const _ModelCard({required this.models, required this.spec, required this.fits});

  final ModelManager models;
  final ModelSpec spec;
  final bool fits;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final app = ArceScope.of(context);
    final file = models.fileOf(spec);
    final selected = models.loadedPath == file.path;
    final state = models.downloadStateOf(spec);
    final ctx = app.settings.value.contextLength;
    final ram = MemoryEstimator.totalBytes(spec, ctx, app.settings.value.kvCache);
    // a download works on every platform; loading (the button of an installed model) only where the engine runs
    final usable = fits || state is DownloadInstalled;
    return Opacity(
      opacity: fits ? 1 : .55,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: selected ? c.accent : c.line),
          boxShadow: selected ? [BoxShadow(color: c.accent.withValues(alpha: .12), spreadRadius: 2)] : null,
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(color: c.accentSoft, borderRadius: BorderRadius.circular(11)),
              alignment: Alignment.center,
              child: ArceIcon(ArceSvg.cube, size: 20, color: c.accent),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(spec.displayName, style: ts(context, 12, weight: FontWeight.w700)),
                const SizedBox(height: 3),
                Text(
                  '${formatGb(spec.fileBytes)} · 推定RAM ${formatGb(ram)}（ctx $ctx）\n'
                  '${spec.format == ModelFormat.gguf ? 'GGUF · llama.cpp' : 'LiteRT-LM'}${spec.npuSoc != null ? ' · NPU' : ''}'
                  '${fits ? '' : '\nこの端末のメモリでは動作しない可能性があります（強制実行で解除）'}',
                  style: ts(context, 10, color: c.muted, height: 1.5),
                ),
              ]),
            ),
            const SizedBox(width: 8),
            _action(context, state, selected, usable, file),
          ]),
          if (state is DownloadRunning) ...[
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value: state.total == 0 ? null : (state.done / state.total).clamp(0.0, 1.0),
              minHeight: 4,
              borderRadius: BorderRadius.circular(2),
              backgroundColor: c.surface3,
            ),
            const SizedBox(height: 4),
            Text('${formatGb(state.done)} / ${formatGb(state.total)}', style: ts(context, 9.5, color: c.muted)),
          ],
          if (state is DownloadPaused && state.reason != null)
            Padding(padding: const EdgeInsets.only(top: 8), child: Text(state.reason!, style: ts(context, 10, color: c.red, height: 1.5))),
          if (state is DownloadFailed)
            Padding(padding: const EdgeInsets.only(top: 8), child: Text(state.reason, style: ts(context, 10, color: c.red, height: 1.5))),
        ]),
      ),
    );
  }

  Widget _action(BuildContext context, DownloadState state, bool selected, bool usable, File file) {
    final c = context.c;
    switch (state) {
      case DownloadInstalled():
        return Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          SoftButton(
            label: selected ? '使用中' : (models.supported ? '読み込み' : 'Android のみ'),
            onTap: !models.supported || selected ? null : () => models.load(file),
          ),
          if (!selected)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                _TextAction('整合性', () => models.verify(spec)),
                const SizedBox(width: 10),
                _TextAction('削除', () => models.delete(file)),
              ]),
            ),
        ]);
      case DownloadRunning():
        return SoftButton(label: '一時停止', onTap: () => models.pauseDownload(spec));
      case DownloadPaused():
        return Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          PrimaryButton(label: '再開', onTap: () => models.startDownload(spec)),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: _TextAction('破棄', () => models.discardPartial(spec)),
          ),
        ]);
      case DownloadVerifying():
        return Row(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 6),
          Text('確認中', style: ts(context, 10, color: c.muted)),
        ]);
      case DownloadFailed():
        return PrimaryButton(label: '再試行', onTap: usable ? () => models.startDownload(spec) : null);
      case DownloadIdle():
        return PrimaryButton(label: 'ダウンロード', onTap: usable ? () => models.startDownload(spec) : null);
    }
  }
}

class _ImportedCard extends StatelessWidget {
  const _ImportedCard({required this.models, required this.file});
  final ModelManager models;
  final File file;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final name = file.uri.pathSegments.last;
    final selected = models.loadedPath == file.path;
    return ArceCard(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      borderColor: selected ? c.accent : null,
      radius: 14,
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, style: ts(context, 12, weight: FontWeight.w700)),
            const SizedBox(height: 3),
            Text('取り込み済みのファイル', style: ts(context, 10, color: c.muted)),
          ]),
        ),
        SoftButton(
          label: selected ? '使用中' : (models.supported ? '読み込み' : 'Android のみ'),
          onTap: selected || !models.supported ? null : () => models.load(file),
        ),
        const SizedBox(width: 8),
        if (!selected) _TextAction('削除', () => models.delete(file)),
      ]),
    );
  }
}

class _TextAction extends StatelessWidget {
  const _TextAction(this.label, this.onTap);
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Text(label, style: ts(context, 10, weight: FontWeight.w600, color: context.c.accent)),
      );
}
