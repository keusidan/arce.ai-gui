import 'package:arce_ai/app.dart';
import 'package:arce_ai/services/app_controller.dart';
import 'package:arce_ai/services/desktop_shell.dart';
import 'package:arce_ai/ui/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app_test.dart' show makeApp, setSize;

void main() {
  testWidgets('PC: the Linux group offers only "sandbox or not"; without it, the approval mode and the dangerous list', (tester) async {
    setSize(tester, const Size(1280, 2400));
    final app = await makeApp(tester);
    expect(app.desktopShell, isNotNull, reason: 'the tests run on a PC');
    await tester.pumpWidget(ArceApp(app: app));
    await tester.pump();
    app.openSettings(SettingsSection.shell);
    await tester.pumpAndSettle();

    expect(find.text('サンドボックス化する'), findsOneWidget);
    expect(find.text('Linux 環境（Ubuntu 24.04）'), findsNothing, reason: 'the Android environment is not offered on a PC');
    expect(find.text('コンテナ'), findsOneWidget, reason: 'sandboxed: the container');
    expect(find.text('実行前の確認'), findsNothing);

    await tester.tap(find.descendant(of: find.byKey(const ValueKey('desktop-sandbox')), matching: find.byType(ArceSwitch)));
    await tester.pumpAndSettle();
    expect(app.settings.value.desktopSandbox, isFalse);
    expect(find.text('実行前の確認'), findsOneWidget);
    expect(find.textContaining('自動（既定）'), findsOneWidget);
    expect(find.text('危険な操作の一覧'), findsOneWidget);
    expect(find.text('コンテナ'), findsNothing);
    expect(app.settings.value.desktopHostApproval, HostApproval.auto);
    await tester.pump(const Duration(seconds: 3));
  });
}
