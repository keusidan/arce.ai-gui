import 'package:flutter/material.dart';

import '../core/secret_book.dart';
import '../core/secret_placeholders.dart';
import '../core/shell_secrets.dart';
import '../services/app_controller.dart';
import '../services/settings.dart';
import 'arce_text_field.dart';
import 'svg_icons.dart';
import 'theme.dart';
import 'widgets.dart';

/// How a list of hosts is typed and checked (one per line, or separated by commas or spaces).
abstract final class SecretHostsInput {
  /// The entries of [text], trimmed, without empty ones and repeats.
  static List<String> parse(String text) {
    final out = <String>[];
    for (final part in text.split(RegExp(r'[\s,;]+'))) {
      final entry = part.trim();
      if (entry.isNotEmpty && !out.contains(entry)) out.add(entry);
    }
    return out;
  }

  /// The first entry that is not a host (`api.example.com`, `*.example.com`, `*`, or an address written as a
  /// URL), or null when all are.
  static String? firstInvalid(List<String> hosts) {
    for (final entry in hosts) {
      if (entry == '*') continue;
      if (entry.contains('://')) {
        if (SecretHosts.normalizeHost(Uri.tryParse(entry)?.host ?? '') == null) return entry;
        continue;
      }
      final bare = entry.startsWith('*.') ? entry.substring(2) : entry;
      if (SecretHosts.normalizeHost(bare) == null || bare.contains('*')) return entry;
    }
    return null;
  }
}

/// What kind of item a secret is, in words.
String secretKindLabel(SecretKind kind) => switch (kind) {
      SecretKind.own => '入力した値',
      SecretKind.provider => 'プロバイダの API キー',
      SecretKind.mcp => 'MCP サーバーのトークン',
      SecretKind.search => '検索 API のキー',
      SecretKind.github => 'GitHub のトークン',
    };

/// The secrets of the app (settings → Linux 環境), every item that holds a key or a token, each with an id
/// made from its name: a model writes `{{secret:ID}}` and the app puts the value in at the moment of use, only
/// for the hosts the secret is bound to. The screen never shows a value.
class ShellSecretsCard extends StatelessWidget {
  const ShellSecretsCard({super.key, required this.app});

  final AppController app;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return ListenableBuilder(
      listenable: Listenable.merge([app.settings, app.providers]),
      builder: (context, _) {
        final entries = app.secretBook().entries;
        final aliases = [for (final secret in app.settings.value.shellSecrets) if (secret.fromMcp) secret];
        return ArceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('秘密（モデルが {{secret:ID}} で使う）', style: ts(context, 12, weight: FontWeight.w700)),
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 8),
                child: Text(
                  'GitHub のトークンなどを、コマンドの環境変数として渡せます（例：git push、gh、npm publish）。'
                  'API キーやトークンを持つ項目には、名前から作った id が付きます。モデルは、キーの値を見ずに、'
                  '`{{secret:id}}` と書くだけで、API を呼べます（`http_request`、またはコマンド）。値は、アプリが使う瞬間にだけ入れ、'
                  '送ってよいのは、その項目に決めたホストだけです。値は、モデル・履歴・承認カード・ログのどこにも出ません。'
                  '渡すのは、あなたが承認したときだけです（毎回、カードに名前とホストが出ます）。'
                  '注意：コマンドの中では、proot は境界ではないので、渡されたコマンドは、その値をネットワークのどこへでも送れます。'
                  '承認する前に、コマンドを読んでください。出力に値がそのまま出たときは伏せますが、変換して出されたものは防げません。'
                  '値は端末の安全な領域にだけ保存し、設定ファイル・バックアップ・チャットには入りません。チャットからは変えられません。',
                  style: ts(context, 9.5, color: c.muted, height: 1.6),
                ),
              ),
              if (entries.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text('まだ、キーやトークンを持つ項目がありません。', style: ts(context, 10, color: c.muted)),
                ),
              for (final entry in entries) _EntryRow(app: app, entry: entry),
              if (aliases.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 10, bottom: 2),
                  child: Text('MCP のトークンの別名（コマンドの環境変数だけで使う）', style: ts(context, 10.5, weight: FontWeight.w700)),
                ),
                for (final secret in aliases) _AliasRow(app: app, secret: secret),
              ],
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(children: [
                  SoftButton(
                    label: '秘密を追加',
                    svg: ArceSvg.plus,
                    onTap: () => showSecretEditor(context, app),
                  ),
                ]),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Opens the editor of a typed secret: a new one, or [existing] (its name stays; the value changes only if one is typed).
Future<void> showSecretEditor(BuildContext context, AppController app, {ShellSecret? existing}) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.c.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (context) => _SecretEditor(app: app, existing: existing),
    );

/// One item of the book: its placeholder, what it is, where it may go, and whether a model may use it.
class _EntryRow extends StatelessWidget {
  const _EntryRow({required this.app, required this.entry});

  final AppController app;
  final SecretInfo entry;

  ShellSecret? get _typed {
    if (entry.kind != SecretKind.own) return null;
    for (final secret in app.settings.value.shellSecrets) {
      if (!secret.fromMcp && entry.stableKey == 'own:${secret.name}') return secret;
    }
    return null;
  }

  Future<void> _setOff(bool off) => app.settings.update((s) {
        final rest = [for (final key in s.secretsOffForModel) if (key != entry.stableKey) key];
        return s.copyWith(secretsOffForModel: off ? [...rest, entry.stableKey] : rest);
      });

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final typed = _typed;
    final reason = entry.unusableReason;
    final hosts = entry.hosts.isEmpty ? '決まっていません' : entry.hosts.join('、');
    final allowed = !app.settings.value.secretsOffForModel.contains(entry.stableKey);
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SelectableText('{{secret:${entry.id}}}', style: ts(context, 11.5, weight: FontWeight.w700, color: c.accent)),
              Text('${entry.label} ・ ${secretKindLabel(entry.kind)}', style: ts(context, 9.5, color: c.muted, height: 1.4)),
            ]),
          ),
          if (typed != null)
            IconTap(
              svg: ArceSvg.close,
              tooltip: '削除',
              onTap: () async {
                await app.settings.removeShellSecret(typed.name);
                app.showToast('${typed.name} を削除しました');
              },
            ),
        ]),
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            '送ってよいホスト：$hosts${typed == null ? '（${secretKindLabel(entry.kind)}のアドレスに合わせて、自動で決まります）' : '（タップして変えられます）'}',
            style: ts(context, 9, color: c.muted, height: 1.5),
          ),
        ),
        if (reason != null && !(reason == 'モデルには使わせない設定です'))
          Text('モデルは、いまは使えません：$reason', style: ts(context, 9, color: c.amber, height: 1.5)),
        Row(children: [
          Expanded(child: Text('モデルに使わせる', style: ts(context, 10.5, weight: FontWeight.w600))),
          ArceSwitch(value: allowed, onChanged: (v) => _setOff(!v)),
        ]),
      ],
    );
    return Container(
      key: ValueKey('secret-entry-${entry.id}'),
      margin: const EdgeInsets.only(top: 6),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: c.line))),
      padding: const EdgeInsets.only(top: 6),
      child: typed == null
          ? body
          : InkWell(
              key: ValueKey('secret-edit-${entry.id}'),
              onTap: () => showSecretEditor(context, app, existing: typed),
              child: body,
            ),
    );
  }
}

/// An alias of an MCP token for commands only: it has no id for a model (the server's own item has one).
class _AliasRow extends StatelessWidget {
  const _AliasRow({required this.app, required this.secret});

  final AppController app;
  final ShellSecret secret;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final server = app.settings.value.mcpServers.where((s) => s.id == secret.mcpServerId).map((s) => s.name.isEmpty ? s.id : s.name).firstOrNull;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(secret.name, style: ts(context, 11.5, weight: FontWeight.w600)),
            Text('MCP サーバー「${server ?? secret.mcpServerId}」のトークン', style: ts(context, 9, color: c.muted)),
          ]),
        ),
        IconTap(
          svg: ArceSvg.close,
          tooltip: '削除',
          onTap: () async {
            await app.settings.removeShellSecret(secret.name);
            app.showToast('${secret.name} を削除しました');
          },
        ),
      ]),
    );
  }
}

class _SecretEditor extends StatefulWidget {
  const _SecretEditor({required this.app, this.existing});

  final AppController app;

  /// The typed secret being edited; null for a new one.
  final ShellSecret? existing;

  @override
  State<_SecretEditor> createState() => _SecretEditorState();
}

class _SecretEditorState extends State<_SecretEditor> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  final _value = TextEditingController();
  late final _hosts = TextEditingController(text: widget.existing?.hosts.join('\n') ?? '');

  /// The MCP server whose token is the value; null for a value typed here.
  String? _server;

  bool get _editing => widget.existing != null;

  @override
  void dispose() {
    _name.dispose();
    _value.dispose();
    _hosts.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final app = widget.app;
    final name = _name.text.trim();
    if (!ShellSecrets.validName(name)) {
      app.showToast('名前は英数字と _ だけ（先頭は数字以外、64 文字まで）。HOME・PATH などは使えません');
      return;
    }
    final hosts = SecretHostsInput.parse(_hosts.text);
    final bad = SecretHostsInput.firstInvalid(hosts);
    if (bad != null) {
      app.showToast('「$bad」はホストとして読めません（例：api.example.com、*.example.com）');
      return;
    }
    if (_editing) {
      final existing = widget.existing!;
      final secret = ShellSecret(name: existing.name, mcpServerId: existing.mcpServerId, hosts: hosts);
      if (_value.text.trim().isEmpty) {
        // only the hosts change: the value that is kept stays
        await app.settings.update((s) => s.copyWith(shellSecrets: [for (final e in s.shellSecrets) e.name == existing.name ? secret : e]));
      } else {
        await app.settings.setShellSecret(secret, _value.text);
      }
    } else {
      if (_server == null && _value.text.trim().isEmpty) {
        app.showToast('値を入れるか、MCP サーバーのトークンを選んでください');
        return;
      }
      await app.settings.setShellSecret(ShellSecret(name: name, mcpServerId: _server ?? '', hosts: hosts), _value.text);
    }
    if (!mounted) return;
    Navigator.of(context).pop();
    app.showToast('$name を保存しました');
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final servers = widget.app.settings.value.mcpServers;
    return Padding(
      padding: EdgeInsets.only(left: 16, right: 16, top: 16, bottom: sheetBottomPadding(context)),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_editing ? '秘密を編集' : '秘密を追加', style: ts(context, 14, weight: FontWeight.w700)),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: ArceTextField(
                key: const ValueKey('secret-name'),
                controller: _name,
                style: ts(context, 12),
                decoration: InputDecoration(
                  labelText: '環境変数の名前',
                  hintText: 'GITHUB_TOKEN',
                  helperText: _editing ? '名前は変えられません（変えるときは、削除して作り直します）' : null,
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
                onChanged: _editing ? null : (_) => setState(() {}),
              ),
            ),
            if (!_editing && servers.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: DropdownButtonFormField<String?>(
                  initialValue: _server,
                  isDense: true,
                  decoration: const InputDecoration(labelText: '値のもと', isDense: true, border: OutlineInputBorder()),
                  items: [
                    const DropdownMenuItem<String?>(value: null, child: Text('ここで入力する')),
                    for (final server in servers)
                      DropdownMenuItem<String?>(value: server.id, child: Text('MCP「${server.name.isEmpty ? server.id : server.name}」のトークン')),
                  ],
                  onChanged: (v) => setState(() => _server = v),
                ),
              ),
            if (_server == null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: ArceTextField(
                  key: const ValueKey('secret-value'),
                  controller: _value,
                  obscure: true,
                  style: ts(context, 12),
                  decoration: InputDecoration(
                    labelText: _editing ? '値（変えるときだけ入力）' : '値',
                    hintText: _editing ? '空なら、いまの値のままです' : '端末の安全な領域に保存します',
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: ArceTextField(
                key: const ValueKey('secret-hosts'),
                controller: _hosts,
                minLines: 1,
                maxLines: 4,
                keyboardType: TextInputType.multiline,
                style: ts(context, 12),
                decoration: const InputDecoration(
                  labelText: '送ってよいホスト（1 行に 1 つ）',
                  hintText: 'api.example.com\n*.example.com',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            _hostsNote(context),
            const SizedBox(height: 6),
            Text(
              'GitHub の gh と git は GH_TOKEN / GITHUB_TOKEN を読みます。最小の権限のトークンを使ってください。',
              style: ts(context, 9, color: c.muted, height: 1.5),
            ),
            const SizedBox(height: 12),
            Row(children: [SoftButton(label: '保存', svg: ArceSvg.check, onTap: _save)]),
          ],
        ),
      ),
    );
  }

  /// What the hosts typed so far mean: nothing (a model cannot use it by placeholder), anywhere (a warning), or a list.
  Widget _hostsNote(BuildContext context) {
    final c = context.c;
    final hosts = SecretHostsInput.parse(_hosts.text);
    if (hosts.isEmpty) {
      return Text(
        'ホストを入れないと、モデルは `{{secret:…}}` では使えません（コマンドの環境変数 \$名前 では使えます）。',
        key: const ValueKey('hosts-empty'),
        style: ts(context, 9, color: c.muted, height: 1.5),
      );
    }
    if (hosts.contains('*')) {
      return Text(
        '「*」は、どこへでも送れます。proot の外の、見知らぬサーバーへも送れてしまうので、必要なホストだけを書いてください。',
        key: const ValueKey('hosts-any'),
        style: ts(context, 9.5, color: c.red, weight: FontWeight.w700, height: 1.5),
      );
    }
    final bad = SecretHostsInput.firstInvalid(hosts);
    if (bad != null) {
      return Text('「$bad」はホストとして読めません。', key: const ValueKey('hosts-bad'), style: ts(context, 9.5, color: c.amber, height: 1.5));
    }
    return Text(
      'このホストにだけ送れます（端末の中や、近くのネットワークのアドレスには、送れません）。',
      key: const ValueKey('hosts-ok'),
      style: ts(context, 9, color: c.muted, height: 1.5),
    );
  }
}

/// The settings of `http_request` (path A): the app calls an address for the model, puts the
/// secrets the model named into the request, and sends them only to the hosts each is bound to.
class HttpRequestCard extends StatelessWidget {
  const HttpRequestCard({super.key, required this.app});

  final AppController app;

  static const confirmLabels = {
    'secretOrWrite': '秘密を使う・書き込みのとき確認（既定）',
    'all': '毎回確認',
    'never': '確認しない（秘密のホスト固定は効く）',
  };

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return ListenableBuilder(
      listenable: app.settings,
      builder: (context, _) {
        final s = app.settings.value;
        void set(AppSettings Function(AppSettings) f) => app.settings.update(f);
        return ArceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('API を呼ぶ道具（http_request）', style: ts(context, 12, weight: FontWeight.w700)),
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 8),
                child: Text(
                  'API を呼ぶだけなら、`http_request` を使わせます。モデルが書くのは、アドレス・ヘッダー・本文と、キーの場所の `{{secret:id}}` だけで、'
                  '通信はアプリが行い、キーの値は、その項目に決めたホストにだけ送ります（別のホストへの転送、https でない通信、端末の中のアドレスは断ります）。'
                  '加工が要るときだけ、スクリプト（コマンド）を使います。そちらは、承認と検査と伏せ字で守りますが、送り先は保証できません。',
                  style: ts(context, 9.5, color: c.muted, height: 1.6),
                ),
              ),
              SettingRow(
                icon: ArceSvg.globe,
                title: 'モデルが http_request（アプリが API を呼ぶ道具）を使えるようにする',
                subtitle: 'オフにすると、モデルにこの道具を渡しません',
                trailing: ArceSwitch(value: s.httpRequestEnabled, onChanged: (v) => set((x) => x.copyWith(httpRequestEnabled: v))),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(2, 10, 2, 4),
                child: Text('呼び出しの前に確認する', style: ts(context, 11, weight: FontWeight.w600)),
              ),
              Wrap(spacing: 6, runSpacing: 4, children: [
                for (final entry in confirmLabels.entries)
                  ChoiceChip(
                    key: ValueKey('http-confirm-${entry.key}'),
                    label: Text(entry.value, style: ts(context, 10)),
                    selected: s.httpRequestConfirm == entry.key,
                    onSelected: (_) => set((x) => x.copyWith(httpRequestConfirm: entry.key)),
                  ),
              ]),
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 6),
                child: s.httpRequestConfirm == 'never'
                    ? Text(
                        '注意：確認しないと、モデルは、あなたの承認なしに、キーを使って API を呼べます（送り先は、秘密に決めたホストだけです。呼び出しの回数や、書き込みは、確認されません）。',
                        key: const ValueKey('http-confirm-warning'),
                        style: ts(context, 9.5, color: c.red, weight: FontWeight.w700, height: 1.5),
                      )
                    : Text(
                        '既定では、キーを使う呼び出しと、GET・HEAD 以外の呼び出しだけ、確認します。チャットからは変えられません。',
                        style: ts(context, 9, color: c.muted, height: 1.5),
                      ),
              ),
              SettingRow(
                icon: ArceSvg.alert,
                title: 'http（暗号化されない通信）でも、キーやトークンを送れるようにする',
                subtitle: '既定はオフ（https だけ）。オンにすると、通信の途中で、キーを見られるおそれがあります。チャットからは変えられません',
                trailing: ArceSwitch(value: s.httpRequestAllowInsecure, onChanged: (v) => set((x) => x.copyWith(httpRequestAllowInsecure: v))),
              ),
              if (s.httpRequestAllowInsecure)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    '注意：http は暗号化されません。同じネットワークの人に、キーを見られるおそれがあります。',
                    key: const ValueKey('http-insecure-warning'),
                    style: ts(context, 9.5, color: c.red, weight: FontWeight.w700, height: 1.5),
                  ),
                ),
              _Choices(
                title: '応答を、モデルに渡す文字数の上限',
                subtitle: '超えた分は省きます',
                keyPrefix: 'http-max',
                value: s.httpRequestMaxResponseChars,
                values: const [5000, 10000, 20000, 50000, 100000],
                label: (v) => '$v 文字',
                onChanged: (v) => set((x) => x.copyWith(httpRequestMaxResponseChars: v)),
              ),
              _Choices(
                title: 'http_request の待ち時間',
                subtitle: 'この秒数で、通信をあきらめます',
                keyPrefix: 'http-timeout',
                value: s.httpRequestTimeoutSeconds,
                values: const [10, 30, 60, 120, 300],
                label: (v) => '$v 秒',
                onChanged: (v) => set((x) => x.copyWith(httpRequestTimeoutSeconds: v)),
              ),
              _Choices(
                title: 'http_request が追うリダイレクトの回数',
                subtitle: '秘密を使うときは、同じホストの https にだけ追います。0 は追いません',
                keyPrefix: 'http-redirects',
                value: s.httpRequestMaxRedirects,
                values: const [0, 2, 5, 10],
                label: (v) => v == 0 ? '追わない' : '$v 回',
                onChanged: (v) => set((x) => x.copyWith(httpRequestMaxRedirects: v)),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// A row with a title, a line under it, and the values to pick from, which wrap when there is no room.
class _Choices extends StatelessWidget {
  const _Choices({
    required this.title,
    required this.subtitle,
    required this.keyPrefix,
    required this.value,
    required this.values,
    required this.label,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final String keyPrefix;
  final int value;
  final List<int> values;
  final String Function(int) label;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: ts(context, 11, weight: FontWeight.w600)),
        Text(subtitle, style: ts(context, 9, color: c.muted)),
        const SizedBox(height: 4),
        Wrap(spacing: 6, runSpacing: 4, children: [
          for (final v in {...values, value}.toList()..sort())
            ChoiceChip(
              key: ValueKey('$keyPrefix-$v'),
              label: Text(label(v), style: ts(context, 10)),
              selected: v == value,
              onSelected: (_) => onChanged(v),
            ),
        ]),
      ]),
    );
  }
}
