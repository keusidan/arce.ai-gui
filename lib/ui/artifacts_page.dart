import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/artifacts.dart';
import 'app_scope.dart';
import 'chat_widgets.dart';
import 'svg_icons.dart';
import 'theme.dart';
import 'widgets.dart';

const _sampleHtml = '''<!doctype html>
<html lang="ja">
<head><meta charset="utf-8"><title>今日のタスク</title></head>
<body style="font-family:sans-serif;padding:24px">
  <main>
    <h1>今日のタスクを、すっきり整理。</h1>
    <p>小さく分けて、ひとつずつ進めましょう。</p>
    <button>タスクを追加</button>
  </main>
</body>
</html>''';

class ArtifactsPage extends StatelessWidget {
  const ArtifactsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = ArceScope.of(context);
    return ListenableBuilder(
      listenable: app.chat,
      builder: (context, _) {
        final items = Artifacts.extract(app.chat.state.messages).reversed.toList();
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(14, 16, 14, 24),
          child: PageColumn(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const PageHeading('生成物', '会話の中で作られたコードやHTMLをまとめて確認できます。'),
              if (items.isEmpty) ...[
                _ArtifactCard(
                  title: '生成物のサンプル',
                  meta: 'UIプレビュー · HTML',
                  code: _sampleHtml,
                  fileName: 'index.html',
                  isHtml: true,
                  sample: true,
                ),
                ArceCard(
                  padding: const EdgeInsets.all(22),
                  child: SizedBox(
                    width: double.infinity,
                    child: Column(children: [
                      Container(
                        width: 54,
                        height: 54,
                        decoration: BoxDecoration(color: context.c.surface2, borderRadius: BorderRadius.circular(17)),
                        alignment: Alignment.center,
                        child: ArceIcon(ArceSvg.sun, size: 25, color: context.c.muted),
                      ),
                      const SizedBox(height: 12),
                      Text('生成物はここに保存されます', style: ts(context, 13, weight: FontWeight.w700)),
                      const SizedBox(height: 6),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 260),
                        child: Text(
                          'モデルが書いたコードやHTMLは、会話が終わるとここに並びます。',
                          textAlign: TextAlign.center,
                          style: ts(context, 10, color: context.c.muted, height: 1.7),
                        ),
                      ),
                    ]),
                  ),
                ),
              ] else
                for (final item in items)
                  _ArtifactCard(
                    title: item.title,
                    meta: '${item.fileName} · ${item.language}',
                    code: item.code,
                    fileName: item.fileName,
                    isHtml: item.isHtml,
                  ),
            ]),
          ),
        );
      },
    );
  }
}

class _ArtifactCard extends StatelessWidget {
  const _ArtifactCard({
    required this.title,
    required this.meta,
    required this.code,
    required this.fileName,
    required this.isHtml,
    this.sample = false,
  });

  final String title;
  final String meta;
  final String code;
  final String fileName;
  final bool isHtml;
  final bool sample;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final app = ArceScope.of(context);
    final lines = code.split('\n');
    final excerpt = lines.take(7).join('\n');
    return ArceCard(
      padding: EdgeInsets.zero,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
          child: Row(children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(color: c.accentSoft, borderRadius: BorderRadius.circular(10)),
              alignment: Alignment.center,
              child: ArceIcon(isHtml ? ArceSvg.window : ArceSvg.code, size: 18, color: c.accent),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(context, 12, weight: FontWeight.w700)),
                const SizedBox(height: 3),
                Text(meta, style: ts(context, 10, color: c.muted)),
              ]),
            ),
            if (sample) const StatusLabel('サンプル'),
          ]),
        ),
        Container(
          width: double.infinity,
          margin: const EdgeInsets.symmetric(horizontal: 10),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: c.surface2, borderRadius: BorderRadius.circular(11), border: Border.all(color: c.line)),
          child: Text(
            excerpt + (lines.length > 7 ? '\n…' : ''),
            style: ts(context, 11, color: c.muted, height: 1.5, family: 'monospace'),
            maxLines: 8,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(14),
          child: Wrap(spacing: 7, runSpacing: 7, children: [
            if (isHtml) PrimaryButton(label: 'プレビュー', svg: ArceSvg.eye, onTap: () => previewHtml(context, code)),
            SoftButton(label: 'コピー', svg: ArceSvg.copy, onTap: () => copyToClipboard(context, code)),
            if (!sample)
              SoftButton(
                label: '保存',
                svg: ArceSvg.file,
                onTap: () async {
                  final saved = await FilePicker.saveFile(fileName: fileName, bytes: utf8.encode(code));
                  if (saved != null) app.showToast('保存しました');
                },
              ),
          ]),
        ),
      ]),
    );
  }
}
