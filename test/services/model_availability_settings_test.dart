import 'package:arce_ai/core/settings_spec.dart';
import 'package:arce_ai/services/settings.dart';
import 'package:flutter_test/flutter_test.dart';

const keys = [
  'hideUnusableModels',
  'markBlockedModels',
  'modelProbeConcurrency',
  'modelProbeTimeoutSeconds',
  'modelAvailabilityTrustDays',
];

void main() {
  test('the defaults: show unusable models greyed (not hidden), mark them, three at a time, 30 seconds, a week', () {
    const d = AppSettings();
    expect(d.hideUnusableModels, isFalse);
    expect(d.markBlockedModels, isTrue);
    expect(d.modelProbeConcurrency, 3);
    expect(d.modelProbeTimeoutSeconds, 30);
    expect(d.modelAvailabilityTrustDays, 7);
  });

  test('they are saved and read back, and an older save without them gets the defaults', () {
    const changed = AppSettings(
      hideUnusableModels: true,
      markBlockedModels: false,
      modelProbeConcurrency: 5,
      modelProbeTimeoutSeconds: 60,
      modelAvailabilityTrustDays: 14,
    );
    final saved = changed.toJson();
    for (final key in keys) {
      expect(saved.containsKey(key), isTrue, reason: key);
    }
    final back = AppSettings.fromJson(saved);
    expect((back.hideUnusableModels, back.markBlockedModels, back.modelProbeConcurrency, back.modelProbeTimeoutSeconds, back.modelAvailabilityTrustDays), (true, false, 5, 60, 14));
    final old = AppSettings.fromJson(const {});
    expect((old.hideUnusableModels, old.markBlockedModels, old.modelProbeConcurrency), (false, true, 3));
  });

  test('the numbers stay inside their ranges, whatever a file says', () {
    final low = AppSettings.fromJson(const {'modelProbeConcurrency': 0, 'modelProbeTimeoutSeconds': 0, 'modelAvailabilityTrustDays': 0});
    expect((low.modelProbeConcurrency, low.modelProbeTimeoutSeconds, low.modelAvailabilityTrustDays), (1, 5, 1));
    final high = AppSettings.fromJson(const {'modelProbeConcurrency': 999, 'modelProbeTimeoutSeconds': 99999, 'modelAvailabilityTrustDays': 99999});
    expect((high.modelProbeConcurrency, high.modelProbeTimeoutSeconds, high.modelAvailabilityTrustDays), (8, 120, 90));
    final wrongType = AppSettings.fromJson(const {'hideUnusableModels': 'yes', 'modelProbeConcurrency': 'many'});
    expect((wrongType.hideUnusableModels, wrongType.modelProbeConcurrency), (false, 3));
  });

  test('they can be changed from the chat (nothing here sends a key anywhere: only which models are listed and how fast they are asked)', () {
    for (final key in keys) {
      expect(AgentSettings.isEditable(key), isTrue, reason: key);
      expect(AgentSettings.blocked, isNot(contains(key)));
    }
  });

  test('a change from the chat is read the way the settings screen writes it', () {
    final spec = AgentSettings.specs['modelProbeConcurrency']!;
    expect(spec.kind, SettingKind.whole);
    expect((spec.min, spec.max), (1, 8));
    final days = AgentSettings.specs['modelAvailabilityTrustDays']!;
    expect((days.min, days.max), (1, 90));
    expect(AgentSettings.specs['hideUnusableModels']!.kind, SettingKind.flag);
    expect(AgentSettings.specs['markBlockedModels']!.kind, SettingKind.flag);
  });
}
