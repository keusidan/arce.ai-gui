import 'package:flutter/material.dart';

import '../services/conversation_database.dart';
import 'app_scope.dart';
import 'chat_widgets.dart';
import 'svg_icons.dart';
import 'theme.dart';
import 'widgets.dart';

class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = ArceScope.of(context);
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final c = context.c;
        final list = app.conversations;
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(14, 16, 14, 24),
          child: PageColumn(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const PageHeading('チャット履歴', 'この端末に保存した会話を確認します。'),
              if (list.isEmpty)
                ArceCard(
                  padding: const EdgeInsets.all(22),
                  child: SizedBox(
                    width: double.infinity,
                    child: Column(children: [
                      Container(
                        width: 54,
                        height: 54,
                        decoration: BoxDecoration(color: c.surface2, borderRadius: BorderRadius.circular(17)),
                        alignment: Alignment.center,
                        child: ArceIcon(ArceSvg.chat, size: 25, color: c.muted),
                      ),
                      const SizedBox(height: 12),
                      Text('履歴はまだありません', style: ts(context, 13, weight: FontWeight.w700)),
                      const SizedBox(height: 6),
                      Text('チャットを始めると、会話はこの端末に保存されます。', style: ts(context, 10, color: c.muted, height: 1.7)),
                    ]),
                  ),
                )
              else
                for (final meta in list) _HistoryItem(meta: meta, current: meta.id == app.conversationId),
              const SizedBox(height: 4),
              Wrap(spacing: 8, children: [
                SoftButton(
                  label: 'この会話をコピー（Markdown）',
                  svg: ArceSvg.copy,
                  onTap: () {
                    final text = app.exportConversation();
                    if (text == null) {
                      app.showToast('コピーする会話がありません');
                    } else {
                      copyToClipboard(context, text);
                    }
                  },
                ),
                PrimaryButton(label: '新しい会話', svg: ArceSvg.plus, onTap: app.newConversation),
              ]),
            ]),
          ),
        );
      },
    );
  }
}

class _HistoryItem extends StatelessWidget {
  const _HistoryItem({required this.meta, required this.current});
  final ConversationMeta meta;
  final bool current;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final app = ArceScope.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: current ? c.accent : c.line),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => app.openConversation(meta.id),
          child: Padding(
            padding: const EdgeInsets.all(11),
            child: Row(children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(color: c.surface2, borderRadius: BorderRadius.circular(10)),
                alignment: Alignment.center,
                child: ArceIcon(ArceSvg.chat, size: 17, color: c.muted),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(meta.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(context, 11, weight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text(
                    '${app.isRunning(meta.id) ? '生成中 · ' : ''}${formatDate(meta.updatedAt)} · ${meta.messageCount}メッセージ',
                    style: ts(context, 9, color: app.isRunning(meta.id) ? c.accent : c.muted),
                  ),
                ]),
              ),
              IconTap(svg: ArceSvg.close, size: 16, tooltip: '削除', onTap: () => app.deleteConversation(meta.id)),
            ]),
          ),
        ),
      ),
    );
  }
}
