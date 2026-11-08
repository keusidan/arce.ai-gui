import 'package:flutter/material.dart';

import '../services/app_controller.dart';
import '../services/conversation_search.dart';
import 'arce_text_field.dart';
import 'svg_icons.dart';
import 'theme.dart';
import 'widgets.dart';

/// A search box and the conversations below it: every conversation while the box is empty, the
/// ones that match in their title or in a message while something is typed.
///
/// Used in the phone drawer and the desktop sidebar. [onDark] picks the colours for the sidebar's
/// dark background; [recentLimit] shows only the newest few while nothing is searched.
class HistoryPanel extends StatefulWidget {
  const HistoryPanel({
    super.key,
    required this.app,
    this.onOpen,
    this.recentLimit,
    this.onDark = false,
    this.scrollable = false,
  });

  final AppController app;

  /// Called after a conversation was opened (the drawer closes itself with it).
  final VoidCallback? onOpen;
  final int? recentLimit;
  final bool onDark;

  /// The list scrolls inside the panel, which then needs a bounded height (the drawer). Without
  /// it the panel is as tall as its content (the sidebar scrolls as a whole).
  final bool scrollable;

  @override
  State<HistoryPanel> createState() => _HistoryPanelState();
}

class _HistoryPanelState extends State<HistoryPanel> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _open(ConversationHit hit) {
    widget.app.openConversation(hit.meta.id);
    widget.onOpen?.call();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final text = widget.onDark ? c.navText : c.ink;
    final muted = widget.onDark ? c.navMuted : c.muted;
    return ListenableBuilder(
      listenable: widget.app,
      builder: (context, _) {
        final query = _controller.text.trim();
        final all = widget.app.searchConversations(query);
        final shown = query.isEmpty && widget.recentLimit != null ? all.take(widget.recentLimit!).toList() : all;

        final field = Padding(
          padding: const EdgeInsets.fromLTRB(2, 2, 2, 8),
          child: ArceTextField(
            controller: _controller,
            onChanged: (_) => setState(() {}),
            textInputAction: TextInputAction.search,
            style: ts(context, 12, color: text),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'チャット履歴を検索',
              hintStyle: ts(context, 12, color: muted),
              filled: true,
              fillColor: widget.onDark ? Colors.white.withValues(alpha: .07) : c.surface2,
              prefixIcon: Padding(
                padding: const EdgeInsets.all(10),
                child: ArceIcon(ArceSvg.search, size: 16, color: muted),
              ),
              prefixIconConstraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              suffixIcon: query.isEmpty
                  ? null
                  : IconTap(
                      svg: ArceSvg.close,
                      size: 15,
                      tooltip: '検索をクリア',
                      color: muted,
                      onTap: () => setState(_controller.clear),
                    ),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(11), borderSide: BorderSide.none),
            ),
          ),
        );

        final Widget empty = Padding(
          padding: const EdgeInsets.fromLTRB(8, 10, 8, 10),
          child: Text(
            query.isEmpty ? '履歴はまだありません' : '「$query」に一致する会話はありません',
            style: ts(context, 11, color: muted),
          ),
        );

        final tiles = [
          for (final hit in shown)
            HistoryTile(
              hit: hit,
              active: hit.meta.id == widget.app.conversationId && widget.app.page == AppPage.chat,
              running: widget.app.isRunning(hit.meta.id),
              onDark: widget.onDark,
              onTap: () => _open(hit),
            ),
        ];

        if (widget.scrollable) {
          return Column(children: [
            field,
            Expanded(child: shown.isEmpty ? Align(alignment: Alignment.topLeft, child: empty) : ListView(children: tiles)),
          ]);
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          field,
          if (shown.isEmpty) empty else ...tiles,
        ]);
      },
    );
  }
}

/// One conversation of the list: its title, the matching line when searching, and its date.
class HistoryTile extends StatelessWidget {
  const HistoryTile({super.key, required this.hit, required this.onTap, this.active = false, this.onDark = false, this.running = false});

  final ConversationHit hit;
  final VoidCallback onTap;
  final bool active;
  final bool onDark;

  /// The conversation is being answered now (maybe in the background).
  final bool running;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final text = onDark ? c.navText : c.ink;
    final muted = onDark ? c.navMuted : c.muted;
    final snippet = hit.snippet;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 1),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          color: active ? const Color(0x2E737BF5) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(
                hit.meta.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ts(context, 11.5, weight: FontWeight.w600, color: active && onDark ? Colors.white : text),
              ),
            ),
            const SizedBox(width: 6),
            if (running) ...[
              SizedBox(width: 9, height: 9, child: CircularProgressIndicator(strokeWidth: 1.6, color: c.accent)),
              const SizedBox(width: 4),
              Text('生成中', style: ts(context, 9.5, color: c.accent, weight: FontWeight.w600)),
              const SizedBox(width: 6),
            ],
            Text(formatDate(hit.meta.updatedAt), style: ts(context, 9.5, color: muted)),
          ]),
          if (snippet != null) ...[
            const SizedBox(height: 3),
            HighlightedSnippet(snippet, color: muted, highlight: c.accent),
          ],
        ]),
      ),
    );
  }
}

/// A search snippet whose matched part is written between `[` and `]`; the brackets are not shown.
class HighlightedSnippet extends StatelessWidget {
  const HighlightedSnippet(this.text, {super.key, required this.color, required this.highlight});

  final String text;
  final Color color;
  final Color highlight;

  /// The text split into plain and matched parts, in order.
  static List<(String, bool)> parts(String text) {
    final out = <(String, bool)>[];
    var cursor = 0;
    for (final m in RegExp(r'\[(.*?)\]', dotAll: true).allMatches(text)) {
      if (m.start > cursor) out.add((text.substring(cursor, m.start), false));
      out.add((m.group(1)!, true));
      cursor = m.end;
    }
    if (cursor < text.length) out.add((text.substring(cursor), false));
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final base = ts(context, 10, color: color, height: 1.45);
    return Text.rich(
      TextSpan(children: [
        for (final (part, matched) in parts(text.replaceAll('\n', ' ')))
          TextSpan(
            text: part,
            style: matched ? base.copyWith(color: highlight, fontWeight: FontWeight.w700) : base,
          ),
      ]),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }
}
