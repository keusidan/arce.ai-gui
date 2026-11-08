import 'package:arce_ai/services/settings.dart';
import 'package:arce_ai/ui/theme.dart';
import 'package:arce_ai/ui/thinking_icon.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> show(WidgetTester tester, ThinkingStyle style) => tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Scaffold(
            body: Center(child: SizedBox(width: 100, height: 60, child: Center(child: ThinkingIcon(style: style, size: 25, animate: false)))),
          ),
        ),
      );

  testWidgets('the styles with dots are one group in the middle of their box', (tester) async {
    for (final style in [ThinkingStyle.basic, ThinkingStyle.dots]) {
      await show(tester, style);
      final box = tester.getRect(find.byType(SizedBox).at(1));
      final icon = tester.getRect(find.byType(ThinkingIcon));
      expect(icon.center.dx, closeTo(box.center.dx, .5), reason: '${style.name}: the group is centred sideways');
      expect(icon.center.dy, closeTo(box.center.dy, .5), reason: '${style.name}: and up and down');
    }
  });

  testWidgets('the basic style is wider than its brain: the dots are inside the group', (tester) async {
    await show(tester, ThinkingStyle.basic);
    expect(tester.getSize(find.byType(ThinkingIcon)).width, greaterThan(25));
    await show(tester, ThinkingStyle.pulse);
    expect(tester.getSize(find.byType(ThinkingIcon)).width, 25);
  });
}
