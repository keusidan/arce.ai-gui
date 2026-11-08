import 'dart:convert';
import 'dart:io' show Directory;

import 'package:http/http.dart' as http;

import '../ai/token_budget.dart';
import '../core/protocol.dart';
import '../core/secret_book.dart';
import '../core/secret_placeholders.dart';
import '../core/shell_secrets.dart';
import '../core/tool_runtime.dart';
import '../services/ci_client.dart';
import '../services/linux_env.dart';
import '../services/shell_sessions.dart';
import 'http_request_tool.dart';
import 'mcp_client.dart';
import 'mcp_server.dart';
import 'placeholder_commands.dart';
import 'show_tool.dart';

/// One configured server together with the client that talks to it.
class McpServerClient {
  const McpServerClient(this.config, this.client);
  final McpServerConfig config;
  final McpClient client;
}

/// What the app's own tools read from the settings, at the moment they are called: a changed
/// limit applies to the next command, without building anything again.
class ShellSettings {
  const ShellSettings({
    this.enabled = true,
    this.confirm = false,
    this.timeoutSeconds = 120,
    this.maxTimeoutSeconds = 600,
    this.maxOutputChars = 20000,
    this.workspaceLimitMb = 2048,
    this.rootfsUrl = defaultRootfsUrl,
    this.rootfsSha256 = defaultRootfsSha256,
    this.dns = '1.1.1.1 8.8.8.8',
    this.compatMode = false,
    this.downloadConnections = 4,
    this.sessions = const ShellSessionSettings(),
  });

  /// The Ubuntu Base 24.04.5 for arm64 that was checked on 2026-10-28 (29,936,675 bytes; the
  /// SHA-256 matches the `SHA256SUMS` beside it and a real download).
  static const defaultRootfsUrl =
      'https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.5-base-arm64.tar.gz';
  static const defaultRootfsSha256 = 'a91d5a93010193712d346d761372b7c9db6dfcf093893161c64ca107f05914f2';

  /// Offer `run_command` at all.
  final bool enabled;

  /// Ask before every command, even one that stays inside the environment. Off by default: a
  /// command that stays inside the sandbox runs without asking.
  final bool confirm;
  final int timeoutSeconds;
  final int maxTimeoutSeconds;
  final int maxOutputChars;

  /// 0 means no limit.
  final int workspaceLimitMb;
  final String rootfsUrl;
  final String rootfsSha256;

  /// Nameservers separated by spaces.
  final String dns;
  final bool compatMode;
  final int downloadConnections;

  /// What a session (a program that is talked to) may do.
  final ShellSessionSettings sessions;

  LinuxConfig get config => LinuxConfig(
    rootfsUrl: rootfsUrl.trim(),
    rootfsSha256: rootfsSha256.trim(),
    dns: [
      for (final server in dns.split(RegExp(r'\s+')))
        if (server.trim().isNotEmpty) server.trim(),
    ],
    workspaceLimitMb: workspaceLimitMb,
    compatMode: compatMode,
    connections: downloadConnections,
  );

  /// The tool without the settings: the defaults, which are what 0.12.0 shipped with.
  static const defaults = ShellSettings();
}

/// The tools of every MCP server the user configured, as the chat sees them.
///
/// A server may publish a name the app already has (`search`, `get_time` ...), so every tool is
/// prefixed with its server: `mcp_<serverId>__<tool>`. The prefix is stripped again before the
/// call goes out and routed to that server only.
///
/// `tools/list` is cached per server for the life of the [cache] map, so a chat turn does not ask
/// every server again. A server that fails is left out for this turn and tried again next time.
///
/// The app's own tools (`run_command`, `ci_status`) are offered from here too, because this is
/// where the chat already looks for calls it cannot run itself: `ToolCallParser` turns every tool
/// the turn allows into an [McpCall], and this class runs those on the device instead of sending
/// them to a server.
class McpTools {
  McpTools(
    this._servers, {
    Map<String, List<McpTool>>? cache,
    this.ciToken = '',
    this.approved = const {},
    this.shell = ShellSettings.defaults,
    this.secrets = const {},
    this.onDemand = false,
    this.onDemandTokens = 2000,
    this.resultMaxChars = 15000,
    LinuxEnvironment? environment,
    bool? shellSupported,
    ShellSessionManager? sessionManager,
    this.secretBook = const EmptySecretBook(),
    this.httpRequest = const HttpRequestSettings(),
    this.httpClient,
    this.show = const ShowSettings(),
    this.workspaceDirectory,
    this.showProbe,
  })  : _cache = cache ?? {},
        _environment = environment ?? shellEnvironment,
        _shellSupported = shellSupported ?? LinuxEnvironment.supported,
        _sessions = sessionManager ?? shellSessions;

  final ShellSessionManager _sessions;

  /// Every secret by id: what a model may name in `{{secret:ID}}`. Never a value of its own.
  final SecretBook secretBook;

  /// What `http_request` reads from the settings, and the client it uses (a test gives its own).
  final HttpRequestSettings httpRequest;
  final http.Client? httpClient;

  /// What `show` reads from the settings, the workspace folder it may show files of (null: none on this device), and
  /// how a test answers "does anything listen on this port".
  final ShowSettings show;
  final Directory? workspaceDirectory;
  final Future<bool> Function(int port)? showProbe;

  ShowTool get _show => ShowTool(settings: show, workspace: workspaceDirectory, probe: showProbe);

  HttpRequestTool get _http => HttpRequestTool(book: secretBook, settings: httpRequest, client: httpClient);

  /// The sessions of the whole app, like [shellEnvironment]: a session outlives the call that began it.
  static final ShellSessionManager shellSessions = ShellSessionManager();

  /// The environment commands run in, and whether this system has one (a test says so for itself).
  final LinuxEnvironment _environment;
  final bool _shellSupported;

  final List<McpServerClient> _servers;
  final Map<String, List<McpTool>> _cache;

  /// The token `ci_status` reads GitHub Actions with: the one typed for the GitHub server, which is
  /// read only here. Empty means the public API, which answers for a public repository.
  final String ciToken;

  /// What `run_command` may do (the Linux environment's settings).
  final ShellSettings shell;

  /// The secrets a command may be given: the name it sees -> the value (only those the user set and
  /// has a value for). The model is told the names; a value never leaves here except into the one
  /// command the user approved, and is taken out of what that command printed.
  final Map<String, String> secrets;

  /// Offer `mcp_find` / `mcp_describe` / `mcp_call` instead of every server's tools when those
  /// definitions would be bigger than [onDemandTokens] (0: always): the model looks a tool up when it
  /// needs one, and the request stays small.
  final bool onDemand;
  final int onDemandTokens;

  /// How long what `mcp_find` and `mcp_describe` answer may be, in characters.
  final int resultMaxChars;

  static const prefix = 'mcp_';
  static const separator = '__';

  /// One environment for the whole app: the workspace is shared by every chat, the Android side runs
  /// one command at a time, and the settings screen shows this same state.
  static final LinuxEnvironment shellEnvironment = LinuxEnvironment();

  static String toolName(String serverId, String tool) =>
      '$prefix$serverId$separator$tool';

  /// Splits `mcp_<id>__<tool>`; null when [name] is not an MCP tool of this shape.
  static (String, String)? parseName(String name) {
    if (!name.startsWith(prefix)) return null;
    final rest = name.substring(prefix.length);
    final at = rest.indexOf(separator);
    if (at <= 0 || at + separator.length >= rest.length) return null;
    return (rest.substring(0, at), rest.substring(at + separator.length));
  }

  static String _cacheKey(McpServerConfig config) =>
      '${config.id}|${config.url}';

  /// The verbs of tools that change something outside the device. Those are shown to the user as
  /// one card and run only when they approve: a chat message must not push code to a repository
  /// without a second look.
  static bool needsApproval(String name, [Map<String, Object?> arguments = const {}]) =>
      ToolApproval.needsApproval(name, arguments);

  /// Tools the user chose not to be asked about again (only MCP tools can be: see [ToolApproval.canRemember]).
  final Set<String> approved;

  /// Whether [name] needs an approval card, following the server's own setting as well.
  bool approvalRequired(String name, [Map<String, Object?> arguments = const {}]) {
    // ci_status only reads GitHub: nothing to approve
    if (name == Protocol.ciStatusName) return false;
    // B: a command that stays inside the sandbox (/workspace and the
    // Ubuntu rootfs) runs without asking; only one that reaches the device outside it asks.
    if (name == Protocol.runCommandName) {
      if (!shell.enabled || !_shellSupported) return false;
      // a command that is given a secret is approved every time, whatever it does: it can send it anywhere
      if ((ShellSecrets.names(arguments['secrets']) ?? const ['?']).isNotEmpty) return true;
      // so is one that writes a placeholder (path B): the card then says where each secret may go
      if (PlaceholderCommands.idsIn('${arguments['command'] ?? ''}').isNotEmpty) return true;
      if (shell.confirm) return true;
      return !SandboxPolicy.isInsideSandbox(McpCall(name, arguments));
    }
    if (name == Protocol.shellSessionName) return _sessionNeedsApproval(arguments);
    if (name == Protocol.httpRequestName) return _http.needsApproval(arguments);
    // show only puts a card in the reply: the page opens when the user presses its button
    if (name == Protocol.showName) return false;
    final parsed = parseName(name);
    if (parsed == null) return false;
    final server = _serverById(parsed.$1);
    if (server == null) return false;
    if (approved.contains(name) && ToolApproval.canRemember(name)) return false;
    return server.config.approveWrites && needsApproval(name, arguments);
  }

  /// A session is judged like a command: the one that is started by its command, what is typed into it by
  /// the text (it may be a shell, or a program that runs what it is told). Reading, stopping and listing
  /// change nothing.
  bool _sessionNeedsApproval(Map<String, Object?> arguments) {
    if (!shell.enabled || !_shellSupported) return false;
    final action = '${arguments['action'] ?? ''}';
    if (action != 'start' && action != 'send') return false;
    if ((ShellSecrets.names(arguments['secrets']) ?? const ['?']).isNotEmpty) return true;
    final text = action == 'start' ? '${arguments['command'] ?? ''}' : '${arguments['input'] ?? ''}';
    // a placeholder is approved every time, in the command that starts a session and in a line typed into it
    if (PlaceholderCommands.idsIn(text).isNotEmpty) return true;
    if (shell.confirm) return true;
    // only keys were pressed (Ctrl-C, an arrow): there is no text to judge
    if (action == 'send' && text.trim().isEmpty) return false;
    final cwd = action == 'start' ? '${arguments['cwd'] ?? '/workspace'}' : '/workspace';
    return !SandboxPolicy.isInsideSandbox(McpCall(Protocol.runCommandName, {'command': text, 'cwd': cwd}));
  }

  /// What the approval card shows under a command that uses secrets by placeholder (path B): which
  /// secrets, where each may be sent, the addresses written in the command, and a warning when there is none.
  /// Empty for anything else, and for a command that will be refused (the card is then for the rest of the call).
  String approvalDetails(String name, Map<String, Object?> arguments) {
    String text;
    Set<String>? only;
    if (name == Protocol.runCommandName) {
      text = '${arguments['command'] ?? ''}';
    } else if (name == Protocol.shellSessionName) {
      final action = '${arguments['action'] ?? ''}';
      if (action == 'start') {
        text = '${arguments['command'] ?? ''}';
      } else if (action == 'send') {
        text = '${arguments['input'] ?? ''}';
        only = _sessions.idsOf('${arguments['session'] ?? ''}');
      } else {
        return '';
      }
    } else {
      return '';
    }
    final plan = _plan(text, arguments['secrets'], onlyIds: only);
    if (plan.problem != null) return '';
    return PlaceholderCommands.cardDetails(plan.prepared) ?? '';
  }

  /// A command (or a line typed into a session) with the secrets it uses dealt with: the ones named in
  /// [asked] (`secrets`: the names of stored values, passed as variables of that name; or ids, passed as
  /// `ARCE_SECRET_<ID>`) and the ones written in [text] as `{{secret:ID}}`. With [onlyIds] only those may be
  /// used (a session's process has the ones it was started with).
  _SecretPlan _plan(String text, Object? asked, {Set<String>? onlyIds}) {
    final plain = PreparedCommand(command: text);
    final names = ShellSecrets.names(asked);
    if (names == null) return _SecretPlan(plain, problem: '"secrets" must be a list of names.');
    final legacy = <String, String>{};
    final ids = <String>[];
    final unknown = <String>[];
    for (final name in names) {
      final value = secrets[name];
      if (value != null) {
        legacy[name] = value;
      } else if (secretBook.byId(name) != null) {
        ids.add(name);
      } else {
        unknown.add(name);
      }
    }
    if (unknown.isNotEmpty) {
      final available = {...secrets.keys, for (final e in secretBook.entries) if (e.modelMayUse) e.id};
      return _SecretPlan(
        plain,
        problem: 'No secret is available under the name ${unknown.join(', ')}. '
            '${available.isEmpty ? 'The user has made none available.' : 'Available: ${available.join(', ')}.'} '
            'Nothing was run.',
        unknown: unknown,
      );
    }
    final prepared = PlaceholderCommands.prepare(
      text,
      secretBook,
      extraIds: ids,
      onlyIds: onlyIds,
      allowInsecure: httpRequest.allowInsecure,
    );
    if (prepared.problem != null) return _SecretPlan(prepared, legacy: legacy, problem: prepared.problem);
    // a variable the user named and one the app makes from an id must not be the same name with two values
    for (final entry in prepared.env.entries) {
      final other = legacy[entry.key];
      if (other != null && other != entry.value) {
        return _SecretPlan(
          prepared,
          legacy: legacy,
          problem: 'The variable ${entry.key} would be given two different values. Nothing was run.',
        );
      }
    }
    return _SecretPlan(prepared, legacy: legacy);
  }

  McpServerClient? _serverById(String id) {
    for (final server in _servers) {
      if (server.config.id == id) return server;
    }
    return null;
  }

  Future<List<McpTool>?> _toolsOf(McpServerClient server) async {
    final key = _cacheKey(server.config);
    final cached = _cache[key];
    if (cached != null) return cached;
    try {
      final tools = await server.client.listTools();
      _cache[key] = tools;
      return tools;
    } on Object {
      // an unreachable server yields no tools; the chat still works this turn
      _cache.remove(key);
      return null;
    }
  }

  /// The tools of all reachable servers in the app's own form. When they are too big to send each
  /// time (see [onDemand]), the three tools that look them up and call them stand in for them.
  Future<List<ToolDefinition>> definitions() async {
    final out = <ToolDefinition>[
      if (shell.enabled && _shellSupported) _runCommandFor(shell, secrets.keys.toList(), _usableSecrets, httpRequest.enabled),
      if (shell.enabled && _shellSupported) _shellSessionFor(shell, _usableSecrets),
      ...[?_http.definition()],
      ...[?_show.definition()],
      Protocol.ciStatus,
    ];
    final reachable = <(McpServerClient, List<McpTool>)>[];
    for (final server in _servers) {
      final tools = await _toolsOf(server);
      if (tools != null) reachable.add((server, tools));
    }
    final total = TokenBudget.estimate(_definitionText([for (final (_, tools) in reachable) ...tools]));
    final lazy = onDemand && reachable.any((r) => r.$2.isNotEmpty) && (onDemandTokens <= 0 || total > onDemandTokens);
    if (lazy) return [...out, ..._onDemandTools(reachable)];
    for (final (server, tools) in reachable) {
      for (final tool in tools) {
        out.add(
          ToolDefinition(
            name: toolName(server.config.id, tool.name),
            description: tool.description.trim().isEmpty
                ? 'MCP tool ${tool.name} (${server.config.name})'
                : '${tool.description.trim()}\n(MCP tool: ${tool.name} / server: ${server.config.name})',
            parameters: tool.parameters,
          ),
        );
      }
    }
    return out;
  }

  /// `mcp_find`, `mcp_describe` and `mcp_call`, with the servers written into the first one's description
  /// (the model cannot look up what exists unless it is told that something does).
  List<ToolDefinition> _onDemandTools(List<(McpServerClient, List<McpTool>)> reachable) {
    final servers = [
      for (final (server, tools) in reachable)
        '${server.config.id} (${server.config.name}, ${tools.length} tools)',
    ].join('; ');
    return [
      ToolDefinition(
        name: Protocol.mcpFindName,
        description: 'Look for a tool of the MCP servers that are connected: $servers. Without query it lists every '
            'tool with a short description; with query, only the tools whose name or description contains it '
            '(case does not matter); server limits it to one server by its id. The tools are not described '
            'in this request: find one here, read its definition with mcp_describe, then call it with mcp_call.',
        parameters: Protocol.mcpFindParameters,
      ),
      ToolDefinition(
        name: Protocol.mcpDescribeName,
        description: 'The full description and parameters of one MCP tool, by the name mcp_find gave. '
            'Read it before the first call to a tool.',
        parameters: Protocol.mcpDescribeParameters,
      ),
      ToolDefinition(
        name: Protocol.mcpCallName,
        description: 'Call an MCP tool by the name mcp_find gave, with arguments as its definition says. A tool that '
            'changes something outside the device is shown to the user for approval first.',
        parameters: Protocol.mcpCallParameters,
      ),
    ];
  }

  /// Human-readable list for the settings screen, for one server.
  Future<String> describe(String id) async {
    final server = _serverById(id);
    if (server == null) return 'サーバーが設定されていません';
    _cache.remove(_cacheKey(server.config));
    final tools = await _toolsOf(server);
    if (tools == null) return '接続できません';
    if (tools.isEmpty) return 'ツールが1つも公開されていません';
    return '${tools.length} 個のツール（毎回の送信に約 ${TokenBudget.estimate(_definitionText(tools))} トークン）: ${tools.map((t) => t.name).join(', ')}';
  }

  /// What the tools of one server add to every request, as text: the tokens are counted from it.
  static String _definitionText(List<McpTool> tools) => [
        for (final tool in tools) '${tool.name} ${tool.description} ${jsonEncode(tool.parameters)}',
      ].join('\n');

  /// How many tokens the tools of server [id] add to every request; null when it cannot be reached.
  Future<int?> overheadTokens(String id) async {
    final server = _serverById(id);
    if (server == null) return null;
    final tools = await _toolsOf(server);
    return tools == null ? null : TokenBudget.estimate(_definitionText(tools));
  }

  Future<ToolOutcome> run(McpCall call) async {
    if (call.name == Protocol.ciStatusName) return _runCiStatus(call.arguments);
    if (call.name == Protocol.shellSessionName && _shellSupported) return _runSession(call.arguments);
    if (call.name == Protocol.httpRequestName) return _http.run(call.arguments);
    if (call.name == Protocol.showName) return _show.run(call.arguments);
    if (call.name == Protocol.mcpFindName) return _find(call.arguments);
    if (call.name == Protocol.mcpDescribeName) return _describeTool(call.arguments);
    if (call.name == Protocol.mcpCallName) {
      // the chat turns a good mcp_call into the server's own call before it gets here
      return const ToolOutcome(
        'mcp_call needs "tool": the full name of an MCP tool, as mcp_find lists it (mcp_<server>__<tool>).',
        ToolActivity('MCP', 'mcp_call の道具名が読めませんでした', failed: true),
      );
    }
    if (call.name == Protocol.runCommandName && _shellSupported) {
      return _runShell(call.arguments);
    }
    final parsed = parseName(call.name);
    final server = parsed == null ? null : _serverById(parsed.$1);
    if (parsed == null || server == null) {
      return ToolOutcome(
        'That MCP server is not configured any more, so this tool cannot run.',
        const ToolActivity('MCP', 'MCPサーバーが見つかりません', failed: true),
      );
    }
    final tool = parsed.$2;
    try {
      final text = await server.client.callTool(tool, call.arguments);
      return ToolOutcome(
        text,
        ToolActivity('MCP', '${server.config.name}: $tool を実行'),
      );
    } catch (e) {
      return ToolOutcome(
        'The MCP tool failed: $e',
        ToolActivity(
          'MCP',
          '${server.config.name}: $tool に失敗: $e',
          failed: true,
        ),
      );
    }
  }

  // ---------------------------------------------------------------- on demand

  static String _firstLine(String text, int max) {
    final line = text.trim().split('\n').first.trim();
    return line.length <= max ? line : '${line.substring(0, max - 1)}…';
  }

  String _cut(String text) => text.length <= resultMaxChars
      ? text
      : '${text.substring(0, resultMaxChars)}\n[… ${text.length - resultMaxChars} characters left out]';

  /// `mcp_find`: the tools that match, as lines of `name: description`.
  Future<ToolOutcome> _find(Map<String, Object?> arguments) async {
    final query = '${arguments['query'] ?? ''}'.trim().toLowerCase();
    final only = '${arguments['server'] ?? ''}'.trim();
    final lines = <String>[];
    var total = 0;
    final unreachable = <String>[];
    for (final server in _servers) {
      if (only.isNotEmpty && server.config.id != only) continue;
      final tools = await _toolsOf(server);
      if (tools == null) {
        unreachable.add(server.config.name);
        continue;
      }
      for (final tool in tools) {
        total++;
        final name = toolName(server.config.id, tool.name);
        if (query.isNotEmpty && !'${tool.name} ${tool.description}'.toLowerCase().contains(query)) continue;
        final about = _firstLine(tool.description, 140);
        lines.add(about.isEmpty ? name : '$name: $about');
      }
    }
    final head = '${lines.length} of $total tools${query.isEmpty ? '' : ' match "$query"'}'
        '${unreachable.isEmpty ? '' : '. Not reachable: ${unreachable.join(', ')}'}';
    if (lines.isEmpty) {
      return ToolOutcome(
        '$head. Try another word, or call mcp_find without query to list everything.',
        ToolActivity('MCP', '道具を探しました（${query.isEmpty ? 'すべて' : query}）: 該当なし'),
      );
    }
    return ToolOutcome(
      _cut('$head:\n${lines.join('\n')}'),
      ToolActivity('MCP', '道具を探しました（${query.isEmpty ? 'すべて' : query}）: ${lines.length} 件'),
    );
  }

  /// `mcp_describe`: one tool's description and parameters.
  Future<ToolOutcome> _describeTool(Map<String, Object?> arguments) async {
    final name = '${arguments['tool'] ?? ''}'.trim();
    final parsed = parseName(name);
    final server = parsed == null ? null : _serverById(parsed.$1);
    if (parsed == null || server == null) {
      return ToolOutcome(
        'No such tool: "$name". Use the name as mcp_find lists it (mcp_<server>__<tool>).',
        ToolActivity('MCP', '道具が見つかりません: $name', failed: true),
      );
    }
    final tools = await _toolsOf(server);
    McpTool? tool;
    for (final candidate in tools ?? const <McpTool>[]) {
      if (candidate.name == parsed.$2) tool = candidate;
    }
    if (tool == null) {
      return ToolOutcome(
        tools == null ? 'The server ${server.config.name} cannot be reached.' : 'No such tool: "$name".',
        ToolActivity('MCP', '道具が見つかりません: $name', failed: true),
      );
    }
    final text = 'name: $name\n${tool.description.trim()}\nparameters (JSON Schema): ${jsonEncode(tool.parameters)}';
    return ToolOutcome(_cut(text), ToolActivity('MCP', '定義を読みました: ${tool.name}'));
  }

  // ---------------------------------------------------------------- ci_status

  /// Reads GitHub Actions for the model: the newest runs of a branch, or the jobs of one run with
  /// the steps that failed. The GitHub MCP server has no Actions tools, so this reads the REST API.
  Future<ToolOutcome> _runCiStatus(Map<String, Object?> arguments) async {
    final repository = '${arguments['repository'] ?? ''}'.trim();
    final branch = '${arguments['branch'] ?? ''}'.trim();
    final limitWanted = arguments['limit'];
    final limit = (limitWanted is num ? limitWanted.toInt() : 10).clamp(1, 30);
    final runId = arguments['run_id'];
    try {
      final client = CiClient(token: ciToken);
      if (runId is num) {
        final jobs = await client.jobs(runId.toInt(), repository: repository);
        final failed = jobs.where((j) => j.failed).toList();
        final buffer = StringBuffer('Run ${runId.toInt()} のジョブ（${jobs.length} 件、失敗 ${failed.length} 件）:\n');
        for (final job in jobs) {
          buffer.writeln('- ${job.describe()}');
        }
        if (jobs.isNotEmpty && failed.isEmpty && jobs.every((j) => j.status == 'completed')) {
          buffer.writeln('→ すべて成功しました。');
        }
        return ToolOutcome(
          buffer.toString().trimRight(),
          ToolActivity('CI', 'Run ${runId.toInt()}: ジョブ ${jobs.length} 件（失敗 ${failed.length} 件）', failed: failed.isNotEmpty),
        );
      }
      final runs = await client.runs(branch: branch, repository: repository, limit: limit);
      if (runs.isEmpty) {
        return const ToolOutcome('この条件のワークフローの実行はありませんでした。', ToolActivity('CI', '実行なし'));
      }
      final buffer = StringBuffer('直近の実行（${runs.length} 件${branch.isEmpty ? '' : '、ブランチ $branch'}）:\n');
      for (final run in runs) {
        buffer.writeln('- ${run.describe()}${run.url == null ? '' : '  ${run.url}'}');
      }
      buffer.writeln('失敗した実行は run_id を渡すと、失敗したステップまで出します。');
      final red = runs.where((r) => r.conclusion == 'failure' || r.conclusion == 'timed_out').length;
      return ToolOutcome(
        buffer.toString().trimRight(),
        ToolActivity('CI', '直近 ${runs.length} 件（赤 $red 件）', failed: red > 0),
      );
    } catch (e) {
      return ToolOutcome(
        'CI を読めませんでした: $e',
        ToolActivity('CI', '読めませんでした: $e', failed: true),
      );
    }
  }

  // ---------------------------------------------------------------- run_command

  /// The tool, with what the settings allow written into its description: the model cannot look
  /// the limits up, so they are said here.
  static ToolDefinition _runCommandFor(
    ShellSettings s,
    List<String> secretNames, [
    List<SecretInfo> usable = const [],
    bool http = false,
  ]) => ToolDefinition(
    name: Protocol.runCommandName,
    description:
        'Run one shell command in the Linux environment (Ubuntu 24.04, arm64) that lives inside this '
        'app, in the root file system under proot. It is a pseudo root, not a sandbox, and there is no '
        'systemd. /workspace is shared by every chat and kept between them'
        '${s.workspaceLimitMb > 0 ? ' (up to ${s.workspaceLimitMb} MB)' : ''}; HOME is /workspace/home. '
        'apt, pip (use --user) and git work, and there is no switch for the network. '
        'Commands run one at a time and cannot ask for input. The output is cut when it is long, and '
        'the command is stopped after ${s.timeoutSeconds} seconds by default or when it runs longer '
        'than timeout_seconds (at most ${s.maxTimeoutSeconds}), or when it fills the workspace. '
        'The first command installs the environment (about 30 MB, a few minutes) if the user has not '
        'done it yet.${s.confirm ? ' The user approves every command first.' : ''}'
        '${secretNames.isEmpty ? '' : ' Stored secrets you may ask for, by name, in secrets (the command then gets each as an environment variable of that name, the user approves that command every time, and you never see the value): ${secretNames.join(', ')}.'}'
        '${_placeholderHint(usable, http: http)}',
    parameters: Protocol.runCommand.parameters,
  );

  /// The secrets a model may name in `{{secret:ID}}`, each with the hosts it may go to (ids and hosts, never values).
  List<SecretInfo> get _usableSecrets => [for (final e in secretBook.entries) if (e.unusableReason == null) e];

  /// What the tool descriptions add about the placeholders that can be used now; nothing when there are none.
  static String _placeholderHint(List<SecretInfo> usable, {bool http = false}) => usable.isEmpty
      ? ''
      : ' Secrets you may write as {{secret:ID}} in the command (id → the hosts it may be sent to): '
          '${[for (final e in usable) '${e.id} → ${e.hosts.join(', ')}'].join('; ')}. '
          'The app puts the value in only at the moment of use, rejects a command that writes another address '
          'with one of them (and says "nothing was run"), and the user approves such a command every time; '
          'write the whole https:// address in the command so that it can be checked. '
          '${http ? 'For a plain call to an API use http_request instead: the app sends it and the key can only go to its own host. ' : ''}'
          'A script written with a here-document reads the key from the variable ARCE_SECRET_<ID in capitals, - as _> '
          '({{secret:ID}} is not replaced inside the here-document, so that the key is never written to a file).';

  /// The session tool, with what the settings allow written into its description.
  static ToolDefinition _shellSessionFor(ShellSettings s, [List<SecretInfo> usable = const []]) => ToolDefinition(
    name: Protocol.shellSessionName,
    description: '${Protocol.shellSession.description} '
        'At most ${s.sessions.maxSessions} sessions run at once; one that nobody uses for '
        '${s.sessions.idleMinutes == 0 ? 'ever' : '${s.sessions.idleMinutes} minutes'} '
        '${s.sessions.idleMinutes == 0 ? 'is kept' : 'is stopped'}. The terminal is ${s.sessions.cols} columns wide and '
        '${s.sessions.rows} rows high. The user approves a session that reaches outside the sandbox, one given a '
        'secret, and what is typed into a session in the same cases. In input, {{secret:ID}} becomes a reference '
        'to the environment variable (right for a shell); a program that is not a shell reads ARCE_SECRET_<ID> itself.'
        '${s.confirm ? ' The user approves every start and every input first.' : ''}'
        '${_placeholderHint(usable)}',
    parameters: Protocol.shellSession.parameters,
  );

  /// `shell_session`: start, send, read, stop, list. Every answer the model reads is a screen.
  Future<ToolOutcome> _runSession(Map<String, Object?> arguments) async {
    ToolOutcome failed(String reason) => ToolOutcome(reason, ToolActivity('Shell', reason, failed: true));
    if (!shell.enabled) return failed('The Linux environment is turned off in the settings.');
    final action = '${arguments['action'] ?? ''}'.trim();
    final settings = shell.sessions;
    final id = '${arguments['session'] ?? ''}'.trim();
    final waited = arguments['wait_ms'];
    final waitMs = waited is num ? waited.toInt().clamp(0, settings.maxWaitMs).toInt() : null;
    try {
      switch (action) {
        case 'start':
          final command = '${arguments['command'] ?? ''}'.trim();
          if (command.isEmpty) return failed('start needs a command.');
          final plan = _plan(command, arguments['secrets']);
          if (plan.problem != null) return failed(plan.problem!);
          // what runs has a reference to a variable where the model wrote a placeholder; the model, the card and
          // the log keep what it wrote
          final given = plan.env;
          final config = shell.config;
          if (!_environment.ready) {
            await _environment.refresh(config);
            if (!_environment.ready) await _environment.install(config);
          }
          final view = await _sessions.start(
            command: plan.command,
            cwd: '${arguments['cwd'] ?? '/workspace'}'.trim(),
            settings: settings,
            workspaceLimitBytes: config.workspaceLimitBytes,
            noSeccomp: config.compatMode,
            secrets: given,
            idValues: plan.prepared.idValues,
            label: command,
            waitMs: waitMs,
          );
          // the manager takes the values out of every screen it hands back, from this one on
          return ToolOutcome(
            view.describe(),
            ToolActivity('Shell', 'セッション ${view.id}: \$ $command${plan.secretNote}'),
          );
        case 'send':
          final input = '${arguments['input'] ?? ''}';
          final keys = arguments['keys'];
          if (id.isEmpty) return failed('send needs "session".');
          if (input.isEmpty && (keys is! List || keys.isEmpty)) return failed('send needs input or keys.');
          // a placeholder in what is typed is allowed for the secrets this session was started with: its process
          // has them, and no others
          final plan = _plan(input, null, onlyIds: _sessions.idsOf(id));
          if (plan.problem != null) return failed(plan.problem!);
          final view = await _sessions.send(id, text: plan.command, keys: [if (keys is List) for (final k in keys) '$k'], waitMs: waitMs);
          return ToolOutcome(
            view.describe(),
            ToolActivity('Shell', 'セッション $id に入力: ${_shorten(input.isEmpty ? '(キー)' : input)}${plan.secretNote}'),
          );
        case 'read':
          if (id.isEmpty) return failed('read needs "session".');
          final view = await _sessions.read(id, waitMs: waitMs);
          return ToolOutcome(view.describe(), ToolActivity('Shell', 'セッション $id の画面を読みました'));
        case 'stop':
          if (id.isEmpty) return failed('stop needs "session".');
          await _sessions.stop(id);
          return ToolOutcome('Session $id was stopped.', ToolActivity('Shell', 'セッション $id を止めました'));
        case 'list':
          return ToolOutcome(await _sessions.list(), const ToolActivity('Shell', 'セッションの一覧'));
        default:
          return failed('Unknown action "$action". Use ${Protocol.shellSessionActions.join(', ')}.');
      }
    } catch (e) {
      return failed('The session could not be used: $e');
    }
  }

  static String _shorten(String text) {
    final line = text.replaceAll('\n', '⏎');
    return line.length <= 60 ? line : '${line.substring(0, 59)}…';
  }

  /// Runs the arguments of `Protocol.runCommand` with the shell settings and turns the result into
  /// what the model reads.
  Future<ToolOutcome> _runShell(Map<String, Object?> arguments) async {
    if (!shell.enabled) {
      return const ToolOutcome(
        'The Linux environment is turned off in the settings.',
        ToolActivity('Shell', '設定でオフです', failed: true),
      );
    }
    final command = '${arguments['command'] ?? ''}'.trim();
    if (command.isEmpty) {
      return const ToolOutcome(
        'The command is empty.',
        ToolActivity('Shell', '空のコマンド', failed: true),
      );
    }
    final cwd = '${arguments['cwd'] ?? '/workspace'}'.trim();
    final wanted = arguments['timeout_seconds'];
    final asked = wanted is num ? wanted.toInt() : shell.timeoutSeconds;
    final seconds = asked.clamp(1, shell.maxTimeoutSeconds).toInt();
    final config = shell.config;
    // the secrets this command uses: names the user made available (given as variables of that name), and ids
    // (in `secrets`, or written in the command as {{secret:ID}}): each must exist and have a value, and an
    // address written in the command must be one that secret may go to
    final plan = _plan(command, arguments['secrets']);
    if (plan.problem != null) {
      return ToolOutcome(
        plan.problem!,
        ToolActivity(
          'Shell',
          plan.unknown.isNotEmpty ? '使えない秘密: ${plan.unknown.join(', ')}' : '秘密を使えません: ${_shorten(plan.problem!)}',
          failed: true,
        ),
      );
    }
    final given = plan.env;
    try {
      // the first command installs the environment; the user approved this call already
      if (!_environment.ready) {
        await _environment.refresh(config);
        if (!_environment.ready) await _environment.install(config);
      }
      final outcome = await _environment.run(
        config: config,
        command: plan.command,
        cwd: cwd,
        timeoutSeconds: seconds,
        maxOutputChars: shell.maxOutputChars,
        secrets: given,
      );
      // a command that printed its environment must not hand the value to the model: the values passed by
      // name, and the ones used by placeholder (in every form a program may print them in)
      return ToolOutcome(
        plan.redact(outcome.describe()),
        ToolActivity('Shell', '\$ $command${plan.secretNote}', failed: !outcome.ok),
      );
    } catch (e) {
      final reason = plan.redact('$e');
      return ToolOutcome(
        'The command could not be run: $reason',
        ToolActivity('Shell', '実行できませんでした: $reason', failed: true),
      );
    }
  }
}

/// The secrets one command (or one typed line) uses, as [McpTools._plan] worked them out: what runs, the
/// variables it gets, and a reason it may not run.
class _SecretPlan {
  const _SecretPlan(this.prepared, {this.legacy = const {}, this.problem, this.unknown = const []});

  /// The text that runs (a placeholder is a reference to a variable), and what was found in it.
  final PreparedCommand prepared;

  /// Secrets named in `secrets` as stored values: variable name -> value.
  final Map<String, String> legacy;

  /// Why nothing may run, or null.
  final String? problem;

  /// Names in `secrets` that are neither a stored value nor an id.
  final List<String> unknown;

  String get command => prepared.command;

  /// Every variable the process gets: name -> value.
  Map<String, String> get env => {...legacy, ...prepared.env};

  bool get usesSecrets => legacy.isNotEmpty || prepared.usesSecrets;

  /// For the log line: the names and ids, never values.
  String get secretNote => usesSecrets ? '  （秘密: ${[...legacy.keys, ...prepared.ids].join(', ')}）' : '';

  /// [text] with every value of this plan taken out.
  String redact(String text) => SecretRedaction.redact(ShellSecrets.redact(text, legacy), prepared.idValues);
}
