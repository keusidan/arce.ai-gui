import 'dart:collection';
import 'dart:convert';

import 'package:arce_ai/core/agents.dart';
import 'package:arce_ai/core/chat_controller.dart';
import 'package:arce_ai/core/engine.dart';
import 'package:arce_ai/core/generation.dart';
import 'package:arce_ai/core/protocol.dart';
import 'package:arce_ai/core/settings_spec.dart';
import 'package:arce_ai/core/tool_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

/// Replays one scripted reply per generate() call.
class _Engine implements InferenceEngine {
  _Engine(this._replies);

  final Queue<(String, FinishReason)> _replies;
  final requests = <GenerateRequest>[];

  @override
  bool get isLoaded => true;
  @override
  Future<void> load(LoadParams params) async {}
  @override
  void cancel() {}
  @override
  Future<void> unload() async {}

  @override
  Stream<GenerationEvent> generate(GenerateRequest request) async* {
    requests.add(request);
    final (text, reason) = _replies.removeFirst();
    yield Piece(text);
    yield Finished(reason);
  }
}

/// What the app would have stored; `get_settings` formats these values.
Map<String, Object?> sampleSettings() => {
      'thinking': true,
      'searchEnabled': false,
      'searxngUrl': '',
      'tone': '',
      'maxChars': 800,
      'speedAccuracy': 0.5,
      'hyperLoad': false,
      'theme': 'dark',
      'thinkingStyle': 'pulse',
      'agentOverride': '',
      'aiAgentSelection': true,
      'contextLength': 8192,
      'threads': 0,
      'batchSize': 0,
      'gpuOffload': 'auto',
      'maxTokens': 2048,
      'retryLimit': 2,
      'maxToolRounds': 4,
      'forceExecution': false,
      'autoUpdateCheck': true,
      'updateIntervalHours': 12,
    };

void main() {
  const updateJson = '{"name":"update_settings","arguments":{"changes":[{"key":"theme","value":"dark"}]}}';

  test('get_settings は許可されたエージェントだけが呼べる', () {
    final ok = ToolCallParser.parse('{"name":"get_settings","arguments":{}}', [Protocol.getSettings]);
    expect((ok as ParseOk).call, isA<GetSettings>());

    final refused = ToolCallParser.parse('{"name":"get_settings","arguments":{}}', [Protocol.askUser]);
    expect(refused, isA<ParseInvalid>());
  });

  test('describe は変更できる設定を現在値つきで並べる', () {
    final text = AgentSettings.describe(sampleSettings());
    for (final key in AgentSettings.keys) {
      expect(text, contains('- $key = '), reason: '設定 $key が抜けている');
    }
    expect(text, contains('theme = dark'));
    expect(text, contains('contextLength = 8192'));
    expect(text, contains('選択肢: system（端末に合わせる）'));
    expect(text, contains('範囲: 512〜131072'));
    expect(text, contains('lastModelPath'), reason: '触れない設定があることも伝える');
  });

  test('get_settings は設定ストアから現在値を返す', () async {
    final runtime = DefaultToolRuntime(settingsValues: sampleSettings);
    final out = await runtime.run(const GetSettings());
    expect(out.activity.failed, isFalse);
    expect(out.response, contains('theme = dark'));
    expect(out.response, contains('maxChars = 800'));

    final none = await DefaultToolRuntime().run(const GetSettings());
    expect(none.activity.failed, isTrue);
  });

  test('update_settings は承認カードになり、承認するまで書かない', () async {
    final engine = _Engine(Queue.of([
      ('<tool_call>\n$updateJson\n</tool_call>', FinishReason.eog),
      ('ダークにしました。', FinishReason.eog),
    ]));
    final applied = <List<SettingsChangeOk>>[];
    final chat = ChatController(
      engine,
      applySettings: (changes) async {
        applied.add(changes);
        return 'The user approved the change: theme=ダーク.';
      },
    );

    await chat.send('テーマをダークにして');
    expect(chat.state.pendingSettings?.single.key, 'theme');
    expect(chat.state.pendingQuestion?.options, [SettingsApproval.approve, SettingsApproval.reject]);
    expect(chat.state.pendingQuestion?.allowFreeInput, isFalse);
    expect(applied, isEmpty, reason: '承認前に書いてはいけない');

    await chat.answer([SettingsApproval.approve], null);
    expect(applied.single.single.value, 'dark');
    expect(engine.requests.last.prompt, contains('The user approved the change'));
    expect(chat.state.messages.last.text, 'ダークにしました。');
    expect(chat.state.pendingSettings, isNull);
  });

  test('拒否された変更は何も書かず、そう伝える', () async {
    final engine = _Engine(Queue.of([
      ('<tool_call>\n$updateJson\n</tool_call>', FinishReason.eog),
      ('やめておきます。', FinishReason.eog),
    ]));
    final applied = <List<SettingsChangeOk>>[];
    final chat = ChatController(
      engine,
      applySettings: (changes) async {
        applied.add(changes);
        return 'applied';
      },
    );

    await chat.send('テーマをダークにして');
    await chat.answer([SettingsApproval.reject], null);
    expect(applied, isEmpty);
    expect(engine.requests.last.prompt, contains('The user rejected the change'));
  });

  test('承認待ちは会話の保存から戻る', () async {
    final engine = _Engine(Queue.of([('<tool_call>\n$updateJson\n</tool_call>', FinishReason.eog)]));
    final chat = ChatController(engine, applySettings: (_) async => 'applied');
    await chat.send('テーマをダークにして');

    final other = ChatController(
      _Engine(Queue.of([('ok', FinishReason.eog)])),
      applySettings: (_) async => 'applied',
    );
    other.restore(ConversationSnapshot.fromJson(chat.snapshot().toJson()));
    expect(other.state.pendingSettings?.single.value, 'dark');
  });

  group('add_provider', () {
    const addJson = '{"name":"add_provider","arguments":{"name":"OrcaRouter","base_url":"https://api.orcarouter.example/v1/",'
        '"models":["orca/fast","orca/fast","orca/deep"]}}';

    ParseResult parseAdd(Object arguments) => ToolCallParser.parse(
          '{"name":"add_provider","arguments":${jsonEncode(arguments)}}',
          [Protocol.addProvider],
        );

    test('名前・URL・モデルを読み取り、末尾の / や重複を整える', () {
      final call = (ToolCallParser.parse(addJson, [Protocol.addProvider]) as ParseOk).call as AddProvider;
      expect(call.draft.name, 'OrcaRouter');
      expect(call.draft.baseUrl, 'https://api.orcarouter.example/v1');
      expect(call.draft.models, ['orca/fast', 'orca/deep']);
      expect(call.draft.supportsTools, isTrue);
    });

    test('貼り付けた /chat/completions は落とす', () {
      final call = (parseAdd({
        'name': 'X',
        'base_url': 'https://api.example.com/v1/chat/completions',
        'models': ['m'],
      }) as ParseOk).call as AddProvider;
      expect(call.draft.baseUrl, 'https://api.example.com/v1');
    });

    test('キーを仕込める形や不正な値は拒否する', () {
      for (final bad in <Map<String, Object?>>[
        {'name': 'X', 'base_url': 'https://user:pass@example.com/v1', 'models': ['m']},
        {'name': 'X', 'base_url': 'https://example.com/v1?api_key=abc', 'models': ['m']},
        {'name': 'X', 'base_url': 'ftp://example.com', 'models': ['m']},
        {'name': 'X', 'base_url': 'example.com', 'models': ['m']},
        {'name': ' ', 'base_url': 'https://example.com', 'models': ['m']},
        {'name': 'X', 'base_url': 'https://example.com', 'models': <String>[]},
        {'name': 'X', 'base_url': 'https://example.com', 'models': [' ']},
        {'name': 'X', 'base_url': 'https://example.com', 'models': [1]},
        {'name': 'X', 'base_url': 'https://example.com', 'models': [for (var i = 0; i < 21; i++) 'm$i']},
      ]) {
        expect(parseAdd(bad), isA<ParseInvalid>(), reason: '$bad');
      }
    });

    test('許可されたエージェントだけが呼べる。設定を変えられるエージェントは呼べる', () {
      expect(ToolCallParser.parse(addJson, [Protocol.askUser]), isA<ParseInvalid>());
      for (final agent in Agents.all) {
        expect(agent.tools.contains(Protocol.addProvider), agent.tools.contains(Protocol.updateSettings), reason: agent.id);
      }
    });

    test('スキーマに APIキーの欄は無い', () {
      final props = (Protocol.addProvider.parameters['properties']! as Map).keys;
      expect(props, unorderedEquals(['name', 'base_url', 'models', 'tools']));
    });

    test('承認カードになり、承認するまで保存しない', () async {
      final engine = _Engine(Queue.of([
        ('<tool_call>\n$addJson\n</tool_call>', FinishReason.eog),
        ('追加しました。キーは詳細設定で入れてください。', FinishReason.eog),
      ]));
      final added = <ProviderDraft>[];
      final chat = ChatController(
        engine,
        addProvider: (draft) async {
          added.add(draft);
          return 'The user approved it and the provider "OrcaRouter" was added.';
        },
      );

      await chat.send('OrcaRouter を追加して');
      expect(chat.state.pendingProvider?.name, 'OrcaRouter');
      expect(chat.state.pendingQuestion?.options, [ProviderApproval.approve, ProviderApproval.reject]);
      expect(chat.state.pendingQuestion?.title, contains('https://api.orcarouter.example/v1'));
      expect(added, isEmpty, reason: '承認前に保存してはいけない');

      await chat.answer([ProviderApproval.approve], null);
      expect(added.single.models, ['orca/fast', 'orca/deep']);
      expect(engine.requests.last.prompt, contains('was added'));
      expect(chat.state.pendingProvider, isNull);
    });

    test('やめるを選ぶと何も保存せず、そう伝える', () async {
      final engine = _Engine(Queue.of([
        ('<tool_call>\n$addJson\n</tool_call>', FinishReason.eog),
        ('やめておきます。', FinishReason.eog),
      ]));
      final added = <ProviderDraft>[];
      final chat = ChatController(engine, addProvider: (d) async {
        added.add(d);
        return 'added';
      });

      await chat.send('OrcaRouter を追加して');
      await chat.answer([ProviderApproval.reject], null);
      expect(added, isEmpty);
      expect(engine.requests.last.prompt, contains('declined to add the provider'));
    });

    test('保存に失敗したときは、失敗をモデルに返す', () async {
      final engine = _Engine(Queue.of([
        ('<tool_call>\n$addJson\n</tool_call>', FinishReason.eog),
        ('失敗しました。', FinishReason.eog),
      ]));
      final chat = ChatController(engine, addProvider: (_) async => throw StateError('disk'));
      await chat.send('OrcaRouter を追加して');
      await chat.answer([ProviderApproval.approve], null);
      expect(engine.requests.last.prompt, contains('adding the provider failed'));
    });

    test('承認待ちは会話の保存から戻る', () async {
      final engine = _Engine(Queue.of([('<tool_call>\n$addJson\n</tool_call>', FinishReason.eog)]));
      final chat = ChatController(engine, addProvider: (_) async => 'ok');
      await chat.send('OrcaRouter を追加して');

      final other = ChatController(_Engine(Queue.of([('ok', FinishReason.eog)])), addProvider: (_) async => 'ok');
      other.restore(ConversationSnapshot.fromJson(chat.snapshot().toJson()));
      expect(other.state.pendingProvider?.baseUrl, 'https://api.orcarouter.example/v1');
    });
  });
}
