import 'package:flutter/material.dart';

import '../ai/provider_config.dart';
import '../ai/thinking_config.dart';
import '../services/app_controller.dart';
import 'theme.dart';
import 'thinking_sheet.dart';

/// The slider beside the chat's 思考 button: how much the model thinks, without opening the menu.
///
/// An online model whose request format names the levels: the steps are the menu's own (オフ・自動 and the
/// words the format knows: 低・中・高, or 低・高・最大), and the step is saved to the model's thinking
/// settings, the same ones the menu and 詳細 write. A model with no format chosen sends nothing, so there is
/// nothing to move: the slider is greyed out and a tap opens the menu, where the format is chosen. The device
/// model: the 速度⇔精度 slider (the fast end does not think), which is the setting the menu has too.
class ThinkingLevelSlider extends StatefulWidget {
  const ThinkingLevelSlider({super.key, required this.app});

  final AppController app;

  /// The width of the slider itself; the name of the step stands to its right.
  static const trackWidth = 84.0;

  @override
  State<ThinkingLevelSlider> createState() => _ThinkingLevelSliderState();
}

class _ThinkingLevelSliderState extends State<ThinkingLevelSlider> {
  /// The step or value under the thumb while it is dragged (the setting is written when it is let go).
  double? _drag;

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return ListenableBuilder(
      listenable: Listenable.merge([app.providers, app.settings]),
      builder: (context, _) {
        final provider = app.providers.active;
        final model = app.providers.activeModel;
        if (provider != null && model != null) return _online(context, provider, model);
        return _device(context);
      },
    );
  }

  Widget _device(BuildContext context) {
    final s = widget.app.settings.value;
    final value = (_drag ?? s.speedAccuracy).clamp(0.0, 1.0);
    final off = !s.thinking || value < 0.25;
    return _frame(
      context,
      slider: _slider(
        context,
        value: value,
        divisions: 20,
        onChanged: (v) => setState(() => _drag = v),
        onEnd: (v) {
          setState(() => _drag = null);
          widget.app.settings.update((x) => x.copyWith(speedAccuracy: v));
        },
      ),
      label: off ? 'オフ' : '${(value * 100).round()}%',
      tooltip: '速度⇔精度（左端付近では思考しません）',
    );
  }

  Widget _online(BuildContext context, ProviderConfig provider, ModelConfig model) {
    final thinking = model.thinking;
    final levels = ThinkingRequest.levelsFor(thinking.format);
    if (thinking.format == ThinkingFormat.none || levels.isEmpty) {
      return _frame(
        context,
        slider: _slider(context, value: 0, divisions: 1, onChanged: null, onEnd: null),
        label: '未設定',
        tooltip: 'このモデルには、思考の送り方がまだ決まっていません。押すと、決める画面を開きます',
        onTap: () => showThinkingSheet(context, widget.app),
      );
    }
    final steps = ['off', 'auto', ...levels];
    final picked = ThinkingRequest.choiceOf(thinking);
    // "on" (always on, the effort left to the other slider) and a number have no step of their own: the
    // thumb stands at 自動, and the name says what is set
    final index = steps.contains(picked) ? steps.indexOf(picked) : steps.indexOf('auto');
    final shown = _drag == null ? index : _drag!.round();
    final name = _drag == null && !steps.contains(picked) ? (picked == 'on' ? 'オン' : picked) : ThinkingSheet.levelLabel(steps[shown]);
    return _frame(
      context,
      slider: _slider(
        context,
        value: shown.toDouble(),
        max: (steps.length - 1).toDouble(),
        divisions: steps.length - 1,
        onChanged: (v) => setState(() => _drag = v),
        onEnd: (v) {
          setState(() => _drag = null);
          final choice = steps[v.round()];
          if (choice != picked) ThinkingSheet.saveThinking(widget.app, provider, model, ThinkingRequest.withChoice(thinking, choice));
        },
      ),
      label: name,
      tooltip: '考える量（オフ・自動・${levels.map(ThinkingSheet.levelLabel).join('・')}）',
    );
  }

  Slider _slider(
    BuildContext context, {
    required double value,
    double max = 1,
    required int divisions,
    required ValueChanged<double>? onChanged,
    required ValueChanged<double>? onEnd,
  }) =>
      Slider(value: value, max: max, divisions: divisions, onChanged: onChanged, onChangeEnd: onEnd);

  Widget _frame(BuildContext context, {required Slider slider, required String label, required String tooltip, VoidCallback? onTap}) {
    final c = context.c;
    final body = Row(mainAxisSize: MainAxisSize.min, children: [
      SizedBox(
        width: ThinkingLevelSlider.trackWidth,
        child: SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            tickMarkShape: const RoundSliderTickMarkShape(tickMarkRadius: 1.2),
          ),
          child: slider,
        ),
      ),
      ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 34),
        child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(context, 10.5, color: onTap == null ? c.accent : c.faint, weight: FontWeight.w700)),
      ),
    ]);
    return Tooltip(
      message: tooltip,
      child: onTap == null ? body : GestureDetector(behavior: HitTestBehavior.opaque, onTap: onTap, child: IgnorePointer(child: body)),
    );
  }
}
