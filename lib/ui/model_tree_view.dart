import 'package:flutter/material.dart';

import '../ai/model_tree.dart';
import 'arce_text_field.dart';
import 'svg_icons.dart';
import 'theme.dart';
import 'widgets.dart';

/// A model list as a tree: folders (a maker, a provider, "recently used") that open and close, and
/// the models inside. It does not scroll by itself; put it in a scroll view.
///
/// A folder with the picked model in it starts open, and so does "recently used". While the user
/// searches, every folder is open: the matches should be in sight, not behind a tap.
class ModelTreeView extends StatefulWidget {
  const ModelTreeView({
    super.key,
    required this.model,
    required this.selectedKey,
    required this.onPick,
    this.searching = false,
    this.leafTrailing,
  });

  final TreeModel model;

  /// The key of the model in use; null for none.
  final String? selectedKey;
  final ValueChanged<String> onPick;

  /// True while a search text is typed: all folders are shown open.
  final bool searching;

  /// Something at the right end of a model's row (edit and delete buttons); null for nothing.
  final Widget? Function(TreeLeaf leaf)? leafTrailing;

  @override
  State<ModelTreeView> createState() => _ModelTreeViewState();
}

class _ModelTreeViewState extends State<ModelTreeView> {
  /// Folders the user opened (true) or closed (false); a folder not here follows the default.
  final _choice = <String, bool>{};

  bool _defaultOpen(TreeNode node) =>
      node.key == 'recent' || (widget.selectedKey != null && node.contains(widget.selectedKey!));

  bool _isOpen(TreeNode node) => widget.searching || (_choice[node.key] ?? _defaultOpen(node));

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    if (model.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(child: Text('一致するモデルがありません', style: ts(context, 11, color: context.c.muted))),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final leaf in model.rootLeaves) _leaf(context, leaf, 0),
        for (final node in model.nodes) ..._node(context, node, 0),
      ],
    );
  }

  List<Widget> _node(BuildContext context, TreeNode node, int depth) {
    final c = context.c;
    final open = _isOpen(node);
    return [
      InkWell(
        onTap: widget.searching ? null : () => setState(() => _choice[node.key] = !open),
        child: Padding(
          padding: EdgeInsets.only(left: 4.0 + depth * 16, top: 9, bottom: 9, right: 4),
          child: Row(children: [
            ArceIcon(open ? ArceSvg.chevronDown : ArceSvg.chevronRight, size: 14, color: c.muted),
            const SizedBox(width: 6),
            Expanded(child: Text(node.label, style: ts(context, 11.5, weight: FontWeight.w700))),
            Text('${node.count}', style: ts(context, 9.5, color: c.muted)),
          ]),
        ),
      ),
      if (open) ...[
        for (final child in node.children) ..._node(context, child, depth + 1),
        for (final leaf in node.leaves) _leaf(context, leaf, depth + 1),
      ],
    ];
  }

  Widget _leaf(BuildContext context, TreeLeaf leaf, int depth) {
    final c = context.c;
    final selected = leaf.key == widget.selectedKey;
    final trailing = widget.leafTrailing?.call(leaf);
    final blocked = leaf.isBlocked;
    final usable = leaf.mark?.isUsable ?? false;
    // what the app found out about this key and model: shown in words as well as with a mark
    final note = blocked
        ? '使えません：${leaf.mark!.reason}'
        : usable
            ? '使えると確認済み'
            : null;
    final info = [if (leaf.badge != null) leaf.badge!, if (leaf.subtitle.isNotEmpty) leaf.subtitle].join(' · ');
    return InkWell(
      onTap: () => widget.onPick(leaf.key),
      child: Opacity(
        // greyed, not disabled: the user may know better (a plan changed), and can still pick it
        opacity: blocked ? .55 : 1,
        child: Padding(
          padding: EdgeInsets.only(left: 4.0 + depth * 16, top: 7, bottom: 7, right: 4),
          child: Row(children: [
            Icon(selected ? Icons.radio_button_checked : Icons.radio_button_unchecked, size: 16, color: selected ? c.accent : c.muted),
            const SizedBox(width: 8),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Flexible(
                    child: Text(
                      leaf.title,
                      style: ts(context, 11.5, weight: selected ? FontWeight.w700 : FontWeight.w600, color: blocked ? c.muted : null),
                    ),
                  ),
                  if (blocked) ...[
                    const SizedBox(width: 6),
                    Icon(Icons.block, key: const ValueKey('model-blocked'), size: 13, color: c.amber),
                  ] else if (usable) ...[
                    const SizedBox(width: 6),
                    Icon(Icons.check_circle_outline, key: const ValueKey('model-usable'), size: 13, color: c.green),
                  ],
                ]),
                if (info.isNotEmpty) Text(info, style: ts(context, 9, color: c.muted)),
                if (note != null) Text(note, style: ts(context, 9, color: blocked ? c.amber : c.green, height: 1.4)),
              ]),
            ),
            ?trailing,
          ]),
        ),
      ),
    );
  }
}

/// A search field for a model list.
class ModelSearchField extends StatelessWidget {
  const ModelSearchField({super.key, required this.controller, required this.onChanged, this.hint = 'モデルを検索（例: claude opus）'});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return ArceTextField(
      controller: controller,
      onChanged: onChanged,
      style: ts(context, 12),
      decoration: InputDecoration(
        hintText: hint,
        isDense: true,
        prefixIcon: Padding(padding: const EdgeInsets.all(11), child: ArceIcon(ArceSvg.search, size: 16, color: c.muted)),
        prefixIconConstraints: const BoxConstraints(minWidth: 38, minHeight: 36),
        suffixIcon: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => controller.text.isEmpty
              ? const SizedBox.shrink()
              : IconTap(
                  svg: ArceSvg.close,
                  size: 15,
                  tooltip: '消す',
                  onTap: () {
                    controller.clear();
                    onChanged('');
                  },
                ),
        ),
        border: const OutlineInputBorder(),
      ),
    );
  }
}

/// Opens a full-height sheet to choose a model: a search field above a tree. Returns the key of the
/// picked model, or null when the sheet was closed without a choice.
///
/// [build] makes the tree for the text typed in the search field (an empty text at first).
Future<String?> showModelPicker(
  BuildContext context, {
  required String title,
  required TreeModel Function(String query) build,
  required String? selectedKey,
  String? note,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: context.c.surface,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
    builder: (context) => _ModelPickerSheet(title: title, build: build, selectedKey: selectedKey, note: note),
  );
}

class _ModelPickerSheet extends StatefulWidget {
  const _ModelPickerSheet({required this.title, required this.build, required this.selectedKey, this.note});

  final String title;
  final TreeModel Function(String query) build;
  final String? selectedKey;
  final String? note;

  @override
  State<_ModelPickerSheet> createState() => _ModelPickerSheetState();
}

class _ModelPickerSheetState extends State<_ModelPickerSheet> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final query = _query.text.trim();
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.88,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 4),
              child: Text(widget.title, style: ts(context, 14, weight: FontWeight.w700)),
            ),
            if (widget.note != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 6),
                child: Text(widget.note!, style: ts(context, 9.5, color: c.muted, height: 1.5)),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
              child: ModelSearchField(controller: _query, onChanged: (_) => setState(() {})),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(14, 0, 14, sheetBottomPadding(context)),
                child: ModelTreeView(
                  model: widget.build(query),
                  selectedKey: widget.selectedKey,
                  searching: query.isNotEmpty,
                  onPick: (key) => Navigator.of(context).pop(key),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
