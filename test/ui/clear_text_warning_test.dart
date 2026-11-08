import 'package:arce_ai/ui/theme.dart';
import 'package:arce_ai/ui/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> pump(WidgetTester tester, String url) => tester.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(body: ClearTextWarning(url: url, what: 'APIキー')),
    ));

void main() {
  testWidgets('an address that would send the key in the clear gets a warning', (tester) async {
    await pump(tester, 'http://api.example.com/v1');
    expect(find.byKey(const ValueKey('clear-text-warning')), findsOneWidget);
    expect(find.textContaining('APIキーが、途中の通信'), findsOneWidget);
    expect(find.textContaining('https にしてください'), findsOneWidget);
  });

  testWidgets('https, the home network and an empty field get nothing', (tester) async {
    for (final url in ['https://api.openai.com/v1', 'http://192.168.0.10:11434/v1', 'http://localhost:8080', '']) {
      await pump(tester, url);
      expect(find.byKey(const ValueKey('clear-text-warning')), findsNothing, reason: url);
    }
  });
}
