import 'dart:async';

import 'package:flutter/material.dart';

import '../core/protocol.dart' show ToolApproval;
import '../mcp/mcp_server.dart';
import '../services/app_controller.dart';
import 'app_scope.dart';
import 'arce_text_field.dart';
import 'svg_icons.dart';
import 'theme.dart';
import 'widgets.dart';

/// The MCP servers the chat may use; each one can be enabled on its own.
class McpSection extends StatelessWidget {
  const McpSection({super.key});

  @override
  Widget build(BuildContext context) {
    final app = ArceScope.of(context);
    return ListenableBuilder(
      listenable: app.settings,
      builder: (context, _) {
        final servers = app.settings.value.mcpServers;
        return ArceCard(
          child: Column(
            children: [
              if (servers.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Text(
                    'まだ MCP サーバーがありません。「追加」から URL を登録すると、その道具をチャットで使えます。',
                    style: ts(
                      context,
                      9.5,
                      color: context.c.muted,
                      height: 1.5,
                    ),
                  ),
                ),
              for (var i = 0; i < servers.length; i++)
                _ServerRow(
                  app: app,
                  server: servers[i],
                  last: i == servers.length - 1,
                ),
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Row(
                  children: [
                    SoftButton(
                      label: 'MCP サーバーを追加',
                      svg: ArceSvg.plus,
                      onTap: () => _edit(context, app, null),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Streamable HTTP の入口を登録します（例：https://api.githubcopilot.com/mcp/）。'
                  'トークンは端末の安全な領域に保存します。',
                  style: ts(context, 9, color: context.c.muted, height: 1.5),
                ),
              ),
              _OnDemand(app: app),
              if (app.settings.value.approvedTools.isNotEmpty) _ApprovedTools(app: app),
            ],
          ),
        );
      },
    );
  }

  static Future<void> _edit(
    BuildContext context,
    AppController app,
    McpServerConfig? existing,
  ) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.c.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (context) => _ServerEditor(app: app, existing: existing),
    );
  }
}

class _ServerRow extends StatelessWidget {
  const _ServerRow({
    required this.app,
    required this.server,
    required this.last,
  });

  final AppController app;
  final McpServerConfig server;
  final bool last;

  Future<void> _confirmDelete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(server.name.isEmpty ? server.id : server.name),
        content: const Text('この MCP サーバーと、保存したトークンを削除します。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('やめる'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await app.settings.update(
      (s) => s.copyWith(
        mcpServers: [
          for (final item in s.mcpServers)
            if (item.id != server.id) item,
        ],
      ),
    );
    await app.settings.forgetMcpToken(server.id);
    // a secret whose value was this server's token has nothing to read any more
    for (final secret in app.settings.value.shellSecrets.where((s) => s.mcpServerId == server.id).toList()) {
      await app.settings.removeShellSecret(secret.name);
    }
    app.showToast('削除しました');
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 1),
      decoration: BoxDecoration(
        border: last ? null : Border(bottom: BorderSide(color: c.line)),
      ),
      child: Row(
        children: [
          ArceIcon(
            ArceSvg.bolt,
            size: 16,
            color: server.enabled ? c.accent : c.muted,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        server.name.isEmpty ? server.id : server.name,
                        overflow: TextOverflow.ellipsis,
                        style: ts(
                          context,
                          12,
                          weight: FontWeight.w700,
                          color: server.enabled ? c.ink : c.muted,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    StatusLabel(
                      server.enabled ? '有効' : '無効',
                      color: server.enabled ? c.green : c.muted,
                      background: server.enabled ? c.greenSoft : c.surface2,
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  server.url,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ts(context, 9, color: c.muted),
                ),
                if (app.settings.mcpTokenOf(server.id).isEmpty)
                  Text('トークン未設定', style: ts(context, 9, color: c.amber)),
              ],
            ),
          ),
          SoftButton(
            label: '確認',
            height: 28,
            onTap: () async => app.showToast(await app.probeMcp(server.id)),
          ),
          const SizedBox(width: 6),
          SoftButton(
            label: '編集',
            height: 28,
            onTap: () => McpSection._edit(context, app, server),
          ),
          const SizedBox(width: 6),
          IconTap(
            svg: ArceSvg.close,
            onTap: () => _confirmDelete(context),
            tooltip: '削除',
            size: 15,
          ),
        ],
      ),
    );
  }
}

class _ServerEditor extends StatefulWidget {
  const _ServerEditor({required this.app, this.existing});

  final AppController app;
  final McpServerConfig? existing;

  @override
  State<_ServerEditor> createState() => _ServerEditorState();
}

class _ServerEditorState extends State<_ServerEditor> {
  late final TextEditingController _name = TextEditingController(
    text: widget.existing?.name ?? '',
  );
  late final TextEditingController _url = TextEditingController(
    text: widget.existing?.url ?? '',
  );
  late final TextEditingController _token = TextEditingController(
    text: widget.existing == null
        ? ''
        : widget.app.settings.mcpTokenOf(widget.existing!.id),
  );
  late bool _enabled = widget.existing?.enabled ?? true;
  late bool _approveWrites = widget.existing?.approveWrites ?? true;

  /// Ready-made servers: the address and what the token is. The tools a server offers (and which of
  /// them write) are asked of the server itself.
  static const _presets = <(String, String, String)>[
    ('Kaggle', 'https://www.kaggle.com/mcp', 'Kaggle の設定 → API の「Generate New Token」で作ったトークン'),
    ('GitHub', 'https://api.githubcopilot.com/mcp/', 'GitHub の個人用アクセストークン'),
  ];

  @override
  void dispose() {
    for (final controller in [_name, _url, _token]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final label = _name.text.trim();
    final url = _url.text.trim();
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      widget.app.showToast('URL は http(s) で入れてください');
      return;
    }
    final existing = widget.existing;
    final server = McpServerConfig(
      id:
          existing?.id ??
          McpServers.idFor(label, widget.app.settings.value.mcpServers),
      name: label.isEmpty ? 'MCP' : label,
      url: url,
      enabled: _enabled,
      approveWrites: _approveWrites,
    );
    await widget.app.settings.update(
      (s) => s.copyWith(
        mcpServers: [
          for (final item in s.mcpServers)
            if (item.id != server.id) item,
          server,
        ],
      ),
    );
    await widget.app.settings.setMcpToken(server.id, _token.text);
    if (!mounted) return;
    final app = widget.app;
    Navigator.of(context).pop();
    app.showToast('${server.name} を保存しました。ツール一覧を取得しています…');
    // saved: the server is asked what it offers at once, so the user sees what it adds to every
    // request (and a warning when that is too much for the model in use)
    if (server.enabled) unawaited(app.probeMcp(server.id).then(app.showToast));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: sheetBottomPadding(context),
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.existing == null ? 'MCP サーバーを追加' : 'MCP サーバーを編集',
              style: ts(context, 14, weight: FontWeight.w700),
            ),
            if (widget.existing == null) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                children: [
                  for (final preset in _presets)
                    ActionChip(
                      label: Text('${preset.$1} を入れる'),
                      onPressed: () => setState(() {
                        _name.text = preset.$1;
                        _url.text = preset.$2;
                        widget.app.showToast('トークン: ${preset.$3}');
                      }),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            _field('名前', _name, 'GitHub / 自宅のサーバー'),
            _field('URL', _url, 'https://...', keyboard: TextInputType.url),
            ListenableBuilder(listenable: _url, builder: (context, _) => ClearTextWarning(url: _url.text, what: 'トークン')),
            _field('トークン', _token, 'Bearer で送ります（端末の安全な領域に保存）', obscure: true),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                'このサーバーを使う',
                style: ts(context, 11, weight: FontWeight.w600),
              ),
              subtitle: Text(
                'オフの間は道具がチャットに出ません',
                style: ts(context, 9, color: c.muted),
              ),
              value: _enabled,
              onChanged: (v) => setState(() => _enabled = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                '書き込みの前に確認する',
                style: ts(context, 11, weight: FontWeight.w600),
              ),
              subtitle: Text(
                'push など外に作用する道具は、承認したときだけ実行します',
                style: ts(context, 9, color: c.muted),
              ),
              value: _approveWrites,
              onChanged: (v) => setState(() => _approveWrites = v),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                SoftButton(
                  label: '接続を確かめる',
                  svg: ArceSvg.shield,
                  onTap: () async {
                    final id = widget.existing?.id;
                    if (id == null) {
                      widget.app.showToast('保存してから確認してください');
                      return;
                    }
                    widget.app.showToast(await widget.app.probeMcp(id));
                  },
                ),
                const SizedBox(width: 8),
                PrimaryButton(label: '保存', onTap: _save),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _field(
    String label,
    TextEditingController controller,
    String hint, {
    bool obscure = false,
    TextInputType? keyboard,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: ArceTextField(
      controller: controller,
      obscure: obscure,
      keyboardType: keyboard,
      style: ts(context, 12),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
    ),
  );
}

/// The tools the user chose not to be asked about again, each with a button that takes it out.
class _ApprovedTools extends StatelessWidget {
  const _ApprovedTools({required this.app});

  final AppController app;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final names = app.settings.value.approvedTools;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('確認しない道具', style: ts(context, 11, weight: FontWeight.w700)),
        Padding(
          padding: const EdgeInsets.only(top: 3, bottom: 6),
          child: Text(
            '承認カードで「この道具は次から確認しない」を選んだ道具です。外すと、また確認します。'
            'チャットからは変えられません（メッセージで確認を切られないため）。',
            style: ts(context, 9, color: c.muted, height: 1.5),
          ),
        ),
        for (final name in names)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(children: [
              Expanded(child: Text(ToolApproval.label(name), style: ts(context, 11, color: c.ink))),
              IconTap(
                svg: ArceSvg.close,
                tooltip: '外す（また確認する）',
                onTap: () => app.settings.update((s) => s.copyWith(approvedTools: [for (final t in s.approvedTools) if (t != name) t])),
              ),
            ]),
          ),
      ]),
    );
  }
}

/// How the MCP tools reach the model: every definition in every request, or three small tools that
/// look a tool up when it is needed (so a server with dozens of tools does not fill the context).
class _OnDemand extends StatelessWidget {
  const _OnDemand({required this.app});

  final AppController app;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final s = app.settings.value;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text('道具が多いときは、探して呼ぶ', style: ts(context, 11, weight: FontWeight.w700))),
          ArceSwitch(value: s.mcpOnDemand, onChanged: (v) => app.settings.update((x) => x.copyWith(mcpOnDemand: v))),
        ]),
        Padding(
          padding: const EdgeInsets.only(top: 3, bottom: 6),
          child: Text(
            'MCP の道具の定義が合わせて ${s.mcpOnDemandTokens == 0 ? '0' : '約 ${s.mcpOnDemandTokens}'} トークンを超えるとき、毎回の送信に定義を載せず、'
            'モデルに mcp_find（探す）・mcp_describe（定義を読む）・mcp_call（呼ぶ）の 3 つだけを渡します。'
            'モデルは、必要になった道具をそのとき探して呼びます（送る文が小さくなります）。'
            '書き込みの確認と「次から確認しない」は、呼んだ道具そのものに効きます。'
            '小さなモデルは、探してから呼ぶ手順を守れないことがあります。そのときはオフにしてください。',
            style: ts(context, 9, color: c.muted, height: 1.5),
          ),
        ),
        Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text('この大きさを超えたら', style: ts(context, 10, color: c.muted)),
          for (final v in const [0, 1000, 2000, 5000, 10000])
            ChoiceChip(
              label: Text(v == 0 ? '常に' : '$v'),
              selected: s.mcpOnDemandTokens == v,
              onSelected: (_) => app.settings.update((x) => x.copyWith(mcpOnDemandTokens: v)),
            ),
        ]),
      ]),
    );
  }
}
