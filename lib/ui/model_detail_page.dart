import 'dart:async';

import 'package:flutter/material.dart';

import '../ai/fallback.dart';
import '../ai/model_availability.dart' show ModelMarks;
import '../ai/model_tree.dart';
import '../ai/provider_config.dart';
import '../services/app_controller.dart';
import '../services/settings.dart';
import 'model_tree_view.dart';
import 'svg_icons.dart';
import 'theme.dart';
import 'widgets.dart';

/// The detail screen of the models: how the model lists are read, the models used last, the
/// fallback rules (what to use when a model cannot be used), and the check of a request against the
/// model's context before it is sent. These are many settings with long explanations, so they have a
/// screen of their own instead of a place in the settings list.
class ModelDetailPage extends StatefulWidget {
  const ModelDetailPage({super.key, required this.app});

  final AppController app;

  @override
  State<ModelDetailPage> createState() => _ModelDetailPageState();
}

class _ModelDetailPageState extends State<ModelDetailPage> {
  /// What the last action of a provider (reading its list) answered.
  final _notes = <String, String>{};
  String? _mcpNote;
  bool _mcpBusy = false;

  AppController get app => widget.app;

  /// "3 時間前" and the like, for the age of a model list.
  static String ago(int? at, {int? now}) {
    if (at == null) return '未取得';
    final minutes = (((now ?? DateTime.now().millisecondsSinceEpoch) - at) / 60000).floor();
    if (minutes < 1) return 'たった今';
    if (minutes < 60) return '$minutes 分前';
    if (minutes < 60 * 24) return '${minutes ~/ 60} 時間前';
    return '${minutes ~/ (60 * 24)} 日前';
  }

  /// A rule's model reference in words: `*`, `provider|*`, `provider|model`, `provider|`.
  String refLabel(String ref) {
    if (ref == '*') return 'すべてのモデル';
    final parsed = FallbackRule.parseRef(ref);
    if (parsed == null) return ref;
    final (providerId, model) = parsed;
    final provider = app.providers.byId(providerId);
    final name = provider == null ? providerId : (provider.label.isEmpty ? provider.id : provider.label);
    if (model == '*') return '$name のすべてのモデル';
    if (model.isEmpty) return '$name の最初のモデル';
    return '$name · $model';
  }

  Future<void> _read(ProviderConfig config) async {
    setState(() => _notes[config.id] = '読み込んでいます…');
    final message = await app.refreshModelList(config.id);
    if (mounted) setState(() => _notes[config.id] = message);
  }

  Future<void> _probeMcp() async {
    final servers = [for (final s in app.settings.value.mcpServers) if (s.enabled) s];
    if (servers.isEmpty) {
      setState(() => _mcpNote = '有効な MCP サーバーがありません');
      return;
    }
    setState(() {
      _mcpBusy = true;
      _mcpNote = '調べています…';
    });
    final lines = <String>[];
    for (final server in servers) {
      lines.add('${server.name}: ${await app.probeMcp(server.id)}');
      if (mounted) setState(() => _mcpNote = lines.join('\n\n'));
    }
    if (mounted) setState(() => _mcpBusy = false);
  }

  Future<void> _editRule(FallbackRule? existing) async {
    final rule = await showModalBottomSheet<FallbackRule>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: context.c.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (context) => _RuleEditor(app: app, existing: existing, label: refLabel),
    );
    if (rule == null) return;
    final rules = [...app.providers.fallbackRules];
    final at = existing == null ? -1 : rules.indexWhere((r) => identical(r, existing) || r.toJson().toString() == existing.toJson().toString());
    if (at >= 0) {
      rules[at] = rule;
    } else {
      rules.add(rule);
    }
    await app.providers.setFallbackRules(rules);
  }

  Future<void> _deleteRule(FallbackRule rule) async {
    final rules = [
      for (final r in app.providers.fallbackRules)
        if (r.toJson().toString() != rule.toJson().toString()) r,
    ];
    await app.providers.setFallbackRules(rules);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Scaffold(
      backgroundColor: c.bg,
      appBar: AppBar(
        backgroundColor: c.bg,
        elevation: 0,
        scrolledUnderElevation: 0,
        foregroundColor: c.ink,
        title: Text('モデルの詳細設定', style: ts(context, 15, weight: FontWeight.w700)),
      ),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: Listenable.merge([app, app.settings, app.providers, app.availability]),
          builder: (context, _) {
            final s = app.settings.value;
            void set(AppSettings Function(AppSettings) edit) => unawaited(app.settings.update(edit));
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
                  children: [
                    ..._lists(context, s, set),
                    ..._recent(context, s, set),
                    ..._availability(context, s, set),
                    ..._fallback(context, s, set),
                    ..._tokens(context, s, set),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  // ---- model lists ----

  List<Widget> _lists(BuildContext context, AppSettings s, void Function(AppSettings Function(AppSettings)) set) {
    final c = context.c;
    final providers = app.providers.providers;
    return [
      const SectionTitle('モデル一覧の自動取得'),
      ArceCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            '提供元の /models から、使えるモデルの一覧を読み込みます。プロバイダを保存したときと、一覧が古くなったときに、'
            'アプリが自動で読み込みます。読み込んだ一覧は設定には足さず、選んだモデルだけが「設定済み」になります。',
            style: ts(context, 10, color: c.muted, height: 1.6),
          ),
          const SizedBox(height: 6),
          SettingRow(
            icon: ArceSvg.retry,
            title: '自動で取得する',
            subtitle: 'オフにすると、「更新」を押したときだけ読み込みます',
            trailing: ArceSwitch(value: s.modelListAutoFetch, onChanged: (v) => set((x) => x.copyWith(modelListAutoFetch: v))),
          ),
          SettingRow(
            icon: ArceSvg.clock,
            title: '取り直す間隔',
            subtitle: '一覧がこの時間より古いとき、起動したときに読み直します',
            last: providers.isEmpty,
            trailing: ValuePill(
              '${s.modelListRefreshHours} 時間',
              onTap: () {
                const values = [1, 6, 12, 24, 72, 168];
                final i = values.indexOf(s.modelListRefreshHours);
                set((x) => x.copyWith(modelListRefreshHours: values[(i + 1) % values.length]));
              },
            ),
          ),
          for (var i = 0; i < providers.length; i++) _providerRow(context, providers[i], last: i == providers.length - 1),
        ]),
      ),
    ];
  }

  Widget _providerRow(BuildContext context, ProviderConfig config, {required bool last}) {
    final c = context.c;
    final reading = app.isReadingModelList(config.id);
    final note = _notes[config.id];
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 9),
      decoration: BoxDecoration(border: last ? null : Border(bottom: BorderSide(color: c.line))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(config.label.isEmpty ? config.id : config.label, style: ts(context, 12, weight: FontWeight.w600)),
              Text(
                '${config.catalog.length} 件 · 取得 ${ago(config.catalogAt)} · 設定済み ${config.models.length} 件',
                style: ts(context, 9, color: c.muted),
              ),
            ]),
          ),
          SoftButton(label: reading ? '読み込み中…' : '今すぐ', height: 28, onTap: reading ? null : () => _read(config)),
          const SizedBox(width: 10),
          ArceSwitch(
            value: config.autoFetchModels,
            onChanged: (v) => unawaited(app.providers.save(config.copyWith(autoFetchModels: v))),
          ),
        ]),
        if (note != null)
          Padding(padding: const EdgeInsets.only(top: 4), child: Text(note, style: ts(context, 9.5, color: c.muted, height: 1.5))),
      ]),
    );
  }

  // ---- recently used ----

  List<Widget> _recent(BuildContext context, AppSettings s, void Function(AppSettings Function(AppSettings)) set) {
    final c = context.c;
    final recent = app.providers.recentRefs;
    return [
      const SectionTitle('最近使ったモデル'),
      ArceCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SettingRow(
            icon: ArceSvg.history,
            title: '覚える数',
            subtitle: 'モデルの一覧と、分担モードの選択画面の先頭に、最近使った順で出します（0 でなし）',
            last: recent.isEmpty,
            trailing: ValuePill(
              '${s.recentModelCount}',
              onTap: () {
                const values = [0, 4, 8, 12, 20, 30];
                final i = values.indexOf(s.recentModelCount);
                set((x) => x.copyWith(recentModelCount: values[(i + 1) % values.length]));
              },
            ),
          ),
          if (recent.isNotEmpty) ...[
            for (final ref in recent)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Text('· ${refLabel(ref)}', style: ts(context, 10.5, color: c.ink)),
              ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: SoftButton(label: '履歴を消す', height: 28, onTap: () => unawaited(app.providers.clearRecent())),
            ),
          ],
        ]),
      ),
    ];
  }

  // ---- which models this key can use ----

  List<Widget> _availability(BuildContext context, AppSettings s, void Function(AppSettings Function(AppSettings)) set) {
    final c = context.c;

    ValuePill pill(String text, List<int> values, int current, AppSettings Function(AppSettings, int) change) => ValuePill(
          text,
          onTap: () {
            final i = values.indexOf(current);
            set((x) => change(x, values[(i + 1) % values.length]));
          },
        );

    return [
      const SectionTitle('使えるモデルの確認'),
      ArceCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            '提供元のモデル一覧は、そのサービスが持っているモデルです。いまのキー（たとえば Gemini の無料枠）で使えるとは限りません。'
            '使えないモデルは、いま設定しているモデルだけを調べます（モデルの一覧の「設定中のモデルを確かめる」。答えるモデル・分担モードのモデル・タイトル用のモデル）。'
            'まず、そのキーで読めるモデル一覧（Gemini なら models.list）を取り、一覧にないモデルや、チャットに対応していないモデルに印を付けます（問い合わせも回数も使いません）。'
            '一覧にあっても、無料枠などで使えないことがあります。それは、下のスイッチで短い問い合わせも送るか、実際に送って「このキーでは使えない」と返ったときに、印が付きます。'
            'モデルを選んだときにも、自動で確かめます。印は灰色の表示と理由で出て、最後に並びます。'
            '覚えているのは、使える・使えないとその理由、調べた時刻だけです（キーも、やり取りの内容も保存しません）。'
            '印は、下の日数が過ぎると外れます（プランは変わるため）。',
            style: ts(context, 10, color: c.muted, height: 1.6),
          ),
          const SizedBox(height: 6),
          SettingRow(
            icon: ArceSvg.eye,
            title: '使えないと分かったモデルを、選択肢から隠す',
            subtitle: 'オフ（既定）では、灰色にして最後に並べます。使っているモデルは、隠れません',
            trailing: ArceSwitch(value: s.hideUnusableModels, onChanged: (v) => set((x) => x.copyWith(hideUnusableModels: v))),
          ),
          SettingRow(
            icon: ArceSvg.shield,
            title: 'モデルを選んだとき、そのモデルを 1 回だけ確かめる',
            subtitle: '答えるモデルを変えたとき、そのモデル 1 つを確かめます（モデル一覧で判断します。印が新しければ確かめません）。使えないときは、そう知らせます',
            trailing: ArceSwitch(value: s.autoCheckSelectedModel, onChanged: (v) => set((x) => x.copyWith(autoCheckSelectedModel: v))),
          ),
          SettingRow(
            icon: ArceSvg.bolt,
            title: '一覧にあるモデルにも、短い問い合わせを 1 回送る',
            subtitle: 'オフ（既定）では、モデル一覧だけで判断します（回数を使いません）。オンにすると、無料枠で使えないモデルまで分かります（確かめるたびに、回数を 1 回ずつ使います）',
            trailing: ArceSwitch(value: s.modelCheckAsksToo, onChanged: (v) => set((x) => x.copyWith(modelCheckAsksToo: v))),
          ),
          SettingRow(
            icon: ArceSvg.alert,
            title: '送信で使えないと分かったら、印を付ける',
            subtitle: '「このキー（プラン）では使えない」という答えが返ったモデルに、印を付けます',
            trailing: ArceSwitch(value: s.markBlockedModels, onChanged: (v) => set((x) => x.copyWith(markBlockedModels: v))),
          ),
          SettingRow(
            icon: ArceSvg.clock,
            title: '印を信じる日数',
            subtitle: 'この日数が過ぎた印は外します',
            trailing: pill('${s.modelAvailabilityTrustDays} 日', const [1, 3, 7, 14, 30, 90], s.modelAvailabilityTrustDays, (x, v) => x.copyWith(modelAvailabilityTrustDays: v)),
          ),
          SettingRow(
            icon: ArceSvg.bolt,
            title: '確かめるときの同時の数',
            subtitle: '「設定中のモデルを確かめる」が、同時に問い合わせるモデルの数',
            trailing: pill('${s.modelProbeConcurrency}', const [1, 2, 3, 5, 8], s.modelProbeConcurrency, (x, v) => x.copyWith(modelProbeConcurrency: v)),
          ),
          SettingRow(
            icon: ArceSvg.clockCircle,
            title: '確かめるときの待ち時間',
            subtitle: '1 つのモデルの返事を待つ時間。過ぎたら一時的な失敗として扱い、印は付けません',
            trailing: pill('${s.modelProbeTimeoutSeconds} 秒', const [10, 20, 30, 60, 120], s.modelProbeTimeoutSeconds, (x, v) => x.copyWith(modelProbeTimeoutSeconds: v)),
          ),
          SettingRow(
            icon: ArceSvg.close,
            title: '印をすべて消す',
            subtitle: '覚えている「使える・使えない」を、すべて忘れます（${app.availability.length} 件）',
            last: true,
            trailing: SoftButton(label: '消す', height: 28, onTap: app.availability.length == 0 ? null : () => unawaited(app.availability.clear())),
          ),
        ]),
      ),
    ];
  }

  // ---- fallback ----

  List<Widget> _fallback(BuildContext context, AppSettings s, void Function(AppSettings Function(AppSettings)) set) {
    final c = context.c;
    final rules = app.providers.fallbackRules;
    return [
      const SectionTitle('フォールバック（使えないとき、別のモデルへ）'),
      ArceCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            '使っているモデルが 403・429・5xx などで答えられないとき、決めておいた別のモデルに自動で切り替えます。'
            '例: OrcaRouter の無料モデルが使えなければ、DeepInfra の DeepSeek を使う。'
            '返信を書き始めたあとの失敗では切り替えません（途中まで書いたモデルのままにします）。'
            '切り替えると、会話の内容は切り替え先の提供元にも送られます。そのためルールはこの画面だけで決め、チャットからは変えられません。',
            style: ts(context, 10, color: c.muted, height: 1.6),
          ),
          const SizedBox(height: 6),
          SettingRow(
            icon: ArceSvg.shield,
            title: 'フォールバックを使う',
            subtitle: 'オフにすると、ルールは残したまま、切り替えません',
            last: rules.isEmpty,
            trailing: ArceSwitch(value: s.fallbackEnabled, onChanged: (v) => set((x) => x.copyWith(fallbackEnabled: v))),
          ),
          for (var i = 0; i < rules.length; i++)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 9),
              decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.line))),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(refLabel(rules[i].from), style: ts(context, 11.5, weight: FontWeight.w700)),
                    for (var t = 0; t < rules[i].targets.length; t++)
                      Text('${t + 1}. ${refLabel(rules[i].targets[t])}', style: ts(context, 10, color: c.muted)),
                    Text(
                      rules[i].statuses.isEmpty ? '切り替える失敗: 既定' : '切り替える失敗: ${(rules[i].statuses.toList()..sort()).join('・')} と 5xx・接続の失敗',
                      style: ts(context, 9, color: c.faint),
                    ),
                  ]),
                ),
                IconTap(svg: ArceSvg.pencil, size: 15, tooltip: '編集', onTap: () => _editRule(rules[i])),
                const SizedBox(width: 8),
                IconTap(svg: ArceSvg.close, size: 15, tooltip: '削除', onTap: () => _deleteRule(rules[i])),
              ]),
            ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: SoftButton(label: 'ルールを追加', svg: ArceSvg.plus, onTap: () => _editRule(null)),
          ),
        ]),
      ),
    ];
  }

  // ---- token precheck ----

  List<Widget> _tokens(BuildContext context, AppSettings s, void Function(AppSettings Function(AppSettings)) set) {
    final c = context.c;
    final active = app.providers.activeModel;
    return [
      const SectionTitle('送る前のトークン長のチェック'),
      ArceCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            '送る前に、指示とツールの定義（MCP サーバーが公開するものを含む）の長さを見積もります。'
            'モデルの文脈に収まらないと分かったら、待たせずに先にエラーにして、どの MCP サーバーが大きいかを知らせます。'
            '文脈の長さが分からないモデルは調べられません。見積もりは目安です。',
            style: ts(context, 10, color: c.muted, height: 1.6),
          ),
          const SizedBox(height: 6),
          SettingRow(
            icon: ArceSvg.shield,
            title: '送る前にチェックする',
            subtitle: active?.contextTokens == null ? '使用中のモデルは文脈の長さが未設定です（モデルの編集の「取得」で調べられます）' : '使用中のモデルの文脈: ${active!.contextTokens} トークン',
            trailing: ArceSwitch(value: s.tokenPrecheck, onChanged: (v) => set((x) => x.copyWith(tokenPrecheck: v))),
          ),
          SettingRow(
            icon: ArceSvg.sliders2,
            title: '指示とツール定義に使ってよい割合',
            subtitle: 'これを超えると、送らずにエラーにします',
            trailing: ValuePill(
              '${s.tokenOverheadPercent}%',
              onTap: () {
                const values = [40, 50, 60, 70, 80, 90, 100];
                final i = values.indexOf(s.tokenOverheadPercent);
                set((x) => x.copyWith(tokenOverheadPercent: values[(i + 1) % values.length]));
              },
            ),
          ),
          SettingRow(
            icon: ArceSvg.search,
            title: 'MCP サーバーのツール定義の大きさ',
            subtitle: '有効なサーバーに聞いて、毎回の送信に足されるトークン数を調べます',
            last: _mcpNote == null,
            trailing: SoftButton(label: _mcpBusy ? '調べ中…' : '調べる', height: 28, onTap: _mcpBusy ? null : _probeMcp),
          ),
          if (_mcpNote != null) Text(_mcpNote!, style: ts(context, 10, color: c.muted, height: 1.6)),
        ]),
      ),
    ];
  }
}

/// One fallback rule: the model it covers, the models to try, and which failures count.
class _RuleEditor extends StatefulWidget {
  const _RuleEditor({required this.app, required this.existing, required this.label});

  final AppController app;
  final FallbackRule? existing;
  final String Function(String ref) label;

  @override
  State<_RuleEditor> createState() => _RuleEditorState();
}

class _RuleEditorState extends State<_RuleEditor> {
  late String _from = widget.existing?.from ?? '';
  late final List<String> _targets = [...?widget.existing?.targets];
  late final Set<int> _statuses = {...?widget.existing?.statuses};

  static const _statusChoices = [401, 403, 404, 408, 429];

  List<ProviderConfig> get _providers => widget.app.providers.providers;

  /// The "any model" choices placed above the tree when the covered model is chosen.
  List<TreeLeaf> get _fromRoots => [
        const TreeLeaf('*', 'すべてのモデル'),
        for (final p in _providers) TreeLeaf('${p.id}|*', '${p.label.isEmpty ? p.id : p.label} のすべてのモデル'),
      ];

  Future<void> _pickFrom() async {
    final picked = await showModelPicker(
      context,
      title: 'どのモデルが使えないとき',
      selectedKey: _from,
      note: '特定のモデル、ある提供元のすべてのモデル、またはすべてのモデルを選べます。より細かく指定したルールが先に使われます',
      // a model this key cannot use is greyed but never hidden here: it is just the one a rule may be for
      build: (query) => ModelTrees.forPicker(_providers, query: query, recent: widget.app.providers.recentRefs, rootLeaves: _fromRoots, marks: ModelMarks(lookup: widget.app.modelMarks.lookup)),
    );
    if (picked != null) setState(() => _from = picked);
  }

  Future<void> _addTarget() async {
    final picked = await showModelPicker(
      context,
      title: '代わりに使うモデル',
      selectedKey: null,
      build: (query) => ModelTrees.forPicker(_providers, query: query, recent: widget.app.providers.recentRefs, marks: widget.app.modelMarks),
    );
    if (picked != null && !_targets.contains(picked)) setState(() => _targets.add(picked));
  }

  void _move(int i, int by) {
    final j = i + by;
    if (j < 0 || j >= _targets.length) return;
    setState(() => _targets.insert(j, _targets.removeAt(i)));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final ready = _from.isNotEmpty && _targets.isNotEmpty;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(16, 16, 16, sheetBottomPadding(context)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.existing == null ? 'ルールを追加' : 'ルールを編集', style: ts(context, 14, weight: FontWeight.w700)),
          const SizedBox(height: 12),
          Text('どのモデルが使えないとき', style: ts(context, 11, weight: FontWeight.w700)),
          const SizedBox(height: 6),
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: _pickFrom,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              decoration: BoxDecoration(color: c.surface2, borderRadius: BorderRadius.circular(8), border: Border.all(color: c.line)),
              child: Row(children: [
                Expanded(child: Text(_from.isEmpty ? '選んでください' : widget.label(_from), style: ts(context, 11.5, weight: FontWeight.w600, color: _from.isEmpty ? c.muted : c.ink))),
                ArceIcon(ArceSvg.chevronDown, size: 14, color: c.muted),
              ]),
            ),
          ),
          const SizedBox(height: 14),
          Text('代わりに使うモデル（上から順に試します）', style: ts(context, 11, weight: FontWeight.w700)),
          const SizedBox(height: 6),
          for (var i = 0; i < _targets.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(children: [
                Text('${i + 1}.', style: ts(context, 10.5, color: c.muted)),
                const SizedBox(width: 6),
                Expanded(child: Text(widget.label(_targets[i]), style: ts(context, 11))),
                IconTap(svg: ArceSvg.chevronUp, size: 15, tooltip: '上へ', onTap: i == 0 ? null : () => _move(i, -1)),
                const SizedBox(width: 6),
                IconTap(svg: ArceSvg.chevronDown, size: 15, tooltip: '下へ', onTap: i == _targets.length - 1 ? null : () => _move(i, 1)),
                const SizedBox(width: 6),
                IconTap(svg: ArceSvg.close, size: 15, tooltip: '外す', onTap: () => setState(() => _targets.removeAt(i))),
              ]),
            ),
          const SizedBox(height: 6),
          SoftButton(label: 'モデルを追加', svg: ArceSvg.plus, height: 32, onTap: _addTarget),
          const SizedBox(height: 14),
          Text('切り替える失敗', style: ts(context, 11, weight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(
            '何も選ばなければ ${FallbackPolicy.defaultStatuses.toList().join('・')} です。5xx と、接続できない・時間切れは、いつでも切り替えます。',
            style: ts(context, 9.5, color: c.muted, height: 1.5),
          ),
          const SizedBox(height: 6),
          Wrap(spacing: 8, runSpacing: 4, children: [
            for (final code in _statusChoices)
              FilterChip(
                label: Text('$code', style: ts(context, 10.5)),
                selected: _statuses.contains(code),
                onSelected: (on) => setState(() => on ? _statuses.add(code) : _statuses.remove(code)),
              ),
          ]),
          const SizedBox(height: 18),
          Row(children: [
            SoftButton(label: 'やめる', onTap: () => Navigator.of(context).pop()),
            const SizedBox(width: 8),
            PrimaryButton(
              label: '保存',
              onTap: ready ? () => Navigator.of(context).pop(FallbackRule(from: _from, targets: List.of(_targets), statuses: Set.of(_statuses))) : null,
            ),
          ]),
        ]),
      ),
    );
  }
}
