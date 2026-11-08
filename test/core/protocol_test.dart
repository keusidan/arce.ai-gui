import 'package:arce_ai/core/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final tools = [Protocol.askUser];

  test('parses a question tile', () {
    final result = ToolCallParser.parse(
      '{"name":"ask_user","arguments":{"title":"言語は？","options":["Kotlin","Java"],"multi_select":true}}',
      tools,
    );
    final call = (result as ParseOk).call as AskUser;
    expect(
      call.tile,
      const QuestionTile(title: '言語は？', options: ['Kotlin', 'Java'], allowFreeInput: false, multiSelect: true),
    );
  });

  test('rejects tools the agent may not use', () {
    expect(ToolCallParser.parse('{"name":"delete_files","arguments":{}}', tools), isA<ParseInvalid>());
  });

  test('rejects content the grammar cannot rule out', () {
    for (final body in [
      '{"name":"ask_user","arguments":{"title":" ","options":["a"]}}',
      '{"name":"ask_user","arguments":{"title":"q","options":["a","a"]}}',
      '{"name":"ask_user","arguments":{"title":"q","options":["a",""]}}',
      '{"name":"ask_user","arguments":{"title":"q","options":"a"}}',
      '{"name":"ask_user","arguments":{"title":{"x":1},"options":["a"]}}',
      'not json',
    ]) {
      expect(ToolCallParser.parse(body, tools), isA<ParseInvalid>(), reason: body);
    }
  });

  test('tool call schema restricts name and arguments per tool', () {
    final schema = Protocol.toolCallSchema(tools);
    final variant = (schema['oneOf']! as List).single as Map;
    final props = variant['properties'] as Map;
    expect((props['name'] as Map)['const'], 'ask_user');
    expect(props['arguments'], Protocol.askUser.parameters);
  });

  test('an agent without tools has no tool call schema', () {
    expect(() => Protocol.toolCallSchema([]), throwsArgumentError);
  });

  test('a tool call that is not JSON says what it looked like, so the cause can be read from the screen', () {
    final result = ToolCallParser.parse('{"name":"web_search","arguments":{"query":"a"}}{"name":"web_search"', [Protocol.webSearch]);
    expect(result, isA<ParseInvalid>());
    final reason = (result as ParseInvalid).reason;
    expect(reason, startsWith('not JSON: '));
    expect(reason, contains('{"name":"web_search","arguments":{"query":"a"}}{'));
  });

  group('delegate（分担の道具）', () {
    ParseResult parse(String arguments) => ToolCallParser.parse('{"name":"delegate","arguments":$arguments}', [Protocol.delegate]);

    test('要約とタスクを読む。revise と files も', () {
      final ok = parse('{"summary":"S","tasks":[{"title":"A","instructions":"Aを作る","files":["a.py"," "],"revise":"d2"},{"title":"B","instructions":"Bを作る"}]}') as ParseOk;
      final call = ok.call as Delegate;
      expect(call.summary, 'S');
      expect(call.tasks.map((t) => t.title), ['A', 'B']);
      expect(call.tasks.first.files, ['a.py'], reason: 'a blank file name is dropped');
      expect(call.tasks.first.revise, 'd2');
      expect(call.tasks.last.revise, isNull);
    });

    test('要約は無くてもよい。タイトルが無ければ番号で補う', () {
      final call = (parse('{"tasks":[{"instructions":"やる"}]}') as ParseOk).call as Delegate;
      expect(call.summary, isEmpty);
      expect(call.tasks.single.title, 'タスク 1');
    });

    test('指示の無いタスクと、タスクが空の依頼は受け付けない', () {
      expect(parse('{"tasks":[{"title":"A","instructions":"  "}]}'), isA<ParseInvalid>());
      expect(parse('{"tasks":[]}'), isA<ParseInvalid>());
    });

    test('仕事に id が付く（無ければ t1, t2 …、重なれば別の id）。待つ仕事は depends_on で書ける', () {
      final call = (parse('{"tasks":[{"id":"a","title":"A","instructions":"x"},{"title":"B","instructions":"y","depends_on":["a"]},{"id":"a","title":"C","instructions":"z"}]}') as ParseOk).call as Delegate;
      expect(call.tasks.map((t) => t.id), ['a', 't2', 't3'], reason: 'a repeated id becomes another job, not an error');
      expect(call.tasks[1].dependsOn, ['a']);
      expect(call.plan, isEmpty);
    });

    test('Mermaid の図の矢印は、依存として仕事に入る（depends_on と合わせる）', () {
      final call = (parse(
        '{"plan":"flowchart TD\\n  a[\\"土台\\"] --> b[\\"上物\\"]\\n  b --> c","tasks":['
        '{"id":"a","title":"土台","instructions":"x"},'
        '{"id":"b","title":"上物","instructions":"y"},'
        '{"id":"c","title":"仕上げ","instructions":"z","depends_on":["a"]}]}',
      ) as ParseOk)
          .call as Delegate;
      expect(call.plan, startsWith('flowchart TD'));
      expect(call.tasks[0].dependsOn, isEmpty);
      expect(call.tasks[1].dependsOn, ['a']);
      expect(call.tasks[2].dependsOn.toSet(), {'a', 'b'}, reason: 'the arrow b --> c and the list agree');
    });

    test('使えない図や依存は、理由を付けて断る（モデルが書き直せるように）', () {
      String reason(String json) => (parse(json) as ParseInvalid).reason;
      const t = '"tasks":[{"id":"a","title":"A","instructions":"x"},{"id":"b","title":"B","instructions":"y"}]';
      expect(reason('{"plan":"これは図ではない（記号なし）!",$t}'), contains('plan has no node'));
      expect(reason('{"plan":"a --> z",$t}'), contains("'z', which is not the id of a task"));
      expect(reason('{"plan":"a --> b\\nb --> a",$t}'), contains('wait for each other in a circle'));
      expect(reason('{"tasks":[{"id":"a","title":"A","instructions":"x","depends_on":["q"]}]}'), contains("waits for 'q'"));
      expect(reason('{"tasks":[{"id":"a","title":"A","instructions":"x","depends_on":["a"]}]}'), contains('waits for itself'));
    });

    test('道具の定義は、タスクの数に上限があり、指示を必須にする（ローカルの文法が守らせる）', () {
      final tasks = (Protocol.delegate.parameters['properties']! as Map)['tasks']! as Map;
      expect(tasks['maxItems'], Protocol.maxDelegateTasks);
      expect(((tasks['items']! as Map)['required']! as List), containsAll(['title', 'instructions']));
      expect(Protocol.toolCallSchema([Protocol.delegate, Protocol.webSearch]), isNotEmpty);
    });
  });

  group('run_command and shell_session as the model writes them', () {
    ParseResult parse(String name, String arguments, ToolDefinition tool) =>
        ToolCallParser.parse('{"name":"$name","arguments":$arguments}', [tool]);

    McpCall ok(ParseResult r) => (r as ParseOk).call as McpCall;

    test('run_command keeps the names of the secrets it asked for (they were dropped once: the card showed none and none were given)', () {
      final call = ok(parse('run_command', '{"command":"git push","secrets":[" GITHUB_TOKEN ","NPM_TOKEN","GITHUB_TOKEN"]}', Protocol.runCommand));
      expect(call.arguments['secrets'], ['GITHUB_TOKEN', 'NPM_TOKEN']);
      expect(ok(parse('run_command', '{"command":"ls"}', Protocol.runCommand)).arguments.containsKey('secrets'), isFalse);
      expect(ok(parse('run_command', '{"command":"ls","secrets":[]}', Protocol.runCommand)).arguments.containsKey('secrets'), isFalse);
      expect(parse('run_command', '{"command":"ls","secrets":"GITHUB_TOKEN"}', Protocol.runCommand), isA<ParseInvalid>());
      expect(parse('run_command', '{"command":"ls","secrets":[1]}', Protocol.runCommand), isA<ParseInvalid>());
    });

    test('shell_session start: the command, where, the secrets and the wait', () {
      final call = ok(parse('shell_session', '{"action":"start","command":" opencode ","cwd":"/workspace/app","secrets":["A"],"wait_ms":3000}', Protocol.shellSession));
      expect(call.name, 'shell_session');
      expect(call.arguments, {'action': 'start', 'command': 'opencode', 'cwd': '/workspace/app', 'secrets': ['A'], 'wait_ms': 3000});
      expect(parse('shell_session', '{"action":"start"}', Protocol.shellSession), isA<ParseInvalid>());
      expect(parse('shell_session', '{"action":"start","command":"x","cwd":"relative"}', Protocol.shellSession), isA<ParseInvalid>());
    });

    test('shell_session send: the input is typed as it is, spaces and line breaks included; keys are a list of names', () {
      final call = ok(parse('shell_session', r'{"action":"send","session":"s1","input":"  print(1)\n","keys":["Enter"," Ctrl-C "]}', Protocol.shellSession));
      expect(call.arguments['input'], '  print(1)\n');
      expect(call.arguments['keys'], ['Enter', 'Ctrl-C']);
      expect(ok(parse('shell_session', '{"action":"send","session":"s1","keys":["Up"]}', Protocol.shellSession)).arguments.containsKey('input'), isFalse);
      expect(parse('shell_session', '{"action":"send","input":"x"}', Protocol.shellSession), isA<ParseInvalid>(), reason: 'which session?');
      expect(parse('shell_session', '{"action":"send","session":"s1"}', Protocol.shellSession), isA<ParseInvalid>(), reason: 'nothing to send');
      expect(parse('shell_session', '{"action":"send","session":"s1","keys":"Enter"}', Protocol.shellSession), isA<ParseInvalid>());
    });

    test('shell_session read, stop, list; an unknown action is the model\'s to fix', () {
      expect(ok(parse('shell_session', '{"action":"read","session":"s1"}', Protocol.shellSession)).arguments, {'action': 'read', 'session': 's1'});
      expect(ok(parse('shell_session', '{"action":"stop","session":"s1"}', Protocol.shellSession)).arguments, {'action': 'stop', 'session': 's1'});
      expect(ok(parse('shell_session', '{"action":"list"}', Protocol.shellSession)).arguments, {'action': 'list'});
      for (final bad in ['{"action":"read"}', '{"action":"stop"}', '{"action":"dance"}', '{}']) {
        expect(parse('shell_session', bad, Protocol.shellSession), isA<ParseInvalid>(), reason: bad);
      }
    });
  });
}
