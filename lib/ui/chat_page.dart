import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/attachments.dart';
import '../core/chat_controller.dart';
import '../services/app_controller.dart';
import 'arce_text_field.dart';
import 'app_scope.dart';
import 'chat_widgets.dart';
import 'svg_icons.dart';
import 'theme.dart';
import 'thinking_level_slider.dart';
import 'thinking_sheet.dart';
import 'widgets.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  final _attachments = <Attachment>[];

  /// What would be sent (the typed text with the attachments' text): the token count under the input reads it.
  final _draft = ValueNotifier<String>('');
  AppController? _app;
  int _lastCount = 0;

  /// A jump to the newest message is waiting for the end of this frame.
  bool _scrollQueued = false;

  void _syncDraft() {
    final app = _app;
    if (app == null) return;
    _draft.value = AttachmentPolicy.compose(_input.text, _attachments, limits: app.settings.value.attachmentLimits);
  }

  bool get _desktop => const {TargetPlatform.windows, TargetPlatform.linux, TargetPlatform.macOS}.contains(defaultTargetPlatform);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = ArceScope.of(context);
    if (_app != app) {
      _app?.chat.removeListener(_onChat);
      _app = app..chat.addListener(_onChat);
      _lastCount = app.chat.state.messages.length;
      // coming back from another page: show the latest messages, not the top of the list
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    }
  }

  @override
  void dispose() {
    _app?.chat.removeListener(_onChat);
    _draft.dispose();
    _input.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onChat() {
    final count = _app!.chat.state.messages.length;
    final grew = count != _lastCount;
    _lastCount = count;
    if (!_scroll.hasClients) return;
    final nearBottom = _scroll.position.maxScrollExtent - _scroll.offset < 160;
    if (!grew && !nearBottom) return;
    // one jump per frame: a reply sends many pieces, and each of them used to queue its own jump
    if (_scrollQueued) return;
    _scrollQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollQueued = false;
      if (!_scroll.hasClients) return;
      if (!grew && _scroll.position.maxScrollExtent - _scroll.offset >= 160) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  Future<void> _pickFiles() async {
    final app = ArceScope.of(context);
    final files = await FilePicker.pickFiles();
    final limits = app.settings.value.attachmentLimits;
    for (final file in files) {
      final path = file.path;
      if (path == null) continue;
      if (_attachments.length >= limits.maxFiles) {
        app.showToast('添付できるのは${limits.maxFiles}ファイルまでです（設定で変えられます）');
        break;
      }
      try {
        // a picture for a model that can see, text for any other file
        final attachment = AttachmentReader.read(
          file.name,
          await File(path).readAsBytes(),
          acceptImages: app.acceptsImages,
          maxImageBytes: limits.maxImageBytes,
        );
        setState(() => _attachments.add(attachment));
        _syncDraft();
      } on AttachmentException catch (e) {
        app.showToast(e.message);
      } catch (_) {
        app.showToast('${file.name} を読み込めませんでした');
      }
    }
  }

  void _send() {
    final app = ArceScope.of(context);
    final text = _input.text;
    if (text.trim().isEmpty && _attachments.isEmpty) return;
    if (app.chat.isRunning) {
      // a reply is going on: the text is read by the model at the next break between two tools
      if (_attachments.isNotEmpty) {
        app.showToast('ファイルの添付は、返信が終わってから送れます');
        return;
      }
      if (app.chat.interject(text)) {
        _input.clear();
        _syncDraft();
        return;
      }
    }
    final shown = text.trim().isEmpty ? 'ファイルを添付しました。' : text;
    final files = List<Attachment>.of(_attachments);
    _input.clear();
    setState(_attachments.clear);
    _syncDraft();
    unawaited(app.chat.send(shown, attachments: files));
  }

  /// The row under the input: the tools on the left and the send (or 割り込む / 停止) buttons on the right.
  /// At the normal text size it is one row. When the text is larger the tools wrap onto more lines, and the
  /// send buttons go on a line of their own, at the right: neither pushes the other out of the screen.
  Widget _toolsAndSend({required List<Widget> tools, required List<Widget> send}) {
    final large = MediaQuery.textScalerOf(context).scale(10) / 10 > 1.25;
    final toolsWrap = Wrap(crossAxisAlignment: WrapCrossAlignment.center, runSpacing: 4, children: tools);
    final sendRow = Row(mainAxisSize: MainAxisSize.min, children: send);
    if (large) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        toolsWrap,
        const SizedBox(height: 6),
        Align(alignment: Alignment.centerRight, child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerRight, child: sendRow)),
      ]);
    }
    return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [Expanded(child: toolsWrap), const SizedBox(width: 8), sendRow]);
  }

  @override
  Widget build(BuildContext context) {
    final app = ArceScope.of(context);
    return Column(children: [
      Expanded(
        child: ListenableBuilder(
          listenable: Listenable.merge([app.chat, app.settings, app.models]),
          builder: (context, _) => _Messages(app: app, scroll: _scroll, onPrompt: _usePrompt),
        ),
      ),
      PageColumn(
        maxWidth: 860,
        child: ListenableBuilder(
          listenable: Listenable.merge([app.chat, app.settings]),
          builder: (context, _) => _composer(context, app),
        ),
      ),
    ]);
  }

  void _usePrompt(String prompt) {
    _input.text = prompt;
    _input.selection = TextSelection.collapsed(offset: prompt.length);
    _focus.requestFocus();
    setState(() {});
    _syncDraft();
  }

  Widget _composer(BuildContext context, AppController app) {
    final c = context.c;
    final chat = app.chat.state;
    final settings = app.settings.value;
    final canSend = _input.text.trim().isNotEmpty || _attachments.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(11, 0, 11, 7),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          padding: const EdgeInsets.fromLTRB(9, 9, 9, 8),
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: c.line),
            boxShadow: const [BoxShadow(color: Color(0x0B1E2537), blurRadius: 14, offset: Offset(0, 4))],
          ),
          child: Column(children: [
            if (_attachments.isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(2, 0, 2, 6),
                  child: Wrap(spacing: 6, runSpacing: 6, children: [
                    for (var i = 0; i < _attachments.length; i++)
                      FileChip(
                        name: _attachments[i].name,
                        onRemove: () {
                          setState(() => _attachments.removeAt(i));
                          _syncDraft();
                        },
                      ),
                  ]),
                ),
              ),
            if (chat.queued.isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(2, 0, 2, 6),
                  child: Wrap(spacing: 6, runSpacing: 6, children: [
                    for (var i = 0; i < chat.queued.length; i++)
                      FileChip(
                        name: '次の区切りで伝える: ${chat.queued[i]}',
                        onRemove: () => app.chat.unqueue(i),
                      ),
                  ]),
                ),
              ),
            Focus(
              onKeyEvent: (node, event) {
                // Enter sends on desktop; Shift+Enter adds a line
                if (_desktop &&
                    event is KeyDownEvent &&
                    event.logicalKey == LogicalKeyboardKey.enter &&
                    !HardwareKeyboard.instance.isShiftPressed &&
                    !_input.value.composing.isValid) {
                  _send();
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: ArceTextField(
                controller: _input,
                focusNode: _focus,
                minLines: 1,
                maxLines: 5,
                maxLength: 4000,
                onChanged: (_) {
                  setState(() {});
                  _syncDraft();
                },
                style: ts(context, 13, height: 1.55),
                decoration: InputDecoration(
                  isCollapsed: true,
                  counterText: '',
                  contentPadding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
                  hintText: 'メッセージを入力してください…',
                  hintStyle: ts(context, 13, color: c.faint),
                  border: InputBorder.none,
                ),
              ),
            ),
            _toolsAndSend(
              tools: [
                _ToolButton(svg: ArceSvg.paperclip, onTap: _pickFiles, tooltip: 'ファイルを添付'),
                const SizedBox(width: 2),
                Container(width: 1, height: 19, color: c.line),
                const SizedBox(width: 2),
                _ToolButton(
                  svg: ArceSvg.brainLabel,
                  label: '思考',
                  on: settings.thinking,
                  tooltip: '思考の量・送り方・表示',
                  onTap: () => showThinkingSheet(context, app),
                ),
                ThinkingLevelSlider(app: app),
                _ToolButton(
                  svg: ArceSvg.search,
                  label: '検索',
                  on: settings.searchEnabled,
                  onTap: () {
                    app.settings.update((s) => s.copyWith(searchEnabled: !s.searchEnabled));
                    app.showToast(!settings.searchEnabled ? '検索をオン' : '検索をオフ');
                  },
                ),
                _ToolButton(
                  svg: ArceSvg.codeEdit,
                  label: '分担',
                  on: settings.codingPlanEnabled,
                  tooltip: '分担モード：plan が設計と分担数を決め、coding が調べてから実装します',
                  onTap: () {
                    app.settings.update((s) => s.copyWith(codingPlanEnabled: !s.codingPlanEnabled));
                    if (settings.codingPlanEnabled) {
                      app.showToast('分担モードをオフ');
                    } else if (!app.settings.value.coding.isReady) {
                      // on, but it cannot work until both models are chosen: take the user there
                      app.showToast('plan と coding のモデルを選んでください');
                      app.openSettings(SettingsSection.coding);
                    } else {
                      app.showToast('分担モードをオン');
                    }
                  },
                ),
              ],
              send: [
                if (chat.isGenerating) ...[
                  if (canSend) ...[
                    _SendButton(label: '割り込む', svg: ArceSvg.send, onTap: _send),
                    const SizedBox(width: 6),
                  ],
                  _SendButton(label: '停止', svg: ArceSvg.stop, onTap: app.chat.stop, stop: true),
                ] else
                  _SendButton(label: '送信', svg: ArceSvg.send, onTap: canSend ? _send : null),
              ],
            ),
          ]),
        ),
        PromptTokenLine(app: app, draft: _draft),
        SizedBox(
          height: 20,
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            ArceIcon(ArceSvg.info, size: 11, color: app.engine.isLoaded ? c.green : c.amber),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                app.engineLabel,
                overflow: TextOverflow.ellipsis,
                style: ts(context, 9, color: c.muted),
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}

class _Messages extends StatefulWidget {
  const _Messages({required this.app, required this.scroll, required this.onPrompt});

  final AppController app;
  final ScrollController scroll;
  final ValueChanged<String> onPrompt;

  @override
  State<_Messages> createState() => _MessagesState();
}

class _MessagesState extends State<_Messages> {
  /// The rows of the messages that are not being written now, kept as they are. A new piece of the
  /// last reply then rebuilds that one row instead of the whole conversation (reading every Markdown
  /// reply again on each piece was the largest cost of a long chat). A row reads the settings, so a
  /// settings change drops them all.
  final _rows = <int, (UiMessage, Object?, Widget)>{};
  ChatController? _chat;

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final state = app.chat.state;
    final settings = app.settings.value;
    if (!identical(_chat, app.chat.current)) {
      _chat = app.chat.current;
      _rows.clear();
    }
    final last = state.messages.isEmpty ? null : state.messages.last;
    // the animated card is for the time before anything arrives; the thinking block takes over then
    final showThinkingCard = state.isGenerating &&
        settings.thinking &&
        (last?.text.trim().isEmpty ?? true) &&
        (last?.thinking.trim().isEmpty ?? true);
    final lastIndex = state.messages.length - 1;
    if (_rows.isNotEmpty) {
      final ids = {for (final m in state.messages) m.id};
      _rows.removeWhere((id, _) => !ids.contains(id));
    }
    Widget messageRow(int i) {
      final message = state.messages[i];
      if (i == lastIndex) return MessageView(message: message, isLast: true, state: state);
      final cached = _rows[message.id];
      if (cached != null && identical(cached.$1, message) && identical(cached.$2, settings)) {
        return cached.$3;
      }
      final row = MessageView(message: message, isLast: false, state: state);
      _rows[message.id] = (message, settings, row);
      return row;
    }

    final hasPartialProgress = last != null &&
        (last.text.isNotEmpty || last.thinking.isNotEmpty || last.activities.isNotEmpty);

    return SelectionArea(
      child: ListView(
        controller: widget.scroll,
        padding: const EdgeInsets.fromLTRB(12, 14, 12, 13),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 920),
              child: state.messages.isEmpty
                  ? _Welcome(app: app, onPrompt: widget.onPrompt)
                  : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      for (var i = 0; i <= lastIndex; i++)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: RepaintBoundary(child: messageRow(i)),
                        ),
                      if (showThinkingCard)
                        ThinkingCard(task: state.task, style: settings.thinkingStyle),
                      if (state.progress != null) RunStatus(progress: state.progress!),
                      if (state.pendingQuestion != null && state.pendingTool != null)
                        ToolApprovalCard(
                          key: ValueKey(state.messages.length),
                          call: state.pendingTool!,
                          tile: state.pendingQuestion!,
                          onAnswer: (selected, free) => app.chat.answer(selected, free),
                        )
                      else if (state.pendingQuestion != null)
                        QuestionCard(
                          key: ValueKey(state.messages.length),
                          tile: state.pendingQuestion!,
                          onAnswer: (selected, free) => app.chat.answer(selected, free),
                        ),
                      if (state.notice != null) NoticeBanner(text: state.notice!, tone: BannerTone.warning),
                      if (state.error != null)
                        NoticeBanner(
                          text: state.error!,
                          tone: BannerTone.error,
                          action: state.isGenerating
                              ? null
                              : state.canContinue && hasPartialProgress
                                  ? Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        SoftButton(label: '途中から続行', onTap: app.chat.continueReply),
                                        const SizedBox(width: 6),
                                        SoftButton(label: '最初から', onTap: app.chat.regenerate),
                                      ],
                                    )
                                  : SoftButton(label: '再試行', onTap: app.chat.regenerate),
                        ),
                    ]),
            ),
          ),
        ],
      ),
    );
  }
}

class _Welcome extends StatelessWidget {
  const _Welcome({required this.app, required this.onPrompt});

  final AppController app;
  final ValueChanged<String> onPrompt;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final loaded = app.engine.isLoaded;
    final chips = <(String, String, VoidCallback)>[
      ('コード生成を試す', ArceSvg.codeEdit, () => onPrompt('Pythonで簡単なToDoリストを作るコードを書いて')),
      ('モデルを確認する', ArceSvg.cube, () => app.goTo(AppPage.models)),
      ('生成物を見る', ArceSvg.grid, () => app.goTo(AppPage.artifacts)),
      ('アプリ設定を開く', ArceSvg.settings, () => app.goTo(AppPage.settings)),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(children: [
        Container(
          width: 66,
          height: 66,
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: c.line),
            boxShadow: const [BoxShadow(color: Color(0x14192132), blurRadius: 30, offset: Offset(0, 10))],
          ),
          child: Stack(alignment: Alignment.center, children: [
            ArceIcon(ArceSvg.welcome, size: 36, color: const Color(0xFF858C9C)),
            Positioned(right: 4, top: 6, child: Text('✦', style: ts(context, 13, weight: FontWeight.w800, color: c.accent))),
            Positioned(right: 13, top: 1, child: Text('✦', style: ts(context, 10, weight: FontWeight.w800, color: c.accent))),
          ]),
        ),
        const SizedBox(height: 15),
        Text('ARCE.AI へようこそ', style: ts(context, 20, weight: FontWeight.w700)),
        const SizedBox(height: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 300),
          child: Text(
            'ローカルAIでチャットを始めましょう。\nモデルを設定すると、会話やコード生成に使えます。',
            textAlign: TextAlign.center,
            style: ts(context, 12, color: c.muted, height: 1.8),
          ),
        ),
        const SizedBox(height: 14),
        Wrap(alignment: WrapAlignment.center, spacing: 7, runSpacing: 7, children: [
          _Badge(icon: ArceSvg.shield, text: 'データは端末内に保存'),
          _Badge(dot: loaded ? c.green : c.amber, text: loaded ? 'AIモデル接続済み' : 'ローカルモデル未接続'),
        ]),
        const SizedBox(height: 21),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
            childAspectRatio: 3.1,
            children: [for (final chip in chips) _PromptChip(label: chip.$1, svg: chip.$2, onTap: chip.$3)],
          ),
        ),
      ]),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({this.icon, this.dot, required this.text});
  final String? icon;
  final Color? dot;
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(30), border: Border.all(color: c.line)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ArceIcon(icon!, size: 12, color: c.muted),
        if (dot != null) StatusDot(color: dot!),
        const SizedBox(width: 5),
        Text(text, style: ts(context, 10, weight: FontWeight.w600, color: c.muted)),
      ]),
    );
  }
}

class _PromptChip extends StatelessWidget {
  const _PromptChip({required this.label, required this.svg, required this.onTap});
  final String label;
  final String svg;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Material(
      color: c.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13), side: BorderSide(color: c.line)),
      child: InkWell(
        borderRadius: BorderRadius.circular(13),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(color: c.accentSoft, borderRadius: BorderRadius.circular(9)),
              alignment: Alignment.center,
              child: ArceIcon(svg, size: 15, color: c.accent),
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(label, style: ts(context, 11, weight: FontWeight.w500, height: 1.35))),
          ]),
        ),
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({required this.svg, required this.onTap, this.label, this.on = false, this.tooltip});
  final String svg;
  final VoidCallback onTap;
  final String? label;
  final bool on;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final color = on ? c.accent : c.muted;
    final button = Material(
      color: on ? c.accentSoft : Colors.transparent,
      borderRadius: BorderRadius.circular(9),
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: onTap,
        child: Container(
          height: 31,
          constraints: const BoxConstraints(minWidth: 31),
          padding: const EdgeInsets.symmetric(horizontal: 7),
          child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
            ArceIcon(svg, size: 17, color: color),
            if (label != null) ...[const SizedBox(width: 5), Text(label!, style: ts(context, 10, weight: FontWeight.w600, color: color))],
          ]),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

class _SendButton extends StatelessWidget {
  const _SendButton({required this.label, required this.svg, required this.onTap, this.stop = false});
  final String label;
  final String svg;
  final VoidCallback? onTap;
  final bool stop;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Opacity(
      opacity: onTap == null ? .42 : 1,
      child: Material(
        color: stop ? c.red : c.nav,
        borderRadius: BorderRadius.circular(11),
        child: InkWell(
          borderRadius: BorderRadius.circular(11),
          onTap: onTap,
          child: Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              ArceIcon(svg, size: 17, color: Colors.white),
              const SizedBox(width: 6),
              Text(label, style: ts(context, 11, weight: FontWeight.w700, color: Colors.white)),
            ]),
          ),
        ),
      ),
    );
  }
}
