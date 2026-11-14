import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../ai/cloudflare_gateway.dart';
import '../ai/model_hints.dart';
import '../ai/model_tree.dart';
import '../ai/openai_compatible.dart';
import '../ai/provider.dart';
import '../ai/provider_config.dart';
import '../ai/provider_import.dart';
import '../ai/responses_provider.dart';
import '../ai/thinking_config.dart';
import '../services/app_controller.dart';
import '../services/provider_store.dart';
import 'app_scope.dart';
import 'arce_text_field.dart';
import 'model_detail_page.dart';
import 'model_tree_view.dart';
import 'svg_icons.dart';
import 'theme.dart';
import 'widgets.dart';

/// The providers, in one list with the device model: either can be the one in use.
///
/// Picking a row switches the engine for the next reply; the choice is stored, so it survives a
/// restart. The key of a provider is kept in the platform's secure storage, not in the settings
/// file, and is only sent to that provider.
class ProvidersSection extends StatelessWidget {
  const ProvidersSection({super.key});

  @override
  Widget build(BuildContext context) {
    final app = ArceScope.of(context);
    return ListenableBuilder(
      listenable: app.providers,
      builder: (context, _) {
        final store = app.providers;
        final local = !store.isCloud;
        final providers = store.providers;
        return ArceCard(
          child: Column(
            children: [
              _ProviderRow(
                icon: ArceSvg.cube,
                title: 'ローカルモデル',
                detail: 'この端末の中だけで動きます（外部に送りません）',
                selected: local,
                badge: local ? '使用中' : null,
                onPick: () => app.setActiveProvider(ProviderList.localId),
                last: providers.isEmpty,
              ),
              for (var i = 0; i < providers.length; i++)
                _ProviderRow(
                  icon: ArceSvg.globe,
                  title: providers[i].label.isEmpty
                      ? providers[i].id
                      : providers[i].label,
                  detail:
                      '${_modelLabel(store.modelOf(providers[i].id))} · ${providers[i].baseUrl}',
                  selected: store.activeId == providers[i].id,
                  badge: providers[i].models.isEmpty
                      ? 'モデル未追加'
                      : (!store.hasKey(providers[i].id)
                            ? 'APIキー未設定'
                            : (store.activeId == providers[i].id
                                  ? '使用中'
                                  : null)),
                  onPick: () => app.setActiveProvider(providers[i].id),
                  onModels: () => _openModels(context, app, providers[i]),
                  onEdit: () => _openEditor(context, app, providers[i]),
                  onDelete: () => _confirmDelete(context, app, providers[i]),
                  last: i == providers.length - 1,
                ),
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    SoftButton(
                      label: 'プロバイダを追加',
                      svg: ArceSvg.plus,
                      onTap: () => _openEditor(context, app, null),
                    ),
                    SoftButton(
                      label: '詳細',
                      svg: ArceSvg.sliders,
                      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ModelDetailPage(app: app))),
                    ),
                    SoftButton(
                      key: const ValueKey('providers-read-all'),
                      label: '全プロバイダのモデルを読み込む',
                      svg: ArceSvg.retry,
                      onTap: providers.isEmpty ? null : () async => app.showToast(await app.refreshAllModelLists()),
                    ),
                    SoftButton(
                      key: const ValueKey('providers-pick-any'),
                      label: 'モデルを選ぶ（全プロバイダ）',
                      svg: ArceSvg.cube,
                      onTap: () => pickAnyModel(context, app),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'OpenAI 互換の API ならどれでも使えます（OpenAI、Groq、OpenRouter、Ollama、LM Studio など）。'
                  'Base URL は /chat/completions より前までです。'
                  '複数の提供元を 1 つにまとめる Cloudflare AI Gateway は、「プロバイダを追加」で「${CloudflareGateway.label}」を選びます。',
                  style: ts(context, 9, color: context.c.muted, height: 1.5),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  static Future<void> _confirmDelete(
    BuildContext context,
    AppController app,
    ProviderConfig config,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(config.label.isEmpty ? config.id : config.label),
        content: const Text('このプロバイダと、保存したAPIキーを削除します。'),
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
    await app.providers.remove(config.id);
    await app.setActiveProvider(app.providers.activeId);
    app.showToast('削除しました');
  }

  static String _modelLabel(ModelConfig? model) =>
      model == null ? 'モデル未追加' : model.id;

  static Future<void> _openModels(
    BuildContext context,
    AppController app,
    ProviderConfig config,
  ) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.c.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (context) => _ModelsSheet(app: app, config: config),
    );
  }

  static Future<void> _openEditor(
    BuildContext context,
    AppController app,
    ProviderConfig? existing,
  ) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.c.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (context) =>
          _ProviderEditor(app: app, store: app.providers, existing: existing),
    );
  }
}

/// Chooses the model that answers from every provider's models at once (and the device model), in one tree with
/// a search field: the chosen model and its provider are in use from then on. The device model goes to the model
/// page when none is loaded yet.
Future<void> pickAnyModel(BuildContext context, AppController app) async {
  final store = app.providers;
  final selected = store.isCloud ? '${store.activeId}|${store.activeModelId}' : '${ProviderList.localId}|';
  final picked = await showModelPicker(
    context,
    title: 'モデルを選ぶ',
    selectedKey: selected,
    note: '登録したすべてのプロバイダのモデルです（提供元ごと）。一覧が古いときは、詳細設定の「オンライン接続」で「全プロバイダのモデルを読み込む」を押してください',
    build: (query) => ModelTrees.forPicker(
      store.providers,
      query: query,
      recent: store.recentRefs,
      rootLeaves: const [TreeLeaf('${ProviderList.localId}|', 'ローカルモデル（この端末）')],
      marks: app.modelMarks,
      keepKey: selected,
    ),
  );
  if (picked == null) return;
  if (picked == '${ProviderList.localId}|' && !app.models.isLoaded) {
    await app.setActiveProvider(ProviderList.localId);
    app.goTo(AppPage.models);
    return;
  }
  if (await app.chooseModel(picked)) {
    final bar = picked.indexOf('|');
    final provider = store.byId(picked.substring(0, bar));
    app.showToast(provider == null ? 'ローカルモデルで答えます' : '${provider.label} · ${picked.substring(bar + 1)} で答えます');
  }
}

class _ProviderRow extends StatelessWidget {
  const _ProviderRow({
    required this.icon,
    required this.title,
    required this.detail,
    required this.selected,
    required this.onPick,
    this.badge,
    this.onModels,
    this.onEdit,
    this.onDelete,
    this.last = false,
  });

  final String icon;
  final String title;
  final String detail;
  final bool selected;
  final VoidCallback onPick;
  final String? badge;
  final VoidCallback? onModels;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final bool last;

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
          ArceIcon(icon, size: 16, color: selected ? c.accent : c.muted),
          const SizedBox(width: 10),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onPick,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          title,
                          overflow: TextOverflow.ellipsis,
                          style: ts(
                            context,
                            12,
                            weight: FontWeight.w700,
                            color: selected ? c.accent : c.ink,
                          ),
                        ),
                      ),
                      if (badge != null) ...[
                        const SizedBox(width: 6),
                        StatusLabel(
                          badge!,
                          color: selected ? c.accent : c.amber,
                          background: selected ? c.accentSoft : c.amberSoft,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    detail,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: ts(context, 9, color: c.muted),
                  ),
                ],
              ),
            ),
          ),
          if (onModels != null) ...[
            const SizedBox(width: 6),
            SoftButton(label: 'モデル', height: 28, onTap: onModels),
          ],
          if (onEdit != null) ...[
            const SizedBox(width: 6),
            IconTap(
              svg: ArceSvg.pencil,
              onTap: onEdit!,
              tooltip: '編集',
              size: 16,
            ),
          ],
          if (onDelete != null) ...[
            const SizedBox(width: 6),
            SoftButton(label: '削除', height: 28, onTap: onDelete),
          ],
          if (onEdit == null) ...[
            const SizedBox(width: 8),
            StatusLabel(
              selected ? '選択中' : '選ぶ',
              color: selected ? c.accent : c.muted,
            ),
          ],
        ],
      ),
    );
  }
}

/// Add or edit one provider; the connection check uses what is typed, not what was saved.
class _ProviderEditor extends StatefulWidget {
  const _ProviderEditor({
    required this.app,
    required this.store,
    this.existing,
  });

  final AppController app;
  final ProviderStore store;
  final ProviderConfig? existing;

  @override
  State<_ProviderEditor> createState() => _ProviderEditorState();
}

class _ProviderEditorState extends State<_ProviderEditor> {
  late final TextEditingController _label = TextEditingController(
    text: widget.existing?.label ?? '',
  );
  late final TextEditingController _baseUrl = TextEditingController(
    text: widget.existing?.baseUrl ?? '',
  );
  late final TextEditingController _key = TextEditingController(
    text: widget.existing == null
        ? ''
        : widget.store.keyOf(widget.existing!.id),
  );

  /// The kind of address: any OpenAI-compatible one, or Cloudflare AI Gateway (made from the account ID).
  late final bool _savedAsCloudflare = widget.existing != null && CloudflareGateway.isGateway(widget.existing!.baseUrl);
  late bool _cloudflare = _savedAsCloudflare;
  late final TextEditingController _account = TextEditingController(
    text: CloudflareGateway.accountOf(widget.existing?.baseUrl ?? '') ?? '',
  );
  late final TextEditingController _gateway = TextEditingController(
    text: _savedAsCloudflare ? CloudflareGateway.gatewayOf(widget.existing!.headers) : '',
  );
  /// The first model of a new Cloudflare provider (it has no list to pick from).
  final TextEditingController _firstModel = TextEditingController();

  /// The whole provider as JSON (「JSON」): pasted to add one or several, or the one being edited.
  bool _json = false;
  late final TextEditingController _jsonText = TextEditingController(
    text: widget.existing == null ? '' : ProviderImport.export(widget.existing!),
  );

  // the gateway has a field of its own, so it is not shown again among the extra headers
  late final TextEditingController _headers = TextEditingController(
    text: ProviderExtras.show({
      for (final entry in {...?widget.existing?.headers}.entries)
        if (!_savedAsCloudflare || entry.key.toLowerCase() != CloudflareGateway.gatewayHeader) entry.key: entry.value,
    }),
  );
  late final TextEditingController _body = TextEditingController(
    text: ProviderExtras.show(widget.existing?.body ?? const {}),
  );
  late bool _tools = widget.existing?.supportsTools ?? true;
  late bool _autoFetch = widget.existing?.autoFetchModels ?? true;
  late bool _promptCache = widget.existing?.promptCache ?? false;
  late ProviderApi _api = widget.existing?.api ?? ProviderApi.chatCompletions;
  late bool _background = widget.existing?.background ?? false;
  late final TextEditingController _cacheField = TextEditingController(
    text: widget.existing?.promptCacheField ?? ProviderConfig.defaultPromptCacheField,
  );

  String? _result;
  bool _busy = false;

  @override
  void dispose() {
    for (final controller in [_label, _baseUrl, _key, _headers, _body, _cacheField, _account, _gateway, _firstModel, _jsonText]) {
      controller.dispose();
    }
    super.dispose();
  }

  ProviderConfig _config() {
    final existing = widget.existing;
    final label = _label.text.trim();
    // a [FormatException] from the two JSON fields is shown by the caller
    final headers = ProviderExtras.parseHeaders(_headers.text);
    final body = ProviderExtras.parseBody(_body.text);
    final name = label.isEmpty ? (_cloudflare ? CloudflareGateway.label : 'プロバイダ') : label;
    // an edited provider keeps what the editor does not show (its models and model list)
    final base = existing ?? ProviderConfig(id: ProviderList.idFor(name, widget.store.providers), label: '', baseUrl: '');
    final first = _firstModel.text.trim();
    return base.copyWith(
      label: name,
      baseUrl: _cloudflare ? CloudflareGateway.baseUrl(_account.text) : _baseUrl.text.trim(),
      headers: _cloudflare ? CloudflareGateway.withGateway(headers, _gateway.text) : headers,
      body: body,
      models: _cloudflare && base.models.isEmpty && first.isNotEmpty ? [ModelConfig(id: first, name: first)] : null,
      supportsTools: _tools,
      // Cloudflare's API has no model list to read
      autoFetchModels: _cloudflare ? false : _autoFetch,
      promptCache: _promptCache,
      promptCacheField: _cacheField.text.trim().isEmpty ? ProviderConfig.defaultPromptCacheField : _cacheField.text.trim(),
      api: _cloudflare ? ProviderApi.chatCompletions : _api,
      background: _cloudflare || _api != ProviderApi.responses ? false : _background,
    );
  }

  /// The config the fields describe, or null (with the reason shown) when a JSON field is wrong.
  ProviderConfig? _configOrExplain() {
    if (_cloudflare && !CloudflareGateway.isAccountId(_account.text)) {
      setState(() => _result = 'Cloudflare のアカウント ID（英数字。wrangler whoami で確かめられます）を入れてください');
      return null;
    }
    try {
      final config = _config();
      if (!ProviderConfig.isValidCacheField(config.promptCacheField)) {
        setState(() => _result = 'キャッシュの項目名は、英数字と _ - . だけで、先頭は数字以外にしてください');
        return null;
      }
      return config;
    } on FormatException catch (e) {
      setState(() => _result = e.message);
      return null;
    }
  }

  Future<void> _check() async {
    final config = _configOrExplain();
    if (config == null) return;
    final model = config.defaultModel;
    if (config.baseUrl.trim().isEmpty) {
      setState(() => _result = 'Base URL（https://…）を入れてください');
      return;
    }
    setState(() {
      _busy = true;
      _result = '接続を確認しています…';
    });
    final provider = (!_cloudflare && _api == ProviderApi.responses)
        ? OpenAiResponsesProvider(
            id: config.id,
            label: config.label,
            baseUrl: config.baseUrl,
            model: model?.id ?? '',
            modelConfig: model,
            apiKey: _key.text.trim(),
            headers: config.headers,
            body: config.body,
            supportsTools: config.supportsTools,
            promptCache: config.promptCache,
            promptCacheField: config.promptCacheField,
            useBackground: config.background,
          )
        : OpenAiCompatibleProvider(
            id: config.id,
            label: config.label,
            baseUrl: config.baseUrl,
            model: model?.id ?? '',
            modelConfig: model,
            apiKey: _key.text.trim(),
            headers: config.headers,
            body: config.body,
            supportsTools: config.supportsTools,
            promptCache: config.promptCache,
            promptCacheField: config.promptCacheField,
          );
    try {
      await provider.verify();
      if (!mounted) return;
      setState(() => _result = model == null ? '接続できました' : '接続できました（${model.id}）');
    } on AiProviderException catch (e) {
      if (!mounted) return;
      setState(() => _result = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _result = '接続できませんでした（$e）');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Saves what the JSON says: new providers (one or several), or the one being edited (its id, its model list
  /// and, when the JSON has none, its models and key stay).
  Future<void> _saveJson() async {
    final existing = widget.existing;
    final List<ImportedProvider> read;
    try {
      read = ProviderImport.parse(_jsonText.text, [
        for (final p in widget.store.providers)
          if (p.id != existing?.id) p,
      ], keepId: existing?.id);
    } on FormatException catch (e) {
      setState(() => _result = e.message);
      return;
    }
    for (final item in read) {
      var config = item.config;
      if (existing != null) {
        config = existing.copyWith(
          label: config.label,
          baseUrl: config.baseUrl,
          models: config.models.isEmpty ? existing.models : config.models,
          headers: config.headers,
          body: config.body,
          supportsTools: config.supportsTools,
          autoFetchModels: config.autoFetchModels,
          promptCache: config.promptCache,
          promptCacheField: config.promptCacheField,
          api: config.api,
          background: config.background,
        );
      }
      await widget.store.save(config);
      if (item.key != null) await widget.store.setKey(config.id, item.key!);
    }
    if (!mounted) return;
    final app = widget.app;
    Navigator.of(context).pop();
    app.showToast(existing != null ? '${read.single.config.label} を保存しました' : '${read.length} 件のプロバイダを追加しました');
    for (final item in read) {
      if (item.config.autoFetchModels) unawaited(app.autoReadModelLists(only: item.config.id, force: true));
    }
  }

  Future<void> _save() async {
    if (_json) return _saveJson();
    final config = _configOrExplain();
    if (config == null) return;
    if (config.baseUrl.trim().isEmpty) {
      setState(() => _result = 'Base URL（https://…）を入れてください');
      return;
    }
    await widget.store.save(config);
    await widget.store.setKey(config.id, _key.text);
    if (!mounted) return;
    final app = widget.app;
    Navigator.of(context).pop();
    app.showToast('${config.label} を保存しました');
    // the address or the key may be new: read the model list now (nothing is shown if it fails)
    if (_autoFetch) unawaited(app.autoReadModelLists(only: config.id, force: true));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final editing = widget.existing != null;
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
              editing ? 'プロバイダを編集' : 'プロバイダを追加',
              style: ts(context, 14, weight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                ChoiceChip(
                  key: const ValueKey('provider-kind-openai'),
                  label: Text('OpenAI 互換', style: ts(context, 11)),
                  selected: !_cloudflare && !_json,
                  onSelected: (_) => setState(() {
                    _cloudflare = false;
                    _json = false;
                  }),
                ),
                ChoiceChip(
                  key: const ValueKey('provider-kind-cloudflare'),
                  label: Text(CloudflareGateway.label, style: ts(context, 11)),
                  selected: _cloudflare && !_json,
                  onSelected: (_) => setState(() {
                    _cloudflare = true;
                    _json = false;
                  }),
                ),
                ChoiceChip(
                  key: const ValueKey('provider-kind-json'),
                  label: Text('JSON', style: ts(context, 11)),
                  selected: _json,
                  onSelected: (_) => setState(() => _json = true),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (_json) ...[
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  editing
                      ? 'このプロバイダの設定を JSON で直せます（id と、読み込んだモデル一覧はそのまま。キーは書いたときだけ変わります）。'
                      : 'プロバイダを JSON で丸ごと追加します。1 つのオブジェクト、配列、{"providers": [...]} のどれでも、複数をまとめて入れられます。'
                          '使える項目：name / label、baseUrl（base_url・url）、models（名前の配列か、{"id", "name", "service_tier"} の配列）、'
                          'headers、body、tools、autoFetch、apiKey（api_key・key、または headers の "Authorization": "Bearer …"）。'
                          'Cloudflare は {"type": "cloudflare", "account_id": "…", "gateway_id": "…"}。キーは安全な領域に保存し、設定には入れません',
                  style: ts(context, 9.5, color: c.muted, height: 1.5),
                ),
              ),
              _field('JSON', _jsonText, '{"name": "OpenAI", "baseUrl": "https://api.openai.com/v1", "models": ["gpt-5-mini"], "apiKey": "sk-…"}', maxLines: 14),
              if (editing)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: SoftButton(
                    label: 'JSON をコピー（キーは含みません）',
                    svg: ArceSvg.copy,
                    height: 28,
                    onTap: () async {
                      await Clipboard.setData(ClipboardData(text: ProviderImport.export(widget.existing!)));
                      if (mounted) setState(() => _result = 'コピーしました');
                    },
                  ),
                ),
            ] else ...[
            if (_cloudflare)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  'Cloudflare のアカウント 1 つで、OpenAI・Anthropic・Google・xAI・Workers AI などのモデルを呼べます。'
                  'モデル名は「提供元/モデル」（openai/gpt-4.1 など。Workers AI は @cf/…）で書きます。'
                  'Workers AI 以外のモデルの料金は、Cloudflare に入れたクレジット（Unified Billing）から引かれます。',
                  style: ts(context, 9.5, color: c.muted, height: 1.5),
                ),
              ),
            _field('名前', _label, _cloudflare ? CloudflareGateway.label : '例: OpenAI / Groq / 自宅の Ollama'),
            if (_cloudflare) ...[
              _field('アカウント ID', _account, '英数字（wrangler whoami で確かめられます）'),
              _field('ゲートウェイ ID（任意）', _gateway, '空なら ${CloudflareGateway.defaultGateway}（最初の呼び出しで自動で作られます）'),
              _field('API トークン', _key, 'Account > Workers AI > Read の権限（端末の安全な領域に保存します）', obscure: true),
              if (widget.existing?.models.isEmpty ?? true)
                _field('最初のモデル（任意。あとで「モデル」から足せます）', _firstModel, CloudflareGateway.exampleModels.join(' / ')),
            ] else ...[
              _field('Base URL', _baseUrl, 'https://api.openai.com/v1'),
              ListenableBuilder(listenable: _baseUrl, builder: (context, _) => ClearTextWarning(url: _baseUrl.text, what: 'APIキー')),
              _field('APIキー', _key, 'sk-…（端末の安全な領域に保存します）', obscure: true),
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text('通信方式', style: ts(context, 10, color: c.muted)),
              ),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  ChoiceChip(
                    key: const ValueKey('provider-api-chat'),
                    label: Text('Chat Completions', style: ts(context, 11)),
                    selected: _api == ProviderApi.chatCompletions,
                    onSelected: (_) => setState(() {
                      _api = ProviderApi.chatCompletions;
                      _background = false;
                    }),
                  ),
                  ChoiceChip(
                    key: const ValueKey('provider-api-responses'),
                    label: Text('Responses (/responses)', style: ts(context, 11)),
                    selected: _api == ProviderApi.responses,
                    onSelected: (_) => setState(() => _api = ProviderApi.responses),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              if (_api == ProviderApi.responses)
                SwitchListTile(
                  key: const ValueKey('provider-responses-background'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: _background,
                  onChanged: (value) => setState(() => _background = value),
                  title: Text('バックグラウンド処理（background: true）', style: ts(context, 12)),
                  subtitle: Text(
                    'オンにすると、Responses API で background: true を送り、GET /responses/{id} をポーリングして応答を待ちます。'
                    'モデルのサービス階層を「flex」にすると metadata.completion_window: flex と background: true で送ります。'
                    '非対応の接続先や Chat Completions では別の形式へ自動切り替えはせず、エラーをそのまま表示します',
                    style: ts(context, 9.5, color: c.muted, height: 1.5),
                  ),
                ),
            ],
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: _tools,
              onChanged: (value) => setState(() => _tools = value),
              title: Text('ツール呼び出しに対応', style: ts(context, 12)),
              subtitle: Text(
                '検索や設定の変更などを、モデルが自分で呼べるようにします。対応しないモデルではオフに',
                style: ts(context, 9.5, color: c.muted),
              ),
            ),
            if (!_cloudflare) SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: _autoFetch,
              onChanged: (value) => setState(() => _autoFetch = value),
              title: Text('モデル一覧を自動で取得', style: ts(context, 12)),
              subtitle: Text(
                '保存したときと、一覧が古くなったときに、提供元の /models を読みます。一覧を返さない提供元ではオフに',
                style: ts(context, 9.5, color: c.muted),
              ),
            ),
            SwitchListTile(
              key: const ValueKey('provider-prompt-cache'),
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: _promptCache,
              onChanged: (value) => setState(() => _promptCache = value),
              title: Text('プロンプトのキャッシュ用の印を送る', style: ts(context, 12)),
              subtitle: Text(
                'オンにすると、同じ会話のリクエストに、同じ印（下の項目名）を付けて送ります。OpenAI など、この印でキャッシュの当たりを良くできる提供元向けです。'
                '提供元が自分で行うキャッシュ（OpenAI・DeepSeek・Gemini など）は、このスイッチを切っても止まりません（アプリが送るものだけを切り替えます）。'
                '知らない項目を断るサーバーでは、断られたらアプリが自動でオフにします',
                style: ts(context, 9.5, color: c.muted, height: 1.5),
              ),
            ),
            if (_promptCache) _field('キャッシュの項目名', _cacheField, ProviderConfig.defaultPromptCacheField),
            _field('追加ヘッダー（JSON・任意）', _headers, '{"HTTP-Referer": "https://example.com"}', maxLines: 3),
            _field('追加のリクエスト項目（JSON・任意）', _body, '{"reasoning_effort": "low"}', maxLines: 3),
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                'モデルは保存したあと自動で取得します。一覧の「モデル」から選べます。',
                style: ts(context, 9.5, color: context.c.muted, height: 1.5),
              ),
            ),
            ],
            if (_result != null) ...[
              const SizedBox(height: 10),
              Text(
                _result!,
                style: ts(
                  context,
                  10,
                  color: _result!.contains('でき') ? c.green : c.amber,
                  height: 1.5,
                ),
              ),
            ],
            const SizedBox(height: 14),
            Row(
              children: [
                SoftButton(
                  label: '接続を確認',
                  svg: ArceSvg.shield,
                  onTap: _busy || _json ? null : _check,
                ),
                const SizedBox(width: 8),
                PrimaryButton(label: '保存', onTap: _busy ? null : _save),
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
    int maxLines = 1,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: ArceTextField(
      controller: controller,
      obscure: obscure,
      maxLines: maxLines,
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

/// The models of one provider: a tree by maker with a search field, the one in use, and the buttons
/// to read the provider's list again, to add a model by hand, and to open the detail screen.
///
/// The provider's list is read by itself (when the provider is saved, and when it is old); a model
/// that is only in the list is set up the moment it is picked.
class _ModelsSheet extends StatefulWidget {
  const _ModelsSheet({required this.app, required this.config});

  final AppController app;
  final ProviderConfig config;

  @override
  State<_ModelsSheet> createState() => _ModelsSheetState();
}

class _ModelsSheetState extends State<_ModelsSheet> {
  String? _result;
  final _query = TextEditingController();

  ProviderConfig get _config => widget.app.providers.byId(widget.config.id) ?? widget.config;

  @override
  void initState() {
    super.initState();
    // opened before the list was ever read: read it now (the setting can turn this off)
    final settings = widget.app.settings.value;
    if (_config.catalog.isEmpty && _config.autoFetchModels && settings.modelListAutoFetch) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _read());
    }
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _read() async {
    setState(() => _result = 'モデル一覧を読み込んでいます…');
    final message = await widget.app.refreshModelList(_config.id);
    if (mounted) setState(() => _result = message);
  }

  Future<void> _add() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('モデルを追加'),
        content: ArceTextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'モデル名',
            hintText: 'gpt-4o-mini',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('やめる'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('追加'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty) return;
    if (_config.modelById(name) != null) {
      setState(() => _result = 'そのモデルはすでにあります');
      return;
    }
    await widget.app.providers.save(
      _config.copyWith(models: [..._config.models, _config.resolveModel(name) ?? ModelConfig(id: name, name: name)]),
    );
    if (mounted) setState(() => _result = '$name を追加しました');
  }

  Future<void> _edit(ModelConfig model) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.c.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (context) =>
          ModelEditor(app: widget.app, provider: _config, model: model),
    );
    if (mounted) setState(() {});
  }

  /// Takes the model out of the settings (its own settings go with it). A model of the provider's
  /// list stays in the list and can be picked again.
  Future<void> _remove(ModelConfig model) async {
    final left = [
      for (final m in _config.models)
        if (m.id != model.id) m,
    ];
    await widget.app.providers.save(_config.copyWith(models: left));
    if (mounted) setState(() => _result = '${model.id} の設定を消しました');
  }

  Future<void> _pick(String id) async {
    final ok = await widget.app.providers.selectModel(_config.id, id);
    if (!ok) return;
    widget.app.showToast('${_config.label} · $id で答えます');
    if (mounted) setState(() {});
  }

  /// Asks the models the app is set to use now (the one that answers, the coding mode's models, the title
  /// model: a handful, not the provider's whole list) the shortest question, and shows which this key can use.
  Future<void> _checkConfigured() async {
    setState(() => _result = '設定中のモデルを確かめています…');
    final message = await widget.app.checkConfiguredModels();
    if (mounted) setState(() => _result = message);
  }

  Future<void> _openDetail() async {
    final navigator = Navigator.of(context);
    navigator.pop();
    await navigator.push(MaterialPageRoute<void>(builder: (_) => ModelDetailPage(app: widget.app)));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final store = widget.app.providers;
    final config = _config;
    final selected = store.modelOf(config.id)?.id;
    final query = _query.text.trim();
    final reading = widget.app.isReadingModelList(config.id);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.9,
        child: ListenableBuilder(
          listenable: Listenable.merge([store, widget.app, widget.app.availability]),
          builder: (context, _) {
            final config = _config;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: Row(children: [
                    Expanded(child: Text('${config.label} のモデル', style: ts(context, 14, weight: FontWeight.w700))),
                    SoftButton(label: '詳細', svg: ArceSvg.sliders, height: 30, onTap: _openDetail),
                  ]),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
                  child: Text(
                    '選んだモデルがチャットで使われます。一覧は提供元から自動で読み込みます。'
                    '選んだモデルは「設定済み」になり、パラメータとプロンプトをモデルごとに保存できます。'
                    '一覧には、このキー（プラン）で使えないモデルも並びます。「設定中のモデルを確かめる」で調べるか、モデルを選ぶと、使えないものに印が付きます。',
                    style: ts(context, 9.5, color: c.muted, height: 1.5),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                  child: ModelSearchField(controller: _query, onChanged: (_) => setState(() {})),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
                    child: config.knownIds.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            child: Text(
                              reading ? '読み込んでいます…' : 'モデルがまだありません。「更新」で提供元の一覧を読み込むか、「追加」で名前を入れてください。',
                              style: ts(context, 10, color: c.amber, height: 1.5),
                            ),
                          )
                        : ModelTreeView(
                            model: ModelTrees.forProvider(config, query: query, recent: store.recentRefs, marks: widget.app.modelMarks, keepKey: selected),
                            selectedKey: selected,
                            searching: query.isNotEmpty,
                            onPick: _pick,
                            leafTrailing: (leaf) {
                              final saved = config.modelById(leaf.key);
                              if (saved == null) return null;
                              return Row(mainAxisSize: MainAxisSize.min, children: [
                                IconTap(svg: ArceSvg.pencil, onTap: () => _edit(saved), tooltip: '編集', size: 15),
                                const SizedBox(width: 8),
                                IconTap(svg: ArceSvg.close, onTap: () => _remove(saved), tooltip: '設定を消す', size: 15),
                              ]);
                            },
                          ),
                  ),
                ),
                Padding(
                  padding: EdgeInsets.fromLTRB(16, 6, 16, sheetBottomPadding(context) > 16 ? 6 : 12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    if (_result != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(_result!, style: ts(context, 10, color: c.muted, height: 1.5)),
                      ),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(children: [
                        SoftButton(
                          label: widget.app.isProbing(config.id) ? '確かめています…' : '設定中のモデルを確かめる',
                          svg: ArceSvg.shield,
                          onTap: widget.app.isProbing(config.id) ? null : _checkConfigured,
                        ),
                      ]),
                    ),
                    Row(children: [
                      SoftButton(label: reading ? '読み込み中…' : '更新', svg: ArceSvg.retry, onTap: reading ? null : _read),
                      const SizedBox(width: 8),
                      SoftButton(label: '追加', svg: ArceSvg.plus, onTap: _add),
                      const Spacer(),
                      Text('${config.knownIds.length} 件', style: ts(context, 9.5, color: c.muted)),
                    ]),
                  ]),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The sampling overrides, limits, thinking settings and extra prompt of one model.
class ModelEditor extends StatefulWidget {
  const ModelEditor({
    super.key,
    required this.app,
    required this.provider,
    required this.model,
  });

  final AppController app;
  final ProviderConfig provider;
  final ModelConfig model;

  @override
  State<ModelEditor> createState() => _ModelEditorState();
}

class _ModelEditorState extends State<ModelEditor> {
  late final TextEditingController _name = TextEditingController(
    text: widget.model.name,
  );
  late final TextEditingController _temperature = TextEditingController(
    text: widget.model.param('temperature')?.toString() ?? '',
  );
  late final TextEditingController _topP = TextEditingController(
    text: widget.model.param('topP')?.toString() ?? '',
  );
  late final TextEditingController _maxTokens = TextEditingController(
    text: widget.model.intParam('maxTokens')?.toString() ?? '',
  );
  late final TextEditingController _prompt = TextEditingController(
    text: widget.model.prompt,
  );
  late final TextEditingController _context = TextEditingController(
    text: widget.model.contextTokens?.toString() ?? '',
  );
  late final TextEditingController _maxOutput = TextEditingController(
    text: widget.model.maxOutputTokens?.toString() ?? '',
  );
  late final TextEditingController _effort = TextEditingController(
    text: widget.model.thinking.effort,
  );
  late ThinkingConfig _thinking = widget.model.thinking;
  late ToolStyle _toolStyle = widget.model.toolStyle;
  late String _tier = widget.model.serviceTier;
  String? _note;
  bool _busy = false;

  ModelHint? get _hint => ModelHints.of(widget.model.id);

  /// Starts from what the chat would do now (the saved choice, or the guess from the name).
  late bool _vision = widget.model.supportsImages;

  @override
  void dispose() {
    for (final controller in [
      _name,
      _temperature,
      _topP,
      _maxTokens,
      _prompt,
      _context,
      _maxOutput,
      _effort,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final params = <String, double>{};
    final temperature = double.tryParse(_temperature.text.trim());
    final topP = double.tryParse(_topP.text.trim());
    final maxTokens = int.tryParse(_maxTokens.text.trim());
    if (temperature != null) {
      params['temperature'] = temperature.clamp(0, 2).toDouble();
    }
    if (topP != null) params['topP'] = topP.clamp(0, 1).toDouble();
    if (maxTokens != null) {
      params['maxTokens'] = maxTokens.clamp(1, 1048576).toDouble();
    }
    final model = widget.model
        .copyWith(
          name: _name.text.trim().isEmpty ? widget.model.id : _name.text.trim(),
          params: params,
          prompt: _prompt.text.trim(),
          vision: _vision,
        )
        .copyWith(thinking: _thinking.copyWith(effort: _effort.text.trim()), toolStyle: _toolStyle, serviceTier: _tier)
        .withLimits(contextTokens: _positive(_context.text), maxOutputTokens: _positive(_maxOutput.text));
    final provider =
        widget.app.providers.byId(widget.provider.id) ?? widget.provider;
    await widget.app.providers.save(
      provider.copyWith(
        models: [
          for (final m in provider.models)
            if (m.id == model.id) model else m,
        ],
      ),
    );
    if (!mounted) return;
    Navigator.of(context).pop();
    widget.app.showToast('${model.id} を保存しました');
  }

  static int? _positive(String text) {
    final value = int.tryParse(text.trim());
    return value != null && value > 0 ? value : null;
  }

  /// Asks the provider (and, for a Hugging Face name, the Hub) what the model can do, and puts the
  /// answer in the fields. Nothing is saved until the user presses 保存.
  Future<void> _fetch() async {
    setState(() {
      _busy = true;
      _note = '調べています…';
    });
    try {
      final provider = widget.app.providers.build(widget.provider, model: widget.model);
      if (provider is! OpenAiCompatibleProvider) return;
      final found = await widget.app.modelInfo.fetchFor(
        provider,
        widget.model.withLimits(),
        useHub: widget.app.settings.value.fetchModelInfoFromHub,
        overwrite: true,
      );
      if (!mounted) return;
      setState(() {
        if (found.contextTokens != null) _context.text = '${found.contextTokens}';
        if (found.maxOutputTokens != null) _maxOutput.text = '${found.maxOutputTokens}';
        if (found.vision != null) _vision = found.vision!;
        _note = found.contextTokens == null && found.maxOutputTokens == null
            ? '上限は見つかりませんでした。提供元が返さないモデルは、数字を直接入れてください'
            : '見つかりました（コンテキスト ${found.contextTokens ?? '—'}、最大出力 ${found.maxOutputTokens ?? '—'}）。保存すると反映されます';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The thinking format that suits this model's name (a suggestion; nothing is sent until saved).
  void _suggestThinking() {
    final family = ModelHints.familyOf(widget.model.id);
    final format = ThinkingRequest.suggestedFormat(
      widget.model.id,
      deepseek: family == ModelFamily.deepseek,
      glm: family == ModelFamily.glm,
    );
    setState(() {
      _thinking = _thinking.copyWith(
        format: format,
        // the GLM-5.3 card: "for chat scenarios, explicitly pass clear_thinking=true"
        clearThinking: family == ModelFamily.glm ? true : null,
      );
      _note = format == ThinkingFormat.none
          ? 'このモデルには、おすすめの送り方がありません'
          : '「${_formatLabel(format)}」を選びました。提供元のドキュメントで、この名前の項目を確かめてください。保存すると反映されます';
    });
  }

  static String _formatLabel(ThinkingFormat format) => switch (format) {
        ThinkingFormat.none => '送らない（提供元の既定）',
        ThinkingFormat.deepseekApi => 'DeepSeek の API（thinking / reasoning_effort）',
        ThinkingFormat.zaiApi => 'Z.ai の API（thinking / clear_thinking）',
        ThinkingFormat.chatTemplate => 'chat template のサーバー（vLLM・SGLang・Together・DeepInfra など）',
        ThinkingFormat.openaiEffort => 'OpenAI の形（reasoning_effort）',
        ThinkingFormat.openRouter => 'OpenRouter の形（reasoning: {effort}）',
      };

  static String _toolStyleLabel(ToolStyle style) => switch (style) {
        ToolStyle.auto => '自動（提供元がツールに対応していれば function calling）',
        ToolStyle.native => 'function calling（tools・tool_calls・tool メッセージ）',
        ToolStyle.text => 'テキスト形式（<tool_call> を本文に書く。Qwen 形式）',
      };

  static String _replayLabel(ReasoningReplay replay) => switch (replay) {
        ReasoningReplay.auto => '自動（DeepSeek・GLM で、ツールが function calling のとき返す）',
        ReasoningReplay.always => '常に返す（reasoning_content）',
        ReasoningReplay.never => '返さない（答えだけを履歴に残す）',
      };

  static String _modeLabel(ThinkingMode mode) => switch (mode) {
        ThinkingMode.auto => '自動（チャットの思考スイッチと、速度⇔精度に従う）',
        ThinkingMode.on => '常にオン',
        ThinkingMode.off => '常にオフ',
      };

  /// What the maker says about thinking, for the families that have a model card.
  static String? _thinkingNote(ModelFamily family) => switch (family) {
        ModelFamily.deepseek =>
          'DeepSeek V4.1（公式モデルカード）：推論の強さは 1〜100 の数値で、low=50・high=75・max=100、既定は high。'
              'ツールを使う会話では、過去のターンの思考を全部残します。',
        ModelFamily.glm =>
          'GLM-5.3（公式モデルカード）：reasoning_effort は low / high / max で、渡さなければ max。'
              'clear_thinking は渡さなければ false で、チャットでは true にするよう書かれています。',
        ModelFamily.other => null,
      };

  Widget _dropdown<T>(String label, T value, Map<T, String> items, ValueChanged<T> onChanged) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: DropdownButtonFormField<T>(
          // the field reads its initial value once: a new value (the suggestion button) needs a new field
          key: ValueKey<Object?>(value),
          initialValue: value,
          isExpanded: true,
          isDense: true,
          decoration: InputDecoration(labelText: label, isDense: true, border: const OutlineInputBorder()),
          style: ts(context, 11.5),
          items: [for (final e in items.entries) DropdownMenuItem(value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis))],
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      );

  /// The thinking part of the editor: how it is asked for, and the maker's own settings for it.
  List<Widget> _thinkingSection(BuildContext context) {
    final c = context.c;
    final family = ModelHints.familyOf(widget.model.id);
    final sent = _thinking.format != ThinkingFormat.none;
    final note = _thinkingNote(family);
    return [
      const SizedBox(height: 4),
      Text('思考（推論）', style: ts(context, 12, weight: FontWeight.w700)),
      const SizedBox(height: 4),
      Text(
        '「送らない」のあいだ、チャットの思考スイッチはこのモデルに届きません（提供元の既定で動きます）。'
        '提供元によって項目の名前が違うので、送り方を選びます。',
        style: ts(context, 9.5, color: c.muted, height: 1.5),
      ),
      if (note != null) ...[
        const SizedBox(height: 4),
        Text(note, style: ts(context, 9.5, color: c.accent, height: 1.5)),
      ],
      const SizedBox(height: 8),
      _dropdown<ThinkingFormat>(
        '思考の送り方',
        _thinking.format,
        {for (final f in ThinkingFormat.values) f: _formatLabel(f)},
        (v) => setState(() => _thinking = _thinking.copyWith(format: v)),
      ),
      if (sent) ...[
        _dropdown<ThinkingMode>(
          '思考',
          _thinking.mode,
          {for (final m in ThinkingMode.values) m: _modeLabel(m)},
          (v) => setState(() => _thinking = _thinking.copyWith(mode: v)),
        ),
        _field('推論の強さ', _effort, 'low / high / max、または 1〜100。空欄は速度⇔精度から決めます'),
        if (family == ModelFamily.glm || _thinking.format == ThinkingFormat.zaiApi || _thinking.format == ThinkingFormat.chatTemplate)
          _dropdown<bool?>(
            'clear_thinking（GLM）',
            _thinking.clearThinking,
            const {null: '指定しない', true: 'true（過去の思考を捨てる・チャット向け）', false: 'false（過去の思考を残す）'},
            (v) => setState(() => _thinking = _thinking.copyWith(clearThinking: v)),
          ),
      ],
      _dropdown<ReasoningReplay>(
        '過去の思考を返す',
        _thinking.replay,
        {for (final r in ReasoningReplay.values) r: _replayLabel(r)},
        (v) => setState(() => _thinking = _thinking.copyWith(replay: v)),
      ),
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: SoftButton(label: 'おすすめの送り方を入れる', svg: ArceSvg.check, onTap: _suggestThinking),
      ),
      Text('ツール', style: ts(context, 12, weight: FontWeight.w700)),
      const SizedBox(height: 4),
      Text(
        'ツールの定義と結果を、function calling の形で送るか、本文のテキストで送るかを選びます。'
        'どちらの形でも、ツールの説明は 1 回だけ送ります。',
        style: ts(context, 9.5, color: c.muted, height: 1.5),
      ),
      const SizedBox(height: 8),
      _dropdown<ToolStyle>(
        'ツールの送り方',
        _toolStyle,
        {for (final s in ToolStyle.values) s: _toolStyleLabel(s)},
        (v) => setState(() => _toolStyle = v),
      ),
    ];
  }

  /// Fills the fields with what the model's maker recommends.
  void _applyHint() {
    final hint = _hint;
    if (hint == null) return;
    setState(() {
      if (hint.temperature != null) _temperature.text = '${hint.temperature}';
      if (hint.topP != null) _topP.text = '${hint.topP}';
      if (hint.maxTokens != null) _maxTokens.text = '${hint.maxTokens}';
      if (_context.text.trim().isEmpty && hint.contextTokens != null) _context.text = '${hint.contextTokens}';
      _note = '推奨の値を入れました。保存すると反映されます';
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final hint = _hint;
    final shared = widget.app.settings.value;
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
              widget.model.id,
              style: ts(context, 14, weight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              hint == null ? '空欄はアプリの既定値を使います。' : '空欄は、下の推奨か、アプリの既定値を使います。',
              style: ts(context, 9.5, color: c.muted),
            ),
            if (hint != null) ...[
              const SizedBox(height: 4),
              Text(hint.label, style: ts(context, 9.5, color: c.accent, height: 1.5)),
            ],
            const SizedBox(height: 10),
            _field('表示名', _name, widget.model.id),
            _field('temperature', _temperature, '${hint?.temperature ?? 0.7}'),
            _field('top_p', _topP, '${hint?.topP ?? 0.95}'),
            _field('最大トークン（1回の返信の長さ。思考の分も含みます）', _maxTokens, '${hint?.maxTokens ?? shared.maxTokens}'),
            _field('最大出力の上限（モデルが返せる最大。最大トークンはこれに収めます）', _maxOutput, '例: 65536'),
            _field('コンテキスト長（入力と出力の合計）', _context, '${hint?.contextTokens ?? '例: 131072'}'),
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Wrap(spacing: 8, runSpacing: 8, children: [
                SoftButton(label: '上限を取得', svg: ArceSvg.retry, onTap: _busy ? null : _fetch),
                if (hint != null) SoftButton(label: '公式の推奨を入れる', svg: ArceSvg.check, onTap: _applyHint),
              ]),
            ),
            if (_note != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(_note!, style: ts(context, 10, color: c.muted, height: 1.5)),
              ),
            _field('追加プロンプト', _prompt, 'このモデルにだけ送る指示（任意）', maxLines: 3),
            ..._thinkingSection(context),
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 4),
              child: Text('処理の種類（service_tier）', style: ts(context, 12)),
            ),
            Text(
              'flex は、安い代わりに返事が遅い処理です（OpenAI のモデル。Cloudflare AI Gateway の openai/… でも指定できます）。'
              '待つ時間は「上限とタイムアウト」の「flex のモデルの応答のタイムアウト」です。対応しない提供元では、断られることがあります',
              style: ts(context, 9.5, color: c.muted, height: 1.5),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final tier in ['', ...ModelConfig.serviceTiers, if (_tier.isNotEmpty && !ModelConfig.serviceTiers.contains(_tier)) _tier])
                  ChoiceChip(
                    key: ValueKey('service-tier-${tier.isEmpty ? 'none' : tier}'),
                    label: Text(tier.isEmpty ? '指定しない' : tier, style: ts(context, 11)),
                    selected: _tier == tier,
                    onSelected: (_) => setState(() => _tier = tier),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: _vision,
              onChanged: (value) => setState(() => _vision = value),
              title: Text('画像を送る', style: ts(context, 12)),
              subtitle: Text(
                '添付した画像を画像のまま送ります。対応していないモデルでは、オフのままにしてください',
                style: ts(context, 9.5, color: c.muted),
              ),
            ),
            const SizedBox(height: 10),
            PrimaryButton(label: '保存', onTap: _save),
          ],
        ),
      ),
    );
  }

  Widget _field(
    String label,
    TextEditingController controller,
    String hint, {
    int maxLines = 1,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: ArceTextField(
      controller: controller,
      maxLines: maxLines,
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
