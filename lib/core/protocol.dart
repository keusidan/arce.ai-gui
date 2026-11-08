import 'dart:convert';

import 'plan_graph.dart';
import 'secret_placeholders.dart';
import 'settings_spec.dart';
import 'shell_secrets.dart';

/// A tool the model may call. [parameters] is a JSON Schema object; the same schema is shown
/// to the model in the system prompt and compiled to GBNF on the native side, so the two
/// cannot drift apart.
class ToolDefinition {
  const ToolDefinition({
    required this.name,
    required this.description,
    required this.parameters,
  });

  final String name;
  final String description;
  final Map<String, Object?> parameters;
}

class QuestionTile {
  const QuestionTile({
    required this.title,
    required this.options,
    required this.allowFreeInput,
    required this.multiSelect,
  });

  static const maxOptions = 8;

  final String title;
  final List<String> options;
  final bool allowFreeInput;
  final bool multiSelect;

  Map<String, Object?> toJson() => {
    'title': title,
    'options': options,
    'allowFreeInput': allowFreeInput,
    'multiSelect': multiSelect,
  };

  factory QuestionTile.fromJson(Map<String, Object?> json) => QuestionTile(
    title: json['title'] as String,
    options: (json['options'] as List).cast<String>(),
    allowFreeInput: json['allowFreeInput'] as bool? ?? false,
    multiSelect: json['multiSelect'] as bool? ?? false,
  );

  @override
  bool operator ==(Object other) =>
      other is QuestionTile &&
      other.title == title &&
      _listEquals(other.options, options) &&
      other.allowFreeInput == allowFreeInput &&
      other.multiSelect == multiSelect;

  @override
  int get hashCode =>
      Object.hash(title, Object.hashAll(options), allowFreeInput, multiSelect);
}

bool _listEquals(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

sealed class ToolCall {
  const ToolCall();
}

class AskUser extends ToolCall {
  const AskUser(this.tile);
  final QuestionTile tile;
}

class WebSearch extends ToolCall {
  const WebSearch(this.query);
  final String query;
}

class GetWeather extends ToolCall {
  const GetWeather(this.location);
  final String location;
}

/// Reads the settings the model may change, with their current values (never API keys).
class GetSettings extends ToolCall {
  const GetSettings();
}

class GetTime extends ToolCall {
  const GetTime(this.timezone);
  final String? timezone;
}

/// A proposed change to the app's own settings. Nothing is applied until the user approves it;
/// the chat shows the list and asks.
class UpdateSettings extends ToolCall {
  const UpdateSettings(this.changes);
  final List<SettingsChangeOk> changes;
}

/// A proposed new provider. Nothing is saved until the user approves it; the API key is never part
/// of it (the user types it on the settings screen).
class AddProvider extends ToolCall {
  const AddProvider(this.draft);
  final ProviderDraft draft;
}

/// One job the planner model gives to the developer model.
class DelegateTask {
  const DelegateTask({
    required this.title,
    required this.instructions,
    this.files = const [],
    this.revise,
    this.id = '',
    this.dependsOn = const [],
  });

  /// Names this job inside one `delegate` call: the node of the plan, and what other jobs wait for.
  /// The parser gives every job one (`t1`, `t2` ...) when the planner wrote none.
  final String id;

  /// The ids of the jobs of this call that must be done first (their results go to this one). The
  /// arrows of the plan and the planner's own `depends_on` are merged here.
  final List<String> dependsOn;

  final String title;

  /// Complete and specific: the developer sees nothing else but this and the summary.
  final String instructions;

  /// The files this task writes, when the planner named them.
  final List<String> files;

  /// The id of an earlier result (`d3`) that this job corrects: [instructions] is then what to change
  /// in it, and the developer is given its own earlier answer again.
  final String? revise;
}

/// The coding mode: the planner model hands jobs to the developer model. The app only carries them
/// out (all at the same time, up to the limit) and returns what came back; what to split, whether
/// the result is good and whether to send work back are the planner's own decisions.
/// The two rounds of the 分担モード: the developer models first look into their parts and report, and build them only
/// once the user has seen the design.
enum DelegatePhase { investigate, build }

class Delegate extends ToolCall {
  const Delegate({required this.summary, required this.tasks, this.plan = '', this.phase, this.workers});

  /// Which round this call is; null when the planner did not say (the setting decides, see `CodingSettings`).
  final DelegatePhase? phase;

  /// How many parts run at the same time (the 分担数 the planner chose); null leaves it to the setting.
  final int? workers;

  /// What every task shares: the decisions, names and interfaces the tasks must agree on.
  final String summary;
  final List<DelegateTask> tasks;

  /// The split as the planner drew it: a Mermaid flowchart (`a["title"]`, `a --> b`). Empty when it
  /// gave only a list; the app then draws one from the jobs and their dependencies.
  final String plan;
}

/// A tool that comes from an MCP server. [arguments] is exactly what the server was sent.
class McpCall extends ToolCall {
  const McpCall(this.name, this.arguments);

  final String name;
  final Map<String, Object?> arguments;

  /// The call a server's tool gets when the model went through `mcp_call` (the on-demand way: the
  /// tool's own definition was not in the request). Everything after the parse (the approval card, the
  /// list of tools that are not asked about again, the run) then sees the real tool, not the wrapper.
  /// Only an MCP server's tool can be reached this way (`mcp_<server>__<tool>`): never the app's own
  /// tools (`run_command`, `update_settings` ...). Any other call is returned as it is.
  McpCall get unwrapped {
    if (name != Protocol.mcpCallName) return this;
    final tool = arguments['tool'];
    if (tool is! String || !Protocol.isServerTool(tool)) return this;
    final inner = arguments['arguments'];
    return McpCall(tool, inner is Map ? inner.cast<String, Object?>() : const {});
  }
}

sealed class ParseResult {
  const ParseResult();
}

class ParseOk extends ParseResult {
  const ParseOk(this.call);
  final ToolCall call;
}

/// The grammar guarantees syntax, so this means the content itself is unusable.
class ParseInvalid extends ParseResult {
  const ParseInvalid(this.reason);
  final String reason;
}

abstract final class Protocol {
  /// Bumped whenever a tool schema changes. Stored with each generation so a regeneration
  /// can tell whether it runs under the same protocol as the original.
  static const schemaVersion = 7;

  static final askUser = ToolDefinition(
    name: 'ask_user',
    description:
        'Ask the user a question and wait for the answer before continuing.',
    parameters: _objectSchema(
      required: ['title', 'options'],
      properties: {
        'title': {'type': 'string'},
        'options': {
          'type': 'array',
          'items': {'type': 'string'},
          'minItems': 1,
          'maxItems': QuestionTile.maxOptions,
        },
        'allow_free_input': {'type': 'boolean'},
        'multi_select': {'type': 'boolean'},
      },
    ),
  );

  static final webSearch = ToolDefinition(
    name: 'web_search',
    description: 'Search the web. Use only when the answer needs current or external information.',
    parameters: _objectSchema(
      required: ['query'],
      properties: {
        'query': {'type': 'string'},
      },
    ),
  );

  static final getWeather = ToolDefinition(
    name: 'get_weather',
    description: 'Get the current weather for a city or place name.',
    parameters: _objectSchema(
      required: ['location'],
      properties: {
        'location': {'type': 'string'},
      },
    ),
  );

  static final getTime = ToolDefinition(
    name: 'get_time',
    description:
        'Get the current date and time. timezone is an IANA name such as Asia/Tokyo; '
        'omit it for the device time zone.',
    parameters: _objectSchema(
      required: [],
      properties: {
        'timezone': {'type': 'string'},
      },
    ),
  );

  static final getSettings = ToolDefinition(
    name: 'get_settings',
    description:
        'Read the app settings the model may change, with their current values, labels, '
        "allowed choices and ranges, plus the configured providers, their models and the MCP "
        'servers (name, URL, whether enabled, which tools). A new provider is added with add_provider; '
        'existing providers and the MCP servers are edited on the settings screen. This tool reports '
        'them so you can answer questions about them instead of guessing. API keys, MCP tokens and the '
        'update source are never returned.',
    parameters: _objectSchema(required: [], properties: {}),
  );

  static final updateSettings = ToolDefinition(
    name: 'update_settings',
    description:
        'Change the app settings (thinking, search, tone, theme, model options, ...). '
        'Each change is shown to the user and applied only if they approve it. '
        'Providers and MCP servers are not settings of this kind: add a provider with add_provider, '
        'and edit existing ones on the settings screen; read them with get_settings. There is '
        'deliberately no way to read or write API keys or MCP tokens, and the update source cannot '
        'be changed either.',
    parameters: _objectSchema(
      required: ['changes'],
      properties: {
        'changes': {
          'type': 'array',
          'minItems': 1,
          'maxItems': AgentSettings.maxChanges,
          'items': {
            'type': 'object',
            'properties': {
              'key': {'type': 'string', 'enum': AgentSettings.keys},
              'value': {
                'oneOf': [
                  {'type': 'boolean'},
                  {'type': 'number'},
                  {'type': 'string'},
                ],
              },
            },
            'required': ['key', 'value'],
            'additionalProperties': false,
          },
        },
      },
    ),
  );

  static final addProvider = ToolDefinition(
    name: 'add_provider',
    description:
        'Add a new online provider with an OpenAI-compatible API (base_url is everything before '
        '/chat/completions, e.g. https://api.example.com/v1). The user is shown the name, address '
        'and models and the provider is saved only if they approve. It cannot change a provider '
        'that already exists, and it has no field for an API key: after it is added, tell the user to '
        'open the settings screen, choose the provider and type the API key there.',
    parameters: _objectSchema(
      required: ['name', 'base_url', 'models'],
      properties: {
        'name': {'type': 'string'},
        'base_url': {'type': 'string'},
        'models': {
          'type': 'array',
          'items': {'type': 'string'},
          'minItems': 1,
          'maxItems': ProviderDraft.maxModels,
        },
        'tools': {'type': 'boolean'},
      },
    ),
  );

  /// Most tasks one `delegate` call may carry (the grammar's limit; the setting can be lower).
  static const maxDelegateTasks = 16;

  static final delegate = ToolDefinition(
    name: 'delegate',
    description:
        '分担モード (split mode): hand parts of the work to the developer models. It goes in two rounds. '
        'phase "investigate": each developer looks into its part and reports (what to change, which files, the '
        'interfaces with the other parts, the risks, how big it is); nothing is written yet. You get all the '
        'reports together; show the user the design and ask whether to build it. phase "build": only after the '
        'user approved, each developer writes its part (give a part the same id as in the investigation, so it '
        'gets its own report). workers is how many parts run at the same time (the 分担数). '
        'Split the work into many '
        'SMALL jobs (one file or one group of functions each). Draw the split in plan as a Mermaid flowchart: '
        'one node per job, written id["title"], and an arrow a --> b when b needs the result of a. Jobs '
        'with no arrow into them run at the same time on different models, so keep as many as possible '
        'independent. Jobs that run at the same time cannot see each other, so put the names, signatures '
        'and data formats they must agree on in summary and in every job that touches them. A job that '
        'waits for others is given their results. Each job must be complete: the developer sees nothing '
        'else, decides every detail itself and does not ask you. You get each result back with an id. The '
        'user sees the developers\' files as they come, so do not copy them into your answer; read them, '
        'and if something is wrong call delegate again with revise (the id of that result) and exactly '
        'what to change.',
    parameters: _objectSchema(
      required: ['tasks'],
      properties: {
        'phase': {'type': 'string', 'enum': ['investigate', 'build']},
        'workers': {'type': 'integer'},
        'plan': {'type': 'string'},
        'summary': {'type': 'string'},
        'tasks': {
          'type': 'array',
          'minItems': 1,
          'maxItems': maxDelegateTasks,
          'items': {
            'type': 'object',
            'properties': {
              'id': {'type': 'string'},
              'title': {'type': 'string'},
              'depends_on': {
                'type': 'array',
                'items': {'type': 'string'},
              },
              'instructions': {'type': 'string'},
              'files': {
                'type': 'array',
                'items': {'type': 'string'},
              },
              'revise': {'type': 'string'},
            },
            'required': ['title', 'instructions'],
            'additionalProperties': false,
          },
        },
      },
    ),
  );

  // ---------------------------------------------------------------- the app's own tools

  /// The app's own shell tool: one command in the Linux environment on the device.
  /// It is parsed as an [McpCall] and run by the MCP runtime, which is where the chat looks
  /// for calls it cannot run itself.
  static const runCommandName = 'run_command';

  static final runCommand = ToolDefinition(
    name: runCommandName,
    description:
        'Run one shell command in the Linux environment (Ubuntu 24.04, arm64) that lives inside this '
        'app, in the root file system under proot. There is no systemd. /workspace is shared by every '
        'chat and kept between them (up to 2048 MB); HOME is /workspace/home. apt, pip (use --user) '
        'and git work. Commands run one at a time and cannot ask for input. Never wait with a '
        'fixed-duration sleep (e.g. sleep 5); wait directly for the process or response to finish, '
        'and rely on timeout_seconds as the timeout cap. The output is cut when it is long, and the '
        'command is stopped when it runs longer than timeout_seconds or fills the workspace. The first '
        'command installs the environment (about 30 MB, a few minutes) if the user has not done it '
        'yet. A command that stays inside the environment (/workspace and the container root file '
        'system) runs at once, without waiting for the user; one that reaches the device outside it is '
        'shown for approval first. Set auto_execute: false to ask first even inside. To give the command a '
        'stored secret as an environment variable, list its name in secrets; the user then approves '
        'that command every time, and you never see the value. You can also write {{secret:ID}} where a key '
        'or a token goes in the command (for example -H "Authorization: Bearer {{secret:ID}}"): the app puts it '
        'in at the moment of use, only for the addresses that secret is bound to, and the user approves that '
        'command every time. Write the whole https:// address in the command so that it can be checked. For '
        'a plain call to an API prefer http_request (the app sends it and the key can only go to its own host); '
        'use a command for what needs a program. Inside a here-document ({{secret:ID}} is not replaced there, '
        'so that the key is never written into a file) a script reads the key from the environment variable '
        'ARCE_SECRET_<ID in capitals, - as _>.',
    parameters: _objectSchema(
      required: ['command'],
      properties: {
        'command': {'type': 'string'},
        'cwd': {'type': 'string'},
        'timeout_seconds': {'type': 'integer'},
        'auto_execute': {'type': 'boolean'},
        'secrets': {
          'type': 'array',
          'items': {'type': 'string'},
        },
      },
    ),
  );

  /// The tool that calls an address for the model, with secrets put in by placeholder (path A).
  static const httpRequestName = 'http_request';

  static const httpRequestMethods = ['GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELETE'];

  /// The definition without the list of secrets (that part of the description is written when the tool is
  /// offered, from what the user has set up: see `HttpRequestTool.definition`).
  static final httpRequest = ToolDefinition(
    name: httpRequestName,
    description:
        'Call an address over HTTP and read the answer (like curl, but the app sends it). To use a key or a '
        'token, write {{secret:ID}} where it goes (in the url, a header value or the body): the app puts the '
        'value in, never shows it to you, and sends it only to the hosts that secret is bound to.',
    parameters: _objectSchema(
      required: ['url'],
      properties: {
        'method': {'type': 'string', 'enum': httpRequestMethods},
        'url': {'type': 'string'},
        'headers': {'type': 'object'},
        'body': {'type': 'string'},
        'json': {'type': 'object'},
        'timeout_seconds': {'type': 'integer'},
      },
    ),
  );

  /// The tool that puts a page on the user's screen, inside the chat.
  static const showName = 'show';

  static final show = ToolDefinition(
    name: showName,
    description:
        'Show a page to the user inside the chat: a card with a button that opens it right there (it runs in a '
        'sandbox). Give exactly one of: html (a whole page, with its style and script written in it), svg (a '
        'picture), path (a file or a folder of /workspace in the Linux environment: .html, .svg or a picture, or a '
        'folder that has an index.html; the style, script and pictures beside it are served too), or port (a program '
        'of this device that serves a page on 127.0.0.1:port, 1024-65535, such as a web server or a viewer you '
        'started with shell_session: a command of run_command ends when it returns, so what must keep running is '
        'started with shell_session). url_path is the address below the port (default /). title names the card. '
        'Use it to show what you made instead of asking the user to open it.',
    parameters: _objectSchema(
      required: [],
      properties: {
        'html': {'type': 'string'},
        'svg': {'type': 'string'},
        'path': {'type': 'string'},
        'port': {'type': 'integer'},
        'url_path': {'type': 'string'},
        'title': {'type': 'string'},
      },
    ),
  );

  /// A program that is talked to: it keeps running, asks for input, shows a screen. Starts under a pseudo
  /// terminal; the answer is always the terminal screen as text.
  static const shellSessionName = 'shell_session';

  static const shellSessionActions = ['start', 'send', 'read', 'stop', 'list'];

  static final shellSession = ToolDefinition(
    name: shellSessionName,
    description:
        'Talk to a program that keeps running and asks for input, in the Linux environment: a read-eval loop '
        '(python3, node), an installer with questions, a command-line agent such as opencode. '
        'action "start" runs command under a pseudo terminal (cwd and secrets as for run_command) and answers with '
        'a session id; "send" types input and presses keys in session; "read" only looks again (use it while the '
        'program is still working); "stop" ends it; "list" lists the sessions. Every answer is the terminal '
        'screen as a person would see it, plus the lines that scrolled off since the last answer. '
        'input is typed as it is (a line break is the Enter key); keys are names pressed after the input: '
        'Enter, Tab, Esc, Up, Down, Left, Right, Backspace, Delete, Home, End, PageUp, PageDown, Space, '
        'Ctrl-C, Ctrl-D, Ctrl-<letter>. wait_ms is how long to wait for output before answering. '
        'A command that does not need talking to is better run with run_command. {{secret:ID}} may stand in '
        'command (as for run_command), and in input only for a secret the session was started with; the user '
        'approves it every time.',
    parameters: _objectSchema(
      required: ['action'],
      properties: {
        'action': {'type': 'string', 'enum': shellSessionActions},
        'command': {'type': 'string'},
        'cwd': {'type': 'string'},
        'session': {'type': 'string'},
        'input': {'type': 'string'},
        'keys': {
          'type': 'array',
          'items': {'type': 'string'},
        },
        'wait_ms': {'type': 'integer'},
        'secrets': {
          'type': 'array',
          'items': {'type': 'string'},
        },
      },
    ),
  );

  /// Whether [call] makes a program run or tells it what to do: a command, or a session started or typed
  /// into. These are what the sandbox rule, the "after reading from outside" rule and the card are about.
  static bool runsCommands(McpCall call) =>
      call.name == runCommandName ||
      (call.name == shellSessionName && (call.arguments['action'] == 'start' || call.arguments['action'] == 'send'));

  /// The three tools that stand for every MCP server's tools when their definitions would be too big
  /// to send each time: look for a tool, read its definition, call it.
  static const mcpFindName = 'mcp_find';
  static const mcpDescribeName = 'mcp_describe';
  static const mcpCallName = 'mcp_call';

  static final mcpFindParameters = _objectSchema(
    required: [],
    properties: {
      'query': {'type': 'string'},
      'server': {'type': 'string'},
    },
  );

  static final mcpDescribeParameters = _objectSchema(
    required: ['tool'],
    properties: {
      'tool': {'type': 'string'},
    },
  );

  static final mcpCallParameters = _objectSchema(
    required: ['tool'],
    properties: {
      'tool': {'type': 'string'},
      'arguments': {'type': 'object'},
    },
  );

  /// Whether [name] is `mcp_<server>__<tool>`: a tool of an MCP server (not the on-demand tools above).
  static bool isServerTool(String name) {
    if (!name.startsWith('mcp_')) return false;
    final at = name.indexOf('__', 4);
    return at > 4 && at + 2 < name.length;
  }

  /// GitHub Actions, read only: what the CI of a branch did, and which steps of one run failed.
  /// The GitHub MCP server the app talks to offers no Actions tools, so this reads the REST API.
  static const ciStatusName = 'ci_status';

  static final ciStatus = ToolDefinition(
    name: ciStatusName,
    description:
        'Read GitHub Actions of a repository (the app\'s own unless repository says otherwise), '
        'read only. Without run_id it lists the newest runs of a branch (all branches when branch '
        'is omitted); with run_id it lists the jobs of that run, with the steps that failed. Use it '
        'to say whether a push is green on every platform, instead of asking the user to copy a log.',
    parameters: _objectSchema(
      required: [],
      properties: {
        'repository': {'type': 'string'},
        'branch': {'type': 'string'},
        'limit': {'type': 'integer'},
        'run_id': {'type': 'integer'},
      },
    ),
  );

  /// The tools that parse as an [McpCall]: the MCP servers' own, and the app's own two above.
  static bool isMcpLike(String name) =>
      name.startsWith('mcp_') || name == runCommandName || name == ciStatusName || name == shellSessionName || name == httpRequestName || name == showName;

  /// JSON Schema for the body of one `<tool_call>` block restricted to [tools]:
  /// `{"name": <one of the tools>, "arguments": <that tool's parameters>}`.
  /// Each agent passes only the tools it may use, so the grammar cannot express any other call.
  static Map<String, Object?> toolCallSchema(List<ToolDefinition> tools) {
    if (tools.isEmpty) {
      throw ArgumentError('an agent without tools needs no tool-call grammar');
    }
    return {
      'oneOf': [
        for (final tool in tools)
          {
            'type': 'object',
            'properties': {
              'name': {'const': tool.name},
              'arguments': tool.parameters,
            },
            'required': ['name', 'arguments'],
            'additionalProperties': false,
          },
      ],
    };
  }

  static Map<String, Object?> _objectSchema({
    required List<String> required,
    required Map<String, Object?> properties,
  }) => {
    'type': 'object',
    'properties': properties,
    'required': required,
    'additionalProperties': false,
  };
}

/// The card the chat shows for [UpdateSettings]: nothing is written until the user approves.
abstract final class SettingsApproval {
  static const approve = '承認';
  static const reject = '拒否';

  static QuestionTile tile(List<SettingsChangeOk> changes) => QuestionTile(
    title: '設定を変更します。${changes.map((c) => c.description).join('、')}。承認しますか？',
    options: const [approve, reject],
    allowFreeInput: false,
    multiSelect: false,
  );

  static bool isApproval(List<String> selected) => selected.contains(approve);
}

/// The card the chat shows for [AddProvider]: nothing is saved until the user approves.
abstract final class ProviderApproval {
  static const approve = '追加する';
  static const reject = 'やめる';

  static QuestionTile tile(ProviderDraft draft) => QuestionTile(
    title: '${draft.description}。追加しますか？（APIキーは追加後に詳細設定で入力します）',
    options: const [approve, reject],
    allowFreeInput: false,
    multiSelect: false,
  );

  static bool isApproval(List<String> selected) => selected.contains(approve);
}

/// The card the chat shows for an [McpCall] that changes something outside the device, and for
/// every `run_command` (a command can do anything the app itself can).
abstract final class ToolApproval {
  static const approve = '実行する';

  /// Runs it, and does not ask again for this tool (settings: 確認しない道具). Not offered for a
  /// command: what a command does depends on the command, not on the tool.
  static const approveAlways = '実行する（この道具は次から確認しない）';
  static const reject = 'やめる';

  /// The card for [call]. [note] says why it asks when that is not obvious (a command asks after
  /// the model has read something from outside); [rememberable] adds [approveAlways]. [details] are lines
  /// the app adds under a command or a line typed into a session (which secrets it uses, where each may go,
  /// the addresses written in it): the command itself is shown as the model wrote it, placeholders and all.
  static QuestionTile tile(McpCall call, {String note = '', bool rememberable = false, String details = ''}) => QuestionTile(
    title: _title(call, note, details),
    options: [approve, if (rememberable && canRemember(call.name)) approveAlways, reject],
    allowFreeInput: false,
    multiSelect: false,
  );

  /// Only an MCP tool can be remembered (`mcp_server__tool`): a command always asks when it asks.
  static bool canRemember(String name) => name != Protocol.runCommandName && name.startsWith('mcp_');

  /// A command is shown as it is (`$ command`), with where and for how long: the model's words
  /// about it are not what the user approves. Another tool is shown by its name (server and tool)
  /// and its arguments one to a line, a long value cut with its size, never as a dumped map.
  static String _title(McpCall call, String note, [String details = '']) {
    final reason = note.isEmpty ? '' : '\n（$note）';
    final more = details.isEmpty ? '' : '\n$details';
    if (call.name == Protocol.runCommandName) {
      final command = '${call.arguments['command'] ?? ''}'.trim();
      final cwd = '${call.arguments['cwd'] ?? '/workspace'}'.trim();
      final seconds = call.arguments['timeout_seconds'];
      final limit = seconds is num ? '・最大 ${seconds.toInt()} 秒' : '';
      final names = ShellSecrets.names(call.arguments['secrets']) ?? const <String>[];
      final secrets = names.isEmpty ? '' : '\n秘密を渡します: ${names.join('、')}（このコマンドは、これらの値を読めます。送り先は制限できません）';
      return 'このコマンドを実行します。$reason\n\$ $command\n場所: $cwd$limit$secrets$more';
    }
    if (call.name == Protocol.httpRequestName) return _httpRequestTitle(call, reason);
    if (call.name == Protocol.shellSessionName) {
      final names = ShellSecrets.names(call.arguments['secrets']) ?? const <String>[];
      final secrets = names.isEmpty ? '' : '\n秘密を渡します: ${names.join('、')}（このコマンドは、これらの値を読めます。送り先は制限できません）';
      if (call.arguments['action'] == 'start') {
        final command = '${call.arguments['command'] ?? ''}'.trim();
        final cwd = '${call.arguments['cwd'] ?? '/workspace'}'.trim();
        return 'このコマンドを、対話できるセッションとして始めます。$reason\n\$ $command\n場所: $cwd$secrets$more';
      }
      final input = '${call.arguments['input'] ?? ''}';
      final keys = call.arguments['keys'];
      final pressed = keys is List && keys.isNotEmpty ? '\nキー: ${keys.join(' ')}' : '';
      return 'セッション ${call.arguments['session'] ?? ''} に入力します。$reason\n> ${input.replaceAll('\n', '⏎')}$pressed$more';
    }
    final b = StringBuffer('この道具を実行します：${label(call.name)}$reason');
    for (final entry in call.arguments.entries) {
      b
        ..writeln()
        ..write('${entry.key}: ${summarize(entry.value)}');
    }
    return b.toString();
  }

  /// The card of `http_request`: the method, the address as the model wrote it (placeholders as they are:
  /// never a value), the host it really goes to, the secrets it uses, and the start of the body.
  static String _httpRequestTitle(McpCall call, String reason) {
    final args = call.arguments;
    final method = '${args['method'] ?? 'GET'}';
    final url = '${args['url'] ?? ''}'.trim();
    final headers = args['headers'];
    final json = args['json'];
    final body = json != null ? jsonEncode(json) : '${args['body'] ?? ''}';
    final everything = [
      url,
      if (headers is Map) ...headers.keys.map((k) => '$k'),
      if (headers is Map) ...headers.values.map((v) => '$v'),
      body,
    ].join('\n');
    final ids = SecretPlaceholders.idsIn(everything);
    final real = SecretPlaceholders.substitute(url, (_) => 'x');
    final host = SecretHosts.normalizeHost(Uri.tryParse(real)?.host ?? '');
    final b = StringBuffer('この HTTP リクエストを送ります。$reason\n$method $url\n送り先のホスト: ${host ?? '（読み取れません）'}');
    if (ids.isNotEmpty) {
      b.write('\n使う秘密: ${ids.join('、')}（値は見えません。設定で決めたホストにだけ送ります。違うホストなら送りません）');
    }
    if (body.isNotEmpty) {
      final shown = body.length > 200 ? '${body.substring(0, 200)}…' : body;
      b.write('\n本文（${body.length} 文字）: ${shown.replaceAll('\n', ' ⏎ ')}');
    }
    return b.toString();
  }

  /// `mcp_github__create_or_update_file` -> `github · create_or_update_file`.
  static String label(String name) {
    final at = name.lastIndexOf('__');
    if (!name.startsWith('mcp_') || at < 0) return name;
    return '${name.substring(4, at)} · ${name.substring(at + 2)}';
  }

  /// A value for the card: short ones whole, a long text cut at [maxChars] with how long it was, a
  /// list or an object as JSON cut the same way.
  static String summarize(Object? value, {int maxChars = 240}) {
    final text = value is String ? value : jsonEncode(value);
    final flat = text.replaceAll(RegExp(r'\s*\n\s*'), ' ⏎ ').trim();
    if (flat.length <= maxChars) return flat;
    final lines = text.split('\n').length;
    return '${flat.substring(0, maxChars)}…（全部で ${text.length} 文字${lines > 1 ? '・$lines 行' : ''}）';
  }

  static bool isApproval(List<String> selected) => selected.contains(approve) || selected.contains(approveAlways);

  /// The user asked not to be asked about this tool again.
  static bool isAlways(List<String> selected) => selected.contains(approveAlways);

  /// The words of a tool name that mean it changes something outside the device (create, delete,
  /// submit, start ...). A tool name is read word by word, whatever its style (`create_or_update_file`,
  /// `CreateBenchmarkTaskFromPrompt`): `ListDatasets` is a read although "datasets" contains "set".
  static const writeVerbs = {
    'create', 'update', 'delete', 'remove', 'push', 'merge', 'commit', 'write', 'edit', 'close', 'reopen',
    'add', 'set', 'put', 'patch', 'fork', 'transfer', 'review', 'submit', 'start', 'cancel', 'stop', 'run',
    'rerun', 'upload', 'publish', 'save', 'post', 'send', 'apply', 'execute', 'trigger', 'enable', 'disable',
    'approve', 'assign', 'import', 'insert', 'rename', 'move', 'replace', 'restore', 'revert', 'invite',
    'grant', 'kill',
  };

  /// Their names come from the server (`mcp_<server>__<tool>`); the server's own id is not read.
  static bool needsApproval(String name, [Map<String, Object?> arguments = const {}]) {
    if (name == Protocol.ciStatusName) return false;
    if (name == Protocol.runCommandName) {
      return !SandboxPolicy.isInsideSandbox(McpCall(name, arguments));
    }
    final at = name.lastIndexOf('__');
    final tool = at >= 0 ? name.substring(at + 2) : name;
    final words = RegExp(r'[A-Z]+(?![a-z])|[A-Z]?[a-z]+|\d+').allMatches(tool).map((m) => m.group(0)!.toLowerCase());
    return words.any(writeVerbs.contains);
  }
}

/// Decides whether a `run_command` call stays inside the local proot environment (/workspace and
/// the Ubuntu rootfs), which is what lets it run without asking the user (B).
///
/// proot is not a sandbox: a command runs with the app's own user and proot only translates paths.
/// What this reads is therefore only "does the command reach the device outside the container":
/// a `cwd` under a host-only folder, or a command that names one, is outside; a command written
/// against `/workspace` and the rootfs is inside.
abstract final class SandboxPolicy {
  /// Host Android paths that live outside the container rootfs and /workspace.
  static final _hostPaths = RegExp(
    r'''(?:^|[\s'"`=:/])(?:/sdcard(?:/|$)|/storage/(?:emulated|self)(?:/|$)|/data/(?:data|user|app)(?:/|$)|/system/(?:bin|xbin|app|priv-app)(?:/|$)|/vendor(?:/|$)|/apex(?:/|$))''',
  );

  /// proot translates paths; it does not close the real file system. A process reaches the device
  /// through the proc entries of itself or of another process (`/proc/self/root`, `/proc/<pid>/cwd`,
  /// `/proc/self/exe`, its memory and environment), and through the file descriptors it holds. These
  /// are the doors a command can name; one that does is not "inside the sandbox". (A command that
  /// builds the name out of variables is not caught: proot is not a boundary, and what stops that is
  /// the question the app asks after the model has read something from outside.)
  static final _procDoors = RegExp(
    r'''proc/(?:self|thread-self|\d+|\$\$|\$\{?[A-Za-z_][A-Za-z0-9_]*\}?|\$\(.*?\))/(?:root|cwd|exe|mem|environ|map_files|fd|fdinfo|task)\b''',
  );

  static const _forbiddenCwdPrefixes = [
    '/sdcard',
    '/storage',
    '/mnt',
    '/data/data',
    '/data/user',
    '/data/app',
    '/system',
    '/vendor',
    '/apex',
  ];

  /// True when [call] is a `run_command` that stays inside the environment and the model did not ask
  /// for a look first (`auto_execute: false`).
  static bool isInsideSandbox(McpCall call) {
    if (call.name != Protocol.runCommandName) return false;
    final autoExec = call.arguments['auto_execute'];
    if (autoExec == false || autoExec == 'false') return false;
    final rawCwd = '${call.arguments['cwd'] ?? '/workspace'}'.trim();
    final cwd = _normalizePath(rawCwd);
    if (cwd == null) return false;
    for (final prefix in _forbiddenCwdPrefixes) {
      if (cwd == prefix || cwd.startsWith('$prefix/')) return false;
    }
    final command = '${call.arguments['command'] ?? ''}'.trim();
    if (command.isEmpty) return false;
    if (_hostPaths.hasMatch(command)) return false;
    if (_procDoors.hasMatch(command) || _procDoors.hasMatch(rawCwd)) return false;
    return true;
  }

  /// Resolves `.` and `..`; null when the path is not absolute or climbs above `/`.
  static String? _normalizePath(String path) {
    if (!path.startsWith('/') || path.contains('\n') || path.contains('\u0000')) return null;
    final stack = <String>[];
    for (final part in path.split('/')) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') {
        if (stack.isEmpty) return null;
        stack.removeLast();
      } else {
        stack.add(part);
      }
    }
    return '/${stack.join('/')}';
  }
}

/// Turns the body of a `<tool_call>` block into a [ToolCall] and checks what the grammar
/// cannot: meaning. GBNF guarantees the JSON shape, not that option labels are non-blank
/// or distinct.
abstract final class ToolCallParser {
  static ParseResult parse(String body, List<ToolDefinition> allowed) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException catch (e) {
      // the start of the text is shown too: "Unexpected character" alone does not say what came
      final preview = body.length > 120 ? '${body.substring(0, 120)}…' : body;
      return ParseInvalid('not JSON: ${e.message.split('\n').first} ($preview)');
    }
    if (decoded is! Map) return const ParseInvalid('not a JSON object');

    final name = decoded['name'];
    if (name is! String) return const ParseInvalid('missing tool name');
    if (allowed.every((t) => t.name != name)) {
      return ParseInvalid("tool '$name' is not allowed here");
    }
    final args = decoded['arguments'];
    if (args is! Map) return const ParseInvalid('missing arguments');

    try {
      if (name == Protocol.askUser.name) return _parseAskUser(args);
      if (name == Protocol.webSearch.name) {
        final q = _requiredText(args, 'query');
        return q == null
            ? const ParseInvalid('search query is blank')
            : ParseOk(WebSearch(q));
      }
      if (name == Protocol.getWeather.name) {
        final l = _requiredText(args, 'location');
        return l == null
            ? const ParseInvalid('weather location is blank')
            : ParseOk(GetWeather(l));
      }
      if (name == Protocol.getTime.name) {
        return ParseOk(GetTime(_requiredText(args, 'timezone')));
      }
      if (name == Protocol.getSettings.name) {
        return ParseOk(const GetSettings());
      }
      if (name == Protocol.updateSettings.name) {
        return _parseUpdateSettings(args);
      }
      if (name == Protocol.addProvider.name) {
        return _parseAddProvider(args);
      }
      if (name == Protocol.delegate.name) {
        return _parseDelegate(args);
      }
      if (name == Protocol.ciStatusName) return _parseCiStatus(args);
      // a tool of an MCP server, or the app's own run_command: the engine's schema already limited
      // it to the tools this turn allows
      if (Protocol.isMcpLike(name)) {
        if (name == Protocol.runCommandName) return _parseRunCommand(args);
        if (name == Protocol.shellSessionName) return _parseShellSession(args);
        if (name == Protocol.httpRequestName) return _parseHttpRequest(args);
        if (name == Protocol.showName) return _parseShow(args);
        return ParseOk(McpCall(name, args.cast<String, Object?>()));
      }
      return ParseInvalid("tool '$name' has no handler");
    } on _WrongType catch (e) {
      return ParseInvalid('argument has the wrong type: ${e.key}');
    }
  }

  static String? _requiredText(Map<dynamic, dynamic> args, String key) {
    final value = args[key];
    if (value == null) return null;
    if (value is Map || value is List) throw _WrongType(key);
    final text = value.toString().trim();
    return text.isEmpty ? null : text;
  }

  static bool _flag(Map<dynamic, dynamic> args, String key) {
    final value = args[key];
    if (value is bool) return value;
    if (value is String) return value == 'true';
    return false;
  }

  static ParseResult _parseAskUser(Map<dynamic, dynamic> args) {
    final title = _requiredText(args, 'title');
    if (title == null) return const ParseInvalid('question title is blank');

    final raw = args['options'];
    if (raw != null && raw is! List) throw _WrongType('options');
    final options = <String>[
      for (final o in (raw as List?) ?? const [])
        if (o is Map || o is List)
          throw _WrongType('options')
        else
          (o?.toString().trim() ?? ''),
    ];
    if (options.isEmpty) return const ParseInvalid('question has no options');
    if (options.length > QuestionTile.maxOptions) {
      return const ParseInvalid('too many options');
    }
    if (options.any((o) => o.isEmpty)) {
      return const ParseInvalid('an option is blank');
    }
    if (options.toSet().length != options.length) {
      return const ParseInvalid('options are not distinct');
    }

    return ParseOk(
      AskUser(
        QuestionTile(
          title: title,
          options: options,
          allowFreeInput: _flag(args, 'allow_free_input'),
          multiSelect: _flag(args, 'multi_select'),
        ),
      ),
    );
  }

  /// The command is the one thing that matters: a blank one is refused, and the rest is passed on
  /// as it came (the runner bounds the time and the output).
  static ParseResult _parseRunCommand(Map<dynamic, dynamic> args) {
    final command = _requiredText(args, 'command');
    if (command == null) return const ParseInvalid('the command is blank');
    final cwd = _requiredText(args, 'cwd');
    if (cwd != null && !cwd.startsWith('/')) {
      return const ParseInvalid('cwd must be an absolute path inside the environment');
    }
    final timeout = args['timeout_seconds'];
    if (timeout != null && timeout is! num) throw _WrongType('timeout_seconds');
    final autoExec = args['auto_execute'];
    if (autoExec != null && autoExec is! bool && autoExec is! String) {
      throw _WrongType('auto_execute');
    }
    final secrets = ShellSecrets.names(args['secrets']);
    if (secrets == null) throw _WrongType('secrets');
    return ParseOk(
      McpCall(Protocol.runCommandName, {
        'command': command,
        'cwd': ?cwd,
        if (timeout is num) 'timeout_seconds': timeout.toInt(),
        if (autoExec != null) 'auto_execute': _flag(args, 'auto_execute'),
        // the names the model asked to give the command; whether they exist is for the tool to say
        if (secrets.isNotEmpty) 'secrets': secrets,
      }),
    );
  }

  /// `show`: one thing to show (a page, a picture, a file of the workspace or a port), with the title of its card.
  static ParseResult _parseShow(Map<dynamic, dynamic> args) {
    for (final key in const ['html', 'svg', 'path', 'url_path', 'title']) {
      if (args[key] != null && args[key] is! String) throw _WrongType(key);
    }
    final port = args['port'];
    if (port != null && (port is! num || port != port.toInt())) throw _WrongType('port');
    final given = [for (final key in const ['html', 'svg', 'path', 'port']) if (args[key] != null) key];
    if (given.length != 1) return const ParseInvalid('give exactly one of html, svg, path or port');
    final title = (args['title'] as String? ?? '').trim();
    final text = args[given.single];
    if (text is String && text.trim().isEmpty) return ParseInvalid('${given.single} is blank');
    return ParseOk(McpCall(Protocol.showName, {
      given.single: port is num ? port.toInt() : text,
      if (args['url_path'] is String && (args['url_path'] as String).trim().isNotEmpty) 'url_path': (args['url_path'] as String).trim(),
      if (title.isNotEmpty) 'title': title,
    }));
  }

  /// `http_request`: the method, the address, the headers and the body, checked here so that the card, the
  /// policy and the tool see the same arguments. A body is either text (`body`) or an object (`json`).
  static ParseResult _parseHttpRequest(Map<dynamic, dynamic> args) {
    final rawMethod = args['method'];
    if (rawMethod != null && rawMethod is! String) throw _WrongType('method');
    final method = (rawMethod as String? ?? 'GET').trim().toUpperCase();
    if (!Protocol.httpRequestMethods.contains(method)) {
      return ParseInvalid('method must be one of ${Protocol.httpRequestMethods.join(', ')}');
    }
    final url = _requiredText(args, 'url');
    if (url == null) return const ParseInvalid('the url is blank');
    final headersRaw = args['headers'];
    final headers = <String, String>{};
    if (headersRaw != null) {
      if (headersRaw is! Map) throw _WrongType('headers');
      for (final entry in headersRaw.entries) {
        final value = entry.value;
        if (entry.key is! String || (value is! String && value is! num && value is! bool)) throw _WrongType('headers');
        headers[entry.key as String] = '$value';
      }
    }
    final body = args['body'];
    if (body != null && body is! String) throw _WrongType('body');
    final json = args['json'];
    if (json != null && json is! Map && json is! List) throw _WrongType('json');
    if (body != null && json != null) return const ParseInvalid('give either body or json, not both');
    final timeout = args['timeout_seconds'];
    if (timeout != null && timeout is! num) throw _WrongType('timeout_seconds');
    return ParseOk(McpCall(Protocol.httpRequestName, {
      'method': method,
      'url': url,
      if (headers.isNotEmpty) 'headers': headers,
      // the body is what the model wrote, spaces and line breaks included
      if (body is String && body.isNotEmpty) 'body': body,
      'json': ?json,
      if (timeout is num) 'timeout_seconds': timeout.toInt(),
    }));
  }

  /// `shell_session`: the action and what it needs, checked here so that the card and the policy see the
  /// same arguments the tool will run with (an unknown action or a missing session is the model's to fix).
  static ParseResult _parseShellSession(Map<dynamic, dynamic> args) {
    final action = _requiredText(args, 'action');
    if (action == null || !Protocol.shellSessionActions.contains(action)) {
      return ParseInvalid('action must be one of ${Protocol.shellSessionActions.join(', ')}');
    }
    final session = _requiredText(args, 'session');
    final cwd = _requiredText(args, 'cwd');
    if (cwd != null && !cwd.startsWith('/')) {
      return const ParseInvalid('cwd must be an absolute path inside the environment');
    }
    final secrets = ShellSecrets.names(args['secrets']);
    if (secrets == null) throw _WrongType('secrets');
    final keysRaw = args['keys'];
    final keys = <String>[];
    if (keysRaw != null) {
      if (keysRaw is! List) throw _WrongType('keys');
      for (final key in keysRaw) {
        if (key is! String) throw _WrongType('keys');
        if (key.trim().isNotEmpty) keys.add(key.trim());
      }
    }
    final waited = args['wait_ms'];
    if (waited != null && waited is! num) throw _WrongType('wait_ms');
    // the input is typed as it is: spaces and line breaks count, so it is not trimmed
    final input = args['input'];
    if (input is Map || input is List) throw _WrongType('input');
    switch (action) {
      case 'start':
        final command = _requiredText(args, 'command');
        if (command == null) return const ParseInvalid('start needs a command');
        return ParseOk(McpCall(Protocol.shellSessionName, {
          'action': action,
          'command': command,
          'cwd': ?cwd,
          if (secrets.isNotEmpty) 'secrets': secrets,
          if (waited is num) 'wait_ms': waited.toInt(),
        }));
      case 'send':
        if (session == null) return const ParseInvalid('send needs a session');
        final text = input == null ? '' : '$input';
        if (text.isEmpty && keys.isEmpty) return const ParseInvalid('send needs input or keys');
        return ParseOk(McpCall(Protocol.shellSessionName, {
          'action': action,
          'session': session,
          if (text.isNotEmpty) 'input': text,
          if (keys.isNotEmpty) 'keys': keys,
          if (waited is num) 'wait_ms': waited.toInt(),
        }));
      case 'read':
      case 'stop':
        if (session == null) return ParseInvalid('$action needs a session');
        return ParseOk(McpCall(Protocol.shellSessionName, {
          'action': action,
          'session': session,
          if (waited is num) 'wait_ms': waited.toInt(),
        }));
      default:
        return const ParseOk(McpCall(Protocol.shellSessionName, {'action': 'list'}));
    }
  }

  /// A repository is `owner/name` (or none, for the app's own), the branch and the run are as they
  /// came: reading the runs is all this does.
  static ParseResult _parseCiStatus(Map<dynamic, dynamic> args) {
    final repository = _requiredText(args, 'repository');
    if (repository != null && !RegExp(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$').hasMatch(repository)) {
      return const ParseInvalid('repository must look like owner/name');
    }
    final branch = _requiredText(args, 'branch');
    final limit = args['limit'];
    if (limit != null && limit is! num) throw _WrongType('limit');
    final runId = args['run_id'];
    if (runId != null && runId is! num) throw _WrongType('run_id');
    final arguments = <String, Object?>{};
    if (repository != null) arguments['repository'] = repository;
    if (branch != null) arguments['branch'] = branch;
    if (limit is num) arguments['limit'] = limit.toInt();
    if (runId is num) arguments['run_id'] = runId.toInt();
    return ParseOk(McpCall(Protocol.ciStatusName, arguments));
  }

  static ParseResult _parseDelegate(Map<dynamic, dynamic> args) {
    final raw = args['tasks'];
    if (raw is! List) throw _WrongType('tasks');
    final tasks = <DelegateTask>[];
    final ids = <String>{};
    for (final item in raw) {
      if (item is! Map) throw _WrongType('tasks');
      final instructions = _requiredText(item, 'instructions');
      if (instructions == null) return const ParseInvalid('a task has no instructions');
      final files = item['files'];
      final written = _requiredText(item, 'id')?.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '');
      var id = written == null || written.isEmpty ? 't${tasks.length + 1}' : written;
      if (!ids.add(id)) {
        // the planner reused an id: the second job is a different job, not an error worth stopping for
        var n = tasks.length + 1;
        while (!ids.add(id = 't$n')) {
          n++;
        }
      }
      final dependsOn = item['depends_on'];
      tasks.add(
        DelegateTask(
          id: id,
          title: _requiredText(item, 'title') ?? 'タスク ${tasks.length + 1}',
          instructions: instructions,
          files: [
            if (files is List)
              for (final f in files)
                if (f is String && f.trim().isNotEmpty) f.trim(),
          ],
          revise: _requiredText(item, 'revise'),
          dependsOn: [
            if (dependsOn is List)
              for (final d in dependsOn)
                if (d is String && d.trim().isNotEmpty) d.trim(),
          ],
        ),
      );
    }
    if (tasks.isEmpty) return const ParseInvalid('delegate has no tasks');

    // the plan (a Mermaid flowchart) and the lists say the same thing in two ways: merged, and checked
    final plan = _requiredText(args, 'plan') ?? '';
    final merged = {for (final t in tasks) t.id: <String>{...t.dependsOn}};
    if (plan.isNotEmpty) {
      final graph = PlanGraph.parse(plan);
      if (graph == null) {
        return const ParseInvalid('plan has no node: write a Mermaid flowchart such as flowchart TD, a["title"], a --> b');
      }
      for (final id in graph.labels.keys) {
        if (!merged.containsKey(id)) return ParseInvalid("plan names '$id', which is not the id of a task");
      }
      for (final (from, to) in graph.edges) {
        merged[to]!.add(from);
      }
    }
    for (final entry in merged.entries) {
      for (final dep in entry.value) {
        if (!merged.containsKey(dep)) return ParseInvalid("task '${entry.key}' waits for '$dep', which is not the id of a task");
        if (dep == entry.key) return ParseInvalid("task '$dep' waits for itself");
      }
    }
    final cycle = PlanGraph(
      {for (final t in tasks) t.id: t.title},
      [for (final entry in merged.entries) for (final dep in entry.value) (dep, entry.key)],
    ).cycle();
    if (cycle != null) return ParseInvalid('the tasks wait for each other in a circle: ${cycle.join(' -> ')}');
    final rawPhase = args['phase'];
    if (rawPhase != null && rawPhase is! String) throw _WrongType('phase');
    final phase = switch ((rawPhase as String? ?? '').trim().toLowerCase()) {
      '' => null,
      'investigate' => DelegatePhase.investigate,
      'build' => DelegatePhase.build,
      _ => DelegatePhase.values.first,
    };
    if (rawPhase is String && rawPhase.trim().isNotEmpty && !const ['investigate', 'build'].contains(rawPhase.trim().toLowerCase())) {
      return const ParseInvalid('phase must be investigate or build');
    }
    final workers = args['workers'];
    if (workers != null && (workers is! num || workers != workers.toInt())) throw _WrongType('workers');
    if (workers is num && workers < 1) return const ParseInvalid('workers must be 1 or more');
    return ParseOk(
      Delegate(
        phase: phase,
        workers: workers is num ? workers.toInt() : null,
        summary: _requiredText(args, 'summary') ?? '',
        plan: plan,
        tasks: [
          for (final t in tasks)
            DelegateTask(
              id: t.id,
              title: t.title,
              instructions: t.instructions,
              files: t.files,
              revise: t.revise,
              dependsOn: merged[t.id]!.toList(),
            ),
        ],
      ),
    );
  }

  static ParseResult _parseAddProvider(Map<dynamic, dynamic> args) {
    final (draft, reason) = ProviderDraft.parse(args);
    return draft == null ? ParseInvalid(reason ?? 'unusable provider') : ParseOk(AddProvider(draft));
  }

  static ParseResult _parseUpdateSettings(Map<dynamic, dynamic> args) {
    switch (AgentSettings.parse(args)) {
      case SettingsPatchInvalid(:final reason):
        return ParseInvalid(reason);
      case SettingsPatch(:final changes):
        return changes.isEmpty
            ? const ParseInvalid('no changes')
            : ParseOk(UpdateSettings(changes));
    }
  }
}

class _WrongType implements Exception {
  _WrongType(this.key);
  final String key;
}
