import 'package:flutter/material.dart';

import '../services/app_controller.dart';
import 'svg_icons.dart';
import 'theme.dart';
import 'widgets.dart';

/// "Linux 環境（試験）": a button that starts the packaged proot once and shows what came back.
/// Only for Android; the Linux environment itself (a root file system, `run_command`) comes later.
class ProotCheckRow extends StatefulWidget {
  const ProotCheckRow({super.key, required this.app});

  final AppController app;

  @override
  State<ProotCheckRow> createState() => _ProotCheckRowState();
}

class _ProotCheckRowState extends State<ProotCheckRow> {
  bool _busy = false;
  String? _report;

  Future<void> _run() async {
    setState(() => _busy = true);
    final report = await widget.app.device.prootCheck();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _report = report?.describe() ?? 'この端末（OS）では確認できません';
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SettingRow(
        icon: ArceSvg.codeEdit,
        title: 'Linux 環境（試験）：proot の確認',
        subtitle: 'アプリに入れた proot を 1 回起動して、この端末で動くかを確かめます（何も変更しません）',
        last: _report == null,
        trailing: SoftButton(label: _busy ? '確認中…' : '確かめる', height: 30, onTap: _busy ? null : _run),
      ),
      if (_report != null)
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          margin: const EdgeInsets.only(top: 4, bottom: 6),
          decoration: BoxDecoration(color: c.surface2, borderRadius: BorderRadius.circular(10), border: Border.all(color: c.line)),
          child: SelectableText(_report!, style: ts(context, 10, color: c.ink, height: 1.55)),
        ),
    ]);
  }
}
