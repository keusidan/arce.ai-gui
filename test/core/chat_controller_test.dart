import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:arce_ai/core/attachments.dart';
import 'package:arce_ai/core/chat_controller.dart';
import 'package:arce_ai/core/engine.dart';
import 'package:arce_ai/core/generation.dart';
import 'package:arce_ai/core/prompt.dart';
import 'package:arce_ai/core/protocol.dart';
import 'package:arce_ai/core/secret_book.dart';
import 'package:arce_ai/core/tool_runtime.dart';
import 'package:arce_ai/mcp/mcp_tools.dart';
import 'package:flutter_test/flutter_test.dart';

/// Replays one scripted reply per generate() call, split into small pieces like real tokens.
class ScriptedEngine implements InferenceEngine {
  ScriptedEngine(Iterable<(String, FinishReason)> replies)
    : _queue = Queue.of(replies);

  final Queue<(String, FinishReason)> _queue;
  final requests = <GenerateRequest>[];
  String? failWith;

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
    if (failWith != null) throw EngineException(failWith!);
    final (text, reason) = _queue.removeFirst();
    for (var i = 0; i < text.length; i += 3) {
      yield Piece(text.substring(i, i + 3 > text.length ? text.length : i + 3));
    }
    yield Finished(reason);
  }
}

/// Answers like [inner], but only after [until] completes: a tool that takes a while.
class _SlowRuntime implements ToolRuntime {
  _SlowRuntime(this.inner, this.until);
  final ToolRuntime inner;
  final Future<void> until;

  @override
  Future<ToolOutcome> run(ToolCall call) async {
    await until;
    return inner.run(call);
  }
}

class _Runtime implements ToolRuntime {
  _Runtime(this._outcome);
  final ToolOutcome Function(ToolCall) _outcome;

  @override
  Future<ToolOutcome> run(ToolCall call) async => _outcome(call);
}

void main() {
  const askJson =
      '{"name":"ask_user","arguments":{"title":"どの言語？","options":["Kotlin","Java"],"allow_free_input":true}}';

  test('an attached image is marked in the prompt and its bytes go with the request', () async {
    final engine = ScriptedEngine([('見えます', FinishReason.eog)]);
    final chat = ChatController(engine);
    final image = ImageData('image/png', Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]));

    await chat.send('これは何？', attachments: [Attachment('a.png', '', image: image)]);

    final request = engine.requests.single;
    expect(request.prompt, contains(ImageMarker.of('a.png', image)));
    expect(request.images[image.id], same(image));
    expect(chat.state.messages.first.text, 'これは何？', reason: 'the screen shows what the user typed, not the marker');
    expect(chat.state.messages.first.attachments, ['a.png']);

    // a new conversation drops the bytes; the saved marker stays in the history only
    chat.clear();
    await chat.send('次');
    expect(engine.requests.last.images, isEmpty);
  });

  test('what the user writes and answers is counted (the 分担モード builds only after it); an approval card is not', () async {
    final engine = ScriptedEngine([
      ('<tool_call>\n$askJson\n</tool_call>', FinishReason.eog),
      ('了解', FinishReason.eog),
      ('<tool_call>\n{"name":"update_settings","arguments":{"changes":[{"key":"searchEnabled","value":false}]}}\n</tool_call>', FinishReason.eog),
      ('変えませんでした', FinishReason.eog),
    ]);
    final chat = ChatController(engine);
    expect(chat.userInputs, 0);
    await chat.send('作って');
    expect(chat.userInputs, 1, reason: 'a message');
    expect(chat.state.pendingQuestion, isNotNull);
    await chat.answer(['Kotlin'], null);
    expect(chat.userInputs, 2, reason: 'an answer to the model\'s question');
    await chat.send('検索を切って');
    expect(chat.userInputs, 3);
    expect(chat.state.pendingSettings, isNotNull);
    await chat.answer(['却下'], null);
    expect(chat.userInputs, 3, reason: 'an approval card of a setting is not an answer to the design');
  });

  test('separates thinking from the answer', () async {
    final chat = ChatController(
      ScriptedEngine([('<think>考え中</think>こんにちは', FinishReason.eog)]),
    );
    await chat.send('hi');
    final reply = chat.state.messages.last;
    expect(reply.thinking, '考え中');
    expect(reply.text, 'こんにちは');
    expect(chat.state.task, TaskState.completed);
  });

  test(
    'a tool call becomes a question tile and the answer resumes generation',
    () async {
      final engine = ScriptedEngine([
        (
          '<think>聞く</think>確認します。<tool_call>\n$askJson\n</tool_call>',
          FinishReason.eog,
        ),
        ('<think></think>Kotlinで作ります。', FinishReason.eog),
      ]);
      final chat = ChatController(engine);
      await chat.send('アプリを作って');

      expect(chat.state.task, TaskState.userWait);
      expect(
        chat.state.pendingQuestion,
        const QuestionTile(
          title: 'どの言語？',
          options: ['Kotlin', 'Java'],
          allowFreeInput: true,
          multiSelect: false,
        ),
      );
      expect(engine.requests.single.toolCallSchema, isNotNull);

      await chat.answer(['Kotlin'], null);
      expect(chat.state.pendingQuestion, isNull);
      expect(chat.state.messages.last.text, 'Kotlinで作ります。');
      expect(
        engine.requests.last.prompt,
        contains('<tool_response>\nKotlin\n</tool_response>'),
      );
      expect(
        engine.requests.last.prompt,
        contains('<tool_call>\n$askJson\n</tool_call>'),
      );
    },
  );

  test('a tool call cut off by the token limit is regenerated', () async {
    final engine = ScriptedEngine([
      ('<tool_call>\n{"name":"ask_', FinishReason.length),
      ('<tool_call>\n$askJson\n</tool_call>', FinishReason.eog),
    ]);
    final chat = ChatController(engine);
    await chat.send('質問して');
    expect(engine.requests, hasLength(2));
    expect(chat.state.task, TaskState.userWait);
  });

  test('a stopped reply can be continued from where it ended', () async {
    final engine = ScriptedEngine([
      ('<think>x</think>前半', FinishReason.cancelled),
      ('と後半', FinishReason.eog),
    ]);
    final chat = ChatController(engine);
    await chat.send('長い説明をして');
    expect(chat.state.canContinue, isTrue);

    await chat.continueReply();
    expect(chat.state.messages.last.text, '前半と後半');
    expect(chat.state.canContinue, isFalse);
    expect(
      engine.requests.last.thinking,
      isFalse,
      reason: 'a continuation does not reason again',
    );
    expect(engine.requests.last.prompt, endsWith('前半'));
  });

  test('regenerate replaces the last reply using the same prompt', () async {
    final engine = ScriptedEngine([
      ('一回目', FinishReason.eog),
      ('二回目', FinishReason.eog),
    ]);
    final chat = ChatController(engine);
    await chat.send('hi');
    await chat.regenerate();
    expect(chat.state.messages.map((m) => m.text), ['hi', '二回目']);
    expect(engine.requests[0].prompt, engine.requests[1].prompt);
  });

  const badQuestion = '{"name":"ask_user","arguments":{"title":"q","options":["a","a"]}}';

  test('an invalid question is reported, not shown, when no retry is allowed', () async {
    final chat = ChatController(
      ScriptedEngine([('<tool_call>\n$badQuestion\n</tool_call>', FinishReason.eog)]),
      settings: () => const GenerationSettings(retryLimit: 0),
    );
    await chat.send('質問して');
    expect(chat.state.task, TaskState.error);
    expect(chat.state.error, 'options are not distinct');
    expect(chat.state.pendingQuestion, isNull);
  });

  test('a tool call that cannot be used is not an error: the model is told why and writes it again', () async {
    final engine = ScriptedEngine([
      ('確認します。<tool_call>\n$badQuestion\n</tool_call>', FinishReason.eog),
      ('<tool_call>\n$askJson\n</tool_call>', FinishReason.eog),
    ]);
    final failures = <String>[];
    final chat = ChatController(engine, onFailure: failures.add);
    await chat.send('質問して');
    expect(engine.requests, hasLength(2));
    expect(engine.requests.last.prompt, contains('could not be used: options are not distinct'));
    expect(chat.state.task, TaskState.userWait, reason: 'the second try is a good question, and it is shown');
    expect(chat.state.error, isNull);
    expect(failures, isEmpty);
    final reply = chat.state.messages.last;
    expect(reply.activities.single.failed, isTrue, reason: 'the screen says the first call could not be read');
    expect(reply.activities.single.summary, contains('options are not distinct'));
    expect(reply.text, contains('確認します'));
  });

  test('a model that keeps writing unusable calls is stopped after the retry limit, with the reason', () async {
    final engine = ScriptedEngine([for (var i = 0; i < 3; i++) ('<tool_call>\n$badQuestion\n</tool_call>', FinishReason.eog)]);
    final chat = ChatController(engine);
    await chat.send('質問して');
    expect(engine.requests, hasLength(3), reason: 'once, and the retry limit (2) more');
    expect(chat.state.task, TaskState.error);
    expect(chat.state.error, 'options are not distinct');
  });

  test('two tool calls in one reply (parallel calls): the first one is run, not the last and not a failure', () async {
    final engine = ScriptedEngine([
      (
        '<tool_call>\n{"name":"web_search","arguments":{"query":"first"}}\n</tool_call>'
            '<tool_call>\n{"name":"web_search","arguments":{"query":"second"}}\n</tool_call>',
        FinishReason.eog,
      ),
      ('done', FinishReason.eog),
    ]);
    final queries = <String>[];
    final runtime = _Runtime((call) {
      queries.add((call as WebSearch).query);
      return const ToolOutcome('result', ToolActivity('Search', 'found'));
    });
    final chat = ChatController(engine, toolRuntime: runtime, store: (_, {required generating}) {});
    await chat.send('調べて');
    expect(queries, ['first']);
    expect(chat.state.messages.last.text, 'done');
  });

  test('a burst of pieces is not told to the screen piece by piece, and the reply still ends whole', () async {
    final reply = 'あ' * 600; // 200 pieces of three characters, all within a few milliseconds
    final engine = ScriptedEngine([(reply, FinishReason.eog)]);
    final chat = ChatController(engine);
    var told = 0;
    chat.addListener(() => told++);
    await chat.send('こんにちは');
    expect(chat.state.messages.last.text, reply, reason: 'the last piece is always told, even inside the interval');
    expect(told, lessThan(100), reason: 'the screen is given the state a few times, not for every piece');
  });

  test('how long the model thought is counted from its first thinking text to its first word, and the live mark is cleared', () async {
    final engine = _SlowThinker();
    final chat = ChatController(engine, store: (_, {required generating}) {});
    final seen = <int>[]; // the live marks the screen saw
    chat.addListener(() {
      if (chat.state.messages.isNotEmpty) seen.add(chat.state.messages.last.thinkingSince);
    });
    await chat.send('こんにちは');
    final reply = chat.state.messages.last;
    expect(reply.thinking, contains('考え中'));
    expect(reply.text, '答えです');
    expect(reply.thinkingMs, greaterThanOrEqualTo(90), reason: 'it thought for 120 ms');
    expect(reply.thinkingMs, lessThan(2000));
    expect(reply.thinkingSince, 0, reason: 'no longer thinking');
    expect(seen.any((v) => v > 0), isTrue, reason: 'while it thought, the screen could count the seconds');
    // and it survives a save and a load of the message
    expect(UiMessage.fromJson(reply.toJson()).thinkingMs, reply.thinkingMs);
  });

  test('a reply that is only thinking, and is stopped, ends its thinking too', () async {
    final engine = _SlowThinker(answer: false);
    final chat = ChatController(engine, store: (_, {required generating}) {});
    final sending = chat.send('こんにちは');
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(chat.state.messages.last.thinkingSince, greaterThan(0));
    engine.stop = true;
    await sending;
    expect(chat.state.messages.last.thinkingSince, 0);
    expect(chat.state.messages.last.thinkingMs, greaterThan(0));
  });

  test('a stop pressed before the request is sent (the tools are still being listed) is not forgotten', () async {
    final engine = ScriptedEngine([('この返信は届かない', FinishReason.eog)]);
    final listing = Completer<List<ToolDefinition>>();
    final chat = ChatController(engine, extraTools: () => listing.future, store: (_, {required generating}) {});
    final sent = chat.send('こんにちは');
    await Future<void>.delayed(Duration.zero);
    expect(chat.isRunning, isTrue);
    chat.stop(); // nothing is being generated yet
    listing.complete(const []);
    await sent;
    expect(engine.requests, isEmpty, reason: 'no request goes out after the stop');
    final reply = chat.state.messages.last;
    expect(reply.finish, FinishReason.cancelled);
    expect(chat.isRunning, isFalse);
    // and the next message is not stopped by the one before
    final next = ScriptedEngine([('ok', FinishReason.eog)]);
    final again = ChatController(next, store: (_, {required generating}) {});
    await again.send('x');
    expect(again.state.messages.last.text, 'ok');
  });

  test(
    'a search tool call is run and the answer continues in the same message',
    () async {
      final engine = ScriptedEngine([
        (
          '<think>調べる</think><tool_call>\n{"name":"web_search","arguments":{"query":"kotlin 2.4"}}\n</tool_call>',
          FinishReason.eog,
        ),
        ('<think></think>Kotlin 2.4 is out.', FinishReason.eog),
      ]);
      final runtime = _Runtime(
        (_) => const ToolOutcome(
          '1. Kotlin 2.4 released https://kotlinlang.org',
          ToolActivity(
            'Search',
            'found',
            links: [Link('K', 'https://kotlinlang.org')],
          ),
        ),
      );
      final saved = <bool>[];
      final chat = ChatController(
        engine,
        toolRuntime: runtime,
        store: (_, {required generating}) => saved.add(generating),
      );
      await chat.send('最新のKotlinを調べて');

      final reply = chat.state.messages.last;
      expect(reply.text, 'Kotlin 2.4 is out.');
      expect(reply.agent, 'Research / Search');
      expect(reply.activities.single.links.map((l) => l.url), [
        'https://kotlinlang.org',
      ]);
      expect(
        engine.requests.last.prompt,
        contains('<tool_response>\n1. Kotlin 2.4 released'),
      );
      expect(chat.state.task, TaskState.completed);
      expect(saved, [
        true,
        true,
        false,
      ], reason: 'saved as unfinished at start and after the tool round, finished at the end');
    },
  );

  test('what the model thought in an earlier round stays when the next round begins', () async {
    final engine = ScriptedEngine([
      ('<think>一回目の考え</think><tool_call>\n{"name":"web_search","arguments":{"query":"q"}}\n</tool_call>', FinishReason.eog),
      ('<think>二回目の考え</think>答え', FinishReason.eog),
    ]);
    final runtime = _Runtime((_) => const ToolOutcome('r', ToolActivity('Search', 'found')));
    final chat = ChatController(engine, toolRuntime: runtime);
    final seen = <String>[];
    chat.addListener(() => seen.add(chat.state.messages.last.thinking));
    await chat.send('調べて');

    final thinking = chat.state.messages.last.thinking;
    expect(thinking, allOf(contains('一回目の考え'), contains('二回目の考え')));
    expect(thinking.indexOf('一回目の考え') < thinking.indexOf('二回目の考え'), isTrue);
    expect(
      seen.where((t) => t.contains('二回目') && !t.contains('一回目')),
      isEmpty,
      reason: 'the first round never drops out while the second streams',
    );
  });

  group('the size of the next request', () {
    test('the parts add up to what is actually sent: instructions, tools, the conversation so far and what is typed', () async {
      final engine = ScriptedEngine([('はい、Dart です。', FinishReason.eog), ('どうも', FinishReason.eog)]);
      final tool = ToolDefinition(name: 'mcp_x__list_things', description: 'lists things', parameters: Protocol.runCommand.parameters);
      final chat = ChatController(engine, extraTools: () async => [tool]);
      final empty = await chat.promptParts('');
      expect(empty.conversation, isEmpty);
      expect(empty.draft, isEmpty);
      expect(empty.tools, contains('mcp_x__list_things'));
      expect(empty.system, contains('Rules'));

      await chat.send('Dart でコードを書いて');
      final parts = await chat.promptParts('ありがとう、次は Python で');
      expect(parts.conversation, allOf(contains('Dart でコードを書いて'), contains('はい、Dart です。')));
      expect(parts.draft, contains('ありがとう、次は Python で'));
      final before = engine.requests.length;
      await chat.send('ありがとう、次は Python で');
      final sent = engine.requests.last.prompt;
      expect(engine.requests.length, before + 1);
      expect(parts.system.length + parts.tools.length + parts.conversation.length + parts.draft.length, sent.length,
          reason: 'the estimate is made from the same pieces the request is');
    });

    test('the agent\'s own tools are counted even when no MCP server adds any; a longer conversation is a bigger conversation part', () async {
      final engine = ScriptedEngine([('一つ目', FinishReason.eog)]);
      final chat = ChatController(engine);
      final first = await chat.promptParts('こんにちは');
      expect(first.tools, allOf(contains('ask_user'), isNot(contains('mcp_'))));
      await chat.send('こんにちは');
      final second = await chat.promptParts('こんにちは');
      expect(second.conversation.length, greaterThan(first.conversation.length));
    });
  });

  group('approval of a tool', () {
    const search = '<tool_call>\n{"name":"web_search","arguments":{"query":"q"}}\n</tool_call>';
    const shell = '<tool_call>\n{"name":"run_command","arguments":{"command":"ls","cwd":"/workspace"}}\n</tool_call>';
    const push = '<tool_call>\n{"name":"mcp_gh__push_files","arguments":{"path":"a"}}\n</tool_call>';
    final shellTool = ToolDefinition(name: 'run_command', description: 'x', parameters: Protocol.runCommand.parameters);
    final pushTool = ToolDefinition(name: 'mcp_gh__push_files', description: 'x', parameters: const {'type': 'object', 'properties': {'path': {'type': 'string'}}});

    ChatController make(ScriptedEngine engine, {required ToolRuntime runtime, bool after = true, Future<void> Function(String)? remember}) => ChatController(
          engine,
          toolRuntime: runtime,
          extraTools: () async => [shellTool, pushTool],
          // the policy of the app: a command inside the environment does not ask; a push does
          mcpApproval: (name, [args = const {}]) => name == 'mcp_gh__push_files',
          confirmAfterExternal: () => after,
          rememberTool: remember,
        );

    test('a command inside the environment runs without asking, until the model has read something from outside', () async {
      final ran = <String>[];
      final runtime = _Runtime((call) {
        ran.add(call is McpCall ? call.name : call.runtimeType.toString());
        return const ToolOutcome('ok', ToolActivity('Shell', 'done'));
      });
      final quiet = make(ScriptedEngine([(shell, FinishReason.eog), ('終わり', FinishReason.eog)]), runtime: runtime);
      await quiet.send('ファイルを見て');
      expect(ran, ['run_command'], reason: 'nothing from outside was read: it just runs');
      expect(quiet.state.task, TaskState.completed);

      ran.clear();
      final read = make(ScriptedEngine([(search, FinishReason.eog), (shell, FinishReason.eog)]), runtime: runtime);
      await read.send('調べて、実行して');
      expect(ran, ['WebSearch'], reason: 'the search ran; the command waits');
      expect(read.state.task, TaskState.userWait);
      expect(read.state.pendingTool!.name, 'run_command');
      expect(read.state.pendingQuestion!.title, contains('検索や外部ツールの結果を読んだあとなので、確認します'));
      expect(read.state.pendingQuestion!.options, [ToolApproval.approve, ToolApproval.reject], reason: 'a command cannot be remembered');
    });

    test('a session that is started or typed into asks after reading from outside, like a command; reading it never does', () async {
      final ran = <String>[];
      final runtime = _Runtime((call) {
        ran.add(call is McpCall ? '${call.name}:${call.arguments['action'] ?? ''}' : call.runtimeType.toString());
        return const ToolOutcome('ok', ToolActivity('Shell', 'done'));
      });
      final sessionTool = ToolDefinition(name: 'shell_session', description: 'x', parameters: Protocol.shellSession.parameters);
      const start = '<tool_call>\n{"name":"shell_session","arguments":{"action":"start","command":"python3"}}\n</tool_call>';
      const read = '<tool_call>\n{"name":"shell_session","arguments":{"action":"read","session":"s1"}}\n</tool_call>';
      ChatController chat(List<(String, FinishReason)> replies) => ChatController(
            ScriptedEngine(replies),
            toolRuntime: runtime,
            extraTools: () async => [sessionTool],
            // the app's own policy: a start inside the sandbox runs, a read always does
            mcpApproval: (name, [args = const {}]) => false,
            confirmAfterExternal: () => true,
          );

      final quiet = chat([(start, FinishReason.eog), ('開きました', FinishReason.eog)]);
      await quiet.send('python を開いて');
      expect(ran, ['shell_session:start'], reason: 'nothing from outside was read: it just runs');

      ran.clear();
      final afterSearch = chat([(search, FinishReason.eog), (start, FinishReason.eog)]);
      await afterSearch.send('調べて、開いて');
      expect(ran, ['WebSearch']);
      expect(afterSearch.state.task, TaskState.userWait);
      expect(afterSearch.state.pendingTool!.name, 'shell_session');
      expect(afterSearch.state.pendingQuestion!.title, contains('検索や外部ツールの結果を読んだあとなので、確認します'));
      expect(afterSearch.state.pendingQuestion!.title, contains('対話できるセッションとして始めます'));
      expect(afterSearch.state.pendingQuestion!.options, [ToolApproval.approve, ToolApproval.reject], reason: 'cannot be remembered');

      ran.clear();
      final reading = chat([(search, FinishReason.eog), (read, FinishReason.eog), ('見ました', FinishReason.eog)]);
      await reading.send('調べて、画面を見て');
      expect(ran, ['WebSearch', 'shell_session:read'], reason: 'looking at a screen changes nothing');
      expect(reading.state.task, TaskState.completed);
    });

    test('a command the model wrote with secrets reaches the card, and the tool, with the names (end to end)', () async {
      final seen = <McpCall>[];
      final runtime = _Runtime((call) {
        if (call is McpCall) seen.add(call);
        return const ToolOutcome('ok', ToolActivity('Shell', 'done'));
      });
      // the policy of the app: McpTools decides, as it does in the running app
      final policy = McpTools(const [], shellSupported: true);
      const withSecret = '<tool_call>\n{"name":"run_command","arguments":{"command":"git push","secrets":["GITHUB_TOKEN"]}}\n</tool_call>';
      final chat = ChatController(
        ScriptedEngine([(withSecret, FinishReason.eog), ('送りました', FinishReason.eog)]),
        toolRuntime: runtime,
        extraTools: () async => [shellTool],
        mcpApproval: (name, [args = const {}]) => policy.approvalRequired(name, args),
      );
      await chat.send('push して');
      expect(seen, isEmpty, reason: 'a command with a secret waits for the user even inside the sandbox');
      expect(chat.state.pendingTool!.arguments['secrets'], ['GITHUB_TOKEN']);
      expect(chat.state.pendingQuestion!.title, contains('秘密を渡します: GITHUB_TOKEN'));
      await chat.answer([ToolApproval.approve], null);
      expect(seen.single.arguments['secrets'], ['GITHUB_TOKEN']);
    });

    test('a command with a {{secret:ID}} waits for the user, and the card says which secret may go where (end to end, the model\'s text to the tool)', () async {
      final seen = <McpCall>[];
      final runtime = _Runtime((call) {
        if (call is McpCall) seen.add(call);
        return const ToolOutcome('ok', ToolActivity('Shell', 'done'));
      });
      final policy = McpTools(
        const [],
        shellSupported: true,
        secretBook: SecretRegistry(const [
          SecretSource(kind: SecretKind.provider, name: 'Gemini', source: 'gem', hosts: ['generativelanguage.googleapis.com'], value: 'AIzaSyExampleKey1234567890'),
        ]),
      );
      const withPlaceholder =
          '<tool_call>\n{"name":"run_command","arguments":{"command":"curl -H \\"k: {{secret:gemini}}\\" https://generativelanguage.googleapis.com/v1beta/models","cwd":"/workspace"}}\n</tool_call>';
      final chat = ChatController(
        ScriptedEngine([(withPlaceholder, FinishReason.eog), ('見ました', FinishReason.eog)]),
        toolRuntime: runtime,
        extraTools: () async => [shellTool],
        mcpApproval: (name, [args = const {}]) => policy.approvalRequired(name, args),
        approvalDetails: policy.approvalDetails,
      );
      await chat.send('モデル一覧を見て');
      expect(seen, isEmpty, reason: 'a placeholder waits for the user even inside the sandbox');
      final card = chat.state.pendingQuestion!.title;
      expect(card, contains('{{secret:gemini}}'), reason: 'the command as the model wrote it');
      expect(card, contains('gemini（送ってよいホスト：generativelanguage.googleapis.com）'));
      expect(card, isNot(contains('AIzaSy')));
      await chat.answer([ToolApproval.approve], null);
      expect(seen.single.arguments['command'], contains('{{secret:gemini}}'), reason: 'the tool is handed the text as written');
    });

    test('with the setting off, reading from outside changes nothing', () async {
      final ran = <String>[];
      final runtime = _Runtime((call) {
        ran.add(call is McpCall ? call.name : call.runtimeType.toString());
        return const ToolOutcome('ok', ToolActivity('Shell', 'done'));
      });
      final chat = make(ScriptedEngine([(search, FinishReason.eog), (shell, FinishReason.eog), ('終わり', FinishReason.eog)]), runtime: runtime, after: false);
      await chat.send('調べて、実行して');
      expect(ran, ['WebSearch', 'run_command']);
    });

    test('a conversation that is opened again remembers that it holds text from outside', () async {
      final runtime = _Runtime((call) => const ToolOutcome('ok', ToolActivity('Shell', 'done')));
      final first = make(ScriptedEngine([(search, FinishReason.eog), ('調べました', FinishReason.eog)]), runtime: runtime);
      await first.send('調べて');
      final saved = first.snapshot();
      final second = make(ScriptedEngine([(shell, FinishReason.eog)]), runtime: runtime)..restore(saved);
      await second.send('実行して');
      expect(second.state.task, TaskState.userWait, reason: 'the earlier search result is still in the conversation');
    });

    test('pressing 実行する shows the work at once, runs the tool, and the model goes on', () async {
      final gate = Completer<void>();
      final runtime = _Runtime((call) => const ToolOutcome('pushed', ToolActivity('MCP', 'gh: push_files')));
      final slow = _SlowRuntime(runtime, gate.future);
      final engine = ScriptedEngine([(push, FinishReason.eog), ('送りました', FinishReason.eog)]);
      final chat = make(engine, runtime: slow);
      await chat.send('送って');
      expect(chat.state.pendingQuestion, isNotNull);

      final answering = chat.answer([ToolApproval.approve], null);
      await Future<void>.delayed(Duration.zero);
      expect(chat.state.pendingQuestion, isNull, reason: 'the card is gone the moment the button is pressed');
      expect(chat.state.isGenerating, isTrue);
      expect(chat.state.progress!.stage, 'ツールを実行しています');
      expect(chat.state.progress!.detail, 'mcp_gh__push_files');
      gate.complete();
      await answering;
      expect(chat.state.messages.last.text, contains('送りました'));
      expect(chat.state.messages.expand((m) => m.activities).map((a) => a.summary), contains('gh: push_files'));
    });

    test('a tool reached through mcp_call is asked about, remembered and run as itself', () async {
      final ran = <String>[];
      final remembered = <String>[];
      final runtime = _Runtime((call) {
        ran.add(call is McpCall ? call.name : call.runtimeType.toString());
        return const ToolOutcome('pushed', ToolActivity('MCP', 'gh: push_files'));
      });
      const viaCall = '<tool_call>\n{"name":"mcp_call","arguments":{"tool":"mcp_gh__push_files","arguments":{"path":"a"}}}\n</tool_call>';
      final engine = ScriptedEngine([(viaCall, FinishReason.eog), ('送りました', FinishReason.eog)]);
      final chat = ChatController(
        engine,
        toolRuntime: runtime,
        // the server's own tool is not in the request: only mcp_call stands for it
        extraTools: () async => [ToolDefinition(name: Protocol.mcpCallName, description: 'x', parameters: Protocol.mcpCallParameters)],
        mcpApproval: (name, [args = const {}]) => name == 'mcp_gh__push_files',
        rememberTool: (name) async => remembered.add(name),
      );
      await chat.send('送って');
      expect(ran, isEmpty, reason: 'nothing runs before the user says so');
      expect(chat.state.pendingTool!.name, 'mcp_gh__push_files', reason: 'the card is for the real tool');
      expect(chat.state.pendingTool!.arguments, {'path': 'a'});
      expect(chat.state.pendingQuestion!.options, contains(ToolApproval.approveAlways), reason: 'a server tool can be remembered');

      await chat.answer([ToolApproval.approveAlways], null);
      expect(ran, ['mcp_gh__push_files']);
      expect(remembered, ['mcp_gh__push_files'], reason: 'the tool is remembered, not the wrapper');
    });

    test('mcp_call cannot reach the app\'s own tools: run_command through it is an ordinary, unknown call', () async {
      final ran = <String>[];
      final runtime = _Runtime((call) {
        ran.add(call is McpCall ? call.name : call.runtimeType.toString());
        return const ToolOutcome('x', ToolActivity('MCP', 'x'));
      });
      const sneaky = '<tool_call>\n{"name":"mcp_call","arguments":{"tool":"run_command","arguments":{"command":"ls"}}}\n</tool_call>';
      final engine = ScriptedEngine([(sneaky, FinishReason.eog), ('終わり', FinishReason.eog)]);
      final chat = ChatController(
        engine,
        toolRuntime: runtime,
        extraTools: () async => [ToolDefinition(name: Protocol.mcpCallName, description: 'x', parameters: Protocol.mcpCallParameters)],
      );
      await chat.send('実行して');
      expect(ran, ['mcp_call'], reason: 'it reaches the runtime as mcp_call, which refuses it: never as run_command');
    });

    test('「次から確認しない」 runs the tool and tells the app to remember it; 実行する alone does not', () async {
      final remembered = <String>[];
      final runtime = _Runtime((call) => const ToolOutcome('pushed', ToolActivity('MCP', 'gh: push_files')));
      final once = make(ScriptedEngine([(push, FinishReason.eog), ('済', FinishReason.eog)]), runtime: runtime, remember: (n) async => remembered.add(n));
      await once.send('送って');
      await once.answer([ToolApproval.approve], null);
      expect(remembered, isEmpty);

      final always = make(ScriptedEngine([(push, FinishReason.eog), ('済', FinishReason.eog)]), runtime: runtime, remember: (n) async => remembered.add(n));
      await always.send('送って');
      expect(always.state.pendingQuestion!.options, contains(ToolApproval.approveAlways));
      await always.answer([ToolApproval.approveAlways], null);
      expect(remembered, ['mcp_gh__push_files']);
      expect(always.state.messages.last.text, contains('済'));
    });

    test('a tool that throws does not take the chat down: the model is told it failed', () async {
      final runtime = _Runtime((call) => throw StateError('boom'));
      final engine = ScriptedEngine([(push, FinishReason.eog), ('失敗しました', FinishReason.eog)]);
      final chat = make(engine, runtime: runtime);
      await chat.send('送って');
      await chat.answer([ToolApproval.approve], null);
      expect(chat.state.error, isNull);
      expect(engine.requests.last.prompt, contains('The tool failed: Bad state: boom'));
      expect(chat.state.messages.expand((m) => m.activities).last.failed, isTrue);
      expect(chat.state.messages.last.text, contains('失敗しました'));
    });

    test('a stop pressed while the tool runs ends the reply without asking the model again', () async {
      final gate = Completer<void>();
      final runtime = _SlowRuntime(_Runtime((call) => const ToolOutcome('pushed', ToolActivity('MCP', 'gh'))), gate.future);
      final engine = ScriptedEngine([(push, FinishReason.eog), ('呼ばれないはず', FinishReason.eog)]);
      final chat = make(engine, runtime: runtime);
      await chat.send('送って');
      final answering = chat.answer([ToolApproval.approve], null);
      await Future<void>.delayed(Duration.zero);
      chat.stop();
      gate.complete();
      await answering;
      expect(engine.requests, hasLength(1), reason: 'the model was not asked again');
      expect(chat.state.task, TaskState.cancelled);
      expect(chat.isRunning, isFalse);
    });
  });

  test('a reply that is empty after thinking is asked again, and says so when it stays empty', () async {
    final retried = ScriptedEngine([('<think>考えた</think>', FinishReason.eog), ('<think></think>書けました', FinishReason.eog)]);
    final a = ChatController(retried);
    await a.send('hi');
    expect(retried.requests, hasLength(2));
    expect(a.state.messages.last.text, '書けました');
    expect(a.state.error, isNull);

    final empty = ScriptedEngine([for (var i = 0; i < 3; i++) ('<think>考えた</think>', FinishReason.eog)]);
    final failures = <String>[];
    final b = ChatController(empty, onFailure: failures.add);
    await b.send('hi');
    expect(empty.requests, hasLength(3), reason: 'once, and the retry limit (2) more');
    expect(b.state.task, TaskState.error);
    expect(b.state.error, contains('返信が空'));
    expect(b.state.messages.last.thinking, contains('考えた'), reason: 'the thinking is still there to read');
    expect(failures, hasLength(1));
  });

  test('a reply that spent its tokens on thinking says the limit was reached, and is not asked again', () async {
    final engine = ScriptedEngine([('<think>長い長い考え</think>', FinishReason.length)]);
    final chat = ChatController(engine);
    await chat.send('hi');
    expect(engine.requests, hasLength(1));
    expect(chat.state.task, TaskState.error);
    expect(chat.state.error, allOf(contains('上限'), contains('最大トークン')));
  });

  test('the files a tool showed are a reply even when the model then writes nothing', () async {
    final engine = ScriptedEngine([
      ('<tool_call>\n{"name":"web_search","arguments":{"query":"q"}}\n</tool_call>', FinishReason.eog),
      ('', FinishReason.eog),
    ]);
    final runtime = _Runtime((_) => const ToolOutcome('r', ToolActivity('Search', 'found'), shown: '### a.py'));
    final chat = ChatController(engine, toolRuntime: runtime);
    await chat.send('x');
    expect(chat.state.task, TaskState.completed);
    expect(chat.state.messages.last.text, contains('a.py'));
  });

  test('a long prompt says what the wait is for: its size, and that a device model needs minutes for it', () async {
    final engine = ScriptedEngine([('答え', FinishReason.eog)]);
    final chat = ChatController(engine);
    final stages = <String>[];
    chat.addListener(() {
      final p = chat.state.progress;
      if (p != null && (stages.isEmpty || stages.last != p.stage)) stages.add(p.stage);
    });
    await chat.send('あ' * 6000); // 18,000 bytes: 6,000 tokens and more
    final waiting = stages.firstWhere((s) => s.contains('返信を待っています'));
    expect(waiting, allOf(contains('指示は約'), contains('トークン'), contains('数分')));
    expect(waiting, matches(RegExp(r'約 \d{1,3}(,\d{3})+ トークン')));
    stages.clear();
    final short = ChatController(ScriptedEngine([('答え', FinishReason.eog)]));
    short.addListener(() {
      final p = short.state.progress;
      if (p != null && (stages.isEmpty || stages.last != p.stage)) stages.add(p.stage);
    });
    await short.send('hi');
    expect(stages, contains('モデルに送信しています（返信を待っています）'), reason: 'a short prompt keeps the plain text');
  });

  test('the progress says what the reply is doing, and counts the requests and the tools', () async {
    final engine = ScriptedEngine([
      ('<think>**検索の計画**\n語を決める</think><tool_call>\n{"name":"web_search","arguments":{"query":"kotlin"}}\n</tool_call>', FinishReason.eog),
      ('<think></think>答え', FinishReason.eog),
    ]);
    final runtime = _Runtime((_) => const ToolOutcome('r', ToolActivity('Search', 'found')));
    final chat = ChatController(engine, toolRuntime: runtime);
    final stages = <String>[];
    final details = <String>[];
    chat.addListener(() {
      final p = chat.state.progress;
      if (p == null) return;
      if (stages.isEmpty || stages.last != p.stage) stages.add(p.stage);
      details.add(p.detail);
    });
    await chat.send('調べて');

    expect(stages, containsAllInOrder(['モデルに送信しています（返信を待っています）', 'モデルが考えています', '検索しています', 'モデルが回答を書いています']));
    expect(details, contains('検索の計画'), reason: 'the heading the model wrote is shown');
    expect(details, contains('kotlin'), reason: 'the search word is shown while it runs');
    final done = chat.state.progress!;
    expect(done.running, isFalse);
    expect(done.modelRequests, 2);
    expect(done.toolRuns, 1);
    expect(done.round, 2);
    expect(done.counts, '通信 2 回 · ツール 1 回');

    // a new conversation does not carry the numbers of the last one
    chat.clear();
    expect(chat.state.progress, isNull);
  });

  test('tool loops are cut off', () async {
    const call =
        '<tool_call>\n{"name":"get_time","arguments":{}}\n</tool_call>';
    final engine = ScriptedEngine([
      for (var i = 0; i < 3; i++) (call, FinishReason.eog),
    ]);
    final runtime = _Runtime(
      (_) => const ToolOutcome('12:00', ToolActivity('Time', '12:00')),
    );
    final chat = ChatController(
      engine,
      toolRuntime: runtime,
      settings: () => const GenerationSettings(maxToolRounds: 2),
    );
    await chat.send('何時？');
    expect(chat.state.task, TaskState.error);
    expect(engine.requests, hasLength(3));
  });

  test(
    'search tool is withheld when search is off and small models get a notice',
    () async {
      final engine = ScriptedEngine([('ok', FinishReason.eog)]);
      final chat = ChatController(
        engine,
        settings: () =>
            const GenerationSettings(searchEnabled: false, modelParamsB: 1.7),
      );
      await chat.send('最新のニュースを調べて');
      expect(
        engine.requests.single.toolCallSchema!,
        isNot(contains('web_search')),
      );
      expect(chat.state.notice, isNotNull);
    },
  );

  test('a snapshot restores the conversation', () async {
    final chat = ChatController(ScriptedEngine([('こんにちは', FinishReason.eog)]));
    await chat.send('hi');
    final json = chat.snapshot().toJson();

    final other = ChatController(ScriptedEngine([('next', FinishReason.eog)]));
    other.restore(ConversationSnapshot.fromJson(json));
    expect(other.state.messages.map((m) => m.text), ['hi', 'こんにちは']);
    await other.send('続けて');
    expect(other.state.messages.last.text, 'next');
    expect(other.snapshot().nextId, 4);
  });

  test('engine errors surface in the state', () async {
    final engine = ScriptedEngine([])..failWith = 'model load failed';
    final chat = ChatController(engine);
    await chat.send('hi');
    expect(chat.state.task, TaskState.error);
    expect(chat.state.error, 'model load failed');
  });

  test('同じ道具を同じ引数で3回続けたら止まる', () async {
    const call = '{"name":"get_time","arguments":{}}';
    final engine = ScriptedEngine([
      ('<tool_call>\n$call\n</tool_call>', FinishReason.eog),
      ('<tool_call>\n$call\n</tool_call>', FinishReason.eog),
      ('<tool_call>\n$call\n</tool_call>', FinishReason.eog),
    ]);
    final chat = ChatController(
      engine,
      toolRuntime: _Runtime(
        (_) => const ToolOutcome(
          'Current time: 2026-10-21',
          ToolActivity('Time', '2026-10-21'),
        ),
      ),
    );
    await chat.send('いま何時？');
    expect(chat.state.task, TaskState.error);
    expect(chat.state.error, contains('同じ道具を同じ引数で繰り返し呼んでいます'));
    expect(engine.requests, hasLength(3));
  });

  String timeCall(String zone) => '<tool_call>\n{"name":"get_time","arguments":{"timezone":"$zone"}}\n</tool_call>';

  test('引数が違う呼び出しは、何回続いても止めない（以前は4回で「上限」になった）', () async {
    final zones = ['Asia/Tokyo', 'Europe/London', 'America/New_York', 'Asia/Seoul', 'Europe/Paris', 'Asia/Dubai', 'Australia/Sydney'];
    final engine = ScriptedEngine([
      for (final zone in zones) (timeCall(zone), FinishReason.eog),
      ('どこも調べました', FinishReason.eog),
    ]);
    final chat = ChatController(
      engine,
      toolRuntime: _Runtime((_) => const ToolOutcome('12:00', ToolActivity('Time', '12:00'))),
    );
    await chat.send('世界の時刻を調べて');
    expect(chat.state.task, isNot(TaskState.error), reason: chat.state.error);
    expect(chat.state.messages.last.text, contains('どこも調べました'));
    expect(engine.requests, hasLength(zones.length + 1));
  });

  test('同じ呼び出しは、間に別の呼び出しをはさんでも、数えて止める', () async {
    final engine = ScriptedEngine([
      (timeCall('Asia/Tokyo'), FinishReason.eog),
      (timeCall('Asia/Seoul'), FinishReason.eog),
      (timeCall('Asia/Tokyo'), FinishReason.eog),
      (timeCall('Asia/Seoul'), FinishReason.eog),
      (timeCall('Asia/Tokyo'), FinishReason.eog),
      ('ここには来ない', FinishReason.eog),
    ]);
    final chat = ChatController(
      engine,
      toolRuntime: _Runtime((_) => const ToolOutcome('12:00', ToolActivity('Time', '12:00'))),
    );
    await chat.send('時刻');
    expect(chat.state.task, TaskState.error);
    expect(chat.state.error, contains('同じ道具を同じ引数で繰り返し呼んでいます'));
    expect(engine.requests, hasLength(5));
  });

  test('上限に達したときは日本語で、どこで増やせるかを言う。0なら上限なし', () async {
    final engine = ScriptedEngine([
      (timeCall('Asia/Tokyo'), FinishReason.eog),
      (timeCall('Asia/Seoul'), FinishReason.eog),
      (timeCall('Asia/Dubai'), FinishReason.eog),
    ]);
    final capped = ChatController(
      engine,
      toolRuntime: _Runtime((_) => const ToolOutcome('12:00', ToolActivity('Time', '12:00'))),
      settings: () => const GenerationSettings(maxToolRounds: 2),
    );
    await capped.send('時刻');
    expect(capped.state.error, contains('上限（2 回）'));
    expect(capped.state.error, contains('ツール呼び出しの上限'));

    final open = ChatController(
      ScriptedEngine([
        (timeCall('Asia/Tokyo'), FinishReason.eog),
        (timeCall('Asia/Seoul'), FinishReason.eog),
        (timeCall('Asia/Dubai'), FinishReason.eog),
        ('終わり', FinishReason.eog),
      ]),
      toolRuntime: _Runtime((_) => const ToolOutcome('12:00', ToolActivity('Time', '12:00'))),
      settings: () => const GenerationSettings(maxToolRounds: 0),
    );
    await open.send('時刻');
    expect(open.state.task, isNot(TaskState.error), reason: open.state.error);
  });

  test('the thinking of each reply is kept in the history and goes back beside the next prompt, never inside it', () async {
    final engine = ScriptedEngine([
      (
        '<think>時刻を調べる</think><tool_call>\n{"name":"get_time","arguments":{}}\n</tool_call>',
        FinishReason.eog,
      ),
      ('<think>答える</think>正午です', FinishReason.eog),
    ]);
    final chat = ChatController(
      engine,
      toolRuntime: _Runtime((_) => const ToolOutcome('12:00', ToolActivity('Time', '12:00'))),
    );
    await chat.send('いま何時');

    expect(engine.requests, hasLength(2));
    expect(engine.requests.first.assistantReasoning, isEmpty);
    expect(engine.requests.last.assistantReasoning, hasLength(1));
    expect(engine.requests.last.assistantReasoning.single, contains('時刻を調べる'));
    expect(engine.requests.last.prompt, isNot(contains('時刻を調べる')), reason: 'the device model never sees old reasoning');

    final saved = chat.snapshot().history.whereType<AssistantTurn>().map((t) => t.reasoning).toList();
    expect(saved.first, contains('時刻を調べる'));
    expect(saved.last, contains('答える'));
  });
  group('a message written while the reply goes on', () {
    const search = '<tool_call>\n{"name":"web_search","arguments":{"query":"q"}}\n</tool_call>';
    final runtime = _Runtime((call) => const ToolOutcome('結果', ToolActivity('Search', 'q')));

    test('is read by the model at the next break between two tools, as a message of its own', () async {
      final gate = Completer<void>();
      final engine = ScriptedEngine([(search, FinishReason.eog), ('両方答えます', FinishReason.eog)]);
      final chat = ChatController(engine, toolRuntime: _SlowRuntime(runtime, gate.future));
      final sending = chat.send('調べて');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(chat.isRunning, isTrue);

      expect(chat.interject('  価格も教えて '), isTrue);
      expect(chat.state.queued, ['価格も教えて'], reason: 'shown under the input until the model has read it');
      expect(engine.requests, hasLength(1), reason: 'the tool that is running is not cut off');

      gate.complete();
      await sending;
      expect(chat.state.queued, isEmpty);
      expect(engine.requests, hasLength(2));
      expect(engine.requests.last.prompt, contains('価格も教えて'));
      expect(
        engine.requests.last.prompt.indexOf('結果'),
        lessThan(engine.requests.last.prompt.indexOf('価格も教えて')),
        reason: 'the tool result comes first, then the new message',
      );
      expect(
        [for (final m in chat.state.messages) (m.role, m.text)],
        [(Role.user, '調べて'), (Role.assistant, ''), (Role.user, '価格も教えて'), (Role.assistant, '両方答えます')],
      );
      expect(chat.state.messages[1].activities, hasLength(1), reason: 'the work before the break stays with its own reply');
      expect(chat.state.messages.last.activities, isEmpty);
      expect(chat.state.task, TaskState.completed);
    });

    test('when the reply ends first, it is sent as the next message', () async {
      final engine = ScriptedEngine([('一つ目', FinishReason.eog), ('二つ目', FinishReason.eog)]);
      final chat = ChatController(_Paced(engine));
      final sending = chat.send('こんにちは');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(chat.interject('もう一つ'), isTrue);
      await sending;
      expect(engine.requests, hasLength(2));
      expect(engine.requests.last.prompt, contains('もう一つ'));
      expect([for (final m in chat.state.messages) m.text], ['こんにちは', '一つ目', 'もう一つ', '二つ目']);
      expect(chat.state.queued, isEmpty);
    });

    test('nothing running: it is not taken (the screen sends it as a message); an empty text is never taken', () async {
      final chat = ChatController(ScriptedEngine(const []));
      expect(chat.interject('こんにちは'), isFalse);
      expect(chat.state.queued, isEmpty);
      final gate = Completer<void>();
      final busy = ChatController(
        ScriptedEngine([(search, FinishReason.eog), ('終', FinishReason.eog)]),
        toolRuntime: _SlowRuntime(runtime, gate.future),
      );
      final sending = busy.send('調べて');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(busy.interject('  '), isFalse);
      gate.complete();
      await sending;
    });

    test('a queued text can be taken back before the model reads it', () async {
      final gate = Completer<void>();
      final engine = ScriptedEngine([(search, FinishReason.eog), ('終', FinishReason.eog)]);
      final chat = ChatController(engine, toolRuntime: _SlowRuntime(runtime, gate.future));
      final sending = chat.send('調べて');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      chat.interject('一つ目');
      chat.interject('二つ目');
      chat.unqueue(0);
      chat.unqueue(5);
      expect(chat.state.queued, ['二つ目']);
      gate.complete();
      await sending;
      expect(engine.requests.last.prompt, isNot(contains('一つ目')));
      expect(engine.requests.last.prompt, contains('二つ目'));
    });

    test('several texts go in as one message', () async {
      final gate = Completer<void>();
      final engine = ScriptedEngine([(search, FinishReason.eog), ('終', FinishReason.eog)]);
      final chat = ChatController(engine, toolRuntime: _SlowRuntime(runtime, gate.future));
      final sending = chat.send('調べて');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      chat.interject('一つ目');
      chat.interject('二つ目');
      gate.complete();
      await sending;
      expect(chat.state.messages.where((m) => m.role == Role.user).map((m) => m.text), ['調べて', '一つ目\n\n二つ目']);
    });
  });
}

/// Answers like [inner] after a short wait, so that a test can write a message while the reply goes on.
class _Paced implements InferenceEngine {
  _Paced(this.inner);
  final ScriptedEngine inner;

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
    await Future<void>.delayed(const Duration(milliseconds: 80));
    yield* inner.generate(request);
  }
}

/// Thinks for 120 ms (a think block) and then answers; with [answer] false it thinks until stopped.
class _SlowThinker implements InferenceEngine {
  _SlowThinker({this.answer = true});
  final bool answer;
  bool stop = false;

  @override
  bool get isLoaded => true;
  @override
  Future<void> load(LoadParams params) async {}
  @override
  void cancel() => stop = true;
  @override
  Future<void> unload() async {}

  @override
  Stream<GenerationEvent> generate(GenerateRequest request) async* {
    yield const Piece('<think>考え中');
    if (answer) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      yield const Piece('</think>答えです');
    } else {
      while (!stop) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }
    yield Finished(answer ? FinishReason.eog : FinishReason.cancelled);
  }
}
