import 'dart:io';

import 'package:arce_ai/core/dangerous_commands.dart';
import 'package:arce_ai/core/protocol.dart';
import 'package:arce_ai/mcp/mcp_tools.dart';
import 'package:arce_ai/services/desktop_shell.dart';
import 'package:flutter_test/flutter_test.dart';

import '../services/desktop_shell_test.dart' show FakeProcess;

/// `run_command` on a PC, from the model's JSON: in the container it runs without asking (like the Android
/// environment); on the PC itself the approval mode decides, and in the automatic mode a dangerous command is
/// refused before anything runs.
void main() {
  late Directory workspace;
  late List<List<String>> started;

  setUp(() {
    workspace = Directory.systemTemp.createTempSync('arce_desktop_tool');
    started = [];
  });
  tearDown(() {
    try {
      workspace.deleteSync(recursive: true);
    } on FileSystemException {
      // the system cleans its temp folder
    }
  });

  McpTools make(DesktopShellSettings desktop, {bool confirm = false}) => McpTools(
        const [],
        shell: ShellSettings(desktop: desktop, confirm: confirm),
        desktopShell: DesktopShell(
          workspace: workspace,
          windows: false,
          run: (exe, args) async => ProcessResult(1, 0, args.first == 'container' ? 'true' : '', ''),
          start: (exe, args, {workingDirectory, environment}) async {
            started.add([exe, ...args]);
            return FakeProcess(stdout: 'done\n');
          },
        ),
      );

  McpCall command(String arguments) {
    final result = ToolCallParser.parse('{"name":"run_command","arguments":$arguments}', [Protocol.runCommand]);
    expect(result, isA<ParseOk>(), reason: arguments);
    return (result as ParseOk).call as McpCall;
  }

  test('the tool is offered on a PC, says where commands run, and there is no session tool (it needs proot)', () async {
    final inBox = (await make(const DesktopShellSettings()).definitions()).map((d) => d.name).toList();
    expect(inBox, contains('run_command'));
    expect(inBox, isNot(contains('shell_session')));
    final box = (await make(const DesktopShellSettings()).definitions()).firstWhere((d) => d.name == 'run_command');
    expect(box.description, allOf(contains('container'), contains('/workspace')));
    final host = (await make(const DesktopShellSettings(sandbox: false)).definitions()).firstWhere((d) => d.name == 'run_command');
    expect(host.description, allOf(contains('directly on the user\'s PC'), contains('refused'), contains(workspace.path)));
  });

  test('in the container: no card (unless every command is to be confirmed), and it runs there', () async {
    final call = command('{"command":"apt-get install -y ripgrep"}');
    expect(make(const DesktopShellSettings()).approvalRequired(call.name, call.arguments), isFalse);
    expect(make(const DesktopShellSettings(), confirm: true).approvalRequired(call.name, call.arguments), isTrue);
    final outcome = await make(const DesktopShellSettings()).run(call);
    expect(outcome.response, contains('done'));
    expect(started.single.first, anyOf('docker', 'podman'));
    expect(started.single, containsAllInOrder(['exec', '-i', '-w', '/workspace']));
  });

  test('on the PC, automatic: no card, and a dangerous command is refused without running anything', () async {
    final tools = make(const DesktopShellSettings(sandbox: false));
    final safe = command('{"command":"ls -la"}');
    final wipe = command('{"command":"rm -rf ~"}');
    expect(tools.approvalRequired(safe.name, safe.arguments), isFalse);
    expect(tools.approvalRequired(wipe.name, wipe.arguments), isFalse, reason: 'refused when it runs, not asked about');
    final refused = await tools.run(wipe);
    expect(refused.response, allOf(contains('Refused'), contains('nothing was run')));
    expect(refused.activity.failed, isTrue);
    expect(started, isEmpty);
    final ran = await tools.run(safe);
    expect(ran.response, contains('done'));
    expect(started.single.last, 'ls -la');
  });

  test('on the PC, every time: every command gets a card; never: none, and the list does not stop anything', () async {
    final wipe = command('{"command":"rm -rf ~"}');
    final ls = command('{"command":"ls"}');
    final always = make(const DesktopShellSettings(sandbox: false, approval: HostApproval.always));
    expect(always.approvalRequired(ls.name, ls.arguments), isTrue);
    final never = make(const DesktopShellSettings(sandbox: false, approval: HostApproval.never));
    expect(never.approvalRequired(wipe.name, wipe.arguments), isFalse);
    // with no list in the way the command reaches the program (a fake one here)
    final ran = await never.run(wipe);
    expect(ran.response, isNot(contains('Refused')));
    expect(started.single.last, 'rm -rf ~');
  });

  test('a command that is given a secret gets a card in every mode', () {
    final call = command('{"command":"gh pr list","secrets":["GH_TOKEN"]}');
    for (final d in const [
      DesktopShellSettings(),
      DesktopShellSettings(sandbox: false),
      DesktopShellSettings(sandbox: false, approval: HostApproval.never),
    ]) {
      expect(make(d).approvalRequired(call.name, call.arguments), isTrue);
    }
  });

  test('the list the settings hold is the one used', () async {
    final tools = make(const DesktopShellSettings(sandbox: false, dangerPatterns: [r'\bnpm\s+publish\b']));
    expect((await tools.run(command('{"command":"npm publish"}'))).response, contains('Refused'));
    expect((await tools.run(command('{"command":"rm -rf ~"}'))).response, isNot(contains('Refused')), reason: 'not on this list');
    expect(DangerousCommands.defaults, isNotEmpty);
  });
}
