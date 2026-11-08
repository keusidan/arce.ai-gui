import 'dart:convert';
import 'dart:io';

import 'package:arce_ai/core/protocol.dart';
import 'package:arce_ai/mcp/mcp_client.dart';
import 'package:arce_ai/mcp/mcp_server.dart';
import 'package:arce_ai/mcp/mcp_tools.dart';
import 'package:arce_ai/services/linux_env.dart';
import 'package:arce_ai/services/shell_sessions.dart';
import 'package:flutter_test/flutter_test.dart';

import '../services/linux_env_test.dart' show FakeBridge;

/// A server that answers from a list, and records the calls it got.
class _FakeClient extends McpClient {
  _FakeClient(this.tools) : super(url: 'https://fake.example/mcp');

  final List<McpTool> tools;
  final calls = <(String, Map<String, Object?>)>[];

  @override
  Future<List<McpTool>> listTools() async => tools;

  @override
  Future<String> callTool(String name, Map<String, Object?> arguments) async {
    calls.add((name, arguments));
    return 'done: $name';
  }
}

McpTool _tool(String name, String description) => McpTool(
      name: name,
      description: description,
      parameters: {
        'type': 'object',
        'properties': {'path': {'type': 'string'}},
      },
    );

McpServerClient _server(String id, _FakeClient client, {String? name}) =>
    McpServerClient(McpServerConfig(id: id, name: name ?? id, url: 'https://fake.example/mcp'), client);

void main() {
  test('道具名はサーバー id と道具名に分けられる', () {
    final name = McpTools.toolName('github', 'create_issue');
    expect(name, 'mcp_github__create_issue');
    expect(McpTools.parseName(name), ('github', 'create_issue'));
    // a tool name may contain the separator itself: only the first one splits
    expect(McpTools.parseName('mcp_github__a__b'), ('github', 'a__b'));
    expect(McpTools.parseName('mcp_'), isNull);
    expect(McpTools.parseName('mcp___x'), isNull);
    expect(McpTools.parseName('web_search'), isNull);
  });

  test('サーバーの id に __ は入らない', () {
    final id = McpServers.idFor('My__Server', const []);
    expect(id, 'my-server');
    expect(id.contains('__'), isFalse);
  });

  test('書き込み前の確認はサーバーごとに切り替えられる', () {
    final servers = [
      McpServerClient(
        const McpServerConfig(id: 'a', name: 'A', url: 'https://a.example/mcp'),
        McpClient(url: 'https://a.example/mcp'),
      ),
      McpServerClient(
        const McpServerConfig(
          id: 'b',
          name: 'B',
          url: 'https://b.example/mcp',
          approveWrites: false,
        ),
        McpClient(url: 'https://b.example/mcp'),
      ),
    ];
    final tools = McpTools(servers);
    expect(tools.approvalRequired('mcp_a__push_files'), isTrue);
    expect(tools.approvalRequired('mcp_b__push_files'), isFalse);

    // a tool the user chose not to be asked about again is not asked about; the others still are
    final remembered = McpTools(servers, approved: {'mcp_a__push_files'});
    expect(remembered.approvalRequired('mcp_a__push_files'), isFalse);
    expect(remembered.approvalRequired('mcp_a__delete_file'), isTrue);
    // a name that cannot be remembered (a command) is not let through by the list
    expect(ToolApproval.canRemember(Protocol.runCommandName), isFalse);
    final listed = McpTools(servers, approved: {'web_search', 'mcp_nobody__push_files'});
    expect(listed.approvalRequired('mcp_a__push_files'), isTrue, reason: 'only the tool named in the list is let through');
  });

  group('on demand', () {
    // thirty tools with long descriptions: the definitions alone are thousands of tokens
    final many = [for (var i = 0; i < 30; i++) _tool('tool_$i', 'Does thing number $i. ${'It does it with great care and detail. ' * 12}')];

    test('definitions too big to send each time are replaced by the three tools that look a tool up and call it', () async {
      final client = _FakeClient(many);
      final tools = McpTools([_server('big', client, name: 'Big Server')], onDemand: true, onDemandTokens: 2000);
      final names = [for (final d in await tools.definitions()) d.name];
      expect(names, containsAll([Protocol.mcpFindName, Protocol.mcpDescribeName, Protocol.mcpCallName]));
      expect(names.where((n) => n.startsWith('mcp_big__')), isEmpty, reason: 'no definition of the server\'s own tools');
      final find = (await tools.definitions()).firstWhere((d) => d.name == Protocol.mcpFindName);
      expect(find.description, contains('big (Big Server, 30 tools)'), reason: 'the model is told that something exists');
    });

    test('small definitions, the setting off, or no tools: everything goes as before', () async {
      final few = _FakeClient([_tool('a', 'x'), _tool('b', 'y')]);
      final small = McpTools([_server('s', few)], onDemand: true, onDemandTokens: 2000);
      expect([for (final d in await small.definitions()) d.name], containsAll(['mcp_s__a', 'mcp_s__b']));
      expect([for (final d in await small.definitions()) d.name], isNot(contains(Protocol.mcpFindName)));

      final off = McpTools([_server('big', _FakeClient(many))], onDemand: false);
      expect((await off.definitions()).where((d) => d.name.startsWith('mcp_big__')), hasLength(30));

      final none = McpTools(const [], onDemand: true, onDemandTokens: 0);
      expect([for (final d in await none.definitions()) d.name], isNot(contains(Protocol.mcpFindName)));
    });

    test('a threshold of 0 means always', () async {
      final tools = McpTools([_server('s', _FakeClient([_tool('a', 'x')]))], onDemand: true, onDemandTokens: 0);
      expect([for (final d in await tools.definitions()) d.name], contains(Protocol.mcpFindName));
    });

    test('mcp_find lists the tools with a short description, or only those that match, or one server\'s', () async {
      final tools = McpTools([
        _server('a', _FakeClient([_tool('push_files', 'Push files to a repository.\nMore text.'), _tool('read_file', 'Read a file')])),
        _server('b', _FakeClient([_tool('push_notes', 'Push a note')])),
      ]);
      final all = await tools.run(const McpCall(Protocol.mcpFindName, {}));
      expect(all.response, startsWith('3 of 3 tools'));
      expect(all.response, contains('mcp_a__push_files: Push files to a repository.'));
      expect(all.response, isNot(contains('More text')), reason: 'the first line only');

      final push = await tools.run(const McpCall(Protocol.mcpFindName, {'query': 'PUSH'}));
      expect(push.response, startsWith('2 of 3 tools match "push"'));
      expect(push.response, isNot(contains('read_file')));

      final one = await tools.run(const McpCall(Protocol.mcpFindName, {'query': 'push', 'server': 'b'}));
      expect(one.response, contains('mcp_b__push_notes'));
      expect(one.response, isNot(contains('mcp_a__')));

      final none = await tools.run(const McpCall(Protocol.mcpFindName, {'query': 'zzz'}));
      expect(none.response, contains('0 of 3 tools match'));
    });

    test('what mcp_find and mcp_describe answer is cut at the length the user set', () async {
      final tools = McpTools([_server('big', _FakeClient(many))], resultMaxChars: 500);
      final found = await tools.run(const McpCall(Protocol.mcpFindName, {}));
      expect(found.response, contains('characters left out'));
      expect(found.response.length, lessThan(700));
    });

    test('mcp_describe gives the definition of one tool, and says when there is none', () async {
      final tools = McpTools([_server('a', _FakeClient([_tool('push_files', 'Push files.')]))]);
      final ok = await tools.run(const McpCall(Protocol.mcpDescribeName, {'tool': 'mcp_a__push_files'}));
      expect(ok.response, contains('name: mcp_a__push_files'));
      expect(ok.response, contains('Push files.'));
      expect(ok.response, contains('"path":{"type":"string"}'));
      expect(ok.activity.failed, isFalse);

      for (final bad in ['mcp_a__nothing', 'mcp_zzz__x', 'run_command', '']) {
        final out = await tools.run(McpCall(Protocol.mcpDescribeName, {'tool': bad}));
        expect(out.activity.failed, isTrue, reason: bad);
        expect(out.response, contains('No such tool'));
      }
    });

    test('a tool called through mcp_call runs on its server, and is asked about like itself', () async {
      final client = _FakeClient([_tool('push_files', 'Push files.')]);
      final tools = McpTools([_server('a', client)], onDemand: true, onDemandTokens: 0);
      const wrapped = McpCall(Protocol.mcpCallName, {'tool': 'mcp_a__push_files', 'arguments': {'path': 'x'}});
      final call = wrapped.unwrapped;
      expect(tools.approvalRequired(call.name, call.arguments), isTrue, reason: 'a push still waits for the user');
      final out = await tools.run(call);
      expect(client.calls.single.$1, 'push_files');
      expect(client.calls.single.$2, {'path': 'x'});
      expect(out.response, 'done: push_files');
      // a wrapper that was not turned into a real call has nothing to run
      final loose = await tools.run(const McpCall(Protocol.mcpCallName, {'tool': 'run_command'}));
      expect(loose.activity.failed, isTrue);
    });
  });

  group('secrets for commands', () {
    const token = 'ghp_ExampleTokenValue123';
    late FakeBridge bridge;
    late LinuxEnvironment env;

    McpTools make({Map<String, String> secrets = const {token: ''}, ShellSettings shell = const ShellSettings()}) {
      return McpTools(
        const [],
        shell: shell,
        secrets: secrets,
        environment: env,
        shellSupported: true,
      );
    }

    setUp(() {
      bridge = FakeBridge()..installed = true;
      env = LinuxEnvironment(bridge: bridge, android: true);
    });

    test('the model is told the names, never the values', () async {
      final tools = make(secrets: {'GITHUB_TOKEN': token, 'NPM_TOKEN': 'npm_secret_value'});
      final definition = (await tools.definitions()).firstWhere((d) => d.name == Protocol.runCommandName);
      expect(definition.description, contains('GITHUB_TOKEN, NPM_TOKEN'));
      expect(definition.description, isNot(contains(token)));
      expect(definition.description, isNot(contains('npm_secret_value')));
      final plain = (await make(secrets: {}).definitions()).firstWhere((d) => d.name == Protocol.runCommandName);
      expect(plain.description, isNot(contains('Stored secrets')));
    });

    test('a command that is given a secret is always approved first, even one that stays in the sandbox', () {
      final tools = make(secrets: {'GITHUB_TOKEN': token});
      expect(tools.approvalRequired(Protocol.runCommandName, {'command': 'ls', 'cwd': '/workspace'}), isFalse, reason: 'inside the sandbox, no secret: runs');
      expect(tools.approvalRequired(Protocol.runCommandName, {'command': 'ls', 'cwd': '/workspace', 'secrets': ['GITHUB_TOKEN']}), isTrue);
      expect(tools.approvalRequired(Protocol.runCommandName, {'command': 'ls', 'secrets': 'GITHUB_TOKEN'}), isTrue, reason: 'a malformed list asks too');
      expect(tools.approvalRequired(Protocol.runCommandName, {'command': 'ls', 'secrets': <String>[]}), isFalse);
    });

    test('the value goes to the command that asked for it, and only that; the output has it taken out', () async {
      bridge.runAnswer = {'exit': 0, 'stdout': 'GITHUB_TOKEN=$token\nNPM=npm_secret_value\n', 'stderr': '', 'elapsedMs': 5};
      final tools = make(secrets: {'GITHUB_TOKEN': token, 'NPM_TOKEN': 'npm_secret_value'});
      final out = await tools.run(const McpCall(Protocol.runCommandName, {'command': 'env', 'secrets': ['GITHUB_TOKEN']}));
      expect(bridge.lastRun!['secrets'], {'GITHUB_TOKEN': token}, reason: 'NPM_TOKEN was not asked for');
      expect(out.response, contains('[GITHUB_TOKEN]'));
      expect(out.response, isNot(contains(token)));
      expect(out.response, contains('npm_secret_value'), reason: 'a secret that was not given is not in the output to take out');
      expect(out.activity.summary, contains('秘密: GITHUB_TOKEN'));
      expect(out.activity.summary, isNot(contains(token)));
    });

    test('a command without secrets gets none', () async {
      final tools = make(secrets: {'GITHUB_TOKEN': token});
      await tools.run(const McpCall(Protocol.runCommandName, {'command': 'ls'}));
      expect(bridge.lastRun!['secrets'], isEmpty);
    });

    test('a name that is not available stops the command before it runs, and says which names are', () async {
      final tools = make(secrets: {'GITHUB_TOKEN': token});
      final out = await tools.run(const McpCall(Protocol.runCommandName, {'command': 'env', 'secrets': ['AWS_SECRET']}));
      expect(bridge.calls, isNot(contains('run')));
      expect(out.activity.failed, isTrue);
      expect(out.response, contains('AWS_SECRET'));
      expect(out.response, contains('Available: GITHUB_TOKEN'));
      expect(out.response, contains('Nothing was run'));

      final none = await make(secrets: {}).run(const McpCall(Protocol.runCommandName, {'command': 'env', 'secrets': ['X']}));
      expect(none.response, contains('The user has made none available'));

      final odd = await tools.run(const McpCall(Protocol.runCommandName, {'command': 'env', 'secrets': 'GITHUB_TOKEN'}));
      expect(odd.activity.failed, isTrue);
      expect(bridge.calls, isNot(contains('run')));
    });
  });

  group('sessions (shell_session)', () {
    const token = 'ghp_ExampleTokenValue123';
    late FakeBridge bridge;
    late LinuxEnvironment env;

    McpTools make({Map<String, String> secrets = const {}, ShellSettings shell = const ShellSettings()}) => McpTools(
          const [],
          shell: shell,
          secrets: secrets,
          environment: env,
          shellSupported: true,
          sessionManager: ShellSessionManager(bridge: bridge),
        );

    Map<String, Object?> session(String action, [Map<String, Object?> more = const {}]) => {'action': action, ...more};

    setUp(() {
      bridge = FakeBridge()..installed = true;
      env = LinuxEnvironment(bridge: bridge, android: true);
    });

    test('the tool is offered with the limits of the settings written into it', () async {
      final tools = make(shell: const ShellSettings(sessions: ShellSessionSettings(maxSessions: 2, idleMinutes: 7, cols: 100, rows: 30)));
      final definition = (await tools.definitions()).firstWhere((d) => d.name == Protocol.shellSessionName);
      expect(definition.description, contains('At most 2 sessions'));
      expect(definition.description, contains('7 minutes'));
      expect(definition.description, contains('100 columns wide and 30 rows high'));
      final properties = definition.parameters['properties'] as Map;
      expect((properties['action'] as Map)['enum'], ['start', 'send', 'read', 'stop', 'list']);
      final off = make(shell: const ShellSettings(enabled: false));
      expect([for (final d in await off.definitions()) d.name], isNot(contains(Protocol.shellSessionName)));
    });

    test('a start is judged like a command; what is typed into a session by its text; reading and stopping never ask', () {
      final tools = make();
      bool asks(Map<String, Object?> args) => tools.approvalRequired(Protocol.shellSessionName, args);
      expect(asks(session('start', {'command': 'python3', 'cwd': '/workspace'})), isFalse, reason: 'inside the sandbox');
      expect(asks(session('start', {'command': 'ls', 'cwd': '/data/data/ai.arce.app'})), isTrue, reason: 'outside it');
      expect(asks(session('start', {'command': 'cat /proc/self/root/x'})), isTrue, reason: 'a door out of the sandbox');
      expect(asks(session('start', {'command': 'git push', 'secrets': ['GITHUB_TOKEN']})), isTrue, reason: 'a secret: always');
      expect(asks(session('send', {'session': 's1', 'input': 'print(1)\n'})), isFalse);
      expect(asks(session('send', {'session': 's1', 'input': 'open("/proc/self/root/etc/x")'})), isTrue);
      expect(asks(session('send', {'session': 's1', 'keys': ['Ctrl-C']})), isFalse, reason: 'keys are not text');
      for (final quiet in ['read', 'stop', 'list']) {
        expect(asks(session(quiet, {'session': 's1'})), isFalse, reason: quiet);
      }
      final sure = make(shell: const ShellSettings(confirm: true));
      expect(sure.approvalRequired(Protocol.shellSessionName, session('start', {'command': 'python3'})), isTrue);
      expect(sure.approvalRequired(Protocol.shellSessionName, session('send', {'session': 's1', 'input': 'x'})), isTrue);
      expect(sure.approvalRequired(Protocol.shellSessionName, session('read', {'session': 's1'})), isFalse);
      final unsupported = McpTools(const [], shellSupported: false);
      expect(unsupported.approvalRequired(Protocol.shellSessionName, session('start', {'command': 'ls', 'cwd': '/etc'})), isFalse, reason: 'it cannot run at all');
    });

    test('start, send, read, stop and list run on the sessions and answer with screens', () async {
      final tools = make();
      bridge.sessionOutput.add(utf8.encode('>>> '));
      final started = await tools.run(McpCall(Protocol.shellSessionName, session('start', {'command': 'python3'})));
      expect(started.response, contains('session s1 · running'));
      expect(started.response, contains('>>>'));
      expect(started.activity.failed, isFalse);
      expect(bridge.sessionStarts.single['command'], 'python3');
      expect(bridge.sessionStarts.single['cwd'], '/workspace');

      bridge.sessionOutput.add(utf8.encode('1+1\r\n2\r\n>>> '));
      final sent = await tools.run(McpCall(Protocol.shellSessionName, session('send', {'session': 's1', 'input': '1+1\n', 'wait_ms': 100})));
      expect(sent.response, contains('2'));
      expect(utf8.decode(bridge.sessionWrites.single), '1+1\r');
      expect(bridge.sessionReads.last['waitMs'], 100);

      final read = await tools.run(McpCall(Protocol.shellSessionName, session('read', {'session': 's1'})));
      expect(read.activity.failed, isFalse);
      final listed = await tools.run(McpCall(Protocol.shellSessionName, session('list')));
      expect(listed.response, contains('s1: running'));
      final stopped = await tools.run(McpCall(Protocol.shellSessionName, session('stop', {'session': 's1'})));
      expect(stopped.response, contains('stopped'));
    });

    test('a request that cannot be served is answered with the reason, not an error', () async {
      final tools = make();
      for (final bad in [
        session('start'),
        session('send'),
        session('send', {'session': 's1'}),
        session('read'),
        session('stop'),
        session('dance'),
        session('send', {'session': 'nobody', 'input': 'x'}),
      ]) {
        final out = await tools.run(McpCall(Protocol.shellSessionName, bad));
        expect(out.activity.failed, isTrue, reason: '$bad');
      }
      expect(bridge.sessionWrites, isEmpty);
      final off = await make(shell: const ShellSettings(enabled: false)).run(McpCall(Protocol.shellSessionName, session('list')));
      expect(off.activity.failed, isTrue);
    });

    test('a secret is passed only when it was asked for and exists; the screens have its value taken out', () async {
      final tools = make(secrets: {'GITHUB_TOKEN': token});
      final unknown = await tools.run(McpCall(Protocol.shellSessionName, session('start', {'command': 'env', 'secrets': ['AWS_SECRET']})));
      expect(unknown.activity.failed, isTrue);
      expect(unknown.response, contains('Available: GITHUB_TOKEN'));
      expect(bridge.sessionStarts, isEmpty, reason: 'nothing was started');

      bridge.sessionOutput.add(utf8.encode('GITHUB_TOKEN=$token\r\n'));
      final out = await tools.run(McpCall(Protocol.shellSessionName, session('start', {'command': 'env', 'secrets': ['GITHUB_TOKEN']})));
      expect(bridge.sessionStarts.single['secrets'], {'GITHUB_TOKEN': token});
      expect(out.response, contains('[GITHUB_TOKEN]'));
      expect(out.response, isNot(contains(token)));
      expect(out.activity.summary, contains('秘密: GITHUB_TOKEN'));
    });

    test('the first start installs the environment when it is not there yet (the user approved the call)', () async {
      bridge.installed = false;
      final fresh = LinuxEnvironment(bridge: bridge, android: true, download: (url, {required connections, onProgress}) async => File('${Directory.systemTemp.path}/x'));
      final tools = McpTools(const [], environment: fresh, shellSupported: true, sessionManager: ShellSessionManager(bridge: bridge));
      final out = await tools.run(McpCall(Protocol.shellSessionName, session('start', {'command': 'python3'})));
      // the fake cannot install a real archive: what matters is that the environment was asked, not the session
      expect(bridge.calls, contains('status'));
      expect(out.activity.failed, isTrue);
      expect(bridge.sessionStarts, isEmpty);
    });
  });
}
