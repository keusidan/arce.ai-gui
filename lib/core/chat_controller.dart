import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'agents.dart';
import 'attachments.dart';
import 'compaction.dart';
import 'engine.dart';
import 'generation.dart';
import 'prompt.dart';
import 'protocol.dart';
import 'run_progress.dart';
import 'settings_spec.dart';
import 'stream_segmenter.dart';
import 'tool_runtime.dart';

enum Role { user, assistant }

class UiMessage {
  const UiMessage({
    required this.id,
    required this.role,
    required this.text,
    this.thinking = '',
    this.thinkingMs = 0,
    this.thinkingSince = 0,
    this.question,
    this.settings,
    this.provider,
    this.tool,
    this.finish,
    this.activities = const [],
    this.agent,
    this.attachments = const [],
    this.time,
  });

  final int id;
  final Role role;
  final String text;
  final String thinking;

  /// How long the model thought, in milliseconds, of the thinking that has ended.
  final int thinkingMs;

  /// When the thinking that is going on now began (milliseconds since the epoch); 0 when the model is
  /// not thinking now. The screen counts the seconds from it.
  final int thinkingSince;
  final QuestionTile? question;

  /// Set with [question] when the card asks the user to approve a settings change.
  final List<SettingsChangeOk>? settings;

  /// Set with [question] when the card asks the user to approve adding a provider.
  final ProviderDraft? provider;

  /// Set with [question] when the card asks the user to approve one MCP tool call.
  final McpCall? tool;
  final FinishReason? finish;
  final List<ToolActivity> activities;
  final String? agent;
  final List<String> attachments;
  final DateTime? time;

  UiMessage copyWith({
    String? text,
    String? thinking,
    int? thinkingMs,
    int? thinkingSince,
    QuestionTile? question,
    List<SettingsChangeOk>? settings,
    ProviderDraft? provider,
    McpCall? tool,
    FinishReason? finish,
    List<ToolActivity>? activities,
  }) => UiMessage(
    id: id,
    role: role,
    text: text ?? this.text,
    thinking: thinking ?? this.thinking,
    thinkingMs: thinkingMs ?? this.thinkingMs,
    thinkingSince: thinkingSince ?? this.thinkingSince,
    question: question ?? this.question,
    settings: settings ?? this.settings,
    provider: provider ?? this.provider,
    tool: tool ?? this.tool,
    finish: finish ?? this.finish,
    activities: activities ?? this.activities,
    agent: agent,
    attachments: attachments,
    time: time,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'role': role.name,
    'text': text,
    'thinking': thinking,
    'thinkingMs': thinkingMs,
    'question': question?.toJson(),
    'tool': tool == null
        ? null
        : {'name': tool!.name, 'arguments': tool!.arguments},
    'settings': settings == null
        ? null
        : [
            for (final change in settings!)
              {'key': change.key, 'value': change.value},
          ],
    'provider': provider?.toJson(),
    'finish': finish?.name,
    'activities': [for (final a in activities) a.toJson()],
    'agent': agent,
    'attachments': attachments,
    'time': time?.millisecondsSinceEpoch,
  };

  factory UiMessage.fromJson(Map<String, Object?> json) => UiMessage(
    id: json['id'] as int,
    role: Role.values.byName(json['role'] as String),
    text: json['text'] as String,
    thinking: json['thinking'] as String? ?? '',
    thinkingMs: json['thinkingMs'] is num ? (json['thinkingMs'] as num).toInt() : 0,
    question: json['question'] == null
        ? null
        : QuestionTile.fromJson((json['question'] as Map).cast()),
    settings: json['settings'] is List
        ? _settingsFromJson(json['settings'] as List)
        : null,
    provider: json['provider'] is Map ? ProviderDraft.parse(json['provider']).$1 : null,
    tool: json['tool'] is Map && (json['tool'] as Map)['name'] is String
        ? McpCall(
            (json['tool'] as Map)['name'] as String,
            (json['tool'] as Map)['arguments'] is Map
                ? ((json['tool'] as Map)['arguments'] as Map)
                      .cast<String, Object?>()
                : const {},
          )
        : null,
    finish: json['finish'] == null
        ? null
        : FinishReason.values.byName(json['finish'] as String),
    activities: [
      for (final a in (json['activities'] as List? ?? const []))
        ToolActivity.fromJson((a as Map).cast()),
    ],
    agent: json['agent'] as String?,
    attachments: (json['attachments'] as List? ?? const []).cast<String>(),
    time: json['time'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(json['time'] as int),
  );
}

const _unset = Object();

class ChatState {
  const ChatState({
    this.messages = const [],
    this.task = TaskState.waiting,
    this.thinkingEnabled = true,
    this.error,
    this.notice,
    this.progress,
    this.queued = const [],
  });

  final List<UiMessage> messages;
  final TaskState task;
  final bool thinkingEnabled;
  final String? error;

  /// What the reply that is going on (or the last one) has done: the step, the requests, the time.
  /// Not saved with the conversation.
  final RunProgress? progress;

  /// Texts the user wrote while the reply was going on. They reach the model at the next break between
  /// two tools; what is left when the reply ends is sent as the next message. Not saved.
  final List<String> queued;

  /// e.g. the selected agent expects a larger model than the one loaded (spec §17.2).
  final String? notice;

  bool get isGenerating =>
      task == TaskState.thinking ||
      task == TaskState.generation ||
      task == TaskState.search;

  QuestionTile? get pendingQuestion =>
      task == TaskState.userWait && messages.isNotEmpty
      ? messages.last.question
      : null;

  /// The changes waiting for the user's approval, when [pendingQuestion] is an approval card.
  List<SettingsChangeOk>? get pendingSettings =>
      task == TaskState.userWait && messages.isNotEmpty
      ? messages.last.settings
      : null;

  /// The provider waiting for the user's approval.
  ProviderDraft? get pendingProvider => task == TaskState.userWait && messages.isNotEmpty
      ? messages.last.provider
      : null;

  /// The MCP tool call waiting for the user's approval.
  McpCall? get pendingTool => task == TaskState.userWait && messages.isNotEmpty
      ? messages.last.tool
      : null;

  /// The last reply stopped before it was finished and can be continued (spec: 続行).
  bool get canContinue {
    if (isGenerating || messages.isEmpty) return false;
    final last = messages.last;
    return last.role == Role.assistant &&
        last.question == null &&
        (last.finish == FinishReason.length ||
            last.finish == FinishReason.cancelled);
  }

  ChatState copyWith({
    List<UiMessage>? messages,
    TaskState? task,
    bool? thinkingEnabled,
    Object? error = _unset,
    Object? notice = _unset,
    Object? progress = _unset,
    List<String>? queued,
  }) => ChatState(
    messages: messages ?? this.messages,
    task: task ?? this.task,
    thinkingEnabled: thinkingEnabled ?? this.thinkingEnabled,
    error: identical(error, _unset) ? this.error : error as String?,
    notice: identical(notice, _unset) ? this.notice : notice as String?,
    progress: identical(progress, _unset) ? this.progress : progress as RunProgress?,
    queued: queued ?? this.queued,
  );
}

/// The settings that shape one generation; read afresh for every request.
class GenerationSettings {
  const GenerationSettings({
    this.tone,
    this.maxChars = 0,
    this.maxTokens = 2048,
    this.searchEnabled = true,
    this.retryLimit = 2,
    this.maxToolRounds = 30,
    this.speedAccuracy = 0.5,
    this.modelParamsB,
    this.agentOverride,
    this.aiAgentSelection = false,
    this.temperature,
    this.topP,
    this.topK,
    this.minP,
    this.dryMultiplier,
    this.userMaxTokens,
    this.useModelMax = false,
    this.extraPrompt = '',
    this.toolRepeatLimit = ChatController.repeatToolLimit,
    this.attachments = const AttachmentLimits(),
    this.compaction = const CompactionSettings(),
  });

  final String? tone;

  /// What the user set for the model that answers (the device's or the online ones'); null keeps
  /// the app's own value for that mode.
  final double? temperature;
  final double? topP;
  final int? topK;
  final double? minP;

  /// The device model's repetition penalty (DRY).
  final double? dryMultiplier;

  /// The reply length the user set for the model that answers (null: they set none, so the shared
  /// default is in [maxTokens]).
  final int? userMaxTokens;

  /// Online: with no length set by the user, ask for the model's own largest reply (when it is known).
  final bool useModelMax;

  /// How many identical tool calls in a row count as a loop.
  final int toolRepeatLimit;

  /// How much of the attached files is kept.
  final AttachmentLimits attachments;

  /// When and how a long conversation is made shorter.
  final CompactionSettings compaction;

  /// An extra instruction for the model that answers; empty for none.
  final String extraPrompt;

  static const extraPromptMaxChars = 2000;

  /// [extraPrompt] without anything that could act as a control sequence (the ChatML markers), and
  /// capped, so the user's own text can steer the answers but not rewrite the prompt's structure.
  String cleanExtraPrompt() {
    final t = extraPrompt.replaceAll(RegExp(r'<\|[^|]*\|>'), '').trim();
    return t.length > extraPromptMaxChars ? t.substring(0, extraPromptMaxChars) : t;
  }

  /// [base] with the user's values written over it.
  SamplingParams applyTo(SamplingParams base) => SamplingParams(
    temperature: temperature ?? base.temperature,
    topP: topP ?? base.topP,
    topK: topK ?? base.topK,
    minP: minP ?? base.minP,
    dryMultiplier: dryMultiplier ?? base.dryMultiplier,
  );

  /// 0 = no limit. Asked of the model in the system prompt.
  final int maxChars;
  final int maxTokens;
  final bool searchEnabled;

  /// Regenerations allowed for a cut-off tool call (詳細設定「エラー再書き込み回数」).
  final int retryLimit;

  /// A safety cap on the tool calls of one reply; 0 means no cap. It is high on purpose: calls with
  /// different arguments (searches for different words) are not a loop and must not be stopped.
  /// A loop is the same call made again and again, which [toolRepeatLimit] stops.
  final int maxToolRounds;

  /// 0 = fastest, 1 = most accurate (spec §8.1 速度 / 精度).
  final double speedAccuracy;

  /// Size of the loaded model in billions of parameters, when known.
  final double? modelParamsB;

  /// Agent chosen by the user; null lets the selector decide.
  final String? agentOverride;

  /// Let the loaded model settle the agent when the keyword rules are unsure (spec §17.1).
  final bool aiAgentSelection;

  /// The fast end of the slider skips reasoning and shortens replies; the accurate end keeps
  /// reasoning and allows longer replies. The user's own Thinking switch still wins when off.
  bool effectiveThinking(bool userSwitch) =>
      userSwitch && speedAccuracy >= 0.25;

  int effectiveMaxTokens() {
    final n = (maxTokens * (0.5 + speedAccuracy)).toInt();
    return n < 256 ? 256 : n;
  }
}

/// Everything needed to restore a conversation, persisted by the app (spec §33/§34).
class ConversationSnapshot {
  const ConversationSnapshot({
    required this.messages,
    required this.history,
    required this.nextId,
  });

  final List<UiMessage> messages;
  final List<ChatMessage> history;
  final int nextId;

  Map<String, Object?> toJson() => {
    'messages': [for (final m in messages) m.toJson()],
    'history': [for (final h in history) h.toJson()],
    'nextId': nextId,
  };

  factory ConversationSnapshot.fromJson(Map<String, Object?> json) =>
      ConversationSnapshot(
        messages: [
          for (final m in (json['messages'] as List))
            UiMessage.fromJson((m as Map).cast()),
        ],
        history: [
          for (final h in (json['history'] as List))
            ChatMessage.fromJson((h as Map).cast()),
        ],
        nextId: json['nextId'] as int,
      );
}

/// Applies one approved settings patch and returns the text the model is given back.
typedef SettingsApplier = Future<String> Function(
  List<SettingsChangeOk> changes,
);

/// Saves the approved provider and returns the text the model is given back.
typedef ProviderAdder = Future<String> Function(ProviderDraft draft);

/// Rebuilds the pending changes of a saved conversation; a key that is no longer settable is dropped.
List<SettingsChangeOk>? _settingsFromJson(List<dynamic> raw) {
  final changes = <SettingsChangeOk>[];
  for (final item in raw) {
    if (item is! Map) continue;
    final key = item['key'];
    if (key is! String) continue;
    final result = AgentSettings.normalize(key, item['value']);
    if (result is SettingsChangeOk) changes.add(result);
  }
  return changes.isEmpty ? null : changes;
}

/// Called at the points where a crash would lose work; [generating] marks an unfinished task.
typedef ConversationStore = void Function(
  ConversationSnapshot snapshot, {
  required bool generating,
});

class _Attempt {
  _Attempt(
    this.reason,
    this.thinking,
    this.answer,
    this.toolCallJson,
    this.cutInsideToolCall,
  );
  final FinishReason reason;
  final String thinking;
  final String answer;
  final String? toolCallJson;
  final bool cutInsideToolCall;
}

/// The pieces of the next request, as texts (see [ChatController.promptParts]).
class PromptParts {
  const PromptParts({required this.system, required this.tools, required this.conversation, required this.draft});

  /// The app's own rules, the agent's role and the extra instructions.
  final String system;

  /// The tool definitions of the agent and of the MCP servers: sent with every request.
  final String tools;

  /// The conversation so far, tool calls and their answers included.
  final String conversation;

  /// What is typed and not sent yet.
  final String draft;
}

/// Runs one conversation: picks an agent, builds prompts, streams output through
/// [StreamSegmenter], runs tool calls through [ToolRuntime] until the model answers, turns
/// ask_user into a question tile, and regenerates cut-off calls per [RetryPolicy].
class ChatController extends ChangeNotifier {
  ChatController(
    this._engine, {
    this._toolRuntime = const NoToolRuntime(),
    GenerationSettings Function()? settings,
    ConversationStore? store,
    this._extraTools,
    this._applySettings,
    this._mcpApproval,
    this._approvalDetails,
    this._addProvider,
    this.delegateEnabled,
    this.delegateInstructions,
    this.rememberTool,
    this.confirmAfterExternal,
    this.conversationKey,
    this.contextTokens,
    this.onFailure,
    StopSignal? stopSignal,
    RunMeter? meter,
  }) : _stopSignal = stopSignal ?? StopSignal(),
       meter = meter ?? RunMeter(),
       _settings = settings ?? (() => const GenerationSettings()),
       _store = store ?? ((_, {required generating}) {}) {
    this.meter.onChange = (p) => _update((s) => s.copyWith(progress: p));
    _router = AgentRouter((prompt, schema) async {
      final out = StringBuffer();
      final stream = _engine
          .generate(
            GenerateRequest(
              prompt: prompt,
              toolCallSchema: null,
              thinking: false,
              maxTokens: 32,
              sampling: const SamplingParams(
                temperature: 0.1,
                topP: 1,
                topK: 1,
                minP: 0,
                dryMultiplier: 0,
              ),
              strictJsonSchema: schema,
            ),
          )
          .where((e) => e is Piece)
          .cast<Piece>();
      final text = stream.fold<void>(null, (_, piece) => out.write(piece.text));
      try {
        await text.timeout(const Duration(seconds: 20));
      } on TimeoutException {
        _engine.cancel();
        return null;
      }
      return out.toString();
    });
  }

  /// How many identical tool calls in a row count as a loop.
  static const repeatToolLimit = 3;

  /// How often the screen is given a new state while text streams in, in milliseconds. A model sends
  /// several pieces between two frames; telling the screen about each one rebuilt the reply more
  /// often than it can be drawn, and the whole conversation with it. 50 ms still shows twenty
  /// updates a second, which reads as writing; a change of step and the end of a round are sent at once.
  static const _streamUpdateMs = 50;

  final InferenceEngine _engine;
  final ToolRuntime _toolRuntime;
  final StopSignal _stopSignal;

  /// Counts what the reply does (requests, tools, time) for [ChatState.progress]. A tool that works
  /// for a long time shares it, to report its own steps.
  final RunMeter meter;

  /// Told why a reply failed (the text the screen shows), so the app can report it.
  final void Function(String reason)? onFailure;

  /// Called when the user answers an approval with 「次から確認しない」: the tool that should not ask again.
  final Future<void> Function(String toolName)? rememberTool;

  /// Whether a command asks first once the model has read something from outside (a search result,
  /// an MCP tool's answer): text a stranger may have written, which can say "now run ...". The
  /// setting is the user's (`shellConfirmAfterExternal`); without it nothing asks for that reason.
  final bool Function()? confirmAfterExternal;

  /// Names this conversation for an online provider's prompt cache (sent only when that provider's switch is
  /// on): the same text for every request of the conversation, a different one for another conversation.
  /// Null sends none.
  final String? Function()? conversationKey;

  /// The context window of the model that answers, in tokens; null when it is not known (then a long
  /// conversation is not made shorter, and the engine says when it does not fit).
  final int? Function()? contextTokens;

  /// Whether this conversation holds text from outside (a search result or an MCP tool's answer, in
  /// this reply or an earlier one). Recomputed when a conversation is opened.
  bool _sawExternal = false;

  static bool _isExternal(ToolCall call) => call is WebSearch || (call is McpCall && call.name != Protocol.runCommandName && call.name != Protocol.ciStatusName && call.name != Protocol.showName);

  /// Whether the history holds the answer of an outside tool (a saved conversation that is opened again).
  static bool _historyHasExternal(Iterable<ChatMessage> history) {
    for (final turn in history) {
      if (turn is! AssistantTurn) continue;
      final json = turn.toolCallJson;
      if (json == null) continue;
      try {
        final name = (jsonDecode(json) as Map)['name'];
        if (name is String && (name == Protocol.webSearch.name || (name.startsWith('mcp_') && name != Protocol.ciStatusName))) return true;
      } catch (_) {
        // a call that cannot be read is not counted
      }
    }
    return false;
  }

  /// Why a command asks although it stays inside the environment: [_sawExternal] and the setting.
  bool _askBecauseExternal(McpCall call) =>
      Protocol.runsCommands(call) && _sawExternal && (confirmAfterExternal?.call() ?? false);

  /// Whether the coding mode can hand jobs to the developer model now. The `delegate` tool is
  /// offered to the coding agent only then.
  final bool Function()? delegateEnabled;

  /// What the planner is told about its team (see [CodingPrompts.plannerInstructions]); read when
  /// the coding agent starts a reply with `delegate` available.
  final String Function()? delegateInstructions;
  final GenerationSettings Function() _settings;
  final ConversationStore _store;
  final SettingsApplier? _applySettings;
  final ProviderAdder? _addProvider;

  /// Whether a tool call coming from an MCP server waits for the user. Null keeps the default
  /// (tools that write outside the device ask every time).
  final bool Function(String name, [Map<String, Object?> arguments])? _mcpApproval;

  /// Lines the app adds under a command on the approval card (which secrets it uses and where they may
  /// go); empty for a call that has nothing to add. Null adds nothing.
  final String Function(String name, Map<String, Object?> arguments)? _approvalDetails;

  /// Tools from outside the app (an MCP server). Read for every generation, so adding or removing
  /// one applies to the next reply.
  final Future<List<ToolDefinition>> Function()? _extraTools;
  late final AgentRouter _router;

  ChatState _state = const ChatState();
  ChatState get state => _state;

  /// A reply is being made or a tool is being run. Wider than [ChatState.isGenerating], which is
  /// false for a moment between the steps of one reply (choosing the agent, asking an MCP server).
  bool get isRunning => _busy || _state.isGenerating;

  final List<ChatMessage> _history = [];

  /// The pictures the history marks, by id. They live only as long as the conversation is open:
  /// a saved conversation keeps the marker, and a model that is asked about it later sees the
  /// file name instead.
  final Map<String, ImageData> _images = {};
  int _nextId = 0;
  AgentDefinition? _agent;

  /// The request the agent is chosen for; selection runs lazily at the start of generation.
  (String, bool) _agentRequest = ('', false);
  bool _busy = false;
  bool _stopRequested = false;

  void _update(ChatState Function(ChatState) change) {
    _state = change(_state);
    notifyListeners();
  }

  void setThinking(bool enabled) =>
      _update((s) => s.copyWith(thinkingEnabled: enabled));

  ConversationSnapshot snapshot() => ConversationSnapshot(
    messages: _state.messages,
    history: List.of(_history),
    nextId: _nextId,
  );

  void restore(ConversationSnapshot snapshot) {
    _history
      ..clear()
      ..addAll(snapshot.history);
    _sawExternal = _historyHasExternal(snapshot.history);
    _images.clear();
    _nextId = snapshot.nextId;
    // Choose the agent again for the restored conversation, from its last request.
    _agent = null;
    final lastUser = snapshot.messages.lastWhere(
      (m) => m.role == Role.user,
      orElse: () => const UiMessage(id: -1, role: Role.user, text: ''),
    );
    _agentRequest = (lastUser.text, false);
    final waiting =
        snapshot.messages.isNotEmpty && snapshot.messages.last.question != null;
    _update(
      (s) => ChatState(
        messages: snapshot.messages,
        task: waiting ? TaskState.userWait : TaskState.waiting,
        thinkingEnabled: s.thinkingEnabled,
      ),
    );
  }

  void clear() =>
      restore(const ConversationSnapshot(messages: [], history: [], nextId: 0));

  /// The texts the next request would carry, split by where they come from, so the screen can say how
  /// many tokens it is before it is sent: the app's instructions, the tool definitions, the
  /// conversation so far, and what is typed. The same pieces [_generate] builds from, with the agent
  /// chosen by the rules only (no request to a model just to count).
  Future<PromptParts> promptParts(String draft) async {
    final config = _settings();
    final agent = _agent ?? await _router.select(draft, false, config.agentOverride, useModel: false);
    final extra = _extraTools == null ? const <ToolDefinition>[] : await _extraTools();
    final canDelegate = delegateEnabled?.call() ?? false;
    final tools = [
      for (final t in agent.tools)
        if ((config.searchEnabled || t != Protocol.webSearch) && (t != Protocol.delegate || canDelegate)) t,
      ...extra,
    ];
    final instructions = [
      'Current role: ${agent.displayName}. ${agent.instructions}',
      if (canDelegate && agent.tools.contains(Protocol.delegate) && delegateInstructions != null) delegateInstructions!(),
      if (config.maxChars > 0) 'Keep each reply under ${config.maxChars} characters.',
      if (config.extraPrompt.isNotEmpty) config.cleanExtraPrompt(),
    ];
    final thinking = config.effectiveThinking(_state.thinkingEnabled);
    String build(List<ChatMessage> history, List<ToolDefinition> toolList) => ChatMlPromptBuilder.build(
          history,
          toolList,
          config.tone,
          thinking,
          extraInstructions: instructions,
        );
    final bare = build(const [], const []);
    final withTools = build(const [], tools);
    final withHistory = build(_history, tools);
    final withDraft = build([..._history, UserTurn(draft)], tools);
    // each step only inserts text, so what a step added is the difference in length
    return PromptParts(
      system: bare,
      tools: withTools.substring(bare.indexOf('<|im_end|>'), bare.indexOf('<|im_end|>') + withTools.length - bare.length),
      conversation: _inserted(withTools, withHistory),
      draft: draft.trim().isEmpty ? '' : _inserted(withHistory, withDraft),
    );
  }

  /// What [longer] has that [shorter] does not, when [longer] is [shorter] with text inserted once.
  static String _inserted(String shorter, String longer) {
    var start = 0;
    while (start < shorter.length && start < longer.length && shorter.codeUnitAt(start) == longer.codeUnitAt(start)) {
      start++;
    }
    return longer.substring(start, start + longer.length - shorter.length);
  }

  /// Returns when the reply has finished (or stopped for a question); callers may ignore it.
  Future<void> send(String text, {List<Attachment> attachments = const []}) {
    if ((text.trim().isEmpty && attachments.isEmpty) ||
        _state.isGenerating ||
        _busy) {
      return Future.value();
    }
    final limits = _settings().attachments;
    for (final a in attachments.take(limits.maxFiles)) {
      final image = a.image;
      if (image != null) _images[image.id] = image;
    }
    _history.add(UserTurn(AttachmentPolicy.compose(text, attachments, limits: limits)));
    _userInputs++;
    _append(
      UiMessage(
        id: _nextId++,
        role: Role.user,
        text: text,
        attachments: [for (final a in attachments) a.name],
        time: DateTime.now(),
      ),
    );
    _agent = null;
    _agentRequest = (text, attachments.isNotEmpty);
    return _start('');
  }

  /// Puts [text] in the reply that is going on: it is read by the model at the next break between two
  /// tools (a tool that is running is not cut off), or sent as the next message when the reply ends
  /// first. Returns false when nothing is running (use [send]) or the text is empty.
  bool interject(String text) {
    if (text.trim().isEmpty || !isRunning) return false;
    _update((s) => s.copyWith(queued: [...s.queued, text.trim()]));
    return true;
  }

  /// Takes back a text that was queued by [interject], before the model has read it.
  void unqueue(int index) {
    if (index < 0 || index >= _state.queued.length) return;
    _update((s) => s.copyWith(queued: [...s.queued]..removeAt(index)));
  }

  /// The queued texts as one message, and the queue emptied.
  String _takeQueued() {
    final text = _state.queued.join('\n\n');
    if (_state.queued.isNotEmpty) {
      _userInputs++;
      _update((s) => s.copyWith(queued: const []));
    }
    return text;
  }

  var _userInputs = 0;

  /// How many times the user has written (a message, a text sent in between) or answered a question of the model in
  /// this chat. It only grows. The 分担モード builds only once the user has answered after the reports (see
  /// `DelegateSession`); an approval card of a tool, a setting or a provider is not such an answer.
  int get userInputs => _userInputs;

  /// Answers the pending question tile (or approves a settings change) and resumes generation.
  Future<void> answer(List<String> selected, String? freeText) async {
    if (_state.pendingQuestion == null || _busy) return Future.value();
    final free = freeText != null && freeText.trim().isNotEmpty
        ? [freeText]
        : const <String>[];
    final answer = [...selected, ...free].join(', ');
    final changes = _state.pendingSettings;
    final pending = _state.pendingTool;
    final draft = _state.pendingProvider;
    var toolResponse = answer;
    if (pending != null) {
      _busy = true;
      try {
        if (ToolApproval.isApproval(selected)) {
          // The card goes the moment the button is pressed, and the screen says what runs: a tool can
          // take a minute, and a card that stays there looked as if the button had frozen. The state
          // stays "working" until the next request is sent, so nothing (the foreground service
          // included) sees a gap in between.
          meter.begin();
          final (stage, detail) = _toolStage(pending);
          meter.stage(stage, detail: detail);
          _stopRequested = false;
          _stopSignal.reset();
          _update((s) => s.copyWith(task: TaskState.generation));
          if (ToolApproval.isAlways(selected)) {
            try {
              await rememberTool?.call(pending.name);
            } catch (_) {
              // the answer is still "run it"; only the memory failed
            }
          }
          ToolOutcome outcome;
          try {
            outcome = await _toolRuntime.run(pending);
          } catch (e) {
            // a tool that throws must not take the chat down with it: the model is told, like any failure
            outcome = ToolOutcome('The tool failed: $e', ToolActivity('Tool', '${ToolApproval.label(pending.name)} に失敗: $e', failed: true));
          }
          meter.toolRun();
          if (_isExternal(pending)) _sawExternal = true;
          toolResponse = outcome.response;
          _update(
            (s) => s.copyWith(
              messages: [
                for (final m in s.messages)
                  m.id == s.messages.last.id
                      ? m.copyWith(
                          activities: [...m.activities, outcome.activity],
                        )
                      : m,
              ],
            ),
          );
        } else {
          toolResponse =
              'The user declined to run ${pending.name}. Nothing was done. '
              'Do not call it again unless they ask for it.';
        }
      } finally {
        _busy = false;
      }
    } else if (draft != null) {
      // the card is the approval: nothing is saved unless the user picked 追加する
      _busy = true;
      try {
        toolResponse = ProviderApproval.isApproval(selected)
            ? await _saveProvider(draft)
            : 'The user declined to add the provider. Nothing was added. '
                  'Do not propose it again unless they ask for it.';
      } finally {
        _busy = false;
      }
    } else if (changes != null) {
      // the card is the approval: nothing is written unless the user picked 承認
      _busy = true;
      try {
        toolResponse = SettingsApproval.isApproval(selected)
            ? await _approve(changes)
            : 'The user rejected the change. Nothing was changed.';
      } finally {
        _busy = false;
      }
    }
    if (pending == null && draft == null && changes == null) _userInputs++;
    _history.add(ToolResponseTurn(toolResponse));
    _append(
      UiMessage(
        id: _nextId++,
        role: Role.user,
        text: answer,
        time: DateTime.now(),
      ),
    );
    // stopped while the tool ran: it is over, and the model is not asked again (the history is complete:
    // the tool's answer is in it)
    if (_stopRequested) {
      _stopRequested = false;
      meter.end();
      _finishWith(TaskState.cancelled);
      return _sendQueued();
    }
    return _start('');
  }

  /// Writes the approved changes through the app and reports the result to the model.
  Future<String> _approve(List<SettingsChangeOk> changes) async {
    final applier = _applySettings;
    if (applier == null) {
      return 'The user approved it, but this build cannot change its settings.';
    }
    try {
      return await applier(changes);
    } catch (e) {
      return 'The user approved it, but the change failed: $e';
    }
  }

  /// Saves the approved provider through the app and reports the result to the model.
  Future<String> _saveProvider(ProviderDraft draft) async {
    final adder = _addProvider;
    if (adder == null) {
      return 'The user approved it, but this build cannot add providers.';
    }
    try {
      return await adder(draft);
    } catch (e) {
      return 'The user approved it, but adding the provider failed: $e';
    }
  }

  /// Stops the reply. A stop that comes while nothing is being generated yet (the agent is being
  /// chosen, an MCP server is being asked, a tool is running) is kept, and ends the reply before the
  /// next request is sent; the engine alone would forget it, as a new request starts it afresh.
  void stop() {
    if (_busy) {
      _stopRequested = true;
      _stopSignal.fire();
    }
    _engine.cancel();
  }


  /// Replaces the last reply with a fresh one generated from the same context.
  Future<void> regenerate() {
    if (_state.isGenerating ||
        _busy ||
        _state.messages.isEmpty ||
        _state.messages.last.role != Role.assistant) {
      return Future.value();
    }
    _dropLastReplyFromHistory();
    _update(
      (s) => s.copyWith(messages: s.messages.sublist(0, s.messages.length - 1)),
    );
    return _start('');
  }

  Future<void> continueReply() {
    if (!_state.canContinue || _busy) return Future.value();
    final partial = _state.messages.last;
    // The partial reply is regenerated from its own text, so drop it from the context first.
    if (_history.isNotEmpty && _history.last is AssistantTurn) {
      _history.removeLast();
    }
    _update(
      (s) => s.copyWith(messages: s.messages.sublist(0, s.messages.length - 1)),
    );
    return _start(partial.text);
  }

  /// Removes the assistant turns (and tool responses) since the last user or answer message.
  void _dropLastReplyFromHistory() {
    while (_history.isNotEmpty) {
      final last = _history.last;
      final before = _history.length >= 2
          ? _history[_history.length - 2]
          : null;
      final isToolResult =
          last is ToolResponseTurn &&
          before is AssistantTurn &&
          before.toolCallJson != null;
      if (last is AssistantTurn || isToolResult) {
        _history.removeLast();
      } else {
        break;
      }
    }
  }

  Future<void> _start(String prefill) async {
    _busy = true;
    _stopRequested = false;
    _stopSignal.reset();
    meter.begin();
    try {
      await _generate(prefill);
    } catch (e) {
      // anything unexpected must not leave the chat stuck in "generating"
      _fail(_nextId - 1, e.toString());
    } finally {
      _busy = false;
      _stopRequested = false;
      meter.end();
      // the state may not have changed since the last notification, but "running" has
      notifyListeners();
    }
    await _sendQueued();
  }

  /// What the user wrote during the reply and the model has not read: sent as the next message once
  /// the reply has ended (finished or stopped). After an error or a question the texts stay queued,
  /// shown under the input, until the user takes them back or the next reply reads them.
  Future<void> _sendQueued() {
    final done = _state.task == TaskState.completed || _state.task == TaskState.cancelled;
    if (!done || _state.queued.isEmpty || _busy || _state.isGenerating) return Future.value();
    return send(_takeQueued());
  }

  Future<void> _generate(String prefill) async {
    final config = _settings();
    final agent = _agent ??= await _router.select(
      _agentRequest.$1,
      _agentRequest.$2,
      config.agentOverride,
      useModel: config.aiAgentSelection && _engine.isLoaded,
    );
    final extra = _extraTools == null
        ? const <ToolDefinition>[]
        : await _extraTools();
    final canDelegate = delegateEnabled?.call() ?? false;
    final tools = [
      for (final t in agent.tools)
        if ((config.searchEnabled || t != Protocol.webSearch) && (t != Protocol.delegate || canDelegate)) t,
      ...extra,
    ];
    final schema = tools.isEmpty
        ? null
        : jsonEncodeSchema(Protocol.toolCallSchema(tools));
    final retry = RetryPolicy(config.retryLimit);
    final instructions = [
      'Current role: ${agent.displayName}. ${agent.instructions}',
      if (canDelegate && agent.tools.contains(Protocol.delegate) && delegateInstructions != null) delegateInstructions!(),
      if (config.maxChars > 0)
        'Keep each reply under ${config.maxChars} characters.',
      if (config.extraPrompt.isNotEmpty) config.cleanExtraPrompt(),
    ];
    final modelB = config.modelParamsB;
    final sizeNotice = modelB != null && modelB < agent.minModelParamsB
        ? '「${agent.displayName}」は${agent.minModelParamsB}B以上のモデルを推奨します（現在 ${modelB}B）。モデルは自動で変更しません。'
        : null;

    var id = _nextId++;
    _append(
      UiMessage(
        id: id,
        role: Role.assistant,
        text: prefill,
        agent: agent.displayName,
        time: DateTime.now(),
      ),
    );
    _update((s) => s.copyWith(error: null, notice: sizeNotice));
    _store(snapshot(), generating: true);

    var earlierText = '';
    // what the model thought in the rounds before this one: each round streams only its own, and
    // without this the thinking of the first round vanished when the second began
    var earlierThinking = '';
    // the planner of the coding mode, or the one model that answers
    // who answers, as the stage texts say it: "plan が考えています" (an English name is set apart by a space) or "モデルが…"
    final actor = canDelegate && agent.tools.contains(Protocol.delegate) ? 'plan ' : 'モデル';
    var emptyReplies = 0;
    // tool calls the model wrote that could not be used (a task with no instructions, a plan that
    // loops ...): the model is told why and writes it again, instead of the reply ending in an error
    var unusableCalls = 0;
    final activities = <ToolActivity>[];
    var rounds = 0;
    var roundPrefill = prefill;
    // A model that keeps asking for the same tool with the same arguments never finishes. The same
    // call made [toolRepeatLimit] times in this reply, in a row or with others between, is a loop;
    // a different call (another search word, another tool) is never counted as one.
    final seenCalls = <String, int>{};

    while (true) {
      meter.round(rounds + 1);
      final thinking =
          config.effectiveThinking(_state.thinkingEnabled) &&
          roundPrefill.isEmpty;
      // a long conversation is made shorter before the request that would not fit
      final room = await _makeRoom(config, tools, instructions, thinking, actor);
      if (room != null) {
        activities.add(ToolActivity('Compaction', room));
        _replace(id, (m) => m.copyWith(activities: List.of(activities)));
        _store(snapshot(), generating: true);
      }
      final prompt = ChatMlPromptBuilder.build(
        _history,
        tools,
        config.tone,
        thinking,
        assistantPrefill: roundPrefill,
        extraInstructions: instructions,
      );
      final request = GenerateRequest(
        prompt: prompt,
        toolCallSchema: schema,
        tools: tools,
        images: _images,
        agentId: agent.id,
        conversationKey: conversationKey?.call(),
        continuation: roundPrefill.isNotEmpty,
        assistantReasoning: [
          for (final turn in _history)
            if (turn is AssistantTurn) turn.reasoning ?? '',
        ],
        user: UserSampling(temperature: config.temperature, topP: config.topP, maxTokens: config.userMaxTokens, speedAccuracy: config.speedAccuracy, useModelMax: config.useModelMax),
        thinking: thinking,
        maxTokens: config.effectiveMaxTokens(),
        sampling: config.applyTo(
          thinking
              ? SamplingParams.qwen3Thinking
              : SamplingParams.qwen3NonThinking,
        ),
      );

      var attempts = 0;
      late _Attempt result;
      String? unusableReason;
      while (true) {
        try {
          result = await _attempt(id, request, earlierText, roundPrefill, earlierThinking: earlierThinking, actor: actor);
        } on EngineException catch (e) {
          _fail(id, e.message);
          return;
        }
        final parsed = result.toolCallJson == null
            ? null
            : ToolCallParser.parse(result.toolCallJson!, tools);
        var semanticError = parsed is ParseInvalid ? parsed.reason : null;
        unusableReason = null;
        if (semanticError != null &&
            unusableCalls < config.retryLimit &&
            result.reason != FinishReason.cancelled &&
            !(result.reason == FinishReason.length && result.cutInsideToolCall)) {
          unusableReason = semanticError;
          semanticError = null;
        }
        final step = retry.decide(
          result.reason,
          endedInsideToolCall: result.cutInsideToolCall,
          semanticError: semanticError,
          attemptsSoFar: attempts,
        );
        if (step is Regenerate) {
          attempts = step.attempt;
        } else if (step is Fail) {
          _fail(id, step.reason);
          return;
        } else {
          break;
        }
      }

      final parsed = result.toolCallJson == null
          ? null
          : ToolCallParser.parse(result.toolCallJson!, tools);
      // a call that went through mcp_call is the server's own tool from here on: the card, the memory of
      // tools that are not asked about again and the run all see the real tool
      final call = parsed is ParseOk ? (parsed.call is McpCall ? (parsed.call as McpCall).unwrapped : parsed.call) : null;
      if (unusableReason != null) {
        unusableCalls++;
        // the broken call is not kept in the history (a provider would be sent JSON it cannot read);
        // the model hears what was wrong as a note from the app
        _history
          ..add(AssistantTurn(result.answer.trim().isEmpty ? '(a tool call that could not be used)' : result.answer, null, result.thinking))
          ..add(UserTurn('[from the app] Your last tool call could not be used: $unusableReason. Call the tool again in a correct form, or answer without it.'));
        earlierThinking = _join(earlierThinking, result.thinking);
        earlierText = _join(earlierText, result.answer);
        activities.add(ToolActivity('Tool', '道具の呼び出しが読めませんでした（$unusableReason）。書き直します', failed: true));
        roundPrefill = '';
        _replace(id, (m) => m.copyWith(text: earlierText, activities: List.of(activities)));
        continue;
      }
      _history.add(
        AssistantTurn(result.answer, call == null ? null : result.toolCallJson, result.thinking),
      );
      earlierThinking = _join(earlierThinking, result.thinking);
      final shown = _join(earlierText, result.answer);

      switch (call) {
        case null:
          // A reply with nothing in it (no text, no tool, and nothing from the tools before it) is not
          // an answer: it was a model that thought and then said nothing, or ran out of tokens while
          // it thought. Say so, instead of leaving an empty chat that looks as if the reply was lost.
          if (result.reason != FinishReason.cancelled && shown.trim().isEmpty) {
            final cut = result.reason == FinishReason.length;
            if (!cut && emptyReplies < config.retryLimit) {
              emptyReplies++;
              _history.removeLast();
              continue;
            }
            _fail(
              id,
              cut
                  ? '$actorは、思考だけで出力の上限に達し、返信の本文を書けませんでした。設定の「最大トークン」を増やすか、思考を弱めてください。'
                  : '$actorの返信が空でした（思考のあとで何も書かれませんでした）。もう一度試すか、別のモデルを選んでください。',
            );
            return;
          }
          _replace(
            id,
            (m) => m.copyWith(
              text: shown,
              finish: result.reason,
              activities: List.of(activities),
            ),
          );
          _finishWith(
            result.reason == FinishReason.cancelled
                ? TaskState.cancelled
                : TaskState.completed,
          );
          return;
        case AskUser(:final tile):
          _replace(
            id,
            (m) => m.copyWith(
              text: shown,
              question: tile,
              finish: result.reason,
              activities: List.of(activities),
            ),
          );
          _finishWith(TaskState.userWait);
          return;
        case final McpCall mcp
            when (_mcpApproval?.call(mcp.name, mcp.arguments) ??
                    ToolApproval.needsApproval(mcp.name, mcp.arguments)) ||
                _askBecauseExternal(mcp):
          // a tool that writes outside the device: one card, and nothing runs until 実行する
          _replace(
            id,
            (m) => m.copyWith(
              text: shown,
              question: ToolApproval.tile(
                mcp,
                rememberable: true,
                note: _askBecauseExternal(mcp) ? '検索や外部ツールの結果を読んだあとなので、確認します' : '',
                details: _approvalDetails?.call(mcp.name, mcp.arguments) ?? '',
              ),
              tool: mcp,
              finish: result.reason,
              activities: List.of(activities),
            ),
          );
          _finishWith(TaskState.userWait);
          return;
        case UpdateSettings(:final changes):
          _replace(
            id,
            (m) => m.copyWith(
              text: shown,
              question: SettingsApproval.tile(changes),
              settings: changes,
              finish: result.reason,
              activities: List.of(activities),
            ),
          );
          _finishWith(TaskState.userWait);
          return;
        case AddProvider(:final draft):
          _replace(
            id,
            (m) => m.copyWith(
              text: shown,
              question: ProviderApproval.tile(draft),
              provider: draft,
              finish: result.reason,
              activities: List.of(activities),
            ),
          );
          _finishWith(TaskState.userWait);
          return;
        default:
          final key = _toolKey(call);
          final times = (seenCalls[key] ?? 0) + 1;
          seenCalls[key] = times;
          if (times >= config.toolRepeatLimit) {
            _fail(id, '同じ道具を同じ引数で繰り返し呼んでいます（$key）');
            return;
          }
          rounds++;
          if (config.maxToolRounds > 0 && rounds > config.maxToolRounds) {
            _fail(id, 'ツールの呼び出しが上限（${config.maxToolRounds} 回）を超えました。設定の「ツール呼び出しの上限」で増やせます');
            return;
          }
          _update(
            (s) => s.copyWith(
              task: call is WebSearch ? TaskState.search : TaskState.generation,
            ),
          );
          final (toolStage, toolDetail) = _toolStage(call);
          meter.stage(toolStage, detail: toolDetail);
          final outcome = await _toolRuntime.run(call);
          meter.toolRun();
          if (_isExternal(call)) _sawExternal = true;
          activities.add(outcome.activity);
          _history.add(ToolResponseTurn(outcome.response));
          earlierText = outcome.shown == null ? shown : _join(shown, outcome.shown!);
          roundPrefill = '';
          _replace(
            id,
            (m) =>
                m.copyWith(text: earlierText, activities: List.of(activities)),
          );
          // what the reply has so far is kept now: a coding reply takes minutes, and the system may
          // close the app or the user may leave before it is over
          _store(snapshot(), generating: true);
          // a break between two tools: what the user wrote meanwhile is read now, as a message of its
          // own, and the model goes on in a new reply under it
          final interjected = _takeQueued();
          if (interjected.isNotEmpty && !_stopRequested) {
            _history.add(UserTurn(interjected));
            _append(UiMessage(id: _nextId++, role: Role.user, text: interjected, time: DateTime.now()));
            id = _nextId++;
            _append(UiMessage(id: id, role: Role.assistant, text: '', agent: agent.displayName, time: DateTime.now()));
            earlierText = '';
            earlierThinking = '';
            activities.clear();
            _store(snapshot(), generating: true);
          }
      }
    }
  }

  /// Makes the next request fit: when it would take more than the set share of the context, the old
  /// tool answers are cut short, and if that is not enough, what came before the last few messages of
  /// the user is replaced by a summary the model writes (a group of the conversation at a time, so
  /// that the request for the summary fits too). Returns what was done, for the screen; null when
  /// nothing was needed or nothing could be done (the request then goes as it is).
  Future<String?> _makeRoom(
    GenerationSettings config,
    List<ToolDefinition> tools,
    List<String> instructions,
    bool thinking,
    String actor,
  ) async {
    final c = config.compaction;
    final context = contextTokens?.call();
    if (!c.enabled || context == null || context <= 0) return null;
    final limit = context * c.atPercent ~/ 100;
    int used() => Compaction.estimateTokens(
          ChatMlPromptBuilder.build(_history, tools, config.tone, thinking, extraInstructions: instructions),
        );
    final before = used();
    if (before <= limit) return null;

    final cut = Compaction.cutIndex(_history, c.keepTurns);
    final clipped = Compaction.clipToolResults(_history, cut ?? (_history.length > 6 ? _history.length - 6 : 0), c.toolResultChars);
    var note = '';
    if (!identical(clipped, _history)) {
      _history
        ..clear()
        ..addAll(clipped);
      note = '古い道具の結果を切り詰めました';
      if (used() <= limit) return '$note（約 ${_tokens(before)} → ${_tokens(used())} トークン）';
    }
    if (cut == null) return note.isEmpty ? null : '$note（約 ${_tokens(before)} → ${_tokens(used())} トークン。直近の発言より前がないので、要約はしていません）';

    meter.stage('会話の前半を要約しています');
    final older = _history.sublist(0, cut);
    final summary = await _summaryOf(older, c, context);
    if (summary == null) {
      // no summary: the request goes as it is (the engine or provider will say if it does not fit)
      return note.isEmpty ? null : '$note（約 ${_tokens(before)} → ${_tokens(used())} トークン。要約は書けませんでした）';
    }
    final replaced = Compaction.replace(_history, cut, summary);
    _history
      ..clear()
      ..addAll(replaced);
    return '会話の前半（${older.length} 件）を要約しました（約 ${_tokens(before)} → ${_tokens(used())} トークン）';
  }

  /// Whether [compactNow] has something to summarize: the conversation is longer than the messages kept.
  bool get canCompact => !isRunning && Compaction.cutIndex(_history, _settings().compaction.keepTurns) != null;

  /// Summarizes the conversation now (the button under the input), whatever the context window says.
  /// Returns what happened, in a sentence for the screen.
  Future<String> compactNow() async {
    if (isRunning) return '返信の最中は要約できません';
    final c = _settings().compaction;
    final cut = Compaction.cutIndex(_history, c.keepTurns);
    if (cut == null) return '要約する前半がありません（直近 ${c.keepTurns} 件の発言より前がありません）';
    _busy = true;
    _stopRequested = false;
    _stopSignal.reset();
    meter.begin();
    meter.stage('会話の前半を要約しています');
    try {
      final older = _history.sublist(0, cut);
      final summary = await _summaryOf(older, c, contextTokens?.call() ?? 8192);
      if (summary == null) return '要約を書けませんでした。もう一度試すか、別のモデルで試してください';
      final replaced = Compaction.replace(_history, cut, summary);
      _history
        ..clear()
        ..addAll(replaced);
      _store(snapshot(), generating: false);
      return '会話の前半（${older.length} 件）を要約しました。次の返信から、この要約を使います';
    } finally {
      _busy = false;
      meter.end();
      notifyListeners();
    }
  }

  /// The summary of [older], written by the model a group at a time (each request carries the summary
  /// so far, so it stays small enough for [context]); null when a group got no usable answer.
  Future<String?> _summaryOf(List<ChatMessage> older, CompactionSettings c, int context) async {
    final groupChars = (context * 0.4).round().clamp(800, 60000);
    var summary = '';
    for (final group in Compaction.chunks(Compaction.lines(older, toolChars: c.toolResultChars), groupChars)) {
      final next = await _summarize(Compaction.request(group, before: summary, maxChars: c.summaryChars), c.summaryChars, context);
      if (next == null) return null;
      summary = next;
    }
    return summary.isEmpty ? null : summary;
  }

  static String _tokens(int n) => n >= 1000 ? '${(n / 1000).toStringAsFixed(1)}k' : '$n';

  /// One request to the model for a summary; null when it gave nothing usable.
  Future<String?> _summarize(String request, int summaryChars, int context) async {
    final prompt = ChatMlPromptBuilder.build(
      [UserTurn(request)],
      const [],
      null,
      false,
      extraInstructions: const [Compaction.instruction],
    );
    final out = StringBuffer();
    meter.modelRequest();
    try {
      await for (final event in _engine.generate(
        GenerateRequest(
          prompt: prompt,
          toolCallSchema: null,
          thinking: false,
          maxTokens: (summaryChars + 512).clamp(256, context ~/ 2 < 256 ? 256 : context ~/ 2),
          sampling: SamplingParams.qwen3NonThinking,
        ),
      )) {
        if (event is Piece) out.write(event.text);
      }
    } on EngineException {
      return null;
    }
    return Compaction.clean(out.toString());
  }

  /// From this many tokens of prompt on, the waiting text says how long a device model may need. A hint for
  /// the screen, not a limit.
  static const slowPromptTokens = 3000;

  static String _grouped(int n) => n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');

  /// One pass through the engine; streams text and thinking into message [id].
  Future<_Attempt> _attempt(
    int id,
    GenerateRequest request,
    String earlierText,
    String prefill, {
    String earlierThinking = '',
    String actor = 'モデル',
  }) async {
    final task = GenerationTask();
    final segmenter = StreamSegmenter();
    var reason = FinishReason.error;
    // The text of this round, appended to as it arrives: a String is copied on every `+=`, which made
    // a long reply quadratic in its own length.
    final thinking = StringBuffer();
    final answer = StringBuffer(prefill);
    String? toolCallJson;
    // how long the model thinks: counted from its first thinking text to its first word of the reply
    // (or the end), and added to what earlier rounds of this reply already thought
    final earlierThinkingMs = _state.messages.where((m) => m.id == id).firstOrNull?.thinkingMs ?? 0;
    var thoughtMs = 0;
    DateTime? thinkingSince;

    // What the screen has not been told yet, and the step to tell it with. The state is pushed at most
    // every [_streamUpdateMs] while pieces stream in, and at once when the step changes or the round ends.
    var stage = '';
    var thinkingStage = false;
    final clock = Stopwatch()..start();
    var lastFlushMs = -_streamUpdateMs;
    var dirty = false;

    void endThinking() {
      final since = thinkingSince;
      if (since == null) return;
      thoughtMs += DateTime.now().difference(since).inMilliseconds;
      thinkingSince = null;
    }

    void flush({bool force = false}) {
      if (!dirty) return;
      final now = clock.elapsedMilliseconds;
      if (!force && now - lastFlushMs < _streamUpdateMs) return;
      dirty = false;
      lastFlushMs = now;
      final thought = thinking.toString();
      final text = _join(earlierText, answer.toString());
      final shownThinking = _join(earlierThinking, thought);
      final thinkingMs = earlierThinkingMs + thoughtMs;
      final since = thinkingSince?.millisecondsSinceEpoch ?? 0;
      // the line under the step is read now, not for every piece: it looks at the end of the thought
      meter.stage(stage, detail: thinkingStage ? ThinkingHeadline.of(thought) : '');
      _update(
        (s) => s.copyWith(
          task: task.state,
          messages: [
            for (final m in s.messages)
              m.id == id
                  ? m.copyWith(
                      text: text,
                      thinking: shownThinking,
                      thinkingMs: thinkingMs,
                      thinkingSince: since,
                    )
                  : m,
          ],
        ),
      );
    }

    void consume(List<StreamEvent> events) {
      for (final event in events) {
        switch (event) {
          case ThinkingText(:final text):
            final began = thinkingSince == null;
            thinking.write(text);
            thinkingSince ??= DateTime.now();
            task.moveTo(TaskState.thinking);
            stage = '$actorが考えています';
            thinkingStage = true;
            dirty = true;
            // the seconds the screen counts start now: tell it at once, not on the next tick
            if (began) flush(force: true);
          case PlainText(:final text):
            final wasThinking = thinkingSince != null;
            // tell the last headline of the thought before the step changes (and clears it)
            if (wasThinking) flush(force: true);
            endThinking();
            answer.write(text);
            final moved = task.state != TaskState.generation;
            task.moveTo(TaskState.generation);
            stage = '$actorが回答を書いています';
            thinkingStage = false;
            dirty = true;
            if (wasThinking || moved) flush(force: true);
          case ToolCallEnd(:final json):
            // one call is run per round; of several calls in one reply (parallel calls) the first is the one
            toolCallJson ??= json;
          case ToolCallStart() || ToolCallDelta():
            final wasThinking = thinkingSince != null;
            if (wasThinking) flush(force: true);
            endThinking();
            final moved = task.state != TaskState.generation;
            task.moveTo(TaskState.generation);
            stage = '$actorが道具の呼び出しを書いています';
            thinkingStage = false;
            dirty = true;
            if (moved) flush(force: true);
        }
      }
      flush();
    }

    // stopped before this request could start: it is not sent
    if (_stopRequested) {
      return _Attempt(FinishReason.cancelled, thinking.toString(), answer.toString(), null, false);
    }
    _update(
      (s) => s.copyWith(
        task: request.thinking ? TaskState.thinking : TaskState.generation,
      ),
    );
    meter.modelRequest();
    // a device model reads the whole prompt before its first word: for a prompt this long that takes
    // minutes on a phone, and the screen should say what it waits for instead of looking stuck
    final promptTokens = (utf8.encode(request.prompt).length / 3).ceil();
    meter.stage(
      promptTokens < slowPromptTokens
          ? '$actorに送信しています（返信を待っています）'
          : '$actorに送信しています（返信を待っています。指示は約 ${_grouped(promptTokens)} トークン。ローカルモデルでは、最初にこれを読み込むので、数分かかることがあります）',
    );
    try {
      await for (final event in _engine.generate(request)) {
        switch (event) {
          case Piece(:final text):
            consume(segmenter.feed(text));
          case Usage(:final promptTokens, :final completionTokens, :final cachedTokens):
            meter.usage(promptTokens: promptTokens, completionTokens: completionTokens, cachedTokens: cachedTokens);
          case Finished(reason: final r):
            reason = r;
        }
      }
      consume(segmenter.finish());
      flush(force: true);
    } finally {
      // a reply that was only thinking (or stopped or failed while thinking) still ends its thinking
      if (thinkingSince != null) {
        endThinking();
        dirty = true;
      }
      flush(force: true);
    }
    return _Attempt(
      reason,
      thinking.toString(),
      answer.toString(),
      toolCallJson,
      segmenter.isInsideToolCall,
    );
  }

  /// What the screen says while [call] runs: the step and a line more.
  static (String, String) _toolStage(ToolCall call) => switch (call) {
    WebSearch() => ('検索しています', call.query),
    GetWeather() => ('天気を調べています', call.location),
    GetTime() => ('時刻を調べています', call.timezone ?? ''),
    McpCall() => ('ツールを実行しています', call.name),
    Delegate() => ('coding に依頼しています', [for (final t in call.tasks) t.title].where((t) => t.trim().isNotEmpty).join('、')),
    _ => ('ツールを実行しています', ''),
  };

  /// The name and arguments of [call], so two identical requests look identical.
  static String _toolKey(ToolCall call) => switch (call) {
    WebSearch() => 'web_search:${call.query}',
    GetWeather() => 'get_weather:${call.location}',
    GetTime() => 'get_time:${call.timezone ?? ''}',
    GetSettings() => 'get_settings',
    AskUser() => 'ask_user',
    UpdateSettings() =>
      'update_settings:${call.changes.map((c) => '${c.key}=${c.value}').join(',')}',
    AddProvider() => 'add_provider:${call.draft.baseUrl}',
    McpCall() => '${call.name}:${jsonEncode(call.arguments)}',
    Delegate() => 'delegate:${call.summary}|${[for (final t in call.tasks) '${t.revise ?? ''}/${t.title}/${t.instructions}'].join('|')}',
  };

  String _join(String earlier, String current) {
    if (earlier.trim().isEmpty) return current;
    if (current.trim().isEmpty) return earlier;
    return '$earlier\n\n$current';
  }

  void _finishWith(TaskState state) {
    _update((s) => s.copyWith(task: state));
    _store(snapshot(), generating: false);
  }

  void _fail(int id, String reason) {
    onFailure?.call(reason);
    _replace(id, (m) => m.copyWith(finish: FinishReason.error));
    _update((s) => s.copyWith(task: TaskState.error, error: reason));
    _store(snapshot(), generating: false);
  }

  void _append(UiMessage message) =>
      _update((s) => s.copyWith(messages: [...s.messages, message]));

  void _replace(int id, UiMessage Function(UiMessage) change) => _update(
    (s) => s.copyWith(
      messages: [for (final m in s.messages) m.id == id ? change(m) : m],
    ),
  );
}

String jsonEncodeSchema(Map<String, Object?> schema) => jsonEncode(schema);
