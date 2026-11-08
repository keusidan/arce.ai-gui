import 'package:flutter/material.dart';

import '../core/releases.dart';
import '../services/update_service.dart';
import 'app_scope.dart';
import 'svg_icons.dart';
import 'theme.dart';
import 'widgets.dart';

String _mb(int bytes) => '${(bytes / 1e6).toStringAsFixed(1)} MB';

/// The whole update flow in one card: check, release notes, download, install.
class UpdateCard extends StatelessWidget {
  const UpdateCard({super.key});

  @override
  Widget build(BuildContext context) {
    final updates = ArceScope.of(context).updates;
    return ListenableBuilder(
      listenable: updates,
      builder: (context, _) {
        final c = context.c;
        final state = updates.state;
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(
                '現在のバージョン  v${updates.currentVersion ?? '—'}',
                style: ts(context, 11, weight: FontWeight.w600),
              ),
            ),
            if (state is! UpdateChecking && state is! UpdateDownloading)
              SoftButton(label: '更新を確認', svg: ArceSvg.retry, onTap: updates.check),
          ]),
          const SizedBox(height: 10),
          switch (state) {
            UpdateIdle() => Text('GitHub のリリースから新しい版を探します。', style: ts(context, 10, color: c.muted)),
            UpdateChecking() => Row(children: [
                const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 8),
                Text('確認しています…', style: ts(context, 10.5, color: c.muted)),
              ]),
            UpdateUpToDate() => Row(children: [
                ArceIcon(ArceSvg.check, size: 14, color: c.green),
                const SizedBox(width: 6),
                Text('最新の版です', style: ts(context, 11, weight: FontWeight.w600, color: c.green)),
              ]),
            UpdateAvailable(:final release) => _Available(release: release, updates: updates),
            UpdateDownloading(:final release, :final done, :final total) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${release.tag} をダウンロード中…', style: ts(context, 11, weight: FontWeight.w600)),
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  value: total == 0 ? null : (done / total).clamp(0.0, 1.0),
                  minHeight: 4,
                  borderRadius: BorderRadius.circular(2),
                  backgroundColor: c.surface3,
                ),
                const SizedBox(height: 4),
                Text('${_mb(done)} / ${_mb(total)}', style: ts(context, 9.5, color: c.muted)),
              ]),
            UpdateReady(:final release) => _Ready(release: release, updates: updates),
            UpdateFailed(:final reason) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(reason, style: ts(context, 10.5, color: c.red, height: 1.6)),
              ]),
          },
        ]);
      },
    );
  }
}

class _Available extends StatelessWidget {
  const _Available({required this.release, required this.updates});
  final Release release;
  final UpdateService updates;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final isIos = UpdateService.target == UpdateTarget.ios;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        StatusLabel('新しい版', color: c.accent, background: c.accentSoft),
        const SizedBox(width: 8),
        Text(release.tag, style: ts(context, 13, weight: FontWeight.w700)),
      ]),
      if (release.notes.trim().isNotEmpty)
        Container(
          width: double.infinity,
          constraints: const BoxConstraints(maxHeight: 130),
          margin: const EdgeInsets.only(top: 8),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: c.surface2, borderRadius: BorderRadius.circular(10)),
          child: SingleChildScrollView(child: Text(release.notes.trim(), style: ts(context, 10, color: c.muted, height: 1.6))),
        ),
      const SizedBox(height: 10),
      Wrap(spacing: 8, runSpacing: 8, children: [
        PrimaryButton(label: isIos ? 'リリースページを開く' : 'ダウンロードして更新', onTap: updates.download),
        SoftButton(label: 'リリースページ', onTap: () => updates.openReleasePage(release)),
      ]),
    ]);
  }
}

class _Ready extends StatelessWidget {
  const _Ready({required this.release, required this.updates});
  final Release release;
  final UpdateService updates;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return FutureBuilder<bool>(
      future: updates.canInstall(),
      builder: (context, snapshot) {
        final allowed = snapshot.data ?? true;
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            ArceIcon(ArceSvg.check, size: 14, color: c.green),
            const SizedBox(width: 6),
            Text('${release.tag} をダウンロードしました（SHA-256 確認済み）', style: ts(context, 11, weight: FontWeight.w600, color: c.green)),
          ]),
          const SizedBox(height: 4),
          Text(
            allowed ? 'インストールするとアプリが再起動します。' : '先に、このアプリにアプリのインストールを許可してください。',
            style: ts(context, 10, color: c.muted, height: 1.6),
          ),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (allowed)
              PrimaryButton(label: '今すぐインストール', onTap: updates.install)
            else
              PrimaryButton(label: '許可の設定を開く', onTap: updates.requestInstallPermission),
            SoftButton(label: '後で', onTap: updates.dismiss),
          ]),
        ]);
      },
    );
  }
}

/// A slim notice above the page when a newer version is out.
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({super.key, required this.onOpen});
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final app = ArceScope.of(context);
    return ListenableBuilder(
      listenable: app.updates,
      builder: (context, _) {
        final state = app.updates.state;
        if (state is! UpdateAvailable && state is! UpdateReady) return const SizedBox.shrink();
        final c = context.c;
        final tag = state is UpdateAvailable ? state.release.tag : (state as UpdateReady).release.tag;
        return Material(
          color: c.accentSoft,
          child: InkWell(
            onTap: onOpen,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              child: Row(children: [
                ArceIcon(ArceSvg.bolt, size: 14, color: c.accent),
                const SizedBox(width: 8),
                Expanded(child: Text('ARCE.AI $tag があります。タップして内容を確認', style: ts(context, 11, weight: FontWeight.w600, color: c.accent))),
                IconTap(svg: ArceSvg.close, size: 14, color: c.accent, onTap: app.updates.dismiss),
              ]),
            ),
          ),
        );
      },
    );
  }
}
