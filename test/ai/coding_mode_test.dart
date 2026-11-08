import 'dart:async';
import 'dart:collection';

import 'package:arce_ai/ai/cloud_engine.dart';
import 'package:arce_ai/ai/delegation.dart';
import 'package:arce_ai/ai/provider.dart';
import 'package:arce_ai/ai/provider_config.dart';
import 'package:arce_ai/ai/roles.dart';
import 'package:arce_ai/ai/routing_engine.dart';
import 'package:arce_ai/core/chat_controller.dart';
import 'package:arce_ai/core/coding_plan.dart';
import 'package:arce_ai/core/engine.dart';
import 'package:arce_ai/core/generation.dart';
import 'package:arce_ai/core/prompt.dart';
import 'package:arce_ai/core/protocol.dart';
import 'package:arce_ai/core/run_progress.dart';
import 'package:arce_ai/core/tool_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

/// The planner model: replies from a script, one per request, and records the requests.
class FakePlanner implements InferenceEngine {
  FakePlanner(Iterable<String> replies) : _queue = Queue.of(replies);

  final Queue<String> _queue;
  final requests = <GenerateRequest>[];
  int cancels = 0;

  @override
  bool get isLoaded => true;
  @override
  Future<void> load(LoadParams params) async {}
  @override
  Future<void> unload() async {}
  @override
  void cancel() => cancels++;

  @override
  Stream<GenerationEvent> generate(GenerateRequest request) async* {
    requests.add(request);
    yield Piece(_queue.removeFirst());
    yield const Finished(FinishReason.eog);
  }
}

class FakeDeveloper implements RoleModel {
  FakeDeveloper(this.answer, {this.delay = Duration.zero});
  final String answer;
  final Duration delay;
  final asked = <List<AiMessage>>[];
  var cancelled = 0;

  @override
  int get maxParallel => 4;
  @override
  bool get usesDevice => false;
  @override
  String get label => '開発';

  @override
  Future<String> ask(
    List<AiMessage> messages, {
    required int maxTokens,
    required bool Function() cancelled,
    double temperature = 0.3,
    int autoTokens = 4096,
  }) async {
    asked.add(messages);
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    return answer;
  }

  @override
  void cancel() => cancelled++;
}

/// What the app puts around the chat: `delegate` goes to the runner, the rest is not needed here.
class _Runtime implements ToolRuntime {
  _Runtime(this.runner, this.stop, this.meter);
  final DelegateRunner runner;
  final StopSignal stop;
  final RunMeter meter;

  @override
  Future<ToolOutcome> run(ToolCall call) {
    if (call is Delegate) return runner.run(call, stop: stop.future, meter: meter);
    throw StateError('unexpected $call');
  }
}

const delegateCall =
    '<tool_call>\n{"name":"delegate","arguments":{"summary":"S","tasks":[{"title":"画面","instructions":"画面を作る","files":["index.html"]}]}}\n</tool_call>';

({ChatController chat, FakePlanner planner, FakeDeveloper developer}) setup({
  List<String>? replies,
  bool enabled = true,
  Duration developerDelay = Duration.zero,
}) {
  final planner = FakePlanner(replies ?? [delegateCall, '作りました。']);
  final developer = FakeDeveloper('```html\n<p>画面</p>\n```', delay: developerDelay);
  final stop = StopSignal();
  final runner = DelegateRunner(
    settings: () => const CodingSettings(investigateFirst: false, enabled: true, planner: 'p|m', developer: 'd|m', maxTasks: 4, parallel: 3),
    developers: () => [developer],
  );
  final meter = RunMeter();
  final chat = ChatController(
    planner,
    stopSignal: stop,
    meter: meter,
    toolRuntime: _Runtime(runner, stop, meter),
    delegateEnabled: () => enabled,
    delegateInstructions: () => '分担の指示（テスト）',
    store: (_, {required generating}) {},
  );
  return (chat: chat, planner: planner, developer: developer);
}

void main() {
  test('plan が delegate を呼ぶと、coding が書き、そのファイルはユーザーに見え、plan は番号つきの結果を読んで締める', () async {
    final t = setup();
    await t.chat.send('ツールを作って');

    // the planner was told about its team, and was given the tool
    final first = t.planner.requests.first;
    expect(first.agentId, 'coding');
    expect(first.tools.map((x) => x.name), contains('delegate'));
    expect(first.prompt, contains('分担の指示（テスト）'));
    // the developer got the job
    expect(t.developer.asked, hasLength(1));
    expect(t.developer.asked.single[1].text, allOf(contains('画面を作る'), contains('index.html'), contains('S')));
    // the planner read the result by its id, and finished
    expect(t.planner.requests.last.prompt, allOf(contains('<tool_response>'), contains('## d1 (t1): 画面'), contains('<p>画面</p>')));
    // the user's reply has the developer's file (shown by the app) and the planner's closing words
    final reply = t.chat.state.messages.last;
    expect(reply.text, allOf(contains('> 実装: 1 件を、分担数 4・開発 で並列に'), contains('### 画面'), contains('<p>画面</p>'), contains('作りました。')));
    expect(reply.text.indexOf('<p>画面</p>'), lessThan(reply.text.indexOf('作りました。')), reason: 'the file first, then the summary');
    expect(reply.activities.single.tool, 'Delegate');
    expect(reply.finish, FinishReason.eog);
  });

  test('分担の途中でも進み具合が分かり、plan の思考は開発のあとも残る。終わると通信の回数が出る', () async {
    final t = setup(
      replies: ['<think>**設計**\n画面を一つに分ける</think>$delegateCall', '<think>**確認**\n結果を読む</think>作りました。'],
      developerDelay: const Duration(milliseconds: 40),
    );
    final stages = <String>[];
    t.chat.addListener(() {
      final p = t.chat.state.progress;
      if (p != null && (stages.isEmpty || stages.last != p.stage)) stages.add(p.stage);
    });
    await t.chat.send('ツールを作って');

    expect(stages, containsAllInOrder([
      'plan が考えています',
      'coding に依頼しています',
      'coding が実装しています（0/1 件完了・分担数 4）',
      'coding が実装しています（1/1 件完了・分担数 4）',
      'plan が考えています',
      'plan が回答を書いています',
    ]));
    final p = t.chat.state.progress!;
    expect((p.modelRequests, p.developerRequests, p.toolRuns, p.round), (2, 1, 1, 2));
    expect(p.counts, '通信 3 回（plan 2・coding 1） · ツール 1 回');
    expect(p.running, isFalse);
    expect(t.chat.state.messages.last.thinking, allOf(contains('画面を一つに分ける'), contains('結果を読む')));
  });

  test('分担が使えないときは、delegate の道具も分担の指示も出さない', () async {
    final t = setup(enabled: false, replies: ['自分で答えます。']);
    await t.chat.send('ツールを作って');
    final request = t.planner.requests.single;
    expect(request.tools.map((x) => x.name), isNot(contains('delegate')));
    expect(request.prompt, isNot(contains('分担の指示（テスト）')));
    expect(t.developer.asked, isEmpty);
  });

  test('コーディングの話でなければ（Coding エージェントでなければ）、分担の道具も指示も出さない', () async {
    final t = setup(replies: ['こんにちは！']);
    await t.chat.send('こんにちは');
    final request = t.planner.requests.single;
    expect(request.agentId, isNot('coding'));
    expect(request.tools.map((x) => x.name), isNot(contains('delegate')));
    expect(request.prompt, isNot(contains('分担の指示（テスト）')));
  });

  test('coding の作業中に停止すると、coding を止め、plan に次の依頼を送らず「止めた」で終わる', () async {
    final t = setup(developerDelay: const Duration(milliseconds: 80));
    final sending = t.chat.send('ツールを作って');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    t.chat.stop();
    await sending;
    expect(t.developer.cancelled, 1);
    expect(t.planner.requests, hasLength(1), reason: 'the planner is not asked again after the stop');
    expect(t.chat.state.messages.last.finish, FinishReason.cancelled);
    expect(t.chat.isRunning, isFalse);
  });

  test('delegate の呼び出しは、同じ内容を繰り返すと止まるが、直し（revise）や別の内容は繰り返しにならない', () async {
    final fix = '<tool_call>\n{"name":"delegate","arguments":{"summary":"S","tasks":[{"title":"直し","instructions":"色を青に","revise":"d1"}]}}\n</tool_call>';
    final t = setup(replies: [delegateCall, fix, '直しました。']);
    await t.chat.send('ツールを作って');
    expect(t.developer.asked, hasLength(2));
    expect(t.developer.asked.last.map((m) => m.role), [AiRole.system, AiRole.user, AiRole.assistant, AiRole.user]);
    expect(t.chat.state.messages.last.text, contains('直しました。'));
  });

  group('どのモデルが答えるか', () {
    GenerateRequest request(String? agent) => GenerateRequest(
          prompt: ChatMlPromptBuilder.build(const [UserTurn('x')], const [], null, false),
          toolCallSchema: null,
          thinking: false,
          maxTokens: 10,
          sampling: SamplingParams.qwen3NonThinking,
          agentId: agent,
        );

    test('Coding エージェントの依頼は、plan のエンジンが答える。ほかは使用中のモデル', () async {
      final local = FakePlanner(['端末', '端末']);
      final planner = FakePlanner(['plan']);
      final router = RoutingEngine(local: local, cloud: CloudEngine(_NoProvider()))
        ..planner = (r) => r.agentId == 'coding' ? planner : null;

      Future<String> text(GenerateRequest r) async => (await router.generate(r).where((e) => e is Piece).cast<Piece>().toList()).map((p) => p.text).join();
      expect(await text(request('coding')), 'plan');
      expect(await text(request('general')), '端末');
      expect(await text(request(null)), '端末', reason: 'the app\'s own short requests (choosing an agent) are not the planner\'s');
    });

    test('端末を使うのは、ローカルモデルが答えるとき（使用中のモデルが端末か、plan が端末のとき）だけ', () {
      final local = FakePlanner([]);
      final online = FakePlanner([]);
      final router = RoutingEngine(local: local, cloud: CloudEngine(_NoProvider()));
      expect(router.usesDevice(request('coding')), isTrue, reason: 'no provider: the device model answers');

      router.target = _NoProvider();
      expect(router.usesDevice(request('coding')), isFalse);

      router.planner = (r) => online;
      expect(router.usesDevice(request('coding')), isFalse, reason: 'an online planner');
      router.planner = (r) => local;
      expect(router.usesDevice(request('coding')), isTrue, reason: 'the planner is the device model');
    });
  });
}

class _NoProvider implements AiProvider {
  @override
  String get id => 'none';
  @override
  String get label => 'なし';
  @override
  String get modelId => '';
  @override
  ModelConfig? get modelConfig => null;
  @override
  ProviderCapabilities get capabilities => const ProviderCapabilities();
  @override
  Future<void> verify() async {}
  @override
  Stream<Delta> stream(AiRequest request) async* {}
}
