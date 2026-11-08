import 'package:arce_ai/ai/thinking_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, Object?> fields(ThinkingConfig c, {bool thinking = true, double accuracy = 0.5}) =>
      ThinkingRequest.fields(c, appThinking: thinking, speedAccuracy: accuracy);

  test('送り方が「送らない」なら、何も足さない（提供元の既定で動く）', () {
    expect(fields(ThinkingConfig.none), isEmpty);
    expect(fields(const ThinkingConfig(mode: ThinkingMode.on, effort: 'max')), isEmpty, reason: 'no format, nothing is sent');
  });

  group('DeepSeek の API の形', () {
    const config = ThinkingConfig(format: ThinkingFormat.deepseekApi);

    test('チャットの思考がオンなら enabled と reasoning_effort、オフなら disabled だけ', () {
      expect(fields(config), {
        'thinking': {'type': 'enabled'},
        'reasoning_effort': 'high',
      });
      expect(fields(config, thinking: false), {
        'thinking': {'type': 'disabled'},
      });
    });

    test('「常にオン／オフ」はチャットのスイッチより強い', () {
      expect(fields(config.copyWith(mode: ThinkingMode.on), thinking: false)['thinking'], {'type': 'enabled'});
      expect(fields(config.copyWith(mode: ThinkingMode.off), thinking: true)['thinking'], {'type': 'disabled'});
    });

    test('推論の強さ：入れた値が先。数字は数字のまま（1〜100）。空欄は 速度⇔精度 から', () {
      expect(fields(config.copyWith(effort: 'max'))['reasoning_effort'], 'max');
      expect(fields(config.copyWith(effort: '75'))['reasoning_effort'], 75);
      expect(fields(config.copyWith(effort: '999'))['reasoning_effort'], 100, reason: 'kept inside 1–100');
      expect(fields(config.copyWith(effort: '0'))['reasoning_effort'], 1);
      expect(fields(config.copyWith(effort: ' HIGH '))['reasoning_effort'], 'high');
      expect(fields(config, accuracy: 0.3)['reasoning_effort'], 'low');
      expect(fields(config, accuracy: 0.6)['reasoning_effort'], 'high');
      expect(fields(config, accuracy: 0.9)['reasoning_effort'], 'max');
    });
  });

  group('GLM（Z.ai）の形', () {
    test('clear_thinking は、指定したときだけ thinking の中に入る', () {
      const base = ThinkingConfig(format: ThinkingFormat.zaiApi);
      expect(fields(base)['thinking'], {'type': 'enabled'});
      expect(fields(base.copyWith(clearThinking: true))['thinking'], {'type': 'enabled', 'clear_thinking': true});
      expect(fields(base.copyWith(clearThinking: false), thinking: false)['thinking'], {'type': 'disabled', 'clear_thinking': false});
      expect(fields(base, accuracy: 0.9)['reasoning_effort'], 'max', reason: 'GLM-5.3 accepts low / high / max');
    });
  });

  group('chat template のサーバーの形', () {
    test('テンプレートが読む名前（thinking・enable_thinking・thinking_mode）を並べる', () {
      const config = ThinkingConfig(format: ThinkingFormat.chatTemplate, clearThinking: true);
      final on = fields(config)['chat_template_kwargs']! as Map;
      expect(on['thinking'], isTrue);
      expect(on['enable_thinking'], isTrue);
      expect(on['thinking_mode'], 'thinking');
      expect(on['reasoning_effort'], 'high');
      expect(on['clear_thinking'], isTrue);

      final off = fields(config, thinking: false)['chat_template_kwargs']! as Map;
      expect(off['thinking'], isFalse);
      expect(off['thinking_mode'], 'chat');
      expect(off.containsKey('reasoning_effort'), isFalse, reason: 'no effort when it does not think');
    });
  });

  group('OpenAI の形', () {
    const config = ThinkingConfig(format: ThinkingFormat.openaiEffort);
    test('reasoning_effort だけ。max は OpenAI にないので high にする。オフは表せないので何も足さない', () {
      expect(fields(config), {'reasoning_effort': 'high'});
      expect(fields(config, accuracy: 0.95), {'reasoning_effort': 'high'});
      expect(fields(config, accuracy: 0.2), {'reasoning_effort': 'low'});
      expect(fields(config, thinking: false), isEmpty);
    });
  });

  test('おすすめの送り方は、名前の付き方から（Hub の名前は vLLM 系の提供元、素の名前はメーカーの API）', () {
    expect(ThinkingRequest.suggestedFormat('deepseek-ai/DeepSeek-V4.1-Flash-1017', deepseek: true, glm: false), ThinkingFormat.chatTemplate);
    expect(ThinkingRequest.suggestedFormat('deepseek-v4-flash', deepseek: true, glm: false), ThinkingFormat.deepseekApi);
    expect(ThinkingRequest.suggestedFormat('zai-org/GLM-5.3', deepseek: false, glm: true), ThinkingFormat.chatTemplate);
    expect(ThinkingRequest.suggestedFormat('glm-5.3', deepseek: false, glm: true), ThinkingFormat.zaiApi);
    expect(ThinkingRequest.suggestedFormat('gpt-4o', deepseek: false, glm: false), ThinkingFormat.none);
  });

  group('保存', () {
    test('書き出して読み戻せる。既定のものは何も書かない', () {
      const config = ThinkingConfig(mode: ThinkingMode.off, format: ThinkingFormat.zaiApi, effort: '75', clearThinking: false);
      final back = ThinkingConfig.fromJson(config.toJson());
      expect(back.mode, ThinkingMode.off);
      expect(back.format, ThinkingFormat.zaiApi);
      expect(back.effort, '75');
      expect(back.clearThinking, isFalse);
      expect(ThinkingConfig.none.toJson(), isEmpty);
      expect(ThinkingConfig.none.isDefault, isTrue);
    });

    test('壊れた値は既定に戻す', () {
      final damaged = ThinkingConfig.fromJson({'mode': 'maybe', 'format': 42, 'effort': 7, 'clearThinking': 'yes'});
      expect(damaged.isDefault, isTrue);
      expect(ThinkingConfig.fromJson('nope').isDefault, isTrue);
      expect(ThinkingConfig.fromJson(null).isDefault, isTrue);
    });

    test('過去の思考を返す設定：既定は自動で書き出さない。選べば往復できる', () {
      expect(ThinkingConfig.none.replay, ReasoningReplay.auto);
      expect(ThinkingConfig.none.toJson().containsKey('replay'), isFalse);
      const config = ThinkingConfig(replay: ReasoningReplay.always);
      expect(config.isDefault, isFalse);
      expect(ThinkingConfig.fromJson(config.toJson()).replay, ReasoningReplay.always);
      expect(ThinkingConfig.fromJson({'replay': 'sometimes'}).replay, ReasoningReplay.auto);
      expect(config.copyWith(effort: 'low').replay, ReasoningReplay.always);
    });

    test('copyWith は、clearThinking を null に戻せる', () {
      const config = ThinkingConfig(clearThinking: true);
      expect(config.copyWith(effort: 'low').clearThinking, isTrue);
      expect(config.copyWith(clearThinking: null).clearThinking, isNull);
    });
  });

  group('OpenRouter の形（ルーターが真似する形も）', () {
    const config = ThinkingConfig(format: ThinkingFormat.openRouter);

    test('オンなら reasoning の effort（low / medium / high）、オフなら enabled: false', () {
      expect(fields(config, accuracy: 0.2), {
        'reasoning': {'effort': 'low'},
      });
      expect(fields(config, accuracy: 0.6), {
        'reasoning': {'effort': 'high'},
      });
      expect(fields(config.copyWith(effort: 'medium')), {
        'reasoning': {'effort': 'medium'},
      });
      expect(fields(config, thinking: false), {
        'reasoning': {'enabled': false},
      });
    });

    test('max は high に、数字は三つに分けて low / medium / high にする', () {
      expect(fields(config.copyWith(effort: 'max')), {
        'reasoning': {'effort': 'high'},
      });
      expect(fields(config.copyWith(effort: '20')), {
        'reasoning': {'effort': 'low'},
      });
      expect(fields(config.copyWith(effort: '50')), {
        'reasoning': {'effort': 'medium'},
      });
      expect(fields(config.copyWith(effort: '90')), {
        'reasoning': {'effort': 'high'},
      });
    });
  });

  group('提供元のアドレスから、おすすめの送り方', () {
    test('作った会社自身の API と、ルーターは分かる。分からないアドレスは null', () {
      expect(ThinkingRequest.suggestedFormatForHost('https://openrouter.ai/api/v1'), ThinkingFormat.openRouter);
      expect(ThinkingRequest.suggestedFormatForHost('https://api.deepseek.com/v1'), ThinkingFormat.deepseekApi);
      expect(ThinkingRequest.suggestedFormatForHost('https://api.z.ai/api/paas/v4'), ThinkingFormat.zaiApi);
      expect(ThinkingRequest.suggestedFormatForHost('https://api.openai.com/v1'), ThinkingFormat.openaiEffort);
      expect(ThinkingRequest.suggestedFormatForHost('https://api.deepinfra.com/v1/openai'), ThinkingFormat.chatTemplate);
      expect(ThinkingRequest.suggestedFormatForHost('https://orca.example/v1'), isNull);
      expect(ThinkingRequest.suggestedFormatForHost('not a url'), isNull);
    });

    test('メニューの選びは、モードと強さに戻せる', () {
      const base = ThinkingConfig(format: ThinkingFormat.deepseekApi);
      expect(ThinkingRequest.choiceOf(base), 'auto');
      final high = ThinkingRequest.withChoice(base, 'high');
      expect((high.mode, high.effort), (ThinkingMode.on, 'high'));
      expect(ThinkingRequest.choiceOf(high), 'high');
      final off = ThinkingRequest.withChoice(high, 'off');
      expect(off.mode, ThinkingMode.off);
      expect(ThinkingRequest.choiceOf(off), 'off');
      final auto = ThinkingRequest.withChoice(off, 'auto');
      expect((auto.mode, auto.effort), (ThinkingMode.auto, ''));
      expect(ThinkingRequest.choiceOf(const ThinkingConfig(mode: ThinkingMode.on)), 'on');
    });

    test('送り方を変えると、新しい形が知らない強さは外れる', () {
      const medium = ThinkingConfig(format: ThinkingFormat.openRouter, mode: ThinkingMode.on, effort: 'medium');
      final moved = ThinkingRequest.withFormat(medium, ThinkingFormat.deepseekApi);
      expect(moved.format, ThinkingFormat.deepseekApi);
      expect(moved.effort, isEmpty, reason: 'DeepSeek names low / high / max only');
      expect(moved.mode, ThinkingMode.auto);
      final kept = ThinkingRequest.withFormat(medium, ThinkingFormat.openaiEffort);
      expect((kept.effort, kept.mode), ('medium', ThinkingMode.on));
      expect(ThinkingRequest.withFormat(const ThinkingConfig(effort: '70'), ThinkingFormat.deepseekApi).effort, '70');
    });

    test('メニューに出す強さは、その形が書いている言葉だけ', () {
      expect(ThinkingRequest.levelsFor(ThinkingFormat.deepseekApi), ['low', 'high', 'max']);
      expect(ThinkingRequest.levelsFor(ThinkingFormat.openRouter), ['low', 'medium', 'high']);
      expect(ThinkingRequest.levelsFor(ThinkingFormat.none), isEmpty);
    });
  });
}
