import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../ai/model_tree.dart';
import '../core/agents.dart';
import '../core/coding_plan.dart';
import '../core/engine.dart';
import '../core/settings_search.dart';
import '../core/dangerous_commands.dart';
import '../services/app_controller.dart';
import '../services/desktop_shell.dart';
import '../services/linux_env.dart';
import '../services/settings.dart';
import 'app_scope.dart';
import 'arce_text_field.dart';
import 'mcp_widgets.dart';
import 'model_tree_view.dart';
import 'search_widgets.dart';
import 'settings_index.dart';
import 'proot_check_card.dart';
import 'provider_widgets.dart';
import 'secrets_widgets.dart';
import 'svg_icons.dart';
import 'theme.dart';
import 'thinking_icon.dart';
import 'update_widgets.dart';
import 'widgets.dart';

/// What one group of the settings list shows when it is closed. The same list is the settings part of the
/// desktop sidebar ([settingsGroups]), so the two always have the same groups, names and order.
class SettingsGroup {
  const SettingsGroup(this.section, this.icon, this.title, this.subtitle);
  final SettingsSection section;
  final String icon;
  final String title;
  final String subtitle;
}

/// The groups of the settings screen, in the order it shows them.
const settingsGroups = [
  SettingsGroup(SettingsSection.providers, ArceSvg.cube, 'オンライン接続（プロバイダ）', 'API の接続先と、使うモデル'),
  SettingsGroup(SettingsSection.online, ArceSvg.globe, 'オンラインモデルの設定', 'temperature・最大トークン・追加プロンプト'),
  SettingsGroup(SettingsSection.local, ArceSvg.sliders, 'ローカルモデルの設定', 'サンプリング・コンテキスト長・スレッド・GPU'),
  SettingsGroup(SettingsSection.coding, ArceSvg.codeEdit, '分担モード', 'plan が設計と分担数を決め、coding が調べてから実装する'),
  SettingsGroup(SettingsSection.shell, ArceSvg.bolt, 'Linux 環境', 'コマンドを動かす（Android は内蔵の Ubuntu、PC はコンテナか PC 全体）'),
  SettingsGroup(SettingsSection.limits, ArceSvg.sliders2, '上限とタイムアウト', '添付・検索・通信・更新の上限と待ち時間'),
  SettingsGroup(SettingsSection.mcp, ArceSvg.bolt, 'MCP サーバー', '外部の道具（GitHub など）をつなぐ'),
  SettingsGroup(SettingsSection.basic, ArceSvg.settings, 'モデル全般設定', 'ローカルとオンライン共通：思考・回答・最大トークン・再試行'),
  SettingsGroup(SettingsSection.search, ArceSvg.search, '検索設定', '検索サーバー・検索 API・結果の件数'),
  SettingsGroup(SettingsSection.display, ArceSvg.moon, '表示・プライバシー', 'テーマ・思考中のアイコン'),
  SettingsGroup(SettingsSection.update, ArceSvg.retry, 'アップデート', '自動で更新する・確認の間隔'),
  SettingsGroup(SettingsSection.reports, ArceSvg.alert, 'エラーの報告', 'エラーを GitHub の issue に自動で送る（トークンを入れたときだけ）'),
];

/// The settings: a landing page with one button for each group (two to a row), and a screen of its own
/// for the group that was pressed. Nothing scrolls by itself when a group is opened: the screen is replaced,
/// and it starts at its top. Back (the button in its header, or the system's back) returns to the buttons.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  /// The group on the screen; null for the landing page.
  SettingsSection? _section;
  AppController? _app;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = ArceScope.of(context);
    if (_app != app) {
      _app?.settingsSection.removeListener(_consume);
      _app = app..settingsSection.addListener(_consume);
      // a group may have been asked for before this page existed (the sidebar does that)
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _consume();
        _report();
      });
    }
  }

  @override
  void dispose() {
    _app?.settingsSection.removeListener(_consume);
    super.dispose();
  }

  /// Shows the group another part of the app asked for.
  void _consume() {
    final app = _app;
    final section = app?.settingsSection.value;
    if (app == null || section == null || !mounted) return;
    app.settingsSection.value = null;
    _show(section);
  }

  void _open(SettingsSection section) => _show(section);

  void _back() => _show(null);

  void _show(SettingsSection? section) {
    setState(() => _section = section);
    _report();
  }

  /// Tells the rest of the app which group is on the screen (the sidebar marks it).
  void _report() {
    if (mounted) _app?.shownSettingsGroup.value = _section;
  }

  @override
  Widget build(BuildContext context) {
    final app = ArceScope.of(context);
    return PopScope(
      // inside a group, back goes to the buttons; on the landing page it is the app's own
      canPop: _section == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: ListenableBuilder(
        listenable: app.settings,
        builder: (context, _) {
          final s = app.settings.value;
          void set(AppSettings Function(AppSettings) f) => app.settings.update(f);
          final section = _section;
          return SingleChildScrollView(
            // a new scroll position for each screen: a group starts at its top, the buttons at theirs
            key: ValueKey(section),
            padding: const EdgeInsets.fromLTRB(14, 16, 14, 24),
            child: PageColumn(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (section == null)
                    _Landing(onOpen: _open)
                  else ...[
                    _SectionHeader(group: settingsGroups.firstWhere((g) => g.section == section), onBack: _back),
                    _content(context, section, app, s, set),
                  ],
                  _Footer(app: app),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _content(
    BuildContext context,
    SettingsSection section,
    AppController app,
    AppSettings s,
    void Function(AppSettings Function(AppSettings)) set,
  ) {
    switch (section) {
      case SettingsSection.providers:
        return const ProvidersSection();
      case SettingsSection.mcp:
        return const McpSection();
      case SettingsSection.shell:
        return _linux(app, s, set);
      case SettingsSection.online:
        return _onlineModel(s, set);
      case SettingsSection.local:
        return _localModel(app, s, set);
      case SettingsSection.coding:
        return _codingMode(app, s, set);
      case SettingsSection.limits:
        return _limits(s, set);
      case SettingsSection.basic:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ArceCard(
              child: Column(
                children: [
                  SettingRow(
                    icon: ArceSvg.brainOutline,
                    title: '思考の表示',
                    subtitle: '生成中の状態と思考プロセスを表示します',
                    trailing: ArceSwitch(value: s.thinking, onChanged: (v) => set((x) => x.copyWith(thinking: v))),
                  ),
                  SettingRow(
                    icon: ArceSvg.brainOutline,
                    title: '思考の内容を開いたまま表示',
                    subtitle: 'オフにすると、思考が終わったあとは折りたたみます（見出しをタップで開け閉めできます）',
                    trailing: ArceSwitch(value: s.thinkingExpanded, onChanged: (v) => set((x) => x.copyWith(thinkingExpanded: v))),
                  ),
                  SettingRow(
                    icon: ArceSvg.codeEdit,
                    title: '長いコードブロックを折りたたむ行数',
                    subtitle: 'この行数より長いコードは、最初は折りたたみます（見出しをタップで開け閉めできます）。0 なら折りたたみません',
                    trailing: _Cycle<int>(
                      value: s.codeFoldLines,
                      values: const [0, 20, 40, 80, 150],
                      label: (v) => v == 0 ? 'なし' : '$v 行',
                      onChanged: (v) => set((x) => x.copyWith(codeFoldLines: v)),
                    ),
                  ),
                  SettingRow(
                    icon: ArceSvg.eye,
                    title: 'HTML・SVG をチャットの中で表示する高さ',
                    subtitle: 'HTML と SVG のコードブロックに「表示」のボタンを出し、押すと、この高さでチャットの中に表示します。0 ならボタンを出しません',
                    trailing: _Cycle<int>(
                      value: s.inlinePreviewHeight,
                      values: const [0, 240, 360, 480, 640],
                      label: (v) => v == 0 ? 'なし' : '$v px',
                      onChanged: (v) => set((x) => x.copyWith(inlinePreviewHeight: v)),
                    ),
                  ),
                  SettingRow(
                    icon: ArceSvg.eye,
                    title: 'モデルが画面にページを出せるようにする（show）',
                    subtitle: 'HTML・SVG・/workspace のファイル・Linux 環境のプログラムが出すページを、モデルがチャットの中のカードとして出します。ボタンを押すと開きます',
                    trailing: ArceSwitch(value: s.showEnabled, onChanged: (v) => set((x) => x.copyWith(showEnabled: v))),
                  ),
                  SettingRow(
                    icon: ArceSvg.eye,
                    title: 'ページを自動で開く',
                    subtitle: 'ボタンを押さなくても、チャットの中のページを開きます。モデルが書いたページを、そのまま動かすので、オフのままをおすすめします（チャットからは変えられません）',
                    last: true,
                    trailing: ArceSwitch(value: s.autoShowPages, onChanged: (v) => set((x) => x.copyWith(autoShowPages: v))),
                  ),
                ],
              ),
            ),
            _subheading(context, 'チャットのタイトル'),
            _titleCard(app, s, set),
            _subheading(context, '回答（口調・速度⇔精度・エージェント・返信の長さ）'),
            _answerCard(context, app, s, set),
            _subheading(context, '最大トークンと再試行（共通）'),
            _developerCard(context, app, s, set),
          ],
        );
      case SettingsSection.search:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ArceCard(
              child: Column(
                children: [
                  _TextRow(
                    icon: ArceSvg.globe,
                    title: 'SearXNG のアドレス',
                    subtitle: '自分の検索サーバー（先に使います）',
                    value: s.searxngUrl,
                    hint: 'http://192.168.0.10:8080',
                    onChanged: (v) => set((x) => x.copyWith(searxngUrl: v)),
                  ),
                  SettingRow(
                    icon: ArceSvg.search,
                    title: '検索結果の件数',
                    subtitle: 'Web検索で使う結果の数',
                    last: true,
                    trailing: _Cycle<int>(
                      value: s.searchResultCount,
                      values: const [3, 5, 8, 10, 15],
                      label: (v) => '$v',
                      onChanged: (v) => set((x) => x.copyWith(searchResultCount: v)),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            const SearchApiSection(),
          ],
        );
      case SettingsSection.display:
        return ArceCard(
          child: Column(
            children: [
              SettingRow(
                icon: ArceSvg.alert,
                title: '許可や答えが必要になったら通知する',
                subtitle: '承認カードや質問で返信が止まったとき（Android）',
                trailing: ArceSwitch(value: s.notifyNeedsYou, onChanged: (v) => _notifySetting(app, set, (x) => x.copyWith(notifyNeedsYou: v), v)),
              ),
              SettingRow(
                icon: ArceSvg.check,
                title: '返信が終わったら通知する',
                subtitle: '長い作業を任せて、ほかのアプリを開いているとき',
                trailing: ArceSwitch(value: s.notifyDone, onChanged: (v) => _notifySetting(app, set, (x) => x.copyWith(notifyDone: v), v)),
              ),
              SettingRow(
                icon: ArceSvg.alert,
                title: '失敗したら通知する',
                subtitle: 'エラーで返信が止まったとき',
                trailing: ArceSwitch(value: s.notifyFailed, onChanged: (v) => _notifySetting(app, set, (x) => x.copyWith(notifyFailed: v), v)),
              ),
              SettingRow(
                icon: ArceSvg.info,
                title: 'そのチャットを開いているときは通知しない',
                subtitle: 'オフにすると、画面を見ているときも通知します',
                trailing: ArceSwitch(value: s.notifyOnlyAway, onChanged: (v) => set((x) => x.copyWith(notifyOnlyAway: v))),
              ),
              SettingRow(
                icon: ArceSvg.file,
                title: '文字の大きさ',
                subtitle: '画面全体の文字（端末の文字サイズの設定に重ねて効きます）',
                trailing: _Cycle<double>(
                  value: s.fontScale,
                  values: const [0.85, 1.0, 1.15, 1.3, 1.5, 1.75, 2.0],
                  label: (v) => '${(v * 100).round()}%',
                  onChanged: (v) => set((x) => x.copyWith(fontScale: v)),
                ),
              ),
              SettingRow(
                icon: ArceSvg.moon,
                title: 'テーマ',
                subtitle: '画面の明るさ',
                trailing: _Dropdown<ThemeMode>(
                  value: s.theme,
                  items: const {ThemeMode.system: '端末に合わせる', ThemeMode.light: 'ライト', ThemeMode.dark: 'ダーク'},
                  onChanged: (v) => set((x) => x.copyWith(theme: v)),
                ),
              ),
              SettingRow(
                icon: ArceSvg.clockCircle,
                title: '思考中のアイコン',
                subtitle: '生成中に使う表示スタイル',
                last: true,
                trailing: const SizedBox.shrink(),
              ),
              _StyleOptions(
                current: s.thinkingStyle,
                onPick: (v) {
                  set((x) => x.copyWith(thinkingStyle: v));
                  app.showToast('思考中のアイコンを変更しました');
                },
              ),
              const SizedBox(height: 8),
              SettingRow(
                icon: ArceSvg.shieldMinus,
                title: '端末内保存',
                subtitle: '会話とモデルはこの端末内にだけ保存されます',
                last: true,
                trailing: StatusLabel('有効', color: context.c.green, background: context.c.greenSoft),
              ),
            ],
          ),
        );
      case SettingsSection.reports:
        return _ReportCard(app: app, s: s, set: set);
      case SettingsSection.update:
        return ArceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const UpdateCard(),
              const SizedBox(height: 6),
              const Divider(height: 24),
              SettingRow(
                icon: ArceSvg.retry,
                title: '自動で確認する',
                subtitle: '起動時と、起動中は一定時間ごとに確認します',
                trailing: ArceSwitch(value: s.autoUpdateCheck, onChanged: (v) => set((x) => x.copyWith(autoUpdateCheck: v))),
              ),
              SettingRow(
                icon: ArceSvg.bolt,
                title: '自動で更新する',
                subtitle: '見つけたらダウンロードとインストールまで自動で進めます',
                trailing: ArceSwitch(value: s.autoInstallUpdate, onChanged: (v) => set((x) => x.copyWith(autoInstallUpdate: v))),
              ),
              SettingRow(
                icon: ArceSvg.cube,
                title: '差分だけダウンロードする',
                subtitle: 'Android：今のアプリとの差分があれば、それだけ取って新しいアプリを組み立てます（なければ全体）',
                trailing: ArceSwitch(value: s.updateUseDelta, onChanged: (v) => set((x) => x.copyWith(updateUseDelta: v))),
              ),
              SettingRow(
                icon: ArceSvg.clock,
                title: '確認の間隔',
                subtitle: '時間',
                trailing: _Cycle<int>(
                  value: s.updateIntervalHours,
                  values: const [1, 6, 12, 24, 72],
                  label: (v) => '$v 時間',
                  onChanged: (v) => set((x) => x.copyWith(updateIntervalHours: v)),
                ),
              ),
              _TextRow(
                icon: ArceSvg.globe,
                title: 'リポジトリ',
                subtitle: '更新を探す GitHub のリポジトリ（owner/name）',
                value: s.updateRepo,
                hint: AppSettings.defaultRepo,
                onChanged: (v) => set((x) => x.copyWith(updateRepo: v.trim())),
              ),
              _TextRow(
                icon: ArceSvg.shield,
                title: 'GitHub トークン',
                subtitle: '非公開リポジトリのときだけ。この端末の安全な領域に保存します',
                value: app.settings.githubToken,
                hint: 'github_pat_…',
                obscure: true,
                last: true,
                onChanged: app.settings.setGithubToken,
              ),
            ],
          ),
        );
    }
  }

  /// The Linux environment: whether the model may run commands and with what limits, what is
  /// installed, how much the shared workspace holds, and the check of proot itself.
  /// Only Android: proot is a child process out of the native library folder.
  Widget _linux(AppController app, AppSettings s, void Function(AppSettings Function(AppSettings)) set) {
    final c = context.c;
    if (app.desktopShell != null) return _desktop(app, s, set);
    if (!Platform.isAndroid) {
      return ArceCard(
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Text(
            'コマンドの実行は、Android（アプリの中の Ubuntu）と PC（Windows・macOS・Linux）の機能です。',
            style: ts(context, 10.5, color: c.muted, height: 1.6),
          ),
        ),
      );
    }
    final environment = app.linux;
    return ListenableBuilder(
      listenable: environment,
      builder: (context, _) {
        final status = environment.status;
        final busy = environment.state == LinuxState.downloading || environment.state == LinuxState.unpacking;
        final ready = environment.state == LinuxState.ready;
        final progress = environment.progress;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ArceCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      'モデルが `run_command` で、アプリの中の Ubuntu（arm64）でコマンドを実行できます。proot の疑似 root で、'
                      'サンドボックスではありません（アプリと同じユーザーで動きます）。`/workspace` は全チャット共通で、アプリを消すまで残ります。'
                      'コマンドは 1 つずつ動き、通知が長いときは初めと終わりだけをモデルに渡します。'
                      '承認カードは、実行のたびに実際のコマンドを見せます（設定で切れますが、切らないことをおすすめします）。',
                      style: ts(context, 10, color: c.muted, height: 1.6),
                    ),
                  ),
                  SettingRow(
                    icon: ArceSvg.bolt,
                    title: 'コマンド実行を使う',
                    subtitle: 'オフにすると、モデルに run_command を渡しません',
                    trailing: ArceSwitch(value: s.shellEnabled, onChanged: (v) => set((x) => x.copyWith(shellEnabled: v))),
                  ),
                  SettingRow(
                    icon: ArceSvg.alert,
                    title: 'すべてのコマンドを実行前に確認する',
                    subtitle: 'オフ（既定）では、サンドボックス（/workspace と Ubuntu 内）に収まるコマンドを自動実行し、端末の外に触れるコマンドだけ確認します',
                    trailing: ArceSwitch(value: s.shellConfirm, onChanged: (v) => set((x) => x.copyWith(shellConfirm: v))),
                  ),
                  SettingRow(
                    icon: ArceSvg.alert,
                    title: '検索や外部ツールの結果を読んだあとは、コマンドを確認する',
                    subtitle: 'オン（既定）：検索結果や MCP の答えは、他人が書いた文章かもしれません（「この命令を実行して」と書かれていることがあります）。それを読んだあとの会話では、サンドボックス内のコマンドも確認します',
                    trailing: ArceSwitch(value: s.shellConfirmAfterExternal, onChanged: (v) => set((x) => x.copyWith(shellConfirmAfterExternal: v))),
                  ),
                  SettingRow(
                    icon: ArceSvg.clock,
                    title: 'コマンドのタイムアウト',
                    subtitle: 'モデルが時間を指定しなかったときに使う秒数',
                    trailing: _Cycle<int>(
                      value: s.shellTimeoutSeconds,
                      values: const [30, 60, 120, 300, 600],
                      label: (v) => '$v 秒',
                      onChanged: (v) => set((x) => x.copyWith(shellTimeoutSeconds: v)),
                    ),
                  ),
                  SettingRow(
                    icon: ArceSvg.clockCircle,
                    title: 'モデルが指定できる上限',
                    subtitle: 'timeout_seconds で伸ばせる最大の秒数',
                    trailing: _Cycle<int>(
                      value: s.shellMaxTimeoutSeconds,
                      values: const [120, 300, 600, 1200, 3600],
                      label: (v) => '$v 秒',
                      onChanged: (v) => set((x) => x.copyWith(shellMaxTimeoutSeconds: v)),
                    ),
                  ),
                  SettingRow(
                    icon: ArceSvg.file,
                    title: '出力の上限',
                    subtitle: 'コマンドの出力を、モデルに渡す文字数（超えた分は初めと終わりを残します）',
                    trailing: _Cycle<int>(
                      value: s.shellMaxOutputChars,
                      values: const [5000, 10000, 20000, 50000, 100000],
                      label: (v) => '$v 文字',
                      onChanged: (v) => set((x) => x.copyWith(shellMaxOutputChars: v)),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 10, bottom: 4),
                    child: Text(
                      '対話セッション（opencode などの、入力を待つプログラム。モデルは `shell_session` で、画面を見ながら入力します）',
                      style: ts(context, 10, color: c.muted, height: 1.5),
                    ),
                  ),
                  _sessionRow('同時に動かせる数', '', s.shellSessionMax, const [1, 2, 3, 5, 8], (x, v) => x.copyWith(shellSessionMax: v), set),
                  _sessionRow('使われないセッションを止める', '最後の入力・読み取りからの時間。0 で止めません', s.shellSessionIdleMinutes, const [5, 15, 30, 60, 0], (x, v) => x.copyWith(shellSessionIdleMinutes: v), set, unit: ' 分'),
                  _sessionRow('出力を待つ時間', 'モデルが指定しないときに、入力のあと出力が落ち着くまで待つ最大の時間', s.shellSessionWaitMs, const [500, 1500, 3000, 8000], (x, v) => x.copyWith(shellSessionWaitMs: v), set, unit: ' ミリ秒'),
                  _sessionRow('モデルが指定できる待ち時間の上限', 'wait_ms で伸ばせる最大の秒数', s.shellSessionMaxWaitSeconds, const [10, 30, 60, 120], (x, v) => x.copyWith(shellSessionMaxWaitSeconds: v), set, unit: ' 秒'),
                  _sessionRow('端末の幅', '', s.shellSessionCols, const [80, 100, 120, 160, 200], (x, v) => x.copyWith(shellSessionCols: v), set, unit: ' 桁'),
                  _sessionRow('端末の高さ', '', s.shellSessionRows, const [24, 40, 60, 80], (x, v) => x.copyWith(shellSessionRows: v), set, unit: ' 行'),
                  _sessionRow('画面から流れた行を残す数', '次の読み取りで、流れた分もモデルに渡します', s.shellSessionScrollback, const [100, 500, 1000, 3000], (x, v) => x.copyWith(shellSessionScrollback: v), set, unit: ' 行'),
                  _sessionRow('読まれるまで残す出力', 'これを超えて出力されると、古い分は失われます', s.shellSessionBufferKb, const [64, 256, 1024, 4096], (x, v) => x.copyWith(shellSessionBufferKb: v), set, unit: ' KB'),
                  SettingRow(
                    icon: ArceSvg.sliders,
                    title: 'ワークスペースの上限',
                    subtitle: '全チャット共通の /workspace が、この大きさを超えて増えたらコマンドを止めます（rm で減らすコマンドは通ります）',
                    trailing: _Cycle<int>(
                      value: s.workspaceLimitMb,
                      values: const [512, 1024, 2048, 4096, 8192],
                      label: (v) => '$v MB',
                      onChanged: (v) => set((x) => x.copyWith(workspaceLimitMb: v)),
                    ),
                  ),
                  SettingRow(
                    icon: ArceSvg.bolt,
                    title: '互換モード（seccomp を切る）',
                    subtitle: 'この端末で proot が起動できないときだけ使います（PROOT_NO_SECCOMP=1）',
                    last: true,
                    trailing: ArceSwitch(value: s.shellCompatMode, onChanged: (v) => set((x) => x.copyWith(shellCompatMode: v))),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            ArceCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SettingRow(
                    icon: ArceSvg.cube,
                    title: 'Linux 環境（Ubuntu 24.04）',
                    subtitle: busy
                        ? (environment.state == LinuxState.downloading
                            ? 'ダウンロード中${progress == null ? '' : ' ${(progress * 100).round()}%'}…'
                            : '展開しています…')
                        : ready
                            ? (status?.describe() ?? '使えます')
                            : (environment.message ?? 'まだ入っていません。入れると、モデルがコマンドを実行できます（約 30 MB）'),
                    trailing: busy
                        ? SoftButton(label: '中止', height: 30, onTap: null)
                        : ready
                            ? SoftButton(label: '削除', height: 30, onTap: () => _removeLinux(app))
                            : SoftButton(
                                label: '入れる',
                                height: 30,
                                onTap: () => _installLinux(app),
                              ),
                  ),
                  if (ready)
                    SettingRow(
                      icon: ArceSvg.file,
                      title: 'ワークスペース（全チャット共通）',
                      subtitle: status == null
                          ? ''
                          : '${formatBytes(status.workspaceBytes)}'
                              '${status.workspaceLimitBytes > 0 ? ' / ${formatBytes(status.workspaceLimitBytes)}' : ''}',
                      last: true,
                      trailing: SoftButton(label: '空にする', height: 30, onTap: () => _clearWorkspace(app)),
                    ),
                  if (!ready) ProotCheckRow(app: app),
                ],
              ),
            ),
            const SizedBox(height: 10),
            ShellSecretsCard(app: app),
            const SizedBox(height: 10),
            HttpRequestCard(app: app),
          ],
        );
      },
    );
  }

  /// Commands on a PC: in a container (sandboxed), or on the PC itself with the user's rights, and how a command
  /// on the PC is let through.
  Widget _desktop(AppController app, AppSettings s, void Function(AppSettings Function(AppSettings)) set) {
    final c = context.c;
    final sandbox = s.desktopSandbox;
    final invalid = DangerousCommands.invalid(s.desktopDangerPatterns);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ArceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'モデルが `run_command` でコマンドを実行できます。ワークスペース（${app.workspaceDirectory?.path ?? ''}）は全チャット共通です。'
                  'コマンドは 1 つずつ動き、出力が長いときは初めと終わりだけをモデルに渡します。',
                  style: ts(context, 10, color: c.muted, height: 1.6),
                ),
              ),
              SettingRow(
                icon: ArceSvg.bolt,
                title: 'コマンド実行を使う',
                subtitle: 'オフにすると、モデルに run_command を渡しません',
                trailing: ArceSwitch(value: s.shellEnabled, onChanged: (v) => set((x) => x.copyWith(shellEnabled: v))),
              ),
              SettingRow(
                key: const ValueKey('desktop-sandbox'),
                icon: ArceSvg.shield,
                title: 'サンドボックス化する',
                subtitle: sandbox
                    ? 'オン（既定）：Docker か Podman のコンテナ（Ubuntu）の中で動かします。PC から見えるのは、ワークスペース（コンテナの /workspace）だけです'
                    : 'オフ：この PC の上で、あなたの権限のまま動きます。PC 全体のファイルを読み書きでき、止める仕組みは下の「実行前の確認」だけです',
                trailing: ArceSwitch(value: sandbox, onChanged: (v) => set((x) => x.copyWith(desktopSandbox: v))),
              ),
              if (sandbox) ...[
                SettingRow(
                  icon: ArceSvg.alert,
                  title: 'すべてのコマンドを実行前に確認する',
                  subtitle: 'オフ（既定）では、コンテナの中のコマンドを確認なしで実行します',
                  trailing: ArceSwitch(value: s.shellConfirm, onChanged: (v) => set((x) => x.copyWith(shellConfirm: v))),
                ),
                SettingRow(
                  icon: ArceSvg.cube,
                  title: 'コンテナを動かすソフト',
                  subtitle: '自動：Docker、なければ Podman',
                  trailing: _Dropdown<String>(
                    value: s.desktopContainerEngine,
                    items: const {'auto': '自動', 'docker': 'Docker', 'podman': 'Podman'},
                    onChanged: (v) => set((x) => x.copyWith(desktopContainerEngine: v)),
                  ),
                ),
                SettingRow(
                  icon: ArceSvg.globe,
                  title: 'コンテナからネットワークを使う',
                  subtitle: 'オン（既定）：apt や pip で入れられます。オフ：外に出られません（次にコンテナを作り直したときから）',
                  trailing: ArceSwitch(value: s.desktopContainerNetwork, onChanged: (v) => set((x) => x.copyWith(desktopContainerNetwork: v))),
                ),
                _TextRow(
                  icon: ArceSvg.cube,
                  title: 'イメージ',
                  subtitle: 'コンテナを作るもと（次にコンテナを作り直したときから）',
                  value: s.desktopContainerImage,
                  hint: DesktopShellSettings.defaultImage,
                  onChanged: (v) => set((x) => x.copyWith(desktopContainerImage: v.trim())),
                ),
                _TextRow(
                  icon: ArceSvg.cube,
                  title: 'コンテナの名前',
                  subtitle: '全チャットが使う 1 つのコンテナ。入れたものは、作り直すまで残ります',
                  value: s.desktopContainerName,
                  hint: DesktopShellSettings.defaultContainer,
                  onChanged: (v) => set((x) => x.copyWith(desktopContainerName: v.trim())),
                ),
                _DesktopShellStatus(app: app),
              ] else ...[
                SettingRow(
                  key: const ValueKey('desktop-approval'),
                  icon: ArceSvg.alert,
                  title: '実行前の確認',
                  subtitle: switch (s.desktopHostApproval) {
                    HostApproval.auto => '自動（既定）：確認せずに実行し、下の一覧に当たる危険な操作だけを止めます',
                    HostApproval.always => '毎回確認：すべてのコマンドを、実行前に承認カードで見せます',
                    HostApproval.never => '確認しない：すべてのコマンドを、そのまま実行します（危険な操作も止めません）',
                  },
                  trailing: _Dropdown<HostApproval>(
                    value: s.desktopHostApproval,
                    items: const {HostApproval.auto: '自動', HostApproval.always: '毎回確認', HostApproval.never: '確認しない'},
                    onChanged: (v) => set((x) => x.copyWith(desktopHostApproval: v)),
                  ),
                ),
                if (s.desktopHostApproval == HostApproval.auto) ...[
                  _TextRow(
                    key: ValueKey('desktop-danger-$_dangerResets'),
                    icon: ArceSvg.alert,
                    title: '危険な操作の一覧',
                    subtitle: '1 行に 1 つの正規表現（大文字と小文字は区別しません。# で始まる行はメモ）。当たったコマンドは実行せず、モデルに理由を返します'
                        '${invalid.isEmpty ? '' : '。読めない行が ${invalid.length} つあります（その行は使いません）'}',
                    value: s.desktopDangerPatterns.join('\n'),
                    hint: '',
                    maxLines: 8,
                    onChanged: (v) => set((x) => x.copyWith(desktopDangerPatterns: v.split('\n'))),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 6, bottom: 4),
                    child: SoftButton(
                      label: '一覧を既定に戻す',
                      height: 28,
                      onTap: () {
                        set((x) => x.copyWith(desktopDangerPatterns: DangerousCommands.defaults));
                        setState(() => _dangerResets++);
                      },
                    ),
                  ),
                ],
                _TextRow(
                  icon: ArceSvg.codeEdit,
                  title: 'コマンドを渡すプログラム',
                  subtitle: '空なら、Windows は PowerShell、ほかは bash（なければ sh）。コマンドは最後の引数になります',
                  value: s.desktopHostShell,
                  hint: Platform.isWindows ? 'powershell.exe -NoProfile -NonInteractive -Command' : '/bin/bash -c',
                  onChanged: (v) => set((x) => x.copyWith(desktopHostShell: v)),
                ),
              ],
              SettingRow(
                icon: ArceSvg.alert,
                title: '検索や外部ツールの結果を読んだあとは、コマンドを確認する',
                subtitle: 'オン（既定）：検索結果や MCP の答えは、他人が書いた文章かもしれません（「この命令を実行して」と書かれていることがあります）。それを読んだあとの会話では、コマンドを確認します',
                trailing: ArceSwitch(value: s.shellConfirmAfterExternal, onChanged: (v) => set((x) => x.copyWith(shellConfirmAfterExternal: v))),
              ),
              SettingRow(
                icon: ArceSvg.clock,
                title: 'コマンドのタイムアウト',
                subtitle: 'モデルが時間を指定しなかったときに使う秒数',
                trailing: _Cycle<int>(
                  value: s.shellTimeoutSeconds,
                  values: const [30, 60, 120, 300, 600],
                  label: (v) => '$v 秒',
                  onChanged: (v) => set((x) => x.copyWith(shellTimeoutSeconds: v)),
                ),
              ),
              SettingRow(
                icon: ArceSvg.clockCircle,
                title: 'モデルが指定できる上限',
                subtitle: 'timeout_seconds で伸ばせる最大の秒数',
                trailing: _Cycle<int>(
                  value: s.shellMaxTimeoutSeconds,
                  values: const [120, 300, 600, 1200, 3600],
                  label: (v) => '$v 秒',
                  onChanged: (v) => set((x) => x.copyWith(shellMaxTimeoutSeconds: v)),
                ),
              ),
              SettingRow(
                icon: ArceSvg.file,
                title: '出力の上限',
                subtitle: 'コマンドの出力を、モデルに渡す文字数（超えた分は初めと終わりを残します）',
                last: true,
                trailing: _Cycle<int>(
                  value: s.shellMaxOutputChars,
                  values: const [5000, 10000, 20000, 50000, 100000],
                  label: (v) => '$v 文字',
                  onChanged: (v) => set((x) => x.copyWith(shellMaxOutputChars: v)),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        ShellSecretsCard(app: app),
        const SizedBox(height: 10),
        HttpRequestCard(app: app),
      ],
    );
  }

  /// Bumped by 「一覧を既定に戻す」, so that the list's text field starts again from the stored value.
  int _dangerResets = 0;

  Future<void> _installLinux(AppController app) async {
    final ok = await _confirm(
      context,
      title: 'Linux 環境を入れますか？',
      body: 'Ubuntu Base 24.04（arm64・約 30 MB）をダウンロードして展開します。数分かかることがあります。'
          'ダウンロード中もアプリは使えます。',
      yes: '入れる',
    );
    if (!ok) return;
    try {
      await app.installLinux();
      if (!mounted) return;
      app.showToast('Linux 環境を入れました');
    } catch (e) {
      if (!mounted) return;
      app.showToast('入れられませんでした: $e');
    }
  }

  Future<void> _removeLinux(AppController app) async {
    final ok = await _confirm(
      context,
      title: 'Linux 環境を削除しますか？',
      body: 'Ubuntu のシステムを消します（ワークスペースの中身は残ります）。次に使うときは、もう一度入れ直します。',
      yes: '削除する',
    );
    if (!ok) return;
    await app.removeLinux();
    if (!mounted) return;
    app.showToast('Linux 環境を削除しました');
  }

  Future<void> _clearWorkspace(AppController app) async {
    final ok = await _confirm(
      context,
      title: 'ワークスペースを空にしますか？',
      body: '全チャットで共有している /workspace の中身を、すべて消します。元に戻せません。',
      yes: '空にする',
    );
    if (!ok) return;
    await app.clearLinuxWorkspace();
    if (!mounted) return;
    app.showToast('ワークスペースを空にしました');
  }

  Future<bool> _confirm(BuildContext context, {required String title, required String body, required String yes}) async {
    final answer = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('やめる')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: Text(yes)),
        ],
      ),
    );
    return answer ?? false;
  }

  Widget _subheading(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
        child: Text(text, style: ts(context, 11, weight: FontWeight.w700, color: context.c.muted)),
      );

  Widget _answerCard(
    BuildContext context,
    AppController app,
    AppSettings s,
    void Function(AppSettings Function(AppSettings)) set,
  ) {
        return ArceCard(
          child: Column(
            children: [
              _TextRow(
                icon: ArceSvg.chat,
                title: '口調',
                subtitle: '回答の話し方（200文字まで）。ルールは変えられません',
                value: s.tone,
                hint: '例: 丁寧で簡潔に',
                onChanged: (v) => set((x) => x.copyWith(tone: v)),
              ),
              _SliderRow(
                icon: ArceSvg.sliders,
                title: '速度 ⇔ 精度',
                subtitle: '左: 速い（思考を省略） / 右: 正確（長く考える）',
                value: s.speedAccuracy,
                onChanged: (v) => set((x) => x.copyWith(speedAccuracy: v)),
              ),
              SettingRow(
                icon: ArceSvg.compass,
                title: 'エージェント',
                subtitle: '用途に合わせた役割。自動のときは内容から選びます',
                trailing: _Dropdown<String>(
                  value: s.agentOverride,
                  items: {'': '自動', for (final a in Agents.all) a.id: a.displayName},
                  onChanged: (v) => set((x) => x.copyWith(agentOverride: v)),
                ),
              ),
              SettingRow(
                icon: ArceSvg.brainOutline,
                title: 'AIによるエージェント選択',
                subtitle: '判断に迷うときだけ読み込み済みモデルに選ばせます',
                trailing: ArceSwitch(value: s.aiAgentSelection, onChanged: (v) => set((x) => x.copyWith(aiAgentSelection: v))),
              ),
              SettingRow(
                icon: ArceSvg.file,
                title: '返信の最大文字数',
                subtitle: '0 は制限なし',
                last: true,
                trailing: _Cycle<int>(
                  value: s.maxChars,
                  values: const [0, 300, 800, 1500, 3000],
                  label: (v) => v == 0 ? '制限なし' : '$v',
                  onChanged: (v) => set((x) => x.copyWith(maxChars: v)),
                ),
              ),
            ],
          ),
        );
  }

  Widget _developerCard(
    BuildContext context,
    AppController app,
    AppSettings s,
    void Function(AppSettings Function(AppSettings)) set,
  ) {
        return ArceCard(
          child: Column(
            children: [
              SettingRow(
                icon: ArceSvg.file,
                title: '最大トークン数（共通）',
                subtitle: '1回の返信の長さの目安（思考の分も含みます）。ローカル・オンラインで別に決めたとき、'
                    'また DeepSeek V4・GLM-5 のように公式の推奨があるモデルでは、そちらが先です',
                trailing: _Cycle<int>(
                  value: s.maxTokens,
                  values: const [1024, 2048, 4096, 8192, 16384, 32768, 65536, 131072, 262144],
                  label: (v) => '$v',
                  onChanged: (v) => set((x) => x.copyWith(maxTokens: v)),
                ),
              ),
              SettingRow(
                icon: ArceSvg.retry,
                title: 'エラー再書き込み回数',
                subtitle: '途中で切れたツール呼び出しを書き直す回数',
                trailing: _Cycle<int>(
                  value: s.retryLimit,
                  values: const [0, 1, 2, 3],
                  label: (v) => '$v',
                  onChanged: (v) => set((x) => x.copyWith(retryLimit: v)),
                ),
              ),
              SettingRow(
                icon: ArceSvg.bolt,
                title: 'ツール呼び出しの上限',
                subtitle: '1回の返信の中で使えるツールの回数の上限です。引数が違う呼び出し（別の言葉での検索など）は、繰り返しとはみなしません',
                last: true,
                trailing: _Cycle<int>(
                  value: s.maxToolRounds,
                  values: const [2, 6, 10, 20, 30, 100, 0],
                  label: (v) => v == 0 ? 'なし' : '$v',
                  onChanged: (v) => set((x) => x.copyWith(maxToolRounds: v)),
                ),
              ),
            ],
          ),
        );
  }

  /// A decimal field that reads "not set" as -1, so an empty box means "the app's own value".
  Widget _decimal({
    required String icon,
    required String title,
    required String subtitle,
    required double value,
    required String hint,
    required double max,
    required void Function(double) onChanged,
    bool last = false,
  }) => _TextRow(
    icon: icon,
    title: title,
    subtitle: subtitle,
    value: value < 0 ? '' : '$value',
    hint: hint,
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    last: last,
    onChanged: (v) {
      final parsed = double.tryParse(v.trim());
      onChanged(parsed == null ? -1 : parsed.clamp(0, max).toDouble());
    },
  );

  /// A whole-number field that reads "not set" as 0.
  Widget _whole({
    required String icon,
    required String title,
    required String subtitle,
    required int value,
    required String hint,
    required int max,
    required void Function(int) onChanged,
    bool last = false,
  }) => _TextRow(
    icon: icon,
    title: title,
    subtitle: subtitle,
    value: value <= 0 ? '' : '$value',
    hint: hint,
    keyboardType: TextInputType.number,
    last: last,
    onChanged: (v) {
      final parsed = int.tryParse(v.trim());
      onChanged(parsed == null ? 0 : parsed.clamp(0, max));
    },
  );

  Widget _limits(AppSettings s, void Function(AppSettings Function(AppSettings)) set) {
    Widget cycle(
      String icon,
      String title,
      String subtitle,
      int value,
      List<int> values,
      AppSettings Function(AppSettings, int) apply, {
      String unit = '',
      bool last = false,
    }) => SettingRow(
      icon: icon,
      title: title,
      subtitle: subtitle,
      last: last,
      trailing: _Cycle<int>(value: value, values: values, label: (v) => '$v$unit', onChanged: (v) => set((x) => apply(x, v))),
    );
    return ArceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              '押すと次の値になります。ほかの値は、チャットで「添付の文字数を 20000 にして」のように頼めます。',
              style: ts(context, 10, color: context.c.muted, height: 1.6),
            ),
          ),
          cycle(ArceSvg.paperclip, '添付できるファイルの数', '1回のメッセージに付けられる数', s.attachMaxFiles, const [1, 3, 5, 10, 20],
              (x, v) => x.copyWith(attachMaxFiles: v)),
          cycle(ArceSvg.eye, 'ブラウザで開く試作ページを残す数', '生成した HTML をブラウザで開く入口（アドレスは推測できない）。これを超えると古いものから消えます', s.previewMaxPages, const [10, 25, 50, 100, 200],
              (x, v) => x.copyWith(previewMaxPages: v)),
          cycle(ArceSvg.eye, 'show で一度に渡せるページの文字数', 'モデルが道具 show に HTML・SVG を直接渡すときの最大の長さ。これより長いページは、ファイルに書いて、パスで見せます', s.showMaxChars, const [50000, 100000, 200000, 500000, 1000000],
              (x, v) => x.copyWith(showMaxChars: v)),
          cycle(ArceSvg.eye, 'show で表示するフォルダから配るファイルの大きさ（MB）', '/workspace のページの画像やスクリプトなどの 1 ファイルの上限。これを超えるファイルは配りません', s.showMaxFileMb, const [5, 20, 50, 100, 200],
              (x, v) => x.copyWith(showMaxFileMb: v)),
          cycle(ArceSvg.file, '添付1ファイルから読む文字数', 'これを超えた分は省略されます', s.attachCharsPerFile, const [2000, 4000, 8000, 16000, 32000],
              (x, v) => x.copyWith(attachCharsPerFile: v)),
          cycle(ArceSvg.file, '添付全体で読む文字数', 'コンテキストを使い切らないための上限', s.attachTotalChars, const [8000, 16000, 32000, 64000, 128000],
              (x, v) => x.copyWith(attachTotalChars: v)),
          cycle(ArceSvg.eye, '送る画像の大きさ', '画像に対応するモデルへ送る1枚の上限', s.attachImageMb, const [1, 2, 4, 8, 16],
              (x, v) => x.copyWith(attachImageMb: v), unit: ' MB'),
          cycle(ArceSvg.clock, '検索・天気のタイムアウト', 'この秒数で通信をあきらめます', s.httpTimeoutSeconds, const [10, 20, 30, 60],
              (x, v) => x.copyWith(httpTimeoutSeconds: v), unit: ' 秒'),
          cycle(ArceSvg.bolt, 'MCPサーバーのタイムアウト', '道具の呼び出しを待つ時間', s.mcpTimeoutSeconds, const [20, 40, 60, 120],
              (x, v) => x.copyWith(mcpTimeoutSeconds: v), unit: ' 秒'),
          cycle(ArceSvg.bolt, 'MCP の結果の上限', 'MCP の道具の結果を、モデルに渡す文字数（超えた分は省きます。画像などのファイルは、中身ではなく説明を渡します）', s.mcpResultMaxChars, const [5000, 15000, 30000, 100000],
              (x, v) => x.copyWith(mcpResultMaxChars: v), unit: ' 文字'),
          cycle(ArceSvg.cube, 'オンラインモデルの応答のタイムアウト', '最初の応答までに待つ時間', s.providerTimeoutSeconds, const [30, 60, 120, 300, 600],
              (x, v) => x.copyWith(providerTimeoutSeconds: v), unit: ' 秒'),
          cycle(ArceSvg.cube, 'flex のモデルの応答のタイムアウト', 'service_tier を flex にしたモデル（安くて遅い処理）を待つ時間', s.flexTimeoutSeconds, const [300, 600, 900, 1800, 3600],
              (x, v) => x.copyWith(flexTimeoutSeconds: v), unit: ' 秒'),
          cycle(ArceSvg.retry, 'ツールの繰り返しで止める回数', '同じ道具を同じ引数で、この回数呼んだら、ループとみなして止めます（引数が違えば数えません）', s.toolRepeatLimit, const [2, 3, 4, 5],
              (x, v) => x.copyWith(toolRepeatLimit: v)),
          SettingRow(
            icon: ArceSvg.file,
            title: '長い会話を要約して、文脈に収める',
            subtitle: '文脈がいっぱいになる前に、古い道具の結果を切り詰め、それでも足りなければ、直近の発言より前をモデルに要約させます（新しい会話を始めなくて済みます）',
            trailing: ArceSwitch(value: s.compactEnabled, onChanged: (v) => set((x) => x.copyWith(compactEnabled: v))),
          ),
          cycle(ArceSvg.file, '要約を始める文脈の使用率', 'この割合を超えそうなときに、送る前に要約します（文脈の大きさが分かるモデルだけ）', s.compactAtPercent, const [50, 65, 80, 90],
              (x, v) => x.copyWith(compactAtPercent: v), unit: ' %'),
          cycle(ArceSvg.file, '要約せずに残す直近の発言', 'あなたの直近の発言を、この数だけ（その後の返信も）そのまま残します', s.compactKeepTurns, const [2, 4, 6, 10],
              (x, v) => x.copyWith(compactKeepTurns: v)),
          cycle(ArceSvg.file, '要約の長さ', '要約を、この文字数以内で書かせます', s.compactSummaryChars, const [1000, 2000, 3000, 6000],
              (x, v) => x.copyWith(compactSummaryChars: v), unit: ' 文字'),
          cycle(ArceSvg.file, '古い道具の結果の長さ', '要約の前に、古い道具の結果をこの文字数まで切り詰めます', s.compactToolResultChars, const [500, 1500, 4000, 10000],
              (x, v) => x.copyWith(compactToolResultChars: v), unit: ' 文字'),
          cycle(ArceSvg.retry, 'ダウンロードの試行回数', '通信が切れたとき、続きから取り直す回数（モデルも更新も）', s.updateRetryAttempts, const [1, 3, 5, 10],
              (x, v) => x.copyWith(updateRetryAttempts: v)),
          cycle(ArceSvg.clock, 'ダウンロードの無通信の判定', 'この秒数なにも届かなければ、切れたとみなします', s.updateStallSeconds, const [15, 30, 60, 120],
              (x, v) => x.copyWith(updateStallSeconds: v), unit: ' 秒'),
          cycle(ArceSvg.bolt, 'ダウンロードの同時接続数', '大きなファイルを分けて同時に取ります。遅いときに増やします（1で分けない）', s.downloadConnections, const [1, 2, 4, 8, 16],
              (x, v) => x.copyWith(downloadConnections: v)),
          SettingRow(
            icon: ArceSvg.retry,
            title: '止まったダウンロードを次の起動で続ける',
            subtitle: 'アプリを閉じて止まったモデルのダウンロードを、起動したときに続きから取ります（モバイル回線でも始まります）',
            last: true,
            trailing: ArceSwitch(value: s.resumeDownloadsOnStart, onChanged: (v) => set((x) => x.copyWith(resumeDownloadsOnStart: v))),
          ),
        ],
      ),
    );
  }

  Widget _sessionRow(
    String title,
    String subtitle,
    int value,
    List<int> values,
    AppSettings Function(AppSettings, int) change,
    void Function(AppSettings Function(AppSettings)) set, {
    String unit = '',
  }) =>
      SettingRow(
        icon: ArceSvg.clock,
        title: title,
        subtitle: subtitle,
        trailing: _Cycle<int>(
          value: value,
          values: values,
          label: (v) => '$v$unit',
          onChanged: (v) => set((x) => change(x, v)),
        ),
      );

  Widget _titleCard(AppController app, AppSettings s, void Function(AppSettings Function(AppSettings)) set) {
    return ArceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              '新しい会話の最初の答えが終わると、モデルが短いタイトルを考えて、履歴に付けます（失敗したときは、最初の質問がタイトルのままです）。'
              'ローカルモデルでは自動では付けません（次の返信が最初から読み直しになり、遅くなるため）。'
              'タイトル用にオンラインモデルを選ぶと、ローカルモデルで話しているときも付きます。',
              style: ts(context, 10, color: context.c.muted, height: 1.6),
            ),
          ),
          SettingRow(
            icon: ArceSvg.pencil,
            title: 'タイトルをモデルに考えさせる',
            subtitle: 'オフにすると、最初の質問がそのままタイトルになります',
            trailing: ArceSwitch(value: s.autoTitle, onChanged: (v) => set((x) => x.copyWith(autoTitle: v))),
          ),
          SettingRow(
            icon: ArceSvg.cube,
            title: 'タイトルを考えるモデル',
            subtitle: '未選択なら、使用中のオンラインモデル（安いモデルにすると節約できます）',
            trailing: _ModelRefField(app: app, value: s.titleModel, title: 'タイトルを考えるモデル', width: 168, onChanged: (v) => set((x) => x.copyWith(titleModel: v))),
          ),
          SettingRow(
            icon: ArceSvg.sliders2,
            title: 'タイトルの最大文字数',
            subtitle: '長いタイトルは、この長さで切ります',
            last: true,
            trailing: _Cycle<int>(
              value: s.titleMaxChars,
              values: const [15, 20, 30, 40, 60],
              label: (v) => '$v',
              onChanged: (v) => set((x) => x.copyWith(titleMaxChars: v)),
            ),
          ),
        ],
      ),
    );
  }

  /// The developer models after the first one: each can be changed or removed, and one more is added
  /// by choosing a model in the last row. The jobs of one `delegate` call are spread over all of them.
  List<Widget> _moreDevelopers(AppController app, AppSettings s, void Function(AppSettings Function(AppSettings)) set) {
    final more = s.coding.moreDevelopers;
    void save(List<String> refs) => set((x) => x.copyWith(developerModelsMore: refs.where((r) => r.trim().isNotEmpty).join('\n')));
    return [
      for (var i = 0; i < more.length; i++)
        SettingRow(
          icon: ArceSvg.bolt,
          title: 'coding の追加モデル ${i + 1}',
          subtitle: '仕事を分け合って、同時に書きます',
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            _ModelRefField(
              app: app,
              value: more[i],
              title: 'coding の追加モデル ${i + 1}',
              width: 140,
              onChanged: (v) => save([for (var j = 0; j < more.length; j++) j == i ? v : more[j]]),
            ),
            IconTap(svg: ArceSvg.close, tooltip: '外す', onTap: () => save([for (var j = 0; j < more.length; j++) if (j != i) more[j]])),
          ]),
        ),
      SettingRow(
        icon: ArceSvg.plus,
        title: 'coding のモデルを追加',
        subtitle: '右で選ぶと、coding が増えます（安いモデルを並べると速くなります）',
        trailing: _ModelRefField(
          app: app,
          value: '',
          title: 'coding の追加モデル',
          width: 140,
          onChanged: (v) {
            if (v.isNotEmpty) save([...more, v]);
          },
        ),
      ),
    ];
  }

  Widget _codingMode(AppController app, AppSettings s, void Function(AppSettings Function(AppSettings)) set) {
    final c = context.c;
    final coding = s.coding;
    final String? problem;
    if (!coding.enabled) {
      problem = null;
    } else if (coding.developers.isEmpty) {
      problem = 'coding のモデルを 1 つ以上選ぶと、分担が始まります。';
    } else if (!coding.plannerFollowsModel && coding.planner.isEmpty) {
      problem = 'plan のモデルを選ぶか、「使用中のモデルに合わせる」をオンにすると、分担が始まります。';
    } else if (((!coding.plannerFollowsModel && coding.planner.startsWith('${CodingSettings.localProvider}|')) ||
            coding.developers.any((d) => d.startsWith('${CodingSettings.localProvider}|'))) &&
        !app.models.isLoaded) {
      problem = 'ローカルモデルを選んでいますが、まだ読み込まれていません。読み込むまで、いつもどおり1つのモデルで答えます。';
    } else {
      problem = null;
    }
    Widget pick(String icon, String title, String subtitle, String value, void Function(String) onPick) => SettingRow(
      icon: icon,
      title: title,
      subtitle: subtitle,
      trailing: _ModelRefField(app: app, value: value, title: title, width: 168, onChanged: onPick),
    );
    return ArceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              'Coding エージェントのとき、plan があなたに答えます。plan は設計と分担数を決め、coding に担当を調べさせます。'
              'coding のレポートが全部そろうと、plan がまとめて設計を見せ、あなたに実装してよいか聞きます。直してほしければ設計を見直して調べ直し、'
              'OK なら coding が担当を実装して、全部そろうまで待ちます。時間がかかりそうなら、plan は分担数を増やす提案をします。'
              'アプリがするのは、同時に走らせる・レポートと結果をそろえる・OK の前に実装させない・ファイルを見せる、です。'
              'plan は短い指示と確認だけを書くので、長いコードの費用を抑えられます。ローカルモデルも選べます（その役は1つずつ動きます）。',
              style: ts(context, 10, color: c.muted, height: 1.6),
            ),
          ),
          SettingRow(
            icon: ArceSvg.codeEdit,
            title: '分担モード',
            subtitle: 'plan が設計と分担数を決め、coding が担当を調べてから実装します',
            trailing: ArceSwitch(value: s.codingPlanEnabled, onChanged: (v) => set((x) => x.copyWith(codingPlanEnabled: v))),
          ),
          if (problem != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(problem, style: ts(context, 10, color: c.amber, height: 1.6)),
            ),
          SettingRow(
            icon: ArceSvg.compass,
            title: 'plan は、使用中のモデルに合わせる',
            subtitle: 'オン：入力欄で選んだモデルが plan になります（切り替えると、コーディングの依頼もそのモデルで答えます）。オフ：下で決めたモデルに固定します',
            trailing: ArceSwitch(value: s.codingPlannerFollows, onChanged: (v) => set((x) => x.copyWith(codingPlannerFollows: v))),
          ),
          if (!s.codingPlannerFollows)
            pick(ArceSvg.compass, 'plan のモデル', 'あなたに答え、仕事を分けて渡し、結果を確認します（高性能なモデル向き）', s.plannerModel,
                (v) => set((x) => x.copyWith(plannerModel: v))),
          pick(ArceSvg.bolt, 'coding のモデル', 'コードを書きます（安いモデル・ローカルモデル向き）', s.developerModel,
              (v) => set((x) => x.copyWith(developerModel: v))),
          ..._moreDevelopers(app, s, set),
          SettingRow(
            icon: ArceSvg.grid,
            title: 'タスクの最大数',
            subtitle: 'plan が 1 回の依頼に入れてよい仕事の数（超えた分は断ります）',
            trailing: _Cycle<int>(
              value: coding.maxTasks,
              values: const [1, 2, 3, 4, 6, 8, 12, 16],
              label: (v) => '$v',
              onChanged: (v) => set((x) => x.copyWith(codingMaxTasks: v)),
            ),
          ),
          SettingRow(
            icon: ArceSvg.sliders2,
            title: '1 つの coding が同時に走らせる数',
            subtitle: 'coding が何個の仕事を同時に受けるか（ローカルモデルは常に1）。coding が複数あれば、その合計だけ同時に走ります',
            trailing: _Cycle<int>(
              value: coding.parallel,
              values: const [1, 2, 3, 4, 6, 8],
              label: (v) => '$v',
              onChanged: (v) => set((x) => x.copyWith(codingParallel: v)),
            ),
          ),
          SettingRow(
            icon: ArceSvg.sliders2,
            title: '分担数の上限',
            subtitle: '同時に動く担当の数の上限。plan はこの中で分担数を決め、足りなければ増やす提案をします',
            trailing: _Cycle<int>(
              value: coding.maxWorkers,
              values: const [1, 2, 3, 4, 6, 8, 12, 16],
              label: (v) => '$v',
              onChanged: (v) => set((x) => x.copyWith(codingMaxWorkers: v)),
            ),
          ),
          SettingRow(
            icon: ArceSvg.check,
            title: '先に調べて、確認してから実装する',
            subtitle: 'オン：coding が担当を調べてレポートを返し、全部そろったら plan がまとめてあなたに見せます。OK が出るまで実装しません。オフ：すぐに実装します',
            trailing: ArceSwitch(value: coding.investigateFirst, onChanged: (v) => set((x) => x.copyWith(codingInvestigateFirst: v))),
          ),
          SettingRow(
            icon: ArceSvg.retry,
            title: 'レビューの回数',
            subtitle: 'plan が直しを指示してよい回数（plan への指示に書きます）。0 なら直させません',
            trailing: _Cycle<int>(
              value: coding.reviewRounds,
              values: const [0, 1, 2, 3],
              label: (v) => '$v',
              onChanged: (v) => set((x) => x.copyWith(codingReviewRounds: v)),
            ),
          ),
          SettingRow(
            icon: ArceSvg.eye,
            title: 'plan が読む結果の長さ',
            subtitle: 'coding の結果を、plan に渡す文字数（1 件ごと。あなたには全部見せます）',
            trailing: _Cycle<int>(
              value: coding.resultChars,
              values: const [3000, 6000, 12000, 24000, 50000],
              label: (v) => '$v',
              onChanged: (v) => set((x) => x.copyWith(codingResultChars: v)),
            ),
          ),
          SettingRow(
            icon: ArceSvg.file,
            title: 'coding の最大トークン',
            subtitle: '1つのタスクのコードの長さ（思考の分も含みます）。自動は、モデルの推奨と上限に合わせます',
            last: true,
            trailing: _Cycle<int>(
              value: coding.developerMaxTokens,
              values: const [0, 8192, 16384, 32768, 65536, 131072, 262144],
              label: (v) => v == 0 ? '自動' : '$v',
              onChanged: (v) => set((x) => x.copyWith(codingDeveloperMaxTokens: v)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _onlineModel(AppSettings s, void Function(AppSettings Function(AppSettings)) set) => ArceCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            'オンラインモデルだけに効く既定値です（ローカルモデルは別。次の「ローカルモデルの設定」）。'
            'モデルごとの設定（プロバイダ → モデル → 編集）があれば、そちらが先です。空欄はアプリの既定値です。',
            style: ts(context, 10, color: context.c.muted, height: 1.6),
          ),
        ),
        _decimal(
          icon: ArceSvg.sliders,
          title: 'temperature',
          subtitle: '大きいほど表現がばらつきます（0〜2）',
          value: s.onlineTemperature,
          hint: '0.7',
          max: 2,
          onChanged: (v) => set((x) => x.copyWith(onlineTemperature: v)),
        ),
        _decimal(
          icon: ArceSvg.sliders2,
          title: 'top_p',
          subtitle: '選ぶ言葉の範囲（0〜1）',
          value: s.onlineTopP,
          hint: '0.95',
          max: 1,
          onChanged: (v) => set((x) => x.copyWith(onlineTopP: v)),
        ),
        _whole(
          icon: ArceSvg.file,
          title: '最大トークン',
          subtitle: '1回の返信の長さの基準（思考の分も含みます）。空欄は、モデルの推奨か共通の値',
          value: s.onlineMaxTokens,
          hint: '${s.maxTokens}',
          max: 1048576,
          onChanged: (v) => set((x) => x.copyWith(onlineMaxTokens: v)),
        ),
        SettingRow(
          icon: ArceSvg.file,
          title: 'モデルごとの最大出力を使う',
          subtitle: '最大トークンが空欄のとき、そのモデルが返せる最大の長さ（提供元の一覧から取得）で頼みます。取得できなければ共通の値です',
          trailing: ArceSwitch(value: s.onlineUseModelMax, onChanged: (v) => set((x) => x.copyWith(onlineUseModelMax: v))),
        ),
        _TextRow(
          icon: ArceSvg.chat,
          title: '追加プロンプト',
          subtitle: 'オンラインモデルにだけ送る指示（2000文字まで）',
          value: s.onlinePrompt,
          hint: '例: 回答は必ず日本語で',
          maxLines: 3,
          onChanged: (v) => set((x) => x.copyWith(onlinePrompt: v)),
        ),
        SettingRow(
          icon: ArceSvg.retry,
          title: 'モデルの上限を自動で調べる',
          subtitle: '使い始めたモデルのコンテキスト長・最大出力・画像対応を、提供元のモデル一覧から調べて保存します',
          trailing: ArceSwitch(value: s.autoFetchModelInfo, onChanged: (v) => set((x) => x.copyWith(autoFetchModelInfo: v))),
        ),
        SettingRow(
          icon: ArceSvg.globe,
          title: 'Hugging Face からも調べる',
          subtitle: '提供元が上限を返さないとき、モデル名（owner/name）だけを huggingface.co に送って、'
              'コンテキスト長を読みます',
          last: true,
          trailing: ArceSwitch(
            value: s.fetchModelInfoFromHub,
            onChanged: (v) => set((x) => x.copyWith(fetchModelInfoFromHub: v)),
          ),
        ),
      ],
    ),
  );

  Widget _localModel(AppController app, AppSettings s, void Function(AppSettings Function(AppSettings)) set) => ArceCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            'ローカルモデル（Android）だけに効く設定です。オンラインモデルは別（上の「オンラインモデルの設定」）。'
            '空欄はアプリの既定値です。コンテキスト長・スレッド・GPU・KV キャッシュは、次にモデルを読み込むときに反映されます。',
            style: ts(context, 10, color: context.c.muted, height: 1.6),
          ),
        ),
        _decimal(
          icon: ArceSvg.sliders,
          title: 'temperature',
          subtitle: '大きいほど表現がばらつきます（0〜2）',
          value: s.localTemperature,
          hint: '0.6 / 0.7（思考の有無で変わります）',
          max: 2,
          onChanged: (v) => set((x) => x.copyWith(localTemperature: v)),
        ),
        _decimal(
          icon: ArceSvg.sliders2,
          title: 'top_p',
          subtitle: '選ぶ言葉の範囲（0〜1）',
          value: s.localTopP,
          hint: '0.95 / 0.8',
          max: 1,
          onChanged: (v) => set((x) => x.copyWith(localTopP: v)),
        ),
        _whole(
          icon: ArceSvg.sliders,
          title: 'top_k',
          subtitle: '候補にする言葉の数（0 は既定）',
          value: s.localTopK,
          hint: '20',
          max: 200,
          onChanged: (v) => set((x) => x.copyWith(localTopK: v)),
        ),
        _decimal(
          icon: ArceSvg.sliders2,
          title: 'min_p',
          subtitle: '確率がこれ未満の言葉を除きます（0〜1）',
          value: s.localMinP,
          hint: '0',
          max: 1,
          onChanged: (v) => set((x) => x.copyWith(localMinP: v)),
        ),
        _decimal(
          icon: ArceSvg.retry,
          title: 'DRY（繰り返しの抑制）',
          subtitle: '大きいほど、同じ言い回しの繰り返しを避けます（0 でオフ）',
          value: s.localDryMultiplier,
          hint: '0.8',
          max: 5,
          onChanged: (v) => set((x) => x.copyWith(localDryMultiplier: v)),
        ),
        _whole(
          icon: ArceSvg.file,
          title: '最大トークン',
          subtitle: '1回の返信の長さの基準。空欄は共通の値',
          value: s.localMaxTokens,
          hint: '${s.maxTokens}',
          max: 32768,
          onChanged: (v) => set((x) => x.copyWith(localMaxTokens: v)),
        ),
        _TextRow(
          icon: ArceSvg.chat,
          title: '追加プロンプト',
          subtitle: 'ローカルモデルにだけ送る指示（2000文字まで）',
          value: s.localPrompt,
          hint: '例: 簡潔に答えてください',
          maxLines: 3,
          onChanged: (v) => set((x) => x.copyWith(localPrompt: v)),
        ),
        SettingRow(
          icon: ArceSvg.sliders,
          title: 'Context Length',
          subtitle: 'モデルが一度に扱う長さ。大きいほどメモリを使います',
          trailing: _Cycle<int>(
            value: s.contextLength,
            values: const [2048, 4096, 8192, 16384],
            label: (v) => '$v',
            onChanged: (v) => set((x) => x.copyWith(contextLength: v)),
          ),
        ),
        SettingRow(
          icon: ArceSvg.sliders2,
          title: 'CPU Threads',
          subtitle: 'Auto は端末のコア数から決めます',
          trailing: _Cycle<int>(
            value: s.threads,
            values: const [0, 1, 2, 4, 8],
            label: (v) => v == 0 ? 'Auto' : '$v',
            onChanged: (v) => set((x) => x.copyWith(threads: v)),
          ),
        ),
        SettingRow(
          icon: ArceSvg.bolt,
          title: 'HyperLoad',
          subtitle: 'CPUを使い切って高速化します（発熱・消費電力が増えます）',
          trailing: ArceSwitch(value: s.hyperLoad, onChanged: (v) => set((x) => x.copyWith(hyperLoad: v))),
        ),
        SettingRow(
          icon: ArceSvg.compass,
          title: 'GPU オフロード',
          subtitle: 'GPU に任せる量（対応する端末のみ）',
          trailing: _Dropdown<GpuOffload>(
            value: s.gpuOffload,
            items: const {
              GpuOffload.auto: 'Auto',
              GpuOffload.cpuOnly: 'CPUのみ',
              GpuOffload.gpuPriority: 'GPU優先',
              GpuOffload.maxGpu: '最大',
            },
            onChanged: (v) => set((x) => x.copyWith(gpuOffload: v)),
          ),
        ),
        SettingRow(
          icon: ArceSvg.sliders,
          title: 'KV キャッシュ',
          subtitle: 'Q8_0 でメモリが約半分、Q4_0 で約3分の1。小さいほど精度は少し落ちます',
          trailing: _Cycle<KvCacheType>(
            value: s.kvCache,
            values: KvCacheType.values,
            label: (v) => switch (v) {
              KvCacheType.f16 => 'F16',
              KvCacheType.q8_0 => 'Q8_0',
              KvCacheType.q4_0 => 'Q4_0',
            },
            onChanged: (v) => set((x) => x.copyWith(kvCache: v)),
          ),
        ),
        SettingRow(
          icon: ArceSvg.file,
          title: 'KV キャッシュをファイルに保存',
          subtitle: '会話の途中までの計算結果を保存し、開き直したときの待ち時間を省きます'
              '（Android の llama.cpp のみ。1つの会話で数百MBになることがあります）',
          last: !s.kvSnapshotEnabled,
          trailing: ArceSwitch(
            value: s.kvSnapshotEnabled,
            onChanged: (v) {
              set((x) => x.copyWith(kvSnapshotEnabled: v));
              // off means the files are not wanted any more
              if (!v) app.clearKvSnapshots();
            },
          ),
        ),
        if (s.kvSnapshotEnabled) ...[
          SettingRow(
            icon: ArceSvg.file,
            title: '保存の上限（合計）',
            subtitle: '超えたら、いちばん長く使っていない会話の分から消します',
            trailing: _Cycle<int>(
              value: s.kvSnapshotMaxMb,
              values: const [256, 512, 1024, 2048, 4096],
              label: (v) => '$v MB',
              onChanged: (v) => set((x) => x.copyWith(kvSnapshotMaxMb: v)),
            ),
          ),
          SettingRow(
            icon: ArceSvg.sliders,
            title: '保存する最小の長さ',
            subtitle: 'これより短いプロンプトは、計算し直すほうが速いので保存しません',
            trailing: _Cycle<int>(
              value: s.kvSnapshotMinTokens,
              values: const [256, 512, 1024, 2048],
              label: (v) => '$v トークン',
              onChanged: (v) => set((x) => x.copyWith(kvSnapshotMinTokens: v)),
            ),
          ),
          SettingRow(
            icon: ArceSvg.close,
            title: '保存済みのキャッシュ',
            subtitle: app.canSaveKv
                ? '合計 ${(app.kvSnapshotBytes / 1048576).toStringAsFixed(1)} MB'
                : 'この端末（OS）では保存できません',
            last: true,
            trailing: SoftButton(label: 'すべて削除', onTap: app.clearKvSnapshots),
          ),
        ],
        SettingRow(
          icon: ArceSvg.alert,
          title: 'Force Execution',
          subtitle: 'メモリ不足の警告があっても、モデルの選択を許可します',
          last: !Platform.isAndroid,
          trailing: ArceSwitch(value: s.forceExecution, onChanged: (v) => set((x) => x.copyWith(forceExecution: v))),
        ),
        if (Platform.isAndroid) ProotCheckRow(app: app),
      ],
    ),
  );
}

/// The first screen of the settings: the heading, the search field, and the groups as buttons, two to a
/// row. While something is typed, the results (the rows of every group that match) take the place of the
/// buttons; a result opens the screen of its group, and nothing scrolls to follow it.
class _Landing extends StatefulWidget {
  const _Landing({required this.onOpen});

  final ValueChanged<SettingsSection> onOpen;

  @override
  State<_Landing> createState() => _LandingState();
}

class _LandingState extends State<_Landing> {
  /// The space between two buttons, across and down.
  static const _gap = 10.0;

  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final text = _query.text;
    final hits = text.trim().isEmpty ? const <SettingsHit>[] : SettingsSearch.search(settingsIndex, text, limit: 40);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const PageHeading('設定', '項目を押すと、その設定の画面に移ります。'),
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: ArceTextField(
            key: const ValueKey('settings-search'),
            controller: _query,
            textInputAction: TextInputAction.search,
            onChanged: (_) => setState(() {}),
            style: ts(context, 13),
            decoration: InputDecoration(
              isDense: true,
              hintText: '設定を検索（例：トークン、通知、タイムアウト）',
              hintStyle: ts(context, 12, color: c.faint),
              prefixIcon: Padding(padding: const EdgeInsets.all(11), child: ArceIcon(ArceSvg.search, size: 16, color: c.muted)),
              prefixIconConstraints: const BoxConstraints(minWidth: 38, minHeight: 38),
              suffixIcon: text.isEmpty
                  ? null
                  : IconTap(
                      svg: ArceSvg.close,
                      tooltip: '検索をやめる',
                      onTap: () => setState(_query.clear),
                    ),
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        if (text.trim().isNotEmpty)
          _results(context, hits)
        else
          // Two to a row, and the two buttons of a row are as tall as the taller one (a Wrap let each one
          // be as tall as its own text, so the lower edges did not line up).
          Column(
            children: [
              for (var i = 0; i < settingsGroups.length; i += 2)
                Padding(
                  padding: EdgeInsets.only(bottom: i + 2 < settingsGroups.length ? _gap : 0),
                  child: IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: _GroupButton(group: settingsGroups[i], onTap: () => widget.onOpen(settingsGroups[i].section))),
                        const SizedBox(width: _gap),
                        Expanded(
                          child: i + 1 < settingsGroups.length
                              ? _GroupButton(group: settingsGroups[i + 1], onTap: () => widget.onOpen(settingsGroups[i + 1].section))
                              : const SizedBox.shrink(),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
      ],
    );
  }

  Widget _results(BuildContext context, List<SettingsHit> hits) {
    final c = context.c;
    if (hits.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Text('見つかりませんでした。別のことばで試してください（「トークン」「通知」「上限」など）。', style: ts(context, 11, color: c.muted, height: 1.6)),
      );
    }
    return ArceCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          for (var i = 0; i < hits.length; i++)
            InkWell(
              key: ValueKey('settings-hit-$i'),
              onTap: () => widget.onOpen(SettingsSection.values.byName(hits[i].entry.sectionId)),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                decoration: BoxDecoration(border: i == hits.length - 1 ? null : Border(bottom: BorderSide(color: c.line))),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      settingsSectionTitle(SettingsSection.values.byName(hits[i].entry.sectionId)),
                      style: ts(context, 9, color: c.accent, weight: FontWeight.w700),
                    ),
                    const SizedBox(height: 2),
                    Text(hits[i].entry.title, style: ts(context, 12, weight: FontWeight.w600, height: 1.4)),
                    if (hits[i].entry.subtitle.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(hits[i].entry.subtitle, maxLines: 2, overflow: TextOverflow.ellipsis, style: ts(context, 9.5, color: c.muted, height: 1.45)),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// One group as a button: its icon above its name and a line about what is in it.
class _GroupButton extends StatelessWidget {
  const _GroupButton({required this.group, required this.onTap});

  final SettingsGroup group;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return ArceCard(
      padding: EdgeInsets.zero,
      margin: EdgeInsets.zero,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: ValueKey('settings-group-${group.section.name}'),
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 128),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 13, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(color: c.accentSoft, borderRadius: BorderRadius.circular(12)),
                    alignment: Alignment.center,
                    child: ArceIcon(group.icon, size: 20, color: c.accent),
                  ),
                  const SizedBox(height: 10),
                  Text(group.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: ts(context, 12.5, weight: FontWeight.w700, height: 1.35)),
                  const SizedBox(height: 4),
                  Text(group.subtitle, maxLines: 3, overflow: TextOverflow.ellipsis, style: ts(context, 9.5, color: c.muted, height: 1.45)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The top of a group's own screen: the way back, and which group it is.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.group, required this.onBack});

  final SettingsGroup group;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          IconTap(key: const ValueKey('settings-back'), svg: ArceSvg.chevronLeft, tooltip: '設定の一覧へ戻る', onTap: onBack),
          const SizedBox(width: 6),
          Container(
            width: 31,
            height: 31,
            decoration: BoxDecoration(color: c.accentSoft, borderRadius: BorderRadius.circular(10)),
            alignment: Alignment.center,
            child: ArceIcon(group.icon, size: 16, color: c.accent),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(group.title, style: ts(context, 15, weight: FontWeight.w700))),
        ],
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Padding(
      padding: const EdgeInsets.fromLTRB(3, 11, 3, 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: Text('ARCE.AI · ローカルAI', style: ts(context, 9, color: c.muted))),
          const SizedBox(width: 8),
          ListenableBuilder(
            listenable: app.updates,
            builder: (context, _) => Text(
              'v${app.updates.currentVersion ?? '—'}',
              style: ts(context, 9, weight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _StyleOptions extends StatelessWidget {
  const _StyleOptions({required this.current, required this.onPick});
  final ThinkingStyle current;
  final ValueChanged<ThinkingStyle> onPick;

  static const _names = {
    ThinkingStyle.brand: 'ロゴ',
    ThinkingStyle.basic: '基本',
    ThinkingStyle.ring: 'リング',
    ThinkingStyle.pulse: 'パルス',
    ThinkingStyle.dots: 'ドット',
    ThinkingStyle.rotation: 'ローテーション',
  };

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 7,
        runSpacing: 7,
        children: [
          for (final style in ThinkingStyle.values)
            SizedBox(
              width: 92,
              child: Material(
                color: style == current ? c.accentSoft : c.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(11),
                  side: BorderSide(color: style == current ? c.accent : c.line),
                ),
                child: InkWell(
                  borderRadius: BorderRadius.circular(11),
                  onTap: () => onPick(style),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Column(
                      children: [
                        SizedBox(
                          height: 30,
                          child: Center(
                            child: ThinkingIcon(style: style, size: 25),
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          _names[style]!,
                          style: ts(
                            context,
                            9,
                            color: style == current ? c.accent : c.muted,
                            weight: style == current
                                ? FontWeight.w700
                                : FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Tapping steps to the next value, like the pill buttons of the original interface.
class _Cycle<T> extends StatelessWidget {
  const _Cycle({
    required this.value,
    required this.values,
    required this.label,
    required this.onChanged,
  });
  final T value;
  final List<T> values;
  final String Function(T) label;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final i = values.indexOf(value);
    return ValuePill(
      label(value),
      onTap: () => onChanged(values[(i + 1) % values.length]),
    );
  }
}

class _Dropdown<T> extends StatelessWidget {
  const _Dropdown({
    required this.value,
    required this.items,
    required this.onChanged,
  });
  final T value;
  final Map<T, String> items;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.line),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: items.containsKey(value) ? value : items.keys.first,
          isDense: true,
          dropdownColor: c.surface,
          icon: ArceIcon(ArceSvg.chevronDown, size: 14, color: c.muted),
          style: ts(context, 10, weight: FontWeight.w600),
          items: [
            for (final e in items.entries) DropdownMenuItem(value: e.key, child: Text(e.value)),
          ],
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ),
    );
  }
}

/// The choice of a model for a job (a provider's model, the device model, or none): the field
/// shows the choice, and a tap opens a full-height tree with a search field. The models used last
/// are at the top, so the ones in use are one tap away.
class _ModelRefField extends StatelessWidget {
  const _ModelRefField({
    required this.app,
    required this.value,
    required this.onChanged,
    required this.title,
    required this.width,
  });
  final AppController app;
  final String value;
  final ValueChanged<String> onChanged;
  final String title;
  final double width;

  static const _roots = [
    TreeLeaf('', '未選択'),
    TreeLeaf('${CodingSettings.localProvider}|', 'ローカルモデル'),
  ];

  String _label() {
    if (value.isEmpty) return '未選択';
    final parsed = CodingSettings.parseRef(value);
    if (parsed == null) return value;
    final (providerId, model) = parsed;
    if (providerId == CodingSettings.localProvider) return 'ローカルモデル';
    final provider = app.providers.byId(providerId);
    return '${provider == null ? providerId : (provider.label.isEmpty ? provider.id : provider.label)} · $model';
  }

  Future<void> _open(BuildContext context) async {
    final picked = await showModelPicker(
      context,
      title: title,
      selectedKey: value,
      note: '提供元ごとに分かれています。上の「最近使った」から選ぶと早く決められます。検索は提供元の名前でも絞れます',
      build: (query) => ModelTrees.forPicker(
        app.providers.providers,
        query: query,
        recent: app.providers.recentRefs,
        rootLeaves: _roots,
        marks: app.modelMarks,
        keepKey: value,
      ),
    );
    if (picked != null) onChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return SizedBox(
      width: width,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => _open(context),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: c.surface2,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: c.line),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(_label(), maxLines: 2, overflow: TextOverflow.ellipsis, style: ts(context, 10, weight: FontWeight.w600)),
              ),
              const SizedBox(width: 4),
              ArceIcon(ArceSvg.chevronDown, size: 14, color: c.muted),
            ],
          ),
        ),
      ),
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });
  final String icon;
  final String title;
  final String subtitle;
  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 1),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.line)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 31,
                height: 31,
                decoration: BoxDecoration(
                  color: c.accentSoft,
                  borderRadius: BorderRadius.circular(10),
                ),
                alignment: Alignment.center,
                child: ArceIcon(icon, size: 16, color: c.accent),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: ts(context, 11, weight: FontWeight.w600),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: ts(context, 9, color: c.muted, height: 1.45),
                    ),
                  ],
                ),
              ),
              Text(
                '${(value * 100).round()}%',
                style: ts(context, 10, weight: FontWeight.w600),
              ),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              overlayShape: SliderComponentShape.noOverlay,
            ),
            child: Slider(value: value, onChanged: onChanged, divisions: 20),
          ),
        ],
      ),
    );
  }
}

class _TextRow extends StatefulWidget {
  const _TextRow({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.hint,
    required this.onChanged,
    this.obscure = false,
    this.last = false,
    this.keyboardType,
    this.maxLines = 1,
  });

  final String icon;
  final String title;
  final String subtitle;
  final String value;
  final String hint;
  final ValueChanged<String> onChanged;
  final bool obscure;
  final bool last;
  final TextInputType? keyboardType;
  final int maxLines;

  @override
  State<_TextRow> createState() => _TextRowState();
}

class _TextRowState extends State<_TextRow> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.value,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 1),
      decoration: BoxDecoration(
        border: widget.last ? null : Border(bottom: BorderSide(color: c.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 31,
                height: 31,
                decoration: BoxDecoration(
                  color: c.accentSoft,
                  borderRadius: BorderRadius.circular(10),
                ),
                alignment: Alignment.center,
                child: ArceIcon(widget.icon, size: 16, color: c.accent),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      style: ts(context, 11, weight: FontWeight.w600),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      widget.subtitle,
                      style: ts(context, 9, color: c.muted, height: 1.45),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ArceTextField(
            controller: _controller,
            obscure: widget.obscure,
            keyboardType: widget.keyboardType,
            maxLines: widget.maxLines,
            style: ts(context, 11.5),
            onChanged: widget.onChanged,
            decoration: InputDecoration(
              isDense: true,
              hintText: widget.hint,
              hintStyle: ts(context, 11.5, color: c.faint),
              filled: true,
              fillColor: c.surface2,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 9,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(9),
                borderSide: BorderSide(color: c.line),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(9),
                borderSide: BorderSide(color: c.line),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(9),
                borderSide: BorderSide(color: c.accent),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The settings of the error reports: what is sent, where, with which token, and a test.
class _ReportCard extends StatefulWidget {
  const _ReportCard({required this.app, required this.s, required this.set});

  final AppController app;
  final AppSettings s;
  final void Function(AppSettings Function(AppSettings)) set;

  @override
  State<_ReportCard> createState() => _ReportCardState();
}

class _ReportCardState extends State<_ReportCard> {
  String? _testResult;
  bool _testing = false;

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _testResult = null;
    });
    final outcome = await widget.app.errors.test(facts: widget.app.errorFacts());
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testResult = outcome.ok ? 'つながりました（issue #${outcome.issue}）。送り先に、テストの issue ができています' : _reasonOf(outcome.status);
    });
  }

  String _reasonOf(String status) {
    if (status.startsWith('refused')) return '断られました。トークンの権限（そのリポジトリの Issues の書き込み）と、リポジトリの名前を確かめてください';
    if (status == 'queued') return 'つながりませんでした。ネットワークを確かめてください（あとで送り直します）';
    if (status == 'rate-limited') return '1 時間の上限に達しています';
    return status;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final s = widget.s;
    final app = widget.app;
    final config = app.errors.config();
    return ListenableBuilder(
      listenable: Listenable.merge([app.errors, app.settings]),
      builder: (context, _) {
        final recent = app.errors.recent.take(5).toList();
        return ArceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'アプリが想定していないエラー（読めなかった応答、プログラムの例外など）を、GitHub の issue に自動で送ります。'
                  '回線・API キー・回数制限のようにあなたの側で直せるものは送りません。'
                  '送るのは、種類・短いメッセージ・アプリ内の呼び出しの履歴・アプリのバージョン・OS・答えたモデルの名前と提供元のホスト名だけで、'
                  '会話の内容（質問・答え・ファイル）は入りません。キー・トークン・アドレスの中身・端末内の場所は伏せ字にします。'
                  '送り先が公開のリポジトリなら、issue も公開されます。同じ問題は 1 つの issue にまとめ、コメントで回数を足します。',
                  style: ts(context, 10, color: c.muted, height: 1.6),
                ),
              ),
              SettingRow(
                icon: ArceSvg.alert,
                title: 'エラーを自動で送る',
                subtitle: config.problem == null ? '送れる状態です' : '送れません：${config.problem}',
                trailing: ArceSwitch(value: s.errorReportEnabled, onChanged: (v) => widget.set((x) => x.copyWith(errorReportEnabled: v))),
              ),
              _TextRow(
                icon: ArceSvg.globe,
                title: '送り先のリポジトリ',
                subtitle: 'owner/name。チャットからは変えられません',
                value: s.errorReportRepo,
                hint: AppSettings.defaultRepo,
                onChanged: (v) => widget.set((x) => x.copyWith(errorReportRepo: v.trim())),
              ),
              _TextRow(
                icon: ArceSvg.shield,
                title: 'issue 用の GitHub トークン',
                subtitle: 'そのリポジトリだけに、Issues の書き込み権限を付けた細かい権限のトークン（fine-grained）を作って入れてください。この端末の安全な領域に保存します。アップデート用のトークンとは別です',
                value: app.settings.issueToken,
                hint: 'github_pat_…',
                obscure: true,
                onChanged: app.settings.setIssueToken,
              ),
              SettingRow(
                icon: ArceSvg.clock,
                title: '同じ問題にコメントする間隔',
                subtitle: 'この間は、同じ問題は数えるだけで送りません',
                trailing: _Cycle<int>(
                  value: s.errorReportMinHours,
                  values: const [1, 3, 6, 12, 24, 72],
                  label: (v) => '$v 時間',
                  onChanged: (v) => widget.set((x) => x.copyWith(errorReportMinHours: v)),
                ),
              ),
              SettingRow(
                icon: ArceSvg.sliders2,
                title: '1 時間に送る件数の上限',
                subtitle: 'すべての報告の合計。多すぎるときは送りません',
                last: true,
                trailing: _Cycle<int>(
                  value: s.errorReportMaxPerHour,
                  values: const [1, 3, 5, 10, 20],
                  label: (v) => '$v 件',
                  onChanged: (v) => widget.set((x) => x.copyWith(errorReportMaxPerHour: v)),
                ),
              ),
              const SizedBox(height: 10),
              Row(children: [
                SoftButton(label: _testing ? '送っています…' : 'テスト送信', svg: ArceSvg.send, onTap: _testing || config.problem != null ? null : _test),
              ]),
              if (_testResult != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_testResult!, style: ts(context, 10, color: c.muted, height: 1.6)),
                ),
              if (recent.isNotEmpty) ...[
                const SizedBox(height: 14),
                Text('最近の報告', style: ts(context, 11, weight: FontWeight.w700)),
                const SizedBox(height: 6),
                for (final entry in recent)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(entry.report.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(context, 10.5, weight: FontWeight.w600)),
                      Text(entry.status, style: ts(context, 9.5, color: c.muted, height: 1.5)),
                    ]),
                  ),
                Text('送る内容の例（いちばん新しい報告）', style: ts(context, 10, color: c.muted, weight: FontWeight.w600)),
                const SizedBox(height: 4),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: c.surface2, borderRadius: BorderRadius.circular(10), border: Border.all(color: c.line)),
                  child: SelectableText(recent.first.report.body, style: ts(context, 9.5, color: c.ink, height: 1.5, family: 'monospace')),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// Changes a notification setting; turning one on also asks the system for the permission to notify.
void _notifySetting(
  AppController app,
  void Function(AppSettings Function(AppSettings)) set,
  AppSettings Function(AppSettings) change,
  bool on,
) {
  set(change);
  if (on) unawaited(app.askForNotifications());
}

/// What the PC has for the container (the engine, the container's state), with a button to look again and one to
/// make the container again.
class _DesktopShellStatus extends StatefulWidget {
  const _DesktopShellStatus({required this.app});
  final AppController app;

  @override
  State<_DesktopShellStatus> createState() => _DesktopShellStatusState();
}

class _DesktopShellStatusState extends State<_DesktopShellStatus> {
  String? _text;
  bool _busy = false;

  Future<void> _check() async {
    setState(() => _busy = true);
    try {
      final text = await widget.app.describeDesktopShell();
      if (mounted) setState(() => _text = text);
    } catch (e) {
      if (mounted) setState(() => _text = '確かめられませんでした（$e）');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _recreate() async {
    setState(() => _busy = true);
    try {
      await widget.app.recreateDesktopContainer();
      if (mounted) widget.app.showToast('コンテナを消しました。次のコマンドで作り直します（ワークスペースは残ります）');
    } catch (e) {
      if (mounted) setState(() => _text = '作り直せませんでした（$e）');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _check();
  }

  @override
  Widget build(BuildContext context) => SettingRow(
        icon: ArceSvg.cube,
        title: 'コンテナ',
        subtitle: _text ?? '「確かめる」で、Docker / Podman とコンテナの様子を見ます',
        trailing: Wrap(
          spacing: 6,
          children: [
            SoftButton(label: '確かめる', height: 28, onTap: _busy ? null : _check),
            SoftButton(label: '作り直す', height: 28, onTap: _busy ? null : _recreate),
          ],
        ),
      );
}
