import 'package:flutter/material.dart';

import '../services/app_controller.dart';
import 'app_scope.dart';
import 'artifacts_page.dart';
import 'chat_page.dart';
import 'history_page.dart';
import 'history_panel.dart';
import 'models_page.dart';
import 'settings_page.dart';
import 'svg_icons.dart';
import 'theme.dart';
import 'update_widgets.dart';
import 'widgets.dart';

/// Width from which the desktop layout (sidebar) is used instead of the phone layout (bottom bar).
const _wideBreakpoint = 900.0;

class AppShell extends StatelessWidget {
  const AppShell({super.key});

  @override
  Widget build(BuildContext context) {
    final app = ArceScope.of(context);
    final wide = MediaQuery.sizeOf(context).width >= _wideBreakpoint;
    return Scaffold(
      resizeToAvoidBottomInset: true,
      drawer: wide ? null : _MenuDrawer(app: app),
      body: Stack(children: [
        ListenableBuilder(
          listenable: app,
          builder: (context, _) => wide ? _WideLayout(app: app) : _NarrowLayout(app: app),
        ),
        Positioned(left: 0, right: 0, bottom: wide ? 40 : 76, child: _Toast(app: app)),
      ]),
    );
  }
}

String _pageTitle(AppController app) => switch (app.page) {
      AppPage.chat => _threadTitle(app),
      AppPage.models => 'モデル管理',
      AppPage.artifacts => '生成物',
      AppPage.settings => '詳細設定',
      AppPage.history => 'チャット履歴',
    };

String _threadTitle(AppController app) => app.currentTitle;

Widget _pageBody(AppController app) => switch (app.page) {
      AppPage.chat => const ChatPage(),
      AppPage.models => const ModelsPage(),
      AppPage.artifacts => const ArtifactsPage(),
      AppPage.settings => const SettingsPage(),
      AppPage.history => const HistoryPage(),
    };

class _NarrowLayout extends StatelessWidget {
  const _NarrowLayout({required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Column(children: [
      Container(
        decoration: BoxDecoration(
          color: c.surface,
          border: Border(bottom: BorderSide(color: c.line)),
          boxShadow: const [BoxShadow(color: Color(0x06151A28), blurRadius: 9, offset: Offset(0, 2))],
        ),
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 9, 14, 0),
            child: Column(children: [
              // as tall as 48 px, and taller when the text is larger (a fixed height made the title overflow)
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                  Builder(
                    builder: (context) => IconTap(
                      svg: ArceSvg.menu,
                      size: 22,
                      color: c.ink,
                      tooltip: 'メニュー',
                      onTap: () => Scaffold.of(context).openDrawer(),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Column(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('ARCE.AI', maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(context, 16, weight: FontWeight.w800, letterSpacing: .56, height: 1.1)),
                      const SizedBox(height: 1),
                      Text('Local AI · Chat & Coding', maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(context, 9, color: c.muted, letterSpacing: .2)),
                    ]),
                  ),
                  const SizedBox(width: 8),
                  EnginePill(app: app, compact: true),
                ]),
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 39),
                child: Row(children: [
                  Expanded(child: ThreadTitle(app: app)),
                  IconTap(svg: ArceSvg.history, tooltip: '会話履歴', onTap: () => app.goTo(AppPage.history)),
                  IconTap(svg: ArceSvg.plus, tooltip: '新しい会話', onTap: app.newConversation),
                ]),
              ),
            ]),
          ),
        ),
      ),
      UpdateBanner(onOpen: () => app.openSettings(SettingsSection.update)),
      InterruptedBanner(app: app),
      Expanded(child: _pageBody(app)),
      _BottomNav(app: app),
    ]);
  }
}

class ThreadTitle extends StatelessWidget {
  const ThreadTitle({super.key, required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([app, app.chat]),
        builder: (context, _) => Row(mainAxisSize: MainAxisSize.min, children: [
          Flexible(
            child: Text(_pageTitle(app), overflow: TextOverflow.ellipsis, maxLines: 1, style: ts(context, 14, weight: FontWeight.w700)),
          ),
          if (app.page == AppPage.chat) ...[
            const SizedBox(width: 7),
            ArceIcon(ArceSvg.pencil, size: 15, color: context.c.muted),
          ],
        ]),
      );
}

class EnginePill extends StatelessWidget {
  const EnginePill({super.key, required this.app, this.compact = false});
  final AppController app;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return ListenableBuilder(
      listenable: Listenable.merge([app.models, app.providers]),
      builder: (context, _) {
        // an online model answering means the device model is not what the user is waiting for
        final online = app.providers.active != null;
        final loaded = online || app.models.isLoaded;
        final label = online
            ? app.providers.activeModelId
            : (app.models.isLoaded ? (app.models.loadedName ?? 'ローカルモデル') : (compact ? 'ローカルモデル未導入' : 'ローカルAI'));
        return Material(
          color: c.surface2,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11), side: BorderSide(color: c.line)),
          child: InkWell(
            borderRadius: BorderRadius.circular(11),
            onTap: () => app.goTo(AppPage.models),
            child: Container(
              height: 34,
              constraints: BoxConstraints(maxWidth: compact ? 156 : 220),
              padding: const EdgeInsets.symmetric(horizontal: 9),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                StatusDot(color: loaded ? c.green : const Color(0xFFE4A546)),
                const SizedBox(width: 8),
                Flexible(child: Text(label, overflow: TextOverflow.ellipsis, style: ts(context, 10.5, weight: FontWeight.w600))),
                const SizedBox(width: 4),
                ArceIcon(ArceSvg.chevronDown, size: 13, color: c.muted),
              ]),
            ),
          ),
        );
      },
    );
  }
}

class _BottomNav extends StatelessWidget {
  const _BottomNav({required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    Widget item(AppPage page, String label, String svg) {
      final active = app.page == page;
      return Expanded(
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => app.goTo(page),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 50),
            child: Column(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
              Container(
                width: 42,
                height: 25,
                decoration: BoxDecoration(
                  color: active ? const Color(0x2E737BF5) : Colors.transparent,
                  borderRadius: BorderRadius.circular(9),
                ),
                alignment: Alignment.center,
                child: ArceIcon(svg, size: 19, color: active ? const Color(0xFFB9BDFF) : c.navMuted),
              ),
              const SizedBox(height: 2),
              Text(label, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis, style: ts(context, 9, weight: FontWeight.w500, color: active ? Colors.white : c.navMuted)),
            ]),
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(color: c.nav, boxShadow: const [BoxShadow(color: Color(0x1F0F1119), blurRadius: 16, offset: Offset(0, -4))]),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 3, 6, 3),
          child: Row(children: [
            item(AppPage.chat, 'チャット', ArceSvg.chat),
            item(AppPage.models, 'モデル', ArceSvg.cube),
            item(AppPage.artifacts, '生成物', ArceSvg.gridNav),
            item(AppPage.settings, '設定', ArceSvg.settings),
          ]),
        ),
      ),
    );
  }
}

class _WideLayout extends StatelessWidget {
  const _WideLayout({required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Row(children: [
      ValueListenableBuilder<bool>(
        valueListenable: app.sidebarOpen,
        builder: (context, open, _) => open ? _Sidebar(app: app) : const SizedBox.shrink(),
      ),
      Expanded(
        child: Column(children: [
          Container(
            height: 56,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(color: c.surface, border: Border(bottom: BorderSide(color: c.line))),
            child: Row(children: [
              IconTap(
                svg: ArceSvg.menu,
                size: 22,
                color: c.ink,
                tooltip: 'サイドバーを開閉',
                onTap: () => app.sidebarOpen.value = !app.sidebarOpen.value,
              ),
              const SizedBox(width: 8),
              Expanded(child: ThreadTitle(app: app)),
              EnginePill(app: app),
            ]),
          ),
          UpdateBanner(onOpen: () => app.openSettings(SettingsSection.update)),
          InterruptedBanner(app: app),
          Expanded(child: _pageBody(app)),
        ]),
      ),
    ]);
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: 280,
      color: c.nav,
      child: DefaultTextStyle(
        style: ts(context, 12, color: c.navText),
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 10),
            child: Row(children: [
              ArceIcon(ArceSvg.brand, size: 36, color: Colors.white),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('ARCE.AI', maxLines: 1, style: ts(context, 17, weight: FontWeight.w800, letterSpacing: .8, color: Colors.white)),
                  Text('Local AI Chat & Coding', maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(context, 10, color: c.navMuted)),
                ]),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: _SideButton(label: '新しい会話', svg: ArceSvg.plus, onTap: app.newConversation),
          ),
          Expanded(
            child: ListView(padding: const EdgeInsets.symmetric(horizontal: 10), children: [
              _NavGroup(
                title: 'チャット履歴',
                svg: ArceSvg.chat,
                initiallyOpen: true,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: HistoryPanel(app: app, onDark: true, recentLimit: 8),
                  ),
                  if (app.conversations.length > 8)
                    _NavItem(label: 'すべて表示', svg: ArceSvg.history, active: app.page == AppPage.history, onTap: () => app.goTo(AppPage.history)),
                ],
              ),
              _NavGroup(
                title: 'ローカルAIインストール',
                svg: ArceSvg.cube,
                initiallyOpen: true,
                children: [
                  _NavItem(label: 'モデル管理', svg: ArceSvg.cube, active: app.page == AppPage.models, onTap: () => app.goTo(AppPage.models)),
                ],
              ),
              _NavGroup(
                title: '生成物',
                svg: ArceSvg.gridNav,
                initiallyOpen: true,
                children: [
                  _NavItem(label: '生成物', svg: ArceSvg.file, active: app.page == AppPage.artifacts, onTap: () => app.goTo(AppPage.artifacts)),
                ],
              ),
              _NavGroup(
                title: '詳細設定',
                svg: ArceSvg.settings,
                initiallyOpen: true,
                children: [
                  _NavItem(label: 'オンラインモデル', svg: ArceSvg.globe, onTap: () => app.openSettings(SettingsSection.online)),
                  _NavItem(label: 'ローカルモデル', svg: ArceSvg.cube, onTap: () => app.openSettings(SettingsSection.local)),
                  _NavItem(label: '分担モード', svg: ArceSvg.codeEdit, onTap: () => app.openSettings(SettingsSection.coding)),
                  _NavItem(label: 'モデル全般設定', svg: ArceSvg.settings, onTap: () => app.openSettings(SettingsSection.basic)),
                  _NavItem(label: '検索設定', svg: ArceSvg.search, onTap: () => app.openSettings(SettingsSection.search)),
                  _NavItem(label: '表示・プライバシー', svg: ArceSvg.moon, onTap: () => app.openSettings(SettingsSection.display)),
                  _NavItem(label: '上限とタイムアウト', svg: ArceSvg.sliders2, onTap: () => app.openSettings(SettingsSection.limits)),
                  _NavItem(label: 'アップデート', svg: ArceSvg.retry, onTap: () => app.openSettings(SettingsSection.update)),
                ],
              ),
            ]),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 14),
            decoration: BoxDecoration(border: Border(top: BorderSide(color: Colors.white.withValues(alpha: .06)))),
            child: Column(children: [
              Row(children: [
                ArceIcon(ArceSvg.moon, size: 18, color: c.navMuted),
                const SizedBox(width: 10),
                Expanded(child: Text('ダークモード', style: ts(context, 12, color: c.navText))),
                ArceSwitch(
                  value: dark,
                  onChanged: (v) => app.settings.update((s) => s.copyWith(theme: v ? ThemeMode.dark : ThemeMode.light)),
                ),
              ]),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: ListenableBuilder(
                  listenable: app.updates,
                  builder: (context, _) => Text('ARCE.AI v${app.updates.currentVersion ?? '—'}', style: ts(context, 10, color: c.navMuted)),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// The phone's menu: a new conversation, the searchable history and the other pages. It opens
/// from the hamburger button at the top left.
class _MenuDrawer extends StatelessWidget {
  const _MenuDrawer({required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    void close() => Scaffold.of(context).closeDrawer();
    void go(AppPage page) {
      close();
      app.goTo(page);
    }

    return Drawer(
      backgroundColor: c.nav,
      child: SafeArea(
        child: DefaultTextStyle(
          style: ts(context, 12, color: c.navText),
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 10),
              child: Row(children: [
                ArceIcon(ArceSvg.brand, size: 32, color: Colors.white),
                const SizedBox(width: 10),
                Flexible(child: Text('ARCE.AI', maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(context, 16, weight: FontWeight.w800, letterSpacing: .8, color: Colors.white))),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: _SideButton(
                label: '新しい会話',
                svg: ArceSvg.plus,
                onTap: () {
                  close();
                  app.newConversation();
                },
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: HistoryPanel(app: app, onDark: true, scrollable: true, onOpen: close),
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(6, 6, 6, 8),
              decoration: BoxDecoration(border: Border(top: BorderSide(color: Colors.white.withValues(alpha: .06)))),
              child: Column(children: [
                _NavItem(label: 'モデル管理', svg: ArceSvg.cube, active: app.page == AppPage.models, onTap: () => go(AppPage.models)),
                _NavItem(label: '生成物', svg: ArceSvg.gridNav, active: app.page == AppPage.artifacts, onTap: () => go(AppPage.artifacts)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

class _SideButton extends StatelessWidget {
  const _SideButton({required this.label, required this.svg, required this.onTap});
  final String label;
  final String svg;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.white.withValues(alpha: .07),
        borderRadius: BorderRadius.circular(11),
        child: InkWell(
          borderRadius: BorderRadius.circular(11),
          onTap: onTap,
          child: Container(
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(children: [
              ArceIcon(svg, size: 17, color: Colors.white),
              const SizedBox(width: 9),
              Text(label, style: ts(context, 12, weight: FontWeight.w600, color: Colors.white)),
            ]),
          ),
        ),
      );
}

class _NavGroup extends StatefulWidget {
  const _NavGroup({required this.title, required this.svg, required this.children, this.initiallyOpen = false});
  final String title;
  final String svg;
  final List<Widget> children;
  final bool initiallyOpen;

  @override
  State<_NavGroup> createState() => _NavGroupState();
}

class _NavGroupState extends State<_NavGroup> {
  late bool _open = widget.initiallyOpen;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .03),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: .05)),
      ),
      child: Column(children: [
        InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            child: Row(children: [
              ArceIcon(widget.svg, size: 18, color: c.navText),
              const SizedBox(width: 10),
              Expanded(child: Text(widget.title, style: ts(context, 12, weight: FontWeight.w700, color: c.navText))),
              ArceIcon(_open ? ArceSvg.chevronUp : ArceSvg.chevronDown, size: 15, color: c.navMuted),
            ]),
          ),
        ),
        if (_open) Padding(padding: const EdgeInsets.only(bottom: 6), child: Column(children: widget.children)),
      ]),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({required this.label, required this.svg, required this.onTap, this.active = false});
  final String label;
  final String svg;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return InkWell(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 6),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          color: active ? const Color(0x2E737BF5) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(children: [
          ArceIcon(svg, size: 15, color: active ? const Color(0xFFB9BDFF) : c.navMuted),
          const SizedBox(width: 10),
          Expanded(
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(context, 11.5, color: active ? Colors.white : c.navText.withValues(alpha: .86))),
          ),
        ]),
      ),
    );
  }
}

/// Offered when the last session ended in the middle of a reply (spec §25.1).
class InterruptedBanner extends StatelessWidget {
  const InterruptedBanner({super.key, required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final item = app.interrupted;
    if (item == null) return const SizedBox.shrink();
    final c = context.c;
    return Container(
      width: double.infinity,
      color: c.amberSoft,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Text('前回の返信が途中で止まりました：「${item.title}」', style: ts(context, 11, weight: FontWeight.w600, color: c.amber)),
        SoftButton(label: '続きから', onTap: () => app.resolveInterrupted('resume')),
        SoftButton(label: '最初から', onTap: () => app.resolveInterrupted('regenerate')),
        SoftButton(label: '破棄', onTap: () => app.resolveInterrupted('discard')),
      ]),
    );
  }
}

class _Toast extends StatelessWidget {
  const _Toast({required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<String?>(
        valueListenable: app.toast,
        builder: (context, text, _) => IgnorePointer(
          child: AnimatedSlide(
            duration: const Duration(milliseconds: 200),
            offset: text == null ? const Offset(0, .4) : Offset.zero,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 200),
              opacity: text == null ? 0 : 1,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
                  decoration: BoxDecoration(
                    color: const Color(0xFF20222A),
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: const [BoxShadow(color: Color(0x42000000), blurRadius: 30, offset: Offset(0, 10))],
                  ),
                  child: Text(text ?? '', style: ts(context, 10, color: Colors.white)),
                ),
              ),
            ),
          ),
        ),
      );
}
