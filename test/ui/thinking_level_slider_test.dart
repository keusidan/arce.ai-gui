import 'package:arce_ai/ai/provider_config.dart';
import 'package:arce_ai/ai/thinking_config.dart';
import 'package:arce_ai/app.dart';
import 'package:arce_ai/ui/thinking_level_slider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app_test.dart' show makeApp, setSize;

ProviderConfig provider(ThinkingFormat format, {ThinkingMode mode = ThinkingMode.auto, String effort = ''}) => ProviderConfig(
      id: 'gem',
      label: 'Gemini',
      baseUrl: 'https://gemini.example/v1beta/openai',
      models: [ModelConfig(id: 'gemini-3.5-flash', name: 'flash', thinking: ThinkingConfig(format: format, mode: mode, effort: effort))],
    );

/// The slider beside the chat's 思考 button: how much the model thinks, without the menu.
void main() {
  Future<void> open(WidgetTester tester, dynamic app) async {
    await tester.pumpWidget(ArceApp(app: app));
    await tester.pump();
  }

  /// Moves the thumb to the middle of step [step] of [steps] and lets go.
  Future<void> dragTo(WidgetTester tester, int step, int steps) async {
    final box = tester.getRect(find.descendant(of: find.byType(ThinkingLevelSlider), matching: find.byType(Slider)));
    // the track is inset by the thumb's overlay, so the ends of the track are a little inside the box
    const inset = 14.0;
    final width = box.width - 2 * inset;
    final x = box.left + inset + width * step / (steps - 1);
    await tester.tapAt(Offset(x, box.center.dy));
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('an online model whose format names the levels: the steps are オフ・自動 and the levels; the one picked is saved to the model', (tester) async {
    setSize(tester, const Size(411, 860));
    final app = await makeApp(tester);
    await app.providers.save(provider(ThinkingFormat.openaiEffort));
    await app.providers.setActive('gem');
    await open(tester, app);

    expect(find.byType(ThinkingLevelSlider), findsOneWidget);
    expect(find.descendant(of: find.byType(ThinkingLevelSlider), matching: find.text('自動')), findsOneWidget, reason: 'nothing picked yet');
    final slider = tester.widget<Slider>(find.descendant(of: find.byType(ThinkingLevelSlider), matching: find.byType(Slider)));
    expect(slider.divisions, 4, reason: 'オフ・自動・低・中・高');

    // 高 is the last step
    await dragTo(tester, 4, 5);
    var saved = app.providers.byId('gem')!.models.single.thinking;
    expect((saved.mode, saved.effort), (ThinkingMode.on, 'high'));
    expect(find.descendant(of: find.byType(ThinkingLevelSlider), matching: find.text('高')), findsOneWidget);

    // オフ is the first
    await dragTo(tester, 0, 5);
    saved = app.providers.byId('gem')!.models.single.thinking;
    expect(saved.mode, ThinkingMode.off);
    expect(find.descendant(of: find.byType(ThinkingLevelSlider), matching: find.text('オフ')), findsOneWidget);

    // 自動 clears the effort again
    await dragTo(tester, 1, 5);
    saved = app.providers.byId('gem')!.models.single.thinking;
    expect((saved.mode, saved.effort), (ThinkingMode.auto, ''));
  });

  testWidgets('DeepSeek and Z.ai name 低・高・最大, not 中', (tester) async {
    setSize(tester, const Size(411, 860));
    final app = await makeApp(tester);
    await app.providers.save(provider(ThinkingFormat.deepseekApi, mode: ThinkingMode.on, effort: 'max'));
    await app.providers.setActive('gem');
    await open(tester, app);
    final slider = tester.widget<Slider>(find.descendant(of: find.byType(ThinkingLevelSlider), matching: find.byType(Slider)));
    expect(slider.divisions, 4, reason: 'オフ・自動・低・高・最大');
    expect(slider.value, 4, reason: 'max is the last step');
    expect(find.descendant(of: find.byType(ThinkingLevelSlider), matching: find.text('最大')), findsOneWidget);
  });

  testWidgets('a model with no format sends nothing: the slider is greyed out and a tap opens the menu', (tester) async {
    setSize(tester, const Size(411, 860));
    final app = await makeApp(tester);
    await app.providers.save(provider(ThinkingFormat.none));
    await app.providers.setActive('gem');
    await open(tester, app);

    final slider = tester.widget<Slider>(find.descendant(of: find.byType(ThinkingLevelSlider), matching: find.byType(Slider)));
    expect(slider.onChanged, isNull, reason: 'nothing to move');
    expect(find.text('未設定'), findsOneWidget);
    await tester.tap(find.byType(ThinkingLevelSlider));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('考える量'), findsOneWidget, reason: 'the menu, where the format is chosen');
    expect(app.providers.byId('gem')!.models.single.thinking.format, ThinkingFormat.none);
  });

  testWidgets('the device model: the slider is 速度⇔精度, and the fast end says オフ', (tester) async {
    setSize(tester, const Size(411, 860));
    final app = await makeApp(tester);
    await open(tester, app);

    expect(app.providers.active, isNull, reason: 'no online model: the device model answers');
    expect(find.text('50%'), findsOneWidget, reason: 'the default 0.5');
    await dragTo(tester, 20, 21);
    expect(app.settings.value.speedAccuracy, closeTo(1.0, 0.001));
    expect(find.text('100%'), findsOneWidget);
    await dragTo(tester, 2, 21);
    expect(app.settings.value.speedAccuracy, closeTo(0.1, 0.001));
    expect(find.descendant(of: find.byType(ThinkingLevelSlider), matching: find.text('オフ')), findsOneWidget, reason: 'below 25% the device model does not think');
  });
}
