import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/search.dart';
import '../services/app_controller.dart';
import 'app_scope.dart';
import 'arce_text_field.dart';
import 'svg_icons.dart';
import 'theme.dart';
import 'widgets.dart';

/// The search services the user set up (address, headers, key and where the results are in the
/// answer). They are tried in this order after the SearXNG server.
class SearchApiSection extends StatelessWidget {
  const SearchApiSection({super.key});

  @override
  Widget build(BuildContext context) {
    final app = ArceScope.of(context);
    return ListenableBuilder(
      listenable: app.settings,
      builder: (context, _) {
        final apis = app.settings.value.searchApis;
        return ArceCard(
          child: Column(
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Text('検索 API', style: ts(context, 12, weight: FontWeight.w700)),
              ),
              const SizedBox(height: 6),
              if (apis.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    'まだありません。「追加」から、好きな検索サービスを登録できます（Brave・Tavily・Exa・Serper などはひな形があります）。',
                    style: ts(context, 9.5, color: context.c.muted, height: 1.5),
                  ),
                ),
              for (var i = 0; i < apis.length; i++) _ApiRow(app: app, api: apis[i], last: i == apis.length - 1),
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Row(children: [SoftButton(label: '検索 API を追加', svg: ArceSvg.plus, onTap: () => _edit(context, app, null))]),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'JSON を返すサービスに対応します（GET と POST）。{query} が検索語、{count} が件数、{key} が API キーに入れ替わります（URL・ヘッダー・本文のどこでも。キーは端末の安全な領域に保存）。',
                  style: ts(context, 9, color: context.c.muted, height: 1.5),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  static Future<void> _edit(BuildContext context, AppController app, SearchApiConfig? existing) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.c.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (context) => _ApiEditor(app: app, existing: existing),
    );
  }
}

class _ApiRow extends StatelessWidget {
  const _ApiRow({required this.app, required this.api, required this.last});

  final AppController app;
  final SearchApiConfig api;
  final bool last;

  Future<void> _confirmDelete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(api.name.isEmpty ? api.id : api.name),
        content: const Text('この検索 API と、保存した API キーを削除します。'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('やめる')),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('削除')),
        ],
      ),
    );
    if (ok != true) return;
    await app.settings.update((s) => s.copyWith(searchApis: [for (final item in s.searchApis) if (item.id != api.id) item]));
    await app.settings.forgetSearchKey(api.id);
    app.showToast('削除しました');
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 1),
      decoration: BoxDecoration(border: last ? null : Border(bottom: BorderSide(color: c.line))),
      child: Row(
        children: [
          ArceIcon(ArceSvg.globe, size: 16, color: api.enabled ? c.accent : c.muted),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        api.name.isEmpty ? api.id : api.name,
                        overflow: TextOverflow.ellipsis,
                        style: ts(context, 12, weight: FontWeight.w700, color: api.enabled ? c.ink : c.muted),
                      ),
                    ),
                    const SizedBox(width: 6),
                    StatusLabel(
                      api.enabled ? '有効' : '無効',
                      color: api.enabled ? c.green : c.muted,
                      background: api.enabled ? c.greenSoft : c.surface2,
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(api.url.split('?').first, maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(context, 9, color: c.muted)),
                if (api.needsKey && app.settings.searchKeyOf(api.id).isEmpty) Text('API キー未設定', style: ts(context, 9, color: c.amber)),
              ],
            ),
          ),
          SoftButton(
            label: '試す',
            height: 28,
            onTap: () async => app.showToast(await app.testSearchApi(api, app.settings.searchKeyOf(api.id))),
          ),
          const SizedBox(width: 6),
          SoftButton(label: '編集', height: 28, onTap: () => SearchApiSection._edit(context, app, api)),
          const SizedBox(width: 6),
          IconTap(svg: ArceSvg.close, onTap: () => _confirmDelete(context), tooltip: '削除', size: 15),
        ],
      ),
    );
  }
}

class _ApiEditor extends StatefulWidget {
  const _ApiEditor({required this.app, this.existing});

  final AppController app;
  final SearchApiConfig? existing;

  @override
  State<_ApiEditor> createState() => _ApiEditorState();
}

class _ApiEditorState extends State<_ApiEditor> {
  late final TextEditingController _name = TextEditingController(text: widget.existing?.name ?? '');
  late final TextEditingController _url = TextEditingController(text: widget.existing?.url ?? '');
  late final TextEditingController _headers = TextEditingController(text: _showHeaders(widget.existing?.headers ?? const {}));
  late final TextEditingController _key = TextEditingController(
    text: widget.existing == null ? '' : widget.app.settings.searchKeyOf(widget.existing!.id),
  );
  late final TextEditingController _results = TextEditingController(text: widget.existing?.resultsPath ?? '');
  late final TextEditingController _title = TextEditingController(text: widget.existing?.titleField ?? 'title');
  late final TextEditingController _link = TextEditingController(text: widget.existing?.urlField ?? 'url');
  late final TextEditingController _snippet = TextEditingController(text: widget.existing?.snippetField ?? 'description');
  late final TextEditingController _body = TextEditingController(text: widget.existing?.body ?? '');
  late final TextEditingController _maxCount = TextEditingController(text: '${widget.existing?.maxCount ?? 50}');
  late String _method = widget.existing?.method ?? 'GET';
  late bool _enabled = widget.existing?.enabled ?? true;

  static String _showHeaders(Map<String, String> headers) =>
      headers.isEmpty ? '' : jsonEncode(headers);

  @override
  void dispose() {
    for (final controller in [_name, _url, _headers, _key, _results, _title, _link, _snippet, _body, _maxCount]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _usePreset(SearchApiConfig preset) => setState(() {
        _name.text = preset.name;
        _url.text = preset.url;
        _headers.text = _showHeaders(preset.headers);
        _results.text = preset.resultsPath;
        _title.text = preset.titleField;
        _link.text = preset.urlField;
        _snippet.text = preset.snippetField;
        _method = preset.method;
        _body.text = preset.body;
        _maxCount.text = '${preset.maxCount}';
      });

  /// The config the fields describe, or null (with the reason shown) when the headers are wrong.
  SearchApiConfig? _config() {
    final label = _name.text.trim();
    final Map<String, String> headers;
    try {
      headers = SearchApiConfig.parseHeaders(_headers.text);
    } on FormatException catch (e) {
      widget.app.showToast(e.message);
      return null;
    }
    final existing = widget.existing;
    return SearchApiConfig(
      id: existing?.id ?? SearchApis.idFor(label, widget.app.settings.value.searchApis),
      name: label.isEmpty ? '検索' : label,
      url: _url.text.trim(),
      headers: headers,
      resultsPath: _results.text.trim(),
      titleField: _title.text.trim().isEmpty ? 'title' : _title.text.trim(),
      urlField: _link.text.trim().isEmpty ? 'url' : _link.text.trim(),
      snippetField: _snippet.text.trim(),
      method: _method,
      body: _method == 'POST' ? _body.text.trim() : '',
      maxCount: int.tryParse(_maxCount.text.trim())?.clamp(1, 1000) ?? 50,
      enabled: _enabled,
    );
  }

  Future<void> _save() async {
    final api = _config();
    if (api == null) return;
    final problem = api.problem;
    if (problem != null) {
      widget.app.showToast(problem);
      return;
    }
    await widget.app.settings.update(
      (s) => s.copyWith(searchApis: [for (final item in s.searchApis) if (item.id != api.id) item, api]),
    );
    await widget.app.settings.setSearchKey(api.id, _key.text);
    if (!mounted) return;
    Navigator.of(context).pop();
    widget.app.showToast('${api.name} を保存しました');
  }

  Future<void> _try() async {
    final api = _config();
    if (api == null) return;
    widget.app.showToast('試しています…');
    widget.app.showToast(await widget.app.testSearchApi(api, _key.text));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Padding(
      padding: EdgeInsets.only(left: 16, right: 16, top: 16, bottom: sheetBottomPadding(context)),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.existing == null ? '検索 API を追加' : '検索 API を編集', style: ts(context, 14, weight: FontWeight.w700)),
            if (widget.existing == null) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                children: [
                  for (final entry in SearchApiConfig.presets.entries)
                    ActionChip(label: Text(entry.key), onPressed: () => _usePreset(entry.value)),
                ],
              ),
            ],
            const SizedBox(height: 12),
            _field('名前', _name, 'Brave Search'),
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: SegmentedButton<String>(
                segments: [for (final m in SearchApiConfig.methods) ButtonSegment(value: m, label: Text(m))],
                selected: {_method},
                onSelectionChanged: (v) => setState(() => _method = v.first),
              ),
            ),
            _field('URL', _url, 'https://…?q={query}&count={count}', keyboard: TextInputType.url),
            if (_method == 'POST') _field('本文（JSON）', _body, '{"query": "{query}", "max_results": {count}}', lines: 3),
            _field('ヘッダー（JSON）', _headers, '{"X-Subscription-Token": "{key}"}', lines: 2),
            _field('API キー', _key, '{key} に入ります（端末の安全な領域に保存）', obscure: true),
            _field('結果の場所', _results, 'web.results（答えそのものが一覧なら空）'),
            _field('1回に頼める件数の上限', _maxCount, '50', keyboard: TextInputType.number),
            Row(
              children: [
                Expanded(child: _field('題名', _title, 'title')),
                const SizedBox(width: 8),
                Expanded(child: _field('URL の項目', _link, 'url')),
                const SizedBox(width: 8),
                Expanded(child: _field('概要', _snippet, 'description')),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('この検索 API を使う', style: ts(context, 11, weight: FontWeight.w600)),
              subtitle: Text('オフの間は検索に使いません', style: ts(context, 9, color: c.muted)),
              value: _enabled,
              onChanged: (v) => setState(() => _enabled = v),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                SoftButton(label: '試す', svg: ArceSvg.shield, onTap: _try),
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
    int lines = 1,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: ArceTextField(
      controller: controller,
      obscure: obscure,
      keyboardType: keyboard,
      minLines: lines,
      maxLines: lines,
      style: ts(context, 12),
      decoration: InputDecoration(labelText: label, hintText: hint, isDense: true, border: const OutlineInputBorder()),
    ),
  );
}
