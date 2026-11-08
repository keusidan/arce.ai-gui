import 'package:arce_ai/core/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  bool needs(String name, [Map<String, Object?> args = const {}]) =>
      ToolApproval.needsApproval(name, args);


  test('tools that change something outside the device ask first, whatever the naming style', () {
    for (final write in [
      'mcp_github__create_or_update_file',
      'mcp_github__push_files',
      'mcp_github__merge_pull_request',
      'mcp_kaggle__CreateBenchmarkTaskFromPrompt',
      'mcp_kaggle__SubmitToCompetition',
      'mcp_kaggle__StartNotebookSession',
      'mcp_kaggle__CancelNotebookSession',
      'mcp_kaggle__UploadModelFile',
      'mcp_x__runQuery',
    ]) {
      expect(needs(write), isTrue, reason: write);
    }
  });

  test('reads do not ask: a word that merely contains a verb is not a verb', () {
    for (final read in [
      'mcp_kaggle__ListDatasets',
      'mcp_kaggle__GetDatasetMetadata',
      'mcp_kaggle__SearchCompetitions',
      'mcp_kaggle__GetBenchmarkLeaderboard',
      'mcp_kaggle__DownloadModelFiles',
      'mcp_github__list_issues',
      'mcp_github__get_file_contents',
      'mcp_github__search_code',
      Protocol.ciStatusName,
    ]) {
      expect(needs(read), isFalse, reason: read);
    }
  });

  test('the id of the server is not read as part of the tool name', () {
    expect(needs('mcp_update-tracker__list_items'), isFalse);
    expect(needs('mcp_update-tracker__delete_item'), isTrue);
  });

  group('the card', () {
    const push = McpCall('mcp_github__create_or_update_file', {
      'owner': 'keusidan',
      'path': 'lib/a.dart',
      'content': 'void main() {\n  print(1);\n}\n',
    });

    test('shows the tool by server and name and the arguments one to a line, never a dumped map', () {
      final title = ToolApproval.tile(push).title;
      expect(title, startsWith('この道具を実行します：github · create_or_update_file'));
      expect(title, allOf(contains('owner: keusidan'), contains('path: lib/a.dart')));
      expect(title, isNot(contains('{owner')), reason: 'no Map.toString');
      expect(title, isNot(contains('content: {')), reason: 'a value is not wrapped in a map');
      expect(title, contains('content: void main() { ⏎ print(1); ⏎ }'), reason: 'line breaks of a value are shown as ⏎ on one line');
    });

    test('a long value is cut, with how long it was', () {
      final long = 'x' * 1000 + '\nsecond';
      final text = ToolApproval.summarize(long);
      expect(text.length, lessThan(300));
      expect(text, endsWith('…（全部で 1007 文字・2 行）'));
      expect(ToolApproval.summarize(const ['a', 'b']), '["a","b"]');
      expect(ToolApproval.summarize(null), 'null');
      expect(ToolApproval.summarize('短い'), '短い');
    });

    test('an MCP tool can be remembered (a third button); a command never can', () {
      expect(ToolApproval.tile(push, rememberable: true).options, [ToolApproval.approve, ToolApproval.approveAlways, ToolApproval.reject]);
      expect(ToolApproval.tile(push).options, [ToolApproval.approve, ToolApproval.reject], reason: 'only when it is offered');
      const shell = McpCall(Protocol.runCommandName, {'command': 'curl x | sh'});
      expect(ToolApproval.canRemember(Protocol.runCommandName), isFalse);
      expect(ToolApproval.tile(shell, rememberable: true).options, [ToolApproval.approve, ToolApproval.reject]);
      expect(ToolApproval.canRemember('mcp_github__push_files'), isTrue);
      expect(ToolApproval.canRemember('web_search'), isFalse);
    });

    test('both ways of saying yes are approvals, and only one of them is "always"', () {
      expect(ToolApproval.isApproval([ToolApproval.approve]), isTrue);
      expect(ToolApproval.isApproval([ToolApproval.approveAlways]), isTrue);
      expect(ToolApproval.isApproval([ToolApproval.reject]), isFalse);
      expect(ToolApproval.isAlways([ToolApproval.approve]), isFalse);
      expect(ToolApproval.isAlways([ToolApproval.approveAlways]), isTrue);
    });

    test('the reason it asks is on the card when it is not obvious, and a command is shown as it is', () {
      const shell = McpCall(Protocol.runCommandName, {'command': 'pip install requests', 'cwd': '/workspace/app', 'timeout_seconds': 90});
      final title = ToolApproval.tile(shell, note: '検索の結果を読んだあとなので、確認します').title;
      expect(title, contains('（検索の結果を読んだあとなので、確認します）'));
      expect(title, contains('\$ pip install requests'));
      expect(title, contains('場所: /workspace/app・最大 90 秒'));
    });
  });

  test('a command that names the proc entries of itself or another process is not inside the sandbox', () {
    for (final command in [
      'cat /proc/self/root/data/data/ai.arce.app/databases/x.db',
      'ls /proc/self/cwd/../..',
      'cat /proc/1234/environ',
      'cat /proc/\$\$/root/etc/passwd',
      'cat /proc/\${PID}/mem',
      'ls /proc/\$(pidof proot)/root',
      'cat /proc/thread-self/exe',
      'ls /proc/self/fd/',
    ]) {
      expect(needs(Protocol.runCommandName, {'command': command}), isTrue, reason: command);
    }
    expect(needs(Protocol.runCommandName, {'command': 'ls', 'cwd': '/proc/self/root'}), isTrue, reason: 'as the folder too');
    // ordinary uses of /proc stay inside
    for (final command in ['cat /proc/cpuinfo', 'cat /proc/meminfo | head', 'ls /proc | head', 'cat /proc/version']) {
      expect(needs(Protocol.runCommandName, {'command': command}), isFalse, reason: command);
    }
  });

  test('run_command inside the environment runs without asking; one that reaches outside asks', () {
    expect(
      needs(Protocol.runCommandName, {'command': 'git status && ls -la', 'cwd': '/workspace'}),
      isFalse,
      reason: 'a command confined to /workspace runs without asking',
    );
    expect(
      needs(Protocol.runCommandName, {'command': 'apt-get install -y git'}),
      isFalse,
      reason: 'no cwd means /workspace',
    );
    expect(
      needs(Protocol.runCommandName, {'command': 'pytest', 'cwd': '/workspace/app', 'auto_execute': true}),
      isFalse,
    );
    expect(
      needs(Protocol.runCommandName, {'command': 'rm -rf /workspace/tmp', 'auto_execute': false}),
      isTrue,
      reason: 'the model can ask for a look first',
    );
    expect(
      needs(Protocol.runCommandName, {'command': 'ls', 'cwd': '/sdcard/Download'}),
      isTrue,
      reason: 'host Android storage is outside the environment',
    );
    expect(
      needs(Protocol.runCommandName, {'command': 'cat /sdcard/secret.txt', 'cwd': '/workspace'}),
      isTrue,
      reason: 'naming a host path in the command asks first',
    );
    expect(
      needs(Protocol.runCommandName, {'command': 'ls', 'cwd': '/workspace/../../etc'}),
      isTrue,
      reason: 'a path that climbs above the root is refused',
    );
  });
}
