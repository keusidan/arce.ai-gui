import 'package:flutter_test/flutter_test.dart';

import 'package:arce_ai/core/settings_spec.dart';

void main() {
  group('変更してよい項目', () {
    test('ふだんの設定は変更できる', () {
      for (final key in ['thinking', 'searchEnabled', 'tone', 'theme', 'maxTokens', 'gpuOffload']) {
        expect(AgentSettings.isEditable(key), isTrue, reason: key);
      }
    });

    test('更新元・読み込み済みモデル・KVキャッシュは変更できない', () {
      for (final key in ['updateRepo', 'lastModelPath', 'kvCache']) {
        expect(AgentSettings.isEditable(key), isFalse, reason: key);
        final result = AgentSettings.normalize(key, 'x');
        expect(result, isA<SettingsChangeInvalid>(), reason: key);
        expect((result as SettingsChangeInvalid).reason, contains('チャットからは変更できません'));
      }
    });

    test('トークンのような設定は存在しないものとして扱う', () {
      for (final key in ['githubToken', 'apiKey', 'openaiKey']) {
        final result = AgentSettings.normalize(key, 'secret');
        expect(result, isA<SettingsChangeInvalid>(), reason: key);
        expect((result as SettingsChangeInvalid).reason, contains('という設定はありません'));
      }
    });

    test('キー一覧は並びが安定している', () {
      expect(AgentSettings.keys, [...AgentSettings.keys]..sort());
      expect(AgentSettings.keys, contains('thinking'));
    });
  });

  group('真偽値', () {
    test('bool を受け付ける', () {
      final ok = AgentSettings.normalize('thinking', false) as SettingsChangeOk;
      expect(ok.value, isFalse);
      expect(ok.key, 'thinking');
    });

    test('文字列の true / false も受け付ける', () {
      expect((AgentSettings.normalize('searchEnabled', 'true') as SettingsChangeOk).value, isTrue);
      expect((AgentSettings.normalize('searchEnabled', ' False ') as SettingsChangeOk).value, isFalse);
    });

    test('それ以外は拒否する', () {
      final result = AgentSettings.normalize('thinking', 'yes');
      expect(result, isA<SettingsChangeInvalid>());
      expect((result as SettingsChangeInvalid).reason, contains('true'));
    });
  });

  group('整数', () {
    test('数値と数字の文字列を受け付ける', () {
      expect((AgentSettings.normalize('maxTokens', 4096) as SettingsChangeOk).value, 4096);
      expect((AgentSettings.normalize('maxTokens', '4096') as SettingsChangeOk).value, 4096);
    });

    test('範囲の外は拒否する', () {
      expect(AgentSettings.normalize('maxTokens', 100), isA<SettingsChangeInvalid>());
      expect(AgentSettings.normalize('maxTokens', 999999), isA<SettingsChangeOk>(), reason: 'a 256K reply is normal for a reasoning model now');
      expect(AgentSettings.normalize('maxTokens', 2000000), isA<SettingsChangeInvalid>());
      expect(AgentSettings.normalize('threads', -1), isA<SettingsChangeInvalid>());
    });

    test('小数は拒否する', () {
      final result = AgentSettings.normalize('maxTokens', 100.5);
      expect(result, isA<SettingsChangeInvalid>());
      expect((result as SettingsChangeInvalid).reason, contains('整数'));
    });

    test('数値でないものは拒否する', () {
      expect(AgentSettings.normalize('maxTokens', 'たくさん'), isA<SettingsChangeInvalid>());
      expect(AgentSettings.normalize('maxTokens', null), isA<SettingsChangeInvalid>());
    });
  });

  group('小数', () {
    test('0〜1 を受け付ける', () {
      expect((AgentSettings.normalize('speedAccuracy', 0.25) as SettingsChangeOk).value, 0.25);
      expect((AgentSettings.normalize('speedAccuracy', '1') as SettingsChangeOk).value, 1.0);
    });

    test('範囲の外は拒否する', () {
      expect(AgentSettings.normalize('speedAccuracy', 1.5), isA<SettingsChangeInvalid>());
      expect(AgentSettings.normalize('speedAccuracy', -0.1), isA<SettingsChangeInvalid>());
    });
  });

  group('選択肢', () {
    test('決められた名前だけ受け付ける', () {
      expect((AgentSettings.normalize('theme', 'dark') as SettingsChangeOk).value, 'dark');
      expect((AgentSettings.normalize('gpuOffload', 'cpuOnly') as SettingsChangeOk).value, 'cpuOnly');
    });

    test('知らない名前は拒否し、候補を示す', () {
      final result = AgentSettings.normalize('theme', 'midnight');
      expect(result, isA<SettingsChangeInvalid>());
      expect((result as SettingsChangeInvalid).reason, contains('system / light / dark'));
    });

    test('大文字小文字は区別する（保存値と一致させるため）', () {
      expect(AgentSettings.normalize('theme', 'Dark'), isA<SettingsChangeInvalid>());
    });
  });

  group('文字列', () {
    test('前後の空白を落とす', () {
      expect((AgentSettings.normalize('tone', '  丁寧に  ') as SettingsChangeOk).value, '丁寧に');
    });

    test('長すぎるものは拒否する', () {
      expect(AgentSettings.normalize('tone', 'あ' * 201), isA<SettingsChangeInvalid>());
      expect(AgentSettings.normalize('tone', 'あ' * 200), isA<SettingsChangeOk>());
    });

    test('文字列でないものは拒否する', () {
      expect(AgentSettings.normalize('tone', 42), isA<SettingsChangeInvalid>());
    });

    test('空文字は許可（口調の解除など）', () {
      expect((AgentSettings.normalize('tone', '') as SettingsChangeOk).value, '');
    });
  });

  group('URL', () {
    test('空は許可（検索サーバーを使わない）', () {
      expect((AgentSettings.normalize('searxngUrl', '') as SettingsChangeOk).value, '');
    });

    test('http と https を受け付ける', () {
      expect(
        (AgentSettings.normalize('searxngUrl', 'https://searx.example.com') as SettingsChangeOk).value,
        'https://searx.example.com',
      );
      expect(
        (AgentSettings.normalize('searxngUrl', 'http://192.168.1.10:8888') as SettingsChangeOk).value,
        'http://192.168.1.10:8888',
      );
    });

    test('スキームやホストが無いものは拒否する', () {
      expect(AgentSettings.normalize('searxngUrl', 'ftp://example.com'), isA<SettingsChangeInvalid>());
      expect(AgentSettings.normalize('searxngUrl', 'example.com'), isA<SettingsChangeInvalid>());
    });
  });

  group('まとめて読む', () {
    test('複数の変更を読める', () {
      final patch = AgentSettings.parse({
        'changes': [
          {'key': 'thinking', 'value': false},
          {'key': 'maxTokens', 'value': 4096},
        ],
      }) as SettingsPatch;

      expect(patch.changes, hasLength(2));
      expect(patch.changes.map((c) => c.key), ['thinking', 'maxTokens']);
    });

    test('同じキーは最後の値だけ残る', () {
      final patch = AgentSettings.parse({
        'changes': [
          {'key': 'tone', 'value': '短く'},
          {'key': 'tone', 'value': '丁寧に'},
        ],
      }) as SettingsPatch;

      expect(patch.changes, hasLength(1));
      expect(patch.changes.single.value, '丁寧に');
    });

    test('空・多すぎる・形が違うものは拒否する', () {
      expect(AgentSettings.parse({'changes': <Object?>[]}), isA<SettingsPatchInvalid>());
      expect(
        AgentSettings.parse({
          'changes': [for (var i = 0; i < 7; i++) {'key': 'maxChars', 'value': i}],
        }),
        isA<SettingsPatchInvalid>(),
      );
      expect(AgentSettings.parse({'changes': 'x'}), isA<SettingsPatchInvalid>());
      expect(AgentSettings.parse(null), isA<SettingsPatchInvalid>());
      expect(AgentSettings.parse({'changes': ['x']}), isA<SettingsPatchInvalid>());
      expect(AgentSettings.parse({'changes': [{'value': 1}]}), isA<SettingsPatchInvalid>());
    });

    test('1つでも不正なら全体を拒否する（半分だけ適用しない）', () {
      final result = AgentSettings.parse({
        'changes': [
          {'key': 'thinking', 'value': false},
          {'key': 'updateRepo', 'value': 'evil/repo'},
        ],
      });
      expect(result, isA<SettingsPatchInvalid>());
    });
  });

  group('承認カード用の文言', () {
    test('真偽値はオン・オフ', () {
      expect(AgentSettings.specs['thinking']!.format(true), 'オン');
      expect(AgentSettings.specs['thinking']!.format(false), 'オフ');
    });

    test('選択肢は日本語のラベル', () {
      expect(AgentSettings.specs['theme']!.format('dark'), 'ダーク');
      expect(AgentSettings.specs['gpuOffload']!.format('maxGpu'), '最大GPU');
    });

    test('文字列は引用符つき、空は（空）', () {
      expect(AgentSettings.specs['tone']!.format('丁寧に'), '「丁寧に」');
      expect(AgentSettings.specs['tone']!.format(''), '（空）');
    });

    test('変更内容を1行で説明する', () {
      final ok = AgentSettings.normalize('thinking', false) as SettingsChangeOk;
      expect(ok.description, '思考プロセスをオフにする');
    });
  });
}
