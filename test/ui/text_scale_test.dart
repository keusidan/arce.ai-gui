import 'package:arce_ai/core/chat_controller.dart';
import 'package:arce_ai/core/prompt.dart';
import 'package:arce_ai/core/protocol.dart';
import 'package:arce_ai/app.dart';
import 'package:arce_ai/services/app_controller.dart';
import 'package:arce_ai/ui/svg_icons.dart';
import 'package:arce_ai/ui/theme.dart';
import 'package:arce_ai/ui/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app_test.dart' show makeApp, setSize;

/// Every screen at the text sizes a person can choose (settings → 表示 → 文字の大きさ) and at the widths of
/// a small phone, a phone and a desktop window: nothing may overflow, because a yellow-and-black stripe
/// (a RenderFlex overflow) is text that does not fit its box. Flutter reports an overflow as an exception
/// in a test, so "no exception" is the check.

const _sizes = [Size(360, 740), Size(411, 860), Size(1280, 800)];
const _scales = [1.0, 1.3, 1.5, 2.0];

/// What Flutter reported since the last call, as short lines ("overflow 25 px right @ lib/ui/x.dart:12");
/// empty when clean. The errors are collected from [FlutterError.onError] (see [_collecting]), because the
/// test binding folds several of them into one "Multiple exceptions" that does not say where.
final _errors = <String>[];

String _reported(WidgetTester tester) {
  tester.takeException(); // the binding's own copy: the details are in _errors
  final out = {..._errors}.toList();
  _errors.clear();
  return out.join('\n');
}

/// Runs [body] with every Flutter error written to [_errors] with where it came from.
Future<void> _collecting(Future<void> Function() body) async {
  final previous = FlutterError.onError;
  _errors.clear();
  FlutterError.onError = (details) {
    final text = details.toString();
    final overflow = RegExp(r'overflowed by ([\d.]+) pixels on the (\w+)')
        .firstMatch(text);
    final where = RegExp(r'file:///[^\s:]*?/((?:lib|test)/[^\s:]+):(\d+)')
        .firstMatch(text);
    final label = overflow == null
        ? details.exceptionAsString().split('\n').first
        : 'overflow ${overflow.group(1)} px ${overflow.group(2)}';
    _errors.add(
      '$label${where == null ? '' : ' @ ${where.group(1)}:${where.group(2)}'}',
    );
  };
  try {
    await body();
  } finally {
    FlutterError.onError = previous;
  }
}

Future<void> _look(
  WidgetTester tester,
  String where,
  List<String> problems,
) async {
  await tester.pump(const Duration(milliseconds: 400));
  final r = _reported(tester);
  if (r.isNotEmpty) {
    problems.add('$where:\n${r.split('\n').map((l) => '    $l').join('\n')}');
  }
}

const _longReply =
    'これは長い返信です。'
    'とても長い一行の文章がどこまでも続いて、画面の幅を超えたときに折り返されることを確かめます。'
    '```dart\nvoid main() { print("a very long line of code that does not fit the width of a small phone screen at all"); }\n```\n'
    '- 箇条書きの一行目はそれなりに長い文章にしておきます\n- 二行目\n\n| 名前 | 値 |\n|---|---|\n| とても長い名前の列 | 12345 |';

void main() {
  for (final size in _sizes) {
    for (final scale in _scales) {
      testWidgets(
        'nothing overflows at ${size.width.toInt()} px wide, text ${scale}x',
        (tester) async {
          setSize(tester, size);
          final app = await makeApp(tester);
          await app.settings.update((s) => s.copyWith(fontScale: scale));
          final problems = <String>[];
          await _collecting(() async {
            await tester.pumpWidget(ArceApp(app: app));
            await _look(tester, 'chat welcome', problems);

            // a conversation with a long reply, a question from the model and an approval card
            const call = McpCall('mcp_github__create_or_update_file', {
              'path': 'lib/some/very/long/path/to/a/file_name.dart',
              'content': 'x',
            });
            app.chat.restore(
              ConversationSnapshot(
                messages: [
                  const UiMessage(
                    id: 0,
                    role: Role.user,
                    text: 'とても長い質問です。これは画面の幅を超えて、折り返されるはずの文章です。',
                  ),
                  const UiMessage(
                    id: 1,
                    role: Role.assistant,
                    text: _longReply,
                  ),
                  const UiMessage(id: 2, role: Role.user, text: '続けて'),
                  UiMessage(
                    id: 3,
                    role: Role.assistant,
                    text: '確認します。',
                    question: const QuestionTile(
                      title: 'どの言語で作りますか？ とても長い質問の見出しで、折り返されます',
                      options: [
                        'Kotlin（Android 向け）',
                        'Java',
                        'Dart（Flutter）で作る長い選択肢',
                      ],
                      allowFreeInput: true,
                      multiSelect: false,
                    ),
                  ),
                ],
                history: const [
                  UserTurn('q'),
                  AssistantTurn('a'),
                  UserTurn('q2'),
                ],
                nextId: 4,
              ),
            );
            await _look(tester, 'chat long reply + question card', problems);

            app.chat.restore(
              ConversationSnapshot(
                messages: [
                  const UiMessage(id: 0, role: Role.user, text: '送って'),
                  UiMessage(
                    id: 1,
                    role: Role.assistant,
                    text: '',
                    question: ToolApproval.tile(call, rememberable: true),
                    tool: call,
                  ),
                ],
                history: const [UserTurn('q')],
                nextId: 2,
              ),
            );
            await _look(tester, 'approval card', problems);
            app.chat.clear();

            // the typed text, the token line, and a reply that is going on with a message queued behind it
            final field = find.byType(TextField);
            await tester.enterText(
              field.first,
              'こんにちは。とても長い文章を入力して、入力欄の中で折り返すか確かめます。',
            );
            await tester.pump(const Duration(milliseconds: 500));
            await _look(
              tester,
              'composer with text and the token line',
              problems,
            );
            final send = find.text('送信');
            if (send.evaluate().isNotEmpty) {
              await tester.tap(send.first);
              await tester.pump(const Duration(milliseconds: 60));
              await tester.enterText(field.first, 'もう一つ頼みたいことがあります');
              await tester.pump(const Duration(milliseconds: 20));
              if (app.chat.isRunning) {
                await _look(
                  tester,
                  'composer while it answers (割り込む・停止)',
                  problems,
                );
                final interject = find.text('割り込む');
                if (interject.evaluate().isNotEmpty) {
                  await tester.tap(interject.first);
                  await tester.pump(const Duration(milliseconds: 20));
                  await _look(tester, 'queued message chip', problems);
                }
              }
              for (var i = 0; i < 40 && app.chat.isRunning; i++) {
                await tester.pump(const Duration(milliseconds: 100));
              }
              _reported(tester);
            }

            // the other pages
            for (final page in [
              AppPage.models,
              AppPage.artifacts,
              AppPage.history,
              AppPage.settings,
            ]) {
              app.goTo(page);
              await _look(tester, 'page ${page.name}', problems);
            }

            // the settings landing grid, a search, and every group's own screen
            app.goTo(AppPage.settings);
            await tester.pump(const Duration(milliseconds: 200));
            final search = find.byKey(const ValueKey('settings-search'));
            if (search.evaluate().isNotEmpty) {
              await tester.enterText(search, 'トークン');
              await _look(tester, 'settings search results', problems);
              await tester.enterText(search, '');
              await tester.pump();
            }
            for (final section in SettingsSection.values) {
              app.openSettings(section);
              await _look(tester, 'settings ${section.name}', problems);
              final back = find.byKey(const ValueKey('settings-back'));
              if (back.evaluate().isNotEmpty) {
                await tester.tap(back);
                await tester.pump(const Duration(milliseconds: 100));
              }
            }

            // the phone's menu drawer
            if (size.width < 700) {
              app.goTo(AppPage.chat);
              await tester.pump();
              final menu = find.byTooltip('メニュー');
              if (menu.evaluate().isNotEmpty) {
                await tester.tap(menu.first);
                await _look(tester, 'menu drawer', problems);
              }
            }
          });
          expect(problems, isEmpty, reason: problems.join('\n'));
        },
      );
    }
  }

  group('a settings row', () {
    Future<void> pumpRow(WidgetTester tester, double scale, double width) async {
      tester.view.physicalSize = Size(width, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
          // in a list a row is as tall as it needs (not as tall as the screen): a scroll view says so
          home: Scaffold(
            body: SingleChildScrollView(
              child: SettingRow(
                icon: ArceSvg.clock,
                title: 'コマンドのタイムアウト',
                subtitle: 'モデルが時間を指定しなかったときに使う秒数。これは少し長い説明の文章です',
                trailing: Container(key: const ValueKey('control'), width: 90, height: 30, color: Colors.red),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('at the normal text size the control is beside the text, as before', (tester) async {
      await pumpRow(tester, 1.0, 411);
      final control = tester.getRect(find.byKey(const ValueKey('control')));
      final title = tester.getRect(find.text('コマンドのタイムアウト'));
      expect(control.left, greaterThan(title.right), reason: 'on the right of the title');
      final subtitle = tester.getRect(find.textContaining('モデルが時間を指定'));
      expect(control.center.dy, inInclusiveRange(title.top, subtitle.bottom), reason: 'in the same row, level with the text');
      expect(tester.takeException(), isNull);
    });

    testWidgets('at a large text size the control goes under the text, whole and inside the row, at the right', (tester) async {
      for (final scale in [1.5, 2.0]) {
        await pumpRow(tester, scale, 360);
        final control = tester.getRect(find.byKey(const ValueKey('control')));
        final subtitle = tester.getRect(find.textContaining('モデルが時間を指定'));
        expect(control.top, greaterThanOrEqualTo(subtitle.bottom), reason: 'below the text at $scale');
        expect(control.right, lessThanOrEqualTo(360), reason: 'inside the screen at $scale');
        expect(control.width, 90, reason: 'it did not have to shrink at $scale');
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('a control wider than the row shrinks to fit instead of overflowing', (tester) async {
      tester.view.physicalSize = const Size(360, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(2.0)), child: child!),
          home: Scaffold(
            body: SingleChildScrollView(
              child: SettingRow(
                icon: ArceSvg.clock,
                title: 'とても幅の広い操作',
                subtitle: '説明',
                trailing: Container(key: const ValueKey('wide'), width: 500, height: 30, color: Colors.red),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(tester.getRect(find.byKey(const ValueKey('wide'))).right, lessThanOrEqualTo(360));
    });
  });
}
