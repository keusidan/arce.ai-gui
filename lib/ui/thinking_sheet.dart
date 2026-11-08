import 'package:flutter/material.dart';

import '../ai/model_hints.dart';
import '../ai/provider_config.dart';
import '../ai/thinking_config.dart';
import '../services/app_controller.dart';
import '../services/settings.dart';
import 'model_detail_page.dart';
import 'svg_icons.dart';
import 'theme.dart';
import 'widgets.dart';

/// The menu of the chat's 思考 button: how much the model thinks, and how the thinking is shown.
///
/// An online model: off / auto / the effort words its request format names, and the format itself
/// (nothing is sent until one is chosen). The device model: the 思考 switch and the 速度⇔精度 slider.
/// The choices are written to the model's own settings, the same ones as in 詳細.
Future<void> showThinkingSheet(BuildContext context, AppController app) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: context.c.surface,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
    builder: (context) => ThinkingSheet(app: app),
  );
}

class ThinkingSheet extends StatelessWidget {
  const ThinkingSheet({super.key, required this.app});

  final AppController app;

  static String formatLabel(ThinkingFormat format) => switch (format) {
        ThinkingFormat.none => '送らない',
        ThinkingFormat.deepseekApi => 'DeepSeek API',
        ThinkingFormat.zaiApi => 'Z.ai API',
        ThinkingFormat.chatTemplate => 'chat template',
        ThinkingFormat.openaiEffort => 'OpenAI',
        ThinkingFormat.openRouter => 'OpenRouter',
      };

  static String levelLabel(String choice) => switch (choice) {
        'off' => 'オフ',
        'auto' => '自動',
        'on' => 'オン',
        'low' => '低',
        'medium' => '中',
        'high' => '高',
        'max' => '最大',
        _ => choice,
      };

  /// Saves [thinking] as the thinking settings of the model in use.
  Future<void> _save(ProviderConfig provider, ModelConfig model, ThinkingConfig thinking) => saveThinking(app, provider, model, thinking);

  /// Saves [thinking] as the thinking settings of [model] of [provider] (the sheet and the chat's slider both do).
  static Future<void> saveThinking(AppController app, ProviderConfig provider, ModelConfig model, ThinkingConfig thinking) {
    return app.providers.save(provider.copyWith(models: [for (final m in provider.models) m.id == model.id ? m.copyWith(thinking: thinking) : m]));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return ListenableBuilder(
      listenable: Listenable.merge([app.providers, app.settings]),
      builder: (context, _) {
        final s = app.settings.value;
        final provider = app.providers.active;
        final model = app.providers.activeModel;
        final cloud = provider != null && model != null;
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(18, 16, 18, sheetBottomPadding(context)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              ArceIcon(ArceSvg.brainLabel, size: 17, color: c.accent),
              const SizedBox(width: 8),
              Expanded(child: Text('思考', style: ts(context, 14, weight: FontWeight.w700))),
            ]),
            const SizedBox(height: 2),
            Text(cloud ? '${provider.label.isEmpty ? provider.id : provider.label} · ${model.id}' : 'ローカルモデル', style: ts(context, 10, color: c.muted)),
            const SizedBox(height: 14),
            if (cloud) ..._online(context, provider, model) else ..._local(context, s),
            const SizedBox(height: 6),
            SettingRow(
              icon: ArceSvg.brainOutline,
              title: '思考の内容を開いたまま表示',
              subtitle: '返信の上に、考えた内容を出します',
              last: true,
              trailing: ArceSwitch(value: s.thinkingExpanded, onChanged: (v) => app.settings.update((x) => x.copyWith(thinkingExpanded: v))),
            ),
            if (cloud) ...[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: SoftButton(
                  label: 'モデルの詳細設定',
                  svg: ArceSvg.sliders2,
                  onTap: () {
                    final navigator = Navigator.of(context);
                    navigator.pop();
                    navigator.push(MaterialPageRoute<void>(builder: (_) => ModelDetailPage(app: app)));
                  },
                ),
              ),
            ],
          ]),
        );
      },
    );
  }

  List<Widget> _local(BuildContext context, AppSettings s) {
    final c = context.c;
    return [
      SettingRow(
        icon: ArceSvg.brainLabel,
        title: '思考する',
        subtitle: '速度⇔精度が左端に近いと、オンでも思考しません',
        trailing: ArceSwitch(value: s.thinking, onChanged: (v) => app.settings.update((x) => x.copyWith(thinking: v))),
      ),
      const SizedBox(height: 10),
      Row(children: [
        Text('速度', style: ts(context, 10, color: c.muted)),
        Expanded(
          child: Slider(
            value: s.speedAccuracy.clamp(0.0, 1.0),
            divisions: 20,
            onChanged: (v) => app.settings.update((x) => x.copyWith(speedAccuracy: v)),
          ),
        ),
        Text('精度', style: ts(context, 10, color: c.muted)),
      ]),
      Text(
        '精度に寄せるほど長く考え、返信も長く書けます。左端付近（25%未満）では思考をオフにします。',
        style: ts(context, 9.5, color: c.muted, height: 1.5),
      ),
    ];
  }

  List<Widget> _online(BuildContext context, ProviderConfig provider, ModelConfig model) {
    final c = context.c;
    final thinking = model.thinking;
    final sent = thinking.format != ThinkingFormat.none;
    final picked = ThinkingRequest.choiceOf(thinking);
    final family = ModelHints.familyOf(model.id);
    final suggestion = ThinkingRequest.suggestedFormatForHost(provider.baseUrl) ??
        ThinkingRequest.suggestedFormat(model.id, deepseek: family == ModelFamily.deepseek, glm: family == ModelFamily.glm);
    final choices = ['off', 'auto', ...ThinkingRequest.levelsFor(thinking.format)];
    return [
      Text('考える量', style: ts(context, 11, weight: FontWeight.w700)),
      const SizedBox(height: 6),
      if (sent) ...[
        Wrap(spacing: 7, runSpacing: 7, children: [
          for (final choice in choices)
            _Pick(label: levelLabel(choice), selected: picked == choice, onTap: () => _save(provider, model, ThinkingRequest.withChoice(thinking, choice))),
          if (!choices.contains(picked) && picked != 'on') _Pick(label: levelLabel(picked), selected: true, onTap: () {}),
        ]),
        const SizedBox(height: 4),
        Text(
          picked == 'auto' || picked == 'on' ? '「自動」は、チャットの思考スイッチと速度⇔精度に従います。' : '選んだ量を、チャットの思考スイッチより優先して送ります。',
          style: ts(context, 9.5, color: c.muted, height: 1.5),
        ),
      ] else
        Text(
          'このモデルには、思考の送り方がまだ決まっていません。決めるまでは、提供元の既定で動き、ここでの量は届きません。',
          style: ts(context, 10, color: c.amber, height: 1.55),
        ),
      const SizedBox(height: 14),
      Text('送り方', style: ts(context, 11, weight: FontWeight.w700)),
      const SizedBox(height: 6),
      Wrap(spacing: 7, runSpacing: 7, children: [
        for (final format in ThinkingFormat.values)
          _Pick(label: formatLabel(format), selected: thinking.format == format, onTap: () => _save(provider, model, ThinkingRequest.withFormat(thinking, format))),
      ]),
      if (!sent && suggestion != ThinkingFormat.none) ...[
        const SizedBox(height: 8),
        SoftButton(
          label: '「${formatLabel(suggestion)}」にする（この提供元・モデル名からの推測）',
          svg: ArceSvg.brainLabel,
          onTap: () => _save(provider, model, ThinkingRequest.withFormat(thinking, suggestion)),
        ),
        const SizedBox(height: 4),
        Text('推測です。提供元のドキュメントで、項目の名前を確かめてください。', style: ts(context, 9.5, color: c.muted, height: 1.5)),
      ],
    ];
  }
}

class _Pick extends StatelessWidget {
  const _Pick({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Material(
      color: selected ? c.accentSoft : c.surface2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: selected ? c.accent : c.line)),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Text(label, style: ts(context, 12, color: selected ? c.accent : c.ink, weight: selected ? FontWeight.w700 : FontWeight.w500)),
        ),
      ),
    );
  }
}
