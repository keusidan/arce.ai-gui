import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show Random;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener, WidgetsFlutterBinding;

import '../ai/cloud_engine.dart';
import '../ai/model_availability.dart';
import '../ai/model_info.dart';
import '../ai/model_list_check.dart';
import '../ai/model_probe.dart';
import '../ai/openai_compatible.dart';
import '../ai/delegation.dart';
import '../ai/provider.dart';
import '../ai/provider_config.dart';
import '../ai/roles.dart';
import '../ai/routing_engine.dart';
import '../ai/token_budget.dart';
import '../ai/titles.dart';
import '../core/agents.dart';
import '../core/error_report.dart';
import '../core/chat_controller.dart';
import '../core/coding_plan.dart';
import '../core/engine.dart';
import '../core/generation.dart';
import '../core/http_get.dart';
import '../core/protocol.dart';
import '../core/run_progress.dart';
import '../core/search.dart';
import '../core/secret_book.dart';
import '../core/settings_spec.dart';
import '../core/tool_runtime.dart';
import '../core/weather.dart';
import '../engine/demo_engine.dart';
import '../mcp/mcp_client.dart';
import '../mcp/http_request_tool.dart';
import '../mcp/mcp_tools.dart';
import 'desktop_shell.dart';
import '../mcp/show_tool.dart' show ShowSettings;
import '../core/page_blocks.dart';
import '../engine/hybrid_engine.dart';
import '../engine/native_engine.dart';
import 'conversation_database.dart';
import 'conversation_search.dart';
import 'device_info.dart';
import 'error_reporter.dart';
import 'linux_env.dart';
import 'model_availability_store.dart';
import 'model_info_fetcher.dart';
import 'foreground_service.dart';
import 'reply_notifier.dart';
import 'shell_sessions.dart';
import '../core/reply_event.dart';
import 'kv_snapshots.dart';
import 'model_manager.dart';
import 'preview_server.dart';
import 'chat_handle.dart';
import 'provider_store.dart';
import 'session_engine.dart';
import 'settings.dart';
import 'update_service.dart';

enum AppPage { chat, models, artifacts, settings, history }

/// Anchors of the sections of the settings page, so the desktop sidebar can jump to one.
enum SettingsSection {
  providers,
  online,
  local,
  coding,
  shell,
  limits,
  mcp,
  basic,
  search,
  display,
  update,
  reports,
}

/// A generation that was still running when the app last stopped (spec §25.1).
class InterruptedConversation {
  const InterruptedConversation(this.id, this.title);
  final String id;
  final String title;
}

/// Application-wide objects. The chat and the loaded model live here rather than in a page,
/// so a generation survives switching pages.
class AppController extends ChangeNotifier {
  AppController._({
    required this.settings,
    required this.providers,
    required this.history,
    required this.models,
    required this.updates,
    required this.foreground,
    required this.device,
    required this.cloud,
    required this.engine,
    required this.preview,
    this.workspaceDirectory,
    this.desktopShell,
    required this.errors,
    required this.linux,
    required this.availability,
    this.notifier = const ReplyNotifier(),
  }) {
    // a provider that the server refused a cache field of turns the switch off: the user is told
    providers.onNotice = showToast;
    _current = _newSession();
    chat = ChatHandle(_current.chat);
    chat.addListener(_syncForeground);
    _applyProvider();
  }

  /// A chat of its own: its controller, its engine (see [SessionEngine]) and, once it is saved, the
  /// id of its conversation. The one on the screen is [_current]; the others that are still
  /// generating are in [_background].
  _Session _newSession() {
    final session = _Session();
    final stop = StopSignal();
    final meter = RunMeter();
    session.chat = ChatController(
      SessionEngine(engine, _lease),
      stopSignal: stop,
      meter: meter,
      delegateEnabled: _delegateAvailable,
      onFailure: (reason) => reportProblem('chat', reason),
      delegateInstructions: () {
        final s = settings.value.coding;
        return CodingPrompts.plannerInstructions(
          maxTasks: s.maxTasks,
          reviewRounds: s.reviewRounds,
          investigateFirst: s.investigateFirst,
          maxWorkers: s.maxWorkers,
        );
      },
      toolRuntime: _SessionToolRuntime(_toolRuntime, _delegate, stop, _lease, meter, DelegateSession(() => session.chat.userInputs)),
      settings: () => settings.value.toGeneration(
        models.loadedParamsB,
        cloud: engine.isCloud,
      ),
      store: (snapshot, {required generating}) => _persist(session, snapshot, generating),
      extraTools: _mcpDefinitions,
      applySettings: _applySettings,
      addProvider: _addProvider,
      mcpApproval: _mcpApprovalRequired,
      approvalDetails: (name, arguments) => _mcpTools.approvalDetails(name, arguments),
      rememberTool: _rememberTool,
      confirmAfterExternal: () => settings.value.shellConfirmAfterExternal,
      conversationKey: () => session.cacheKey,
      contextTokens: _contextTokens,
    )..setThinking(settings.value.thinking);
    session.chat.addListener(_syncForeground);
    session.chat.addListener(() => _notifyAbout(session));
    return session;
  }

  String _lastRunning = '';
  final _lease = ExclusiveLease();
  late _Session _current;
  final _background = <_Session>[];

  Iterable<_Session> get _sessions => [_current, ..._background];

  bool get _anyGenerating => _sessions.any((s) => s.chat.isRunning);

  /// The conversation on the screen; null for a new one that has not been saved yet.
  String? get conversationId => _current.id;

  /// Whether conversation [id] is being answered now (on the screen or in the background).
  bool isRunning(String id) => _sessions.any((s) => s.id == id && s.chat.isRunning);

  /// Puts the session that is on the screen aside if it is still generating (it goes on in the
  /// background), and returns the session to fill: the same one when it was idle.
  _Session _freeCurrent() {
    if (_current.chat.isRunning) {
      _background.add(_current);
      _current = _newSession();
    }
    return _current;
  }

  /// Ends a background session that has finished: its conversation is saved, nothing is left to run.
  void _reapBackground() {
    final done = _background.where((s) => !s.chat.isRunning).toList();
    for (final session in done) {
      _background.remove(session);
      // not inside its own notification
      Timer.run(() {
        session.chat.removeListener(_syncForeground);
        session.chat.dispose();
      });
    }
  }

  final SettingsStore settings;

  /// The providers the user added, and the one in use (device model or one of them).
  final ProviderStore providers;
  final ConversationDatabase history;
  final ModelManager models;
  final UpdateService updates;
  final DeviceInfoService device;

  /// The cloud side of the router; its provider is replaced when the user picks another one.
  final CloudEngine cloud;

  /// Sends each request to the device model or to the chosen provider.
  final RoutingEngine engine;
  final PreviewServer preview;

  /// The folder the Linux environment sees as `/workspace` (null where there is no such environment): what `show` may
  /// show files of.
  final Directory? workspaceDirectory;

  /// The address that shows [source] on this device (an address only the app knows, or the port of a program that serves
  /// it). Throws a sentence for the user when the page cannot be shown (no workspace here, no such file any more).
  Future<Uri> pageAddress(PageSource source) async {
    switch (source) {
      case HtmlSource():
        return preview.publish(source.html);
      case SvgSource():
        return preview.publish(PageBlocks.pageOfSvg(source.svg));
      case PortSource():
        return PageBlocks.addressOf(source);
      case WorkspaceSource():
        final workspace = workspaceDirectory;
        if (workspace == null) throw 'この端末には、ワークスペースがありません';
        final found = WorkspacePages.resolve(workspace, source.path);
        if (found == null) throw 'ワークスペースに、そのページがありません（/workspace/${source.path}）';
        return preview.publishFolder(found.root, found.entry);
    }
  }

  /// Sends the errors to a GitHub issue (settings: エラーの報告).
  final ErrorReporter errors;

  /// The Linux environment on the device: whether it is installed, installing
  /// it, and its state for the settings screen. The tool itself runs through [McpTools].
  final LinuxEnvironment linux;

  /// Where `run_command` runs on a PC (a container, or the PC itself); null on Android and iOS.
  final DesktopShell? desktopShell;

  /// What the settings screen says about the commands on a PC (the engine, the container).
  Future<String> describeDesktopShell() async =>
      desktopShell == null ? '' : desktopShell!.describe(settings.value.desktopShell);

  /// Removes the container; the next command makes it again from the image (the workspace stays).
  Future<void> recreateDesktopContainer() async => desktopShell?.recreate(settings.value.desktopShell);

  /// Shared with [updates]: a download keeps running when another app is in front.
  final ForegroundService foreground;

  /// System notifications for a reply that waits, ends or fails (Android).
  final ReplyNotifier notifier;

  /// Whether the app is in front of the user; set by the root widget from the system's lifecycle.
  bool inForeground = true;
  late final ChatHandle chat;

  /// Whether the model that answers takes images, so attached pictures are read as pictures.
  /// The device model never does: it reads text only.
  bool get acceptsImages => engine.cloudProvider?.capabilities.vision ?? false;

  AppPage page = AppPage.chat;

  /// Finds out what an online model can do (its limits, whether it sees images).
  final modelInfo = ModelInfoFetcher();

  /// The models already asked about in this run, so each is asked once.
  final _modelInfoAsked = <String>{};

  /// Saves the device model's KV cache of a conversation to a file; null where the engine cannot.
  KvSnapshotService? _kv;

  /// The conversation whose prompt the engine's KV cache holds, set when the device model has
  /// answered in it.
  String? _kvOwner;
  AppLifecycleListener? _lifecycle;

  /// Which part of the settings page to scroll to (set by the desktop sidebar).
  final settingsSection = ValueNotifier<SettingsSection?>(null);

  /// The group the settings page shows now (null: its buttons). The page sets it; the desktop sidebar marks
  /// that group. Only meaningful while [page] is [AppPage.settings].
  final shownSettingsGroup = ValueNotifier<SettingsSection?>(null);

  /// Whether the desktop sidebar is shown (the hamburger button toggles it).
  final sidebarOpen = ValueNotifier<bool>(true);
  InterruptedConversation? interrupted;
  List<ConversationMeta> conversations = const [];

  /// Text shown briefly at the bottom of the screen.
  final toast = ValueNotifier<String?>(null);
  Timer? _toastTimer;

  /// [supportDirectory] replaces the platform's app-data folder (tests use a temporary one).
  static bool get _isDesktop => Platform.isLinux || Platform.isWindows || Platform.isMacOS;

  static Future<AppController> create({
    Directory? supportDirectory,
    UpdateService? updateService,
    http.Client? reportClient,
    LinuxEnvironment? linux,
    ReplyNotifier? notifier,
    ModelAvailabilityStore? availability,
    Directory? workspaceDirectory,
    DesktopShell? desktopShell,
  }) async {
    final settings = await SettingsStore.load();
    // Android's environment keeps its workspace in the app's data folder (`LinuxEnv.kt`: filesDir/workspace); a PC
    // keeps it in the same place. iOS runs no commands.
    final workspace = workspaceDirectory ??
        (LinuxEnvironment.supported || _isDesktop ? Directory('${(supportDirectory ?? await getApplicationSupportDirectory()).path}/workspace') : null);
    final providers = await ProviderStore.load();
    final device = DeviceInfoService();
    final native = NativeEngine();
    final foreground = ForegroundService();
    final models = await ModelManager.create(
      engine: native,
      settings: settings,
      device: device,
      foreground: foreground,
      supportDirectory: supportDirectory,
    );
    final history = await ConversationDatabase.open(
      supportDirectory: supportDirectory,
    );
    final updates = updateService ?? UpdateService(settings, foreground: foreground);
    final cloud = CloudEngine(const _NoProvider());
    final app = AppController._(
      settings: settings,
      providers: providers,
      history: history,
      models: models,
      updates: updates,
      foreground: foreground,
      device: device,
      cloud: cloud,
      // the device model answers until the user picks a provider
      engine: RoutingEngine(
        local: HybridEngine(native, DemoEngine()),
        cloud: cloud,
      ),
      preview: PreviewServer(),
      // the app's data folder is where the Linux environment keeps its workspace (`LinuxEnv.kt`: filesDir/workspace);
      // a PC keeps it in the same place, and its container sees it as /workspace
      workspaceDirectory: workspace,
      desktopShell: desktopShell ?? (_isDesktop && workspace != null ? DesktopShell(workspace: workspace) : null),
      errors: ErrorReporter(
        client: reportClient,
        prefs: await SharedPreferences.getInstance(),
        config: () => ErrorReportConfig(
          enabled: settings.value.errorReportEnabled,
          repo: settings.value.errorReportRepo,
          token: settings.issueToken,
          minHours: settings.value.errorReportMinHours,
          maxPerHour: settings.value.errorReportMaxPerHour,
        ),
      ),
      // the same environment the tool runs in, so the settings screen shows its real state
      linux: linux ?? McpTools.shellEnvironment,
      availability: availability ?? await ModelAvailabilityStore.load(),
      notifier: notifier ?? const ReplyNotifier(),
    );
    final local = app.engine.local;
    if (local is KvStatePersistence) {
      app._kv = KvSnapshotService(
        database: history,
        engine: local as KvStatePersistence,
        config: () => settings.value.kvSnapshot,
      );
    }
    app.engine.planner = app._plannerEngine;
    // a model this key cannot use is noted when a real request finds out, and a note is taken back when it answers
    cloud.onProviderFailure = app._noteProviderFailure;
    cloud.onProviderSuccess = app._noteProviderSuccess;
    providers.addListener(app._syncAvailability);
    app._syncAvailability();
    unawaited(app._start());
    return app;
  }

  late final _http = packageHttpGet(
    timeoutOf: () => Duration(seconds: settings.value.httpTimeoutSeconds.clamp(3, 300)),
  );

  late final _httpPost = packageHttpPost(
    timeoutOf: () => Duration(seconds: settings.value.httpTimeoutSeconds.clamp(3, 300)),
  );

  /// Built per call so a changed SearXNG address or search switch applies immediately.
  late final ToolRuntime _toolRuntime = _SettingsToolRuntime(
    settings,
    providers,
    _http,
    _httpPost,
    () => _mcpTools,
  );

  /// Applies the settings the user approved in the chat (protocol `update_settings`). The reply
  /// says what the settings are now, so the model can confirm instead of assuming.
  Future<String> _applySettings(List<SettingsChangeOk> changes) async {
    await settings.update((current) => withSettings(current, changes));
    final values = settings.value.toJson();
    final now = [
      for (final change in changes)
        '${change.key}=${change.spec.format(values[change.key])}',
    ].join(', ');
    final reload = changes.any((c) => _reloadNeeded.contains(c.key));
    return 'The user approved the change: $now.'
        '${reload ? ' It takes effect the next time the model is loaded.' : ''}';
  }

  /// Saves the provider the user approved in the chat (protocol `add_provider`). It is always a new
  /// entry with a new id, so no existing provider (and no key kept for it) is touched, and it is not
  /// made the active one. The key is typed on the settings screen.
  Future<String> _addProvider(ProviderDraft draft) async {
    final config = ProviderConfig(
      id: ProviderList.idFor(draft.name, providers.providers),
      label: draft.name,
      baseUrl: draft.baseUrl,
      models: [for (final id in draft.models) ModelConfig(id: id, name: id)],
      supportsTools: draft.supportsTools,
    );
    await providers.save(config);
    return 'The user approved it and the provider "${config.label}" (id=${config.id}) was added with '
        'the models ${draft.models.join(', ')}. It has no API key yet and is not in use. Tell the user to '
        'open the settings screen, choose the provider, type the API key there, and then pick it in '
        'the model menu.';
  }

  /// Settings a running model keeps until it is loaded again.
  static const _reloadNeeded = {
    'contextLength',
    'threads',
    'batchSize',
    'gpuOffload',
  };

  /// `tools/list` results, kept per server so a chat turn does not ask every server again.
  final Map<String, List<McpTool>> _mcpCache = {};

  /// The enabled servers with an http(s) URL, built per use so a changed setting applies at once.
  List<McpServerClient> _mcpServerClients() => [
    for (final server in settings.value.mcpServers)
      if (server.enabled &&
          (server.url.trim().startsWith('http://') ||
              server.url.trim().startsWith('https://')))
        McpServerClient(
          server,
          McpClient(
            url: server.url.trim(),
            token: settings.mcpTokenOf(server.id),
            timeout: Duration(seconds: settings.value.mcpTimeoutSeconds.clamp(5, 600)),
            maxResultChars: settings.value.mcpResultMaxChars,
          ),
        ),
  ];

  /// The GitHub token `ci_status` reads with: the one kept for the GitHub server, so the tool needs
  /// no key of its own (empty: the public API, which answers for a public repository).
  String get _ciToken {
    for (final server in settings.value.mcpServers) {
      final id = server.id.toLowerCase();
      final name = server.name.toLowerCase();
      if (id == 'github' ||
          name == 'github' ||
          server.url.contains('githubcopilot.com') ||
          server.url.contains('api.github.com')) {
        return settings.mcpTokenOf(server.id);
      }
    }
    return '';
  }

  /// What the Linux environment's settings say now, asked on every use so a change applies to the
  /// next command.
  ShellSettings get _shellSettings {
    final s = settings.value;
    return ShellSettings(
      enabled: s.shellEnabled,
      confirm: s.shellConfirm,
      timeoutSeconds: s.shellTimeoutSeconds,
      maxTimeoutSeconds: s.shellMaxTimeoutSeconds,
      maxOutputChars: s.shellMaxOutputChars,
      workspaceLimitMb: s.workspaceLimitMb,
      rootfsUrl: s.linuxRootfsUrl,
      rootfsSha256: s.linuxRootfsSha256,
      dns: s.linuxDns,
      compatMode: s.shellCompatMode,
      downloadConnections: s.downloadConnections,
      desktop: s.desktopShell,
      sessions: ShellSessionSettings(
        maxSessions: s.shellSessionMax,
        idleMinutes: s.shellSessionIdleMinutes,
        waitMs: s.shellSessionWaitMs,
        maxWaitMs: s.shellSessionMaxWaitSeconds * 1000,
        cols: s.shellSessionCols,
        rows: s.shellSessionRows,
        scrollback: s.shellSessionScrollback,
        bufferKb: s.shellSessionBufferKb,
      ),
    );
  }

  /// What the settings screen needs to install, remove and measure the environment.
  LinuxConfig get linuxConfig => _shellSettings.config;

  /// Reads the environment's state from the Android side (what the settings screen shows).
  Future<void> refreshLinux() async {
    if (!LinuxEnvironment.supported) return;
    try {
      await linux.refresh(linuxConfig);
    } catch (e) {
      debugPrint('could not read the Linux environment: $e');
    }
  }

  /// Downloads and unpacks the root file system, as the settings screen asks.
  Future<void> installLinux() async {
    await linux.refresh(linuxConfig);
    if (linux.ready) return;
    await linux.install(linuxConfig);
  }

  /// Removes the root file system; the shared workspace stays.
  Future<void> removeLinux() async {
    await linux.remove();
    notifyListeners();
  }

  /// Empties the workspace every chat shares.
  Future<void> clearLinuxWorkspace() async {
    await linux.clearWorkspace(linuxConfig);
    notifyListeners();
  }

  McpTools get _mcpTools => McpTools(
    desktopShell: desktopShell,
    _mcpServerClients(),
    cache: _mcpCache,
    ciToken: _ciToken,
    approved: settings.value.approvedTools.toSet(),
    shell: _shellSettings,
    secrets: _shellSecretValues(),
    secretBook: secretBook(),
    show: ShowSettings(enabled: settings.value.showEnabled, maxChars: settings.value.showMaxChars),
    workspaceDirectory: workspaceDirectory,
    httpRequest: HttpRequestSettings(
      enabled: settings.value.httpRequestEnabled,
      confirm: settings.value.httpRequestConfirm,
      maxResponseChars: settings.value.httpRequestMaxResponseChars,
      timeoutSeconds: settings.value.httpRequestTimeoutSeconds,
      allowInsecure: settings.value.httpRequestAllowInsecure,
      maxRedirects: settings.value.httpRequestMaxRedirects,
    ),
    onDemand: settings.value.mcpOnDemand,
    onDemandTokens: settings.value.mcpOnDemandTokens,
    resultMaxChars: settings.value.mcpResultMaxChars,
  );

  /// Every item that holds a key or a token, each with an id made from its name: the
  /// providers' API keys, the MCP servers' tokens, the search services' keys, the GitHub tokens and the
  /// values typed for commands. A model names one in `{{secret:ID}}`; its value goes only to the hosts it is
  /// bound to (the host of the provider's address, of the server's address, ... or the ones the user wrote).
  SecretBook secretBook() {
    final s = settings.value;
    String? hostOf(String url) => SecretRegistry.hostOfUrl(url);
    List<String> hosts(String url) => [...?(hostOf(url) == null ? null : [hostOf(url)!])];
    return SecretRegistry(
      [
        for (final secret in s.shellSecrets)
          if (!secret.fromMcp)
            SecretSource(kind: SecretKind.own, name: secret.name, source: secret.name, hosts: secret.hosts, value: settings.shellSecretValue(secret)),
        for (final provider in providers.providers)
          SecretSource(kind: SecretKind.provider, name: provider.label, source: provider.id, hosts: hosts(provider.baseUrl), value: providers.keyOf(provider.id)),
        for (final server in s.mcpServers)
          SecretSource(kind: SecretKind.mcp, name: server.name.isEmpty ? server.id : server.name, source: server.id, hosts: hosts(server.url), value: settings.mcpTokenOf(server.id)),
        for (final api in s.searchApis)
          SecretSource(
            kind: SecretKind.search,
            name: api.name,
            source: api.id,
            hosts: hosts(api.url.replaceAll(SearchApiConfig.queryMark, 'q').replaceAll(SearchApiConfig.countMark, '1').replaceAll(SearchApiConfig.keyMark, 'k')),
            value: settings.searchKeyOf(api.id),
          ),
        SecretSource(kind: SecretKind.github, name: 'GitHub token', source: 'token', hosts: const ['api.github.com'], value: settings.githubToken),
        SecretSource(kind: SecretKind.github, name: 'GitHub issue token', source: 'issue', hosts: const ['api.github.com'], value: settings.issueToken),
      ],
      off: s.secretsOffForModel.toSet(),
    );
  }

  /// The secrets a command may be given, name -> value; one without a value is left out (it cannot be
  /// given, and the model is not told it exists).
  Map<String, String> _shellSecretValues() => {
        for (final secret in settings.value.shellSecrets)
          if (settings.shellSecretValue(secret).isNotEmpty) secret.name: settings.shellSecretValue(secret),
      };

  /// The user answered an approval with 「この道具は次から確認しない」: the tool is added to the list in
  /// the settings (where it can be taken out again).
  Future<void> _rememberTool(String name) async {
    if (!ToolApproval.canRemember(name)) return;
    final current = settings.value.approvedTools;
    if (current.contains(name)) return;
    await settings.update((s) => s.copyWith(approvedTools: [...s.approvedTools, name]));
  }

  /// How many tokens the next request would be, with [draft] as the message: the app's instructions,
  /// the tool definitions (every MCP server's too), the conversation and the draft. An estimate
  /// ([TokenBudget.estimate]); the context is the model's own when it is known.
  Future<PromptTokens> promptTokens(String draft) async {
    final parts = await chat.current.promptParts(draft);
    return PromptTokens(
      system: TokenBudget.estimate(parts.system),
      tools: TokenBudget.estimate(parts.tools),
      conversation: TokenBudget.estimate(parts.conversation),
      draft: TokenBudget.estimate(parts.draft),
      context: engine.isCloud ? providers.activeModel?.contextTokens : null,
    );
  }

  /// The context window of the model that answers now: the online model's when the user set it (or the
  /// app found it out), the loaded device model's own. Null when it is not known.
  int? _contextTokens() => engine.isCloud ? providers.activeModel?.contextTokens : models.loadedWith?.contextLength;

  /// The tools of every MCP server, added to the ones the agent already has.
  Future<List<ToolDefinition>> _mcpDefinitions() => _mcpTools.definitions();

  /// Whether an MCP tool should wait for the user; a server can turn this off for itself.
  bool _mcpApprovalRequired(String name, [Map<String, Object?> arguments = const {}]) =>
      _mcpTools.approvalRequired(name, arguments);

  /// Used by the settings screen: asks one server what it offers and says so, with what its tools
  /// add to every request, and a warning when that is more than the model in use can take.
  Future<String> probeMcp(String id) async {
    final tools = _mcpTools;
    final text = await tools.describe(id);
    final tokens = await tools.overheadTokens(id);
    final context = providers.activeModel?.contextTokens;
    if (tokens == null || context == null) return text;
    final ratio = settings.value.tokenOverheadPercent / 100;
    if (tokens > context * ratio) {
      return '$text\n注意: 使用中のモデル（${providers.activeModelId}）の文脈 $context トークンに対して、'
          'ツール定義だけで約 $tokens トークンです。このままでは送る前にエラーになります';
    }
    if (tokens > context * 0.4) {
      return '$text\n注意: ツール定義が、使用中のモデルの文脈の ${(tokens * 100 / context).round()}% を使います';
    }
    return text;
  }

  /// Runs one search with the values of the editor (saved or not) and says what came back.
  Future<String> testSearchApi(SearchApiConfig config, String key) async {
    final problem = config.problem;
    if (problem != null) return problem;
    try {
      final hits = await ConfiguredSearchProvider(config, key, _http, post: _httpPost).search('test', 3);
      return hits.isEmpty
          ? '接続できましたが、結果を読み取れませんでした（結果のパスと項目名を確かめてください）'
          : '${hits.length} 件読み取れました: ${hits.first.title}';
    } catch (e) {
      return '失敗: $e';
    }
  }

  /// What the report says about the setting it happened in: the version, the system, who was
  /// answering (the device or an online model: its host and its model name). Nothing of the
  /// conversation, and no key.
  Map<String, String> errorFacts() {
    final config = providers.active;
    final host = config == null ? '' : (Uri.tryParse(config.baseUrl.trim())?.host ?? '');
    return {
      'app': '${updates.currentVersion ?? ''}',
      'os': '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      'engine': config == null ? 'device' : 'online',
      if (host.isNotEmpty) 'provider host': host,
      if (config != null) 'model': providers.activeModelId,
    };
  }

  /// Reports an error to the GitHub issue, if it is the kind that is the app's to fix (see
  /// [ErrorPolicy]), the setting is on and a token is set. It runs in the background and never fails.
  void reportProblem(String kind, String message, {Object? error, StackTrace? stack}) {
    try {
      if (!ErrorPolicy.shouldReport(kind, '$message ${error ?? ''}')) return;
      final report = ErrorReport.of(kind: kind, message: message, error: error, stack: stack, facts: errorFacts());
      unawaited(errors.report(report));
    } catch (e) {
      debugPrint('could not report an error: $e');
    }
  }

  Future<void> _start() async {
    // reports that waited for the network go out now
    unawaited(errors.flush());
    // a model download that the app was closed in the middle of carries on (a setting)
    if (settings.value.resumeDownloadsOnStart) {
      models.resumeInterrupted();
    } else {
      models.interrupted.clear();
    }
    settings.addListener(() {
      for (final session in _sessions) {
        session.chat.setThinking(settings.value.thinking);
      }
    });
    // adding, removing or editing a provider changes which one answers
    providers.addListener(_applyProvider);
    // the app going to the background may end with the system closing it: keep the cache now
    try {
      WidgetsFlutterBinding.ensureInitialized();
      _lifecycle = AppLifecycleListener(onPause: () => unawaited(_saveKv()));
    } catch (e) {
      debugPrint('no lifecycle events: $e');
    }
    // a changed timeout reaches the provider in use by building it again
    var timeout = settings.value.providerTimeoutSeconds;
    settings.addListener(() {
      _applyEngineSettings();
      if (settings.value.providerTimeoutSeconds == timeout) return;
      timeout = settings.value.providerTimeoutSeconds;
      _applyProvider();
    });
    _applyEngineSettings();
    // what the settings screen shows about the Linux environment (its size, whether it is there)
    unawaited(refreshLinux());
    // the model lists that are missing or old are read in the background
    unawaited(autoReadModelLists().catchError((Object e) => debugPrint('could not read the model lists: $e')));
    try {
      await refreshConversations();
      final item = conversations.where((c) => c.generating).firstOrNull;
      if (item != null) {
        interrupted = InterruptedConversation(item.id, item.title);
        notifyListeners();
      }
    } catch (e) {
      debugPrint('could not read the conversation list: $e');
    }
    unawaited(
      updates.init().catchError(
        (Object e) => debugPrint('update check setup failed: $e'),
      ),
    );
    unawaited(
      models.restoreLastModel().catchError(
        (Object e) => debugPrint('could not restore the last model: $e'),
      ),
    );
  }

  /// Carries out the planner's `delegate` calls with the developer models (see [DelegateRunner]).
  late final _delegate = DelegateRunner(
    settings: () => settings.value.coding,
    developers: _developerRoles,
  );

  /// The developer models that can be used now, in the order of the settings.
  List<RoleModel> _developerRoles({bool note = true}) => [
        for (final ref in settings.value.coding.developers) ?_roleFor(ref, note: note),
      ];

  /// Whether the coding mode can work now: it is on, at least one developer model can be used, and
  /// the planner is known (the model in use, or the one chosen). Only then is the `delegate` tool
  /// offered.
  bool _delegateAvailable() {
    final s = settings.value.coding;
    if (!s.isReady || _developerRoles(note: false).isEmpty) return false;
    return s.plannerFollowsModel || _plannerEngine(null, note: false) != null;
  }

  /// The engine of the planner model for [request], or null when the model in use answers: the
  /// coding mode is off or not ready, the planner follows the model in use, or the request is not
  /// the coding agent's.
  InferenceEngine? _plannerEngine(GenerateRequest? request, {bool note = true}) {
    final s = settings.value.coding;
    if (!s.isReady || s.plannerFollowsModel) return null;
    if (request != null && request.agentId != Agents.coding.id) return null;
    if (_developerRoles(note: false).isEmpty) return null;
    final parsed = CodingSettings.parseRef(s.planner);
    if (parsed == null) return null;
    final (providerId, modelId) = parsed;
    if (providerId == CodingSettings.localProvider) return models.isLoaded ? engine.local : null;
    final config = providers.byId(providerId);
    if (config == null || !config.isComplete) return null;
    final provider = providers.build(config, model: config.resolveModel(modelId) ?? config.defaultModel);
    final keep = settings.value.recentModelCount;
    if (note && keep > 0) unawaited(providers.markUsed(providerId, provider.modelId, keep: keep));
    final s2 = settings.value;
    // answers like the model in use would: the same bridging, tool style, thinking and stop
    return CloudEngine(provider)
      ..fallbackFor = s2.fallbackEnabled ? providers.fallbackPlanFor : null
      ..onFallback = _announceFallback
      ..tokenPrecheck = s2.tokenPrecheck
      ..overheadRatio = s2.tokenOverheadPercent / 100;
  }

  /// The model behind a `provider|model` reference of the coding mode, or null when it cannot be
  /// used now: the provider was removed or is incomplete, or the device model is not loaded.
  RoleModel? _roleFor(String ref, {bool note = true}) {
    final parsed = CodingSettings.parseRef(ref);
    if (parsed == null) return null;
    final (providerId, modelId) = parsed;
    if (providerId == CodingSettings.localProvider) {
      return models.isLoaded
          ? LocalRole(engine.local, name: models.loadedName ?? 'ローカルモデル')
          : null;
    }
    final config = providers.byId(providerId);
    if (config == null || !config.isComplete) return null;
    // a model that is only in the provider's catalog works as it is, with what the list says of it
    final provider = providers.build(config, model: config.resolveModel(modelId) ?? config.defaultModel);
    final keep = settings.value.recentModelCount;
    if (note && keep > 0) unawaited(providers.markUsed(providerId, provider.modelId, keep: keep));
    return ProviderRole(
      provider,
      fallback: settings.value.fallbackEnabled ? providers.fallbackPlanFor(provider) : null,
      onFallback: _announceFallback,
    );
  }

  /// A notification for a reply that now waits for the user, is finished or failed, when the
  /// settings ask for it and (by default) the user is not looking at that chat.
  void _notifyAbout(_Session session) {
    final event = session.watch.update(session.chat.state);
    if (event == null) return;
    final s = settings.value;
    final wanted = switch (event.kind) {
      ReplyEventKind.needsYou => s.notifyNeedsYou,
      ReplyEventKind.done => s.notifyDone,
      ReplyEventKind.failed => s.notifyFailed,
    };
    if (!wanted) return;
    if (s.notifyOnlyAway && inForeground && identical(session, _current)) return;
    unawaited(notifier.show(event, group: session.id ?? ''));
  }

  /// Asks for the permission to notify when a notification setting is turned on.
  Future<void> askForNotifications() async {
    if (!notifier.supported || await notifier.allowed()) return;
    if (!await notifier.request()) {
      showToast('通知が許可されていません。端末の設定でこのアプリの通知をオンにしてください');
    }
  }

  /// Keeps Android's foreground service in step with whether a reply is being generated.
  void _syncForeground() {
    _reapBackground();
    // the history list marks the chats that are answering: tell it when that set changes
    final running = [for (final s in _sessions) if (s.id != null && s.chat.isRunning) s.id!].join(',');
    if (running != _lastRunning) {
      _lastRunning = running;
      notifyListeners();
    }
    if (_anyGenerating) {
      unawaited(foreground.start());
    } else {
      unawaited(foreground.stop());
    }
  }

  /// Points the router at the chosen provider; the device model when none is usable.
  /// Asks the provider (and the Hub) about the model in use when its limits are not known yet, and
  /// keeps the answer with the model. Once per model and run; what the user typed is not replaced.
  Future<void> _autoFillModelInfo() async {
    final config = providers.active;
    final model = providers.activeModel;
    if (!settings.value.autoFetchModelInfo || config == null || model == null) return;
    if (model.contextTokens != null && model.maxOutputTokens != null) return;
    if (!_modelInfoAsked.add('${config.id}|${model.id}')) return;
    try {
      final provider = providers.build(config, model: model);
      if (provider is! OpenAiCompatibleProvider) return;
      List<ModelInfo>? read;
      // the list the availability check reads is the same one (a Gemini key's own list has the limits): read once
      final found = await modelInfo.fetchFor(provider, model, useHub: settings.value.fetchModelInfoFromHub, readList: () async {
        read = await _readKeyModels(config);
        return read;
      });
      if (jsonEncode(found.toJson()) == jsonEncode(model.toJson())) return;
      // the provider may have changed while it was being asked
      final current = providers.byId(config.id);
      if (current == null) return;
      await providers.save(
        current.copyWith(models: [for (final m in current.models) m.id == found.id ? m.mergeInfo(ModelInfo(found.id, contextTokens: found.contextTokens, maxOutputTokens: found.maxOutputTokens, vision: found.vision)) : m]),
      );
      // saving the provider dropped the lists read for it, but only the limits of a model changed: the list is still the key's
      final kept = read;
      if (kept != null) _keyModels[config.id] = kept;
    } catch (e) {
      debugPrint('could not look up ${model.id}: $e');
    }
  }

  void _applyProvider() {
    _autoCheckActive();
    unawaited(_autoFillModelInfo());
    providers.requestTimeout = Duration(seconds: settings.value.providerTimeoutSeconds.clamp(10, 1800));
    final provider = providers.buildActive();
    if (provider != null) cloud.provider = provider;
    engine.target = provider;
    _applyEngineSettings();
    notifyListeners();
  }

  /// What the settings say about the online engine: the fallback rules, and the check of a request
  /// against the model's context before it is sent.
  void _applyEngineSettings() {
    final s = settings.value;
    cloud.fallbackFor = s.fallbackEnabled ? providers.fallbackPlanFor : null;
    cloud.onFallback = _announceFallback;
    cloud.tokenPrecheck = s.tokenPrecheck;
    cloud.overheadRatio = s.tokenOverheadPercent / 100;
    preview.maxPages = s.previewMaxPages;
    preview.maxFileBytes = s.showMaxFileMb * 1024 * 1024;
  }

  void _announceFallback(AiProvider from, AiProvider to, String reason) {
    showToast('${from.label} · ${from.modelId} が使えないため（$reason）、${to.label} · ${to.modelId} で答えます');
  }

  // ---------------------------------------------------------------- which models this key can use

  /// What was found out about each provider's models: usable, or not usable with this key and plan.
  final ModelAvailabilityStore availability;

  int get _trustDays => settings.value.modelAvailabilityTrustDays;

  /// What the model lists need to mark models (and hide the unusable ones, when the setting says so).
  ModelMarks get modelMarks => ModelMarks(
        lookup: (providerId, modelId) => availability.recordOf(providerId, modelId, trustDays: _trustDays),
        hideBlocked: settings.value.hideUnusableModels,
      );

  /// A request of a model failed: when the answer says this key cannot use the model, it is noted (the
  /// lists mark it), and the error says which model and what to do. Anything else is left as it is.
  Object _noteProviderFailure(AiProvider provider, Object error) {
    final verdict = AvailabilityClassifier.classifyError(error);
    if (!verdict.isBlocked || error is! AiProviderException) return error;
    final mark = settings.value.markBlockedModels;
    if (mark) unawaited(availability.record(provider.id, provider.modelId, verdict, trustDays: _trustDays));
    return AiProviderException(
      AvailabilityClassifier.blockedMessage(
        providerLabel: provider.label,
        modelId: provider.modelId,
        verdict: verdict,
        original: AvailabilityClassifier.providerMessage(error.body) ?? error.message,
        marked: mark,
      ),
      statusCode: error.statusCode,
      body: error.body,
    );
  }

  /// A model answered: a note that it cannot be used is no longer true.
  void _noteProviderSuccess(AiProvider provider) {
    if (settings.value.markBlockedModels) unawaited(availability.noteAnswered(provider.id, provider.modelId));
  }

  /// A removed provider takes what was found out about its models with it.
  void _syncAvailability() {
    // a provider was saved, changed or removed: what its key could see may have changed too
    _keyModels.clear();
    unawaited(availability.keepOnly({for (final p in providers.providers) p.id}));
  }

  /// Providers whose models are being asked now (a second question at the same time is refused).
  final _probing = <String>{};

  bool isProbing(String providerId) => _probing.contains(providerId);

  /// Asks [ids] of provider [providerId] one word each (a real request each: it counts against the key's
  /// limits), keeps which can be used and which cannot, and returns what to tell the user.
  Future<String> probeModels(String providerId, List<String> ids) async {
    final config = providers.byId(providerId);
    if (config == null) return 'プロバイダが見つかりません';
    if (!config.isComplete && config.baseUrl.trim().isEmpty) return 'Base URL を入れてください';
    if (ids.isEmpty) return '確かめるモデルがありません';
    if (_probing.contains(providerId)) return 'いま確認しています';
    final s = settings.value;
    final timeout = Duration(seconds: s.modelProbeTimeoutSeconds);
    _probing.add(providerId);
    notifyListeners();
    try {
      final report = await ModelProbe.run(
        modelIds: ids,
        concurrency: s.modelProbeConcurrency,
        timeout: timeout + const Duration(seconds: 5),
        ask: (id) => ModelProbe.askOnce(
          providers.build(config, model: config.resolveModel(id) ?? ModelConfig(id: id, name: id)),
          abortAfter: timeout,
        ),
      );
      await availability.recordAll(
        providerId,
        {for (final o in report.outcomes) o.modelId: o.verdict},
        trustDays: _trustDays,
      );
      return report.summary();
    } catch (e) {
      return '確認できませんでした（$e）';
    } finally {
      _probing.remove(providerId);
      notifyListeners();
    }
  }

  /// The online models the app is set to use now, once each: the one that answers, the planner and the
  /// developers of the coding mode, and the model that writes titles. (provider id, model id). The device
  /// model has nothing to ask.
  List<(String, String)> configuredModels() {
    final out = <(String, String)>[];
    void add(String? providerId, String? modelId) {
      if (providerId == null || modelId == null || providerId.isEmpty || modelId.isEmpty) return;
      if (providerId == CodingSettings.localProvider || providers.byId(providerId) == null) return;
      if (!out.contains((providerId, modelId))) out.add((providerId, modelId));
    }

    void addRef(String ref) {
      final parsed = CodingSettings.parseRef(ref);
      if (parsed != null) add(parsed.$1, parsed.$2);
    }

    add(providers.isCloud ? providers.active?.id : null, providers.isCloud ? providers.activeModel?.id : null);
    final coding = settings.value.coding;
    if (coding.enabled) {
      if (!coding.plannerFollowsModel) addRef(coding.planner);
      coding.developers.forEach(addRef);
    }
    addRef(settings.value.titleModel);
    return out;
  }

  /// The models each key can see (`models.list`), kept for this run so that choosing a model again does not
  /// read the list again. Dropped when a provider is saved or removed, and by the check button.
  final _keyModels = <String, List<ModelInfo>>{};

  Future<List<ModelInfo>?> _readKeyModels(ProviderConfig config, {bool refresh = false}) async {
    if (!refresh) {
      final cached = _keyModels[config.id];
      if (cached != null) return cached;
    }
    final provider = providers.build(config);
    if (provider is! OpenAiCompatibleProvider) return null;
    // a read that is under way is the one a second caller waits for (the limits of the model in use and the
    // check of the models both ask for it when a provider is chosen)
    final running = _keyModelReads[config.id];
    if (!refresh && running != null) return running;
    final read = provider.fetchKeyModels();
    _keyModelReads[config.id] = read;
    try {
      final list = await read;
      _keyModels[config.id] = list;
      return list;
    } finally {
      if (identical(_keyModelReads[config.id], read)) _keyModelReads.remove(config.id);
    }
  }

  final _keyModelReads = <String, Future<List<ModelInfo>>>{};

  /// Finds out whether this key can use each of [ids] of provider [providerId], and says it model by model
  /// (model id -> a line; the entry '' is a problem with the key or the address, said once).
  ///
  /// First the model list the key can read (`models.list`): one request, no use of the quota. A model that
  /// the list does not have, or that does not do chat, is out (and marked). One that is listed may still
  /// have no quota (a free tier lists models it cannot answer with): only a real request shows that, so
  /// listed models are asked too only when the setting says so; a request that fails later marks them.
  /// When the list cannot be read or is empty, the models are asked instead.
  Future<Map<String, String>> checkModels(String providerId, List<String> ids, {bool refreshList = false}) async {
    final config = providers.byId(providerId);
    if (config == null) return {'': 'プロバイダが見つかりません'};
    if (!(Uri.tryParse(config.baseUrl.trim())?.hasScheme ?? false)) return {'': 'Base URL（https://…）を入れてください'};
    if (ids.isEmpty) return {'': '確かめるモデルがありません'};
    List<ModelInfo>? list;
    try {
      list = await _readKeyModels(config, refresh: refreshList);
    } on AiProviderException catch (e) {
      final code = e.statusCode;
      if (code == 401 || code == 403) {
        return {'': 'APIキーが受け付けられなかったので、確認をやめました（モデルのことは分かっていません）。キーを確かめてください'};
      }
      list = null; // the list could not be read: the models are asked instead
    } catch (_) {
      list = null;
    }
    final lines = <String, String>{};
    final toAsk = <String>[];
    final blocked = <String, AvailabilityVerdict>{};
    for (final id in ids) {
      final verdict = ModelListCheck.judge(id, list);
      if (verdict == null) {
        toAsk.add(id);
      } else if (verdict.isBlocked) {
        blocked[id] = AvailabilityVerdict(ModelAvailability.blocked, verdict.reason);
        lines[id] = '使えません（${verdict.reason}）';
      } else if (settings.value.modelCheckAsksToo) {
        toAsk.add(id);
      } else {
        lines[id] = '一覧にあります（無料枠などの回数の制限までは、一覧では分かりません。送って「使えない」と返れば、印が付きます）';
      }
    }
    if (blocked.isNotEmpty) await availability.recordAll(providerId, blocked, trustDays: _trustDays);
    if (toAsk.isNotEmpty) {
      final message = await probeModels(providerId, toAsk);
      for (final id in toAsk) {
        final record = availability.recordOf(providerId, id, trustDays: _trustDays);
        lines[id] = record == null
            ? (message.startsWith('APIキーが受け付けられなかった') ? 'キーが拒否されたので、分かりません' : '判断できませんでした（一時的な失敗かもしれません。あとでもう一度）')
            : record.isBlocked
                ? '使えません（${record.reason}）'
                : '使えます（問い合わせで確認しました）';
      }
      if (message.startsWith('APIキーが受け付けられなかった')) lines[''] = message;
    }
    return lines;
  }

  /// Checks each model the app is set to use (not the provider's whole list: only these few) and says it
  /// model by model. The button on the model list: it reads the key's list afresh.
  Future<String> checkConfiguredModels() async {
    final models = configuredModels();
    if (models.isEmpty) return '確かめるモデルがありません（オンラインモデルを選んでください）';
    final byProvider = <String, List<String>>{};
    for (final (providerId, modelId) in models) {
      byProvider.putIfAbsent(providerId, () => []).add(modelId);
    }
    final out = <String>[];
    for (final entry in byProvider.entries) {
      final label = providers.byId(entry.key)?.label ?? entry.key;
      final lines = await checkModels(entry.key, entry.value, refreshList: true);
      for (final id in entry.value) {
        out.add('$label · $id：${lines[id] ?? lines[''] ?? '判断できませんでした'}');
      }
      final problem = lines[''];
      if (problem != null && !out.last.endsWith(problem)) out.add('$label: $problem');
    }
    return out.join('\n');
  }

  String? _activeRef;
  bool _activeKnown = false;

  /// The model that answers was changed: ask that one model once, unless a result is still fresh, and say
  /// so when this key cannot use it. Not at start-up, and not when the setting is off.
  void _autoCheckActive() {
    final config = providers.isCloud ? providers.active : null;
    final model = providers.isCloud ? providers.activeModel : null;
    final ref = config == null || model == null ? null : '${config.id}|${model.id}';
    if (!_activeKnown) {
      _activeKnown = true;
      _activeRef = ref;
      return;
    }
    if (ref == _activeRef) return;
    _activeRef = ref;
    if (config == null || model == null || !settings.value.autoCheckSelectedModel) return;
    if (availability.recordOf(config.id, model.id, trustDays: _trustDays) != null) return;
    unawaited(() async {
      await checkModels(config.id, [model.id]);
      final record = availability.recordOf(config.id, model.id, trustDays: _trustDays);
      if (record != null && record.isBlocked) {
        showToast('${config.label} · ${model.id} は、このキーでは使えない可能性があります（${record.reason}）。別のモデルを選んでください');
      }
    }());
  }

  final _listBusy = <String>{};

  /// True while the model list of provider [id] is being read.
  bool isReadingModelList(String id) => _listBusy.contains(id);

  /// Reads the model list of provider [id] and keeps it as the provider's catalog (the models the
  /// user can pick). The models already set up only gain the limits they lacked. Returns what to
  /// tell the user.
  Future<String> refreshModelList(String id) async {
    final config = providers.byId(id);
    if (config == null) return 'プロバイダが見つかりません';
    if (!(Uri.tryParse(config.baseUrl.trim())?.hasScheme ?? false)) return 'Base URL（https://…）を入れてください';
    if (!_listBusy.add(id)) return 'いま読み込んでいます';
    notifyListeners();
    try {
      final provider = providers.build(config);
      if (provider is! OpenAiCompatibleProvider) return 'このプロバイダはモデル一覧を読めません';
      final infos = await provider.fetchModelInfos();
      final added = await providers.updateCatalog(id, infos);
      final withLimits = infos.where((i) => i.hasLimits).length;
      return '${infos.length} 件のモデルを読み込みました'
          '${(added ?? 0) > 0 ? '（新しく ${added!} 件）' : ''}'
          '${infos.isNotEmpty && withLimits == 0 ? '。この提供元は上限を返しません（モデルの編集の「取得」で Hugging Face から調べられます）' : ''}';
    } on AiProviderException catch (e) {
      return e.message;
    } catch (e) {
      return '取得できませんでした（$e）';
    } finally {
      _listBusy.remove(id);
      notifyListeners();
    }
  }

  /// Reads the model lists that are missing or older than the setting says, one provider at a time.
  /// [only] limits it to one provider, and [force] reads it even when the list is recent (the
  /// provider has just been saved, so its address or key may be new). A failure is not shown: a
  /// provider that has no list, or whose key is not typed yet, simply has none.
  Future<void> autoReadModelLists({String? only, bool force = false}) async {
    final s = settings.value;
    if (!s.modelListAutoFetch) return;
    final maxAge = s.modelListRefreshHours * 3600 * 1000;
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final config in providers.providers) {
      if (only != null && config.id != only) continue;
      if (!config.autoFetchModels) continue;
      final at = config.catalogAt;
      if (!force && at != null && now - at < maxAge) continue;
      await refreshModelList(config.id);
    }
  }

  /// Notes that the model in use answers now, for the "recently used" part of the model lists.
  void _noteModelUsed() {
    final keep = settings.value.recentModelCount;
    if (providers.isCloud && keep > 0) {
      unawaited(providers.markUsed(providers.activeId, providers.activeModelId, keep: keep));
    }
  }

  /// True when replies go to a provider outside this device.
  bool get usingCloud => providers.isCloud;

  /// What the chat shows under the composer: who will answer, and whether it leaves the device.
  String get engineLabel {
    final config = providers.active;
    if (config != null) {
      return '${config.label} · ${providers.activeModelId}（外部送信）';
    }
    if (providers.isCloud) return 'プロバイダの設定が未完了です';
    return engine.isLoaded
        ? '${models.loadedName ?? 'ローカルモデル'} · ${models.backend ?? ''}'
        : 'ローカルモデル未接続 · デモ応答のみ';
  }

  /// [ProviderList.localId] goes back to the device model.
  Future<void> setActiveProvider(String id) async {
    if (_anyGenerating) {
      showToast('生成中は切り替えられません');
      return;
    }
    await providers.setActive(id);
    _applyProvider();
    final config = providers.active;
    showToast(config == null ? 'ローカルモデルで答えます' : '${config.label} で答えます');
  }

  void goTo(AppPage target) {
    if (page == target) return;
    page = target;
    notifyListeners();
  }

  void openSettings(SettingsSection section) {
    goTo(AppPage.settings);
    settingsSection.value = section;
  }

  void showToast(String text) {
    toast.value = text;
    _toastTimer?.cancel();
    _toastTimer = Timer(
      const Duration(milliseconds: 2200),
      () => toast.value = null,
    );
  }

  /// The conversations that match [query] in their title or in any message; all of them, newest
  /// first, when the query is empty.
  List<ConversationHit> searchConversations(String query) {
    return ConversationSearch.find(history, conversations, query);
  }

  Future<void> refreshConversations() async {
    conversations = await history.list();
    notifyListeners();
  }

  void newConversation() {
    unawaited(_saveKv(leaving: true));
    // a chat that is still answering goes on in the background; an idle one is emptied and reused
    final session = _freeCurrent();
    session.id = null;
    session.cacheKey = _Session.newCacheKey();
    session.titled = false;
    session.titleTries = 0;
    session.chat.clear();
    chat.show(session.chat);
    goTo(AppPage.chat);
    notifyListeners();
  }

  Future<void> openConversation(String id) async {
    if (_current.id == id && _current.chat.isRunning) {
      goTo(AppPage.chat);
      return;
    }
    // it is answering in the background: bring that chat to the screen as it is
    final running = _background.where((s) => s.id == id).firstOrNull;
    if (running != null) {
      final old = _current;
      if (old.chat.isRunning) _background.add(old);
      _background.remove(running);
      _current = running;
      chat.show(running.chat);
      if (!old.chat.isRunning) {
        old.chat.removeListener(_syncForeground);
        Timer.run(old.chat.dispose);
      }
      goTo(AppPage.chat);
      notifyListeners();
      return;
    }
    final snapshot = await history.get(id);
    if (snapshot == null) return;
    if (id != _current.id) unawaited(_saveKv(leaving: true));
    final session = _freeCurrent();
    session.chat.restore(snapshot);
    session.id = id;
    session.cacheKey = 'arce-$id';
    session.titled = true; // it has its title already
    chat.show(session.chat);
    goTo(AppPage.chat);
    notifyListeners();
    _restoreKv(id);
  }

  Future<void> deleteConversation(String id) async {
    // a reply still being written for it is stopped first
    for (final session in _sessions.where((s) => s.id == id)) {
      session.chat.stop();
    }
    // its cache is deleted with it; saving it first would be for nothing
    if (_kvOwner == id) _kvOwner = null;
    await history.delete(id);
    _background.removeWhere((s) => s.id == id);
    if (conversationId == id) newConversation();
    await refreshConversations();
  }

  /// The user's choice for an interrupted generation: resume it, regenerate, or discard it.
  Future<void> resolveInterrupted(String action) async {
    final item = interrupted;
    if (item == null) return;
    interrupted = null;
    notifyListeners();
    await history.clearGenerating(item.id);
    if (action == 'discard') {
      await refreshConversations();
      return;
    }
    final snapshot = await history.get(item.id);
    if (snapshot == null) return;
    unawaited(_saveKv(leaving: true));
    final session = _freeCurrent();
    session.chat.restore(snapshot);
    session.id = item.id;
    session.cacheKey = 'arce-${item.id}';
    session.titled = true;
    chat.show(session.chat);
    goTo(AppPage.chat);
    notifyListeners();
    _restoreKv(item.id);
    if (action == 'resume') {
      if (session.chat.state.canContinue) {
        unawaited(session.chat.continueReply());
      } else {
        unawaited(session.chat.regenerate());
      }
    } else {
      unawaited(session.chat.regenerate());
    }
  }

  String? exportConversation() {
    final snapshot = chat.snapshot();
    if (snapshot.messages.isEmpty) return null;
    return snapshot.messages
        .map(
          (m) => '${m.role == Role.user ? '## User' : '## ARCE.AI'}\n${m.text}',
        )
        .join('\n\n');
  }

  // One writer at a time, in order: the first save of a new chat must get its id before the next.
  Future<void> _writer = Future.value();

  /// What a saved KV cache must match: the model in memory and how it was loaded. Null when there
  /// is nothing to save (no llama.cpp model: LiteRT-LM keeps its own cache).
  String? _kvFingerprint() {
    final loaded = models.loadedWith;
    if (loaded == null || models.backend != 'llama.cpp') return null;
    final file = File(loaded.path);
    final int size;
    try {
      size = file.lengthSync();
    } on FileSystemException {
      return null;
    }
    return KvSnapshotService.fingerprint(
      modelName: file.uri.pathSegments.last,
      modelBytes: size,
      contextLength: loaded.contextLength,
      kvCache: loaded.kvCache,
      appVersion: '${updates.currentVersion ?? ''}',
    );
  }

  /// Keeps the engine's cache of the conversation it last worked on. [leaving] is a switch to
  /// another conversation: the cache then belongs to nobody any more.
  Future<void> _saveKv({bool leaving = false}) async {
    final owner = _kvOwner;
    if (leaving) _kvOwner = null;
    final kv = _kv;
    final fingerprint = _kvFingerprint();
    if (kv == null || owner == null || fingerprint == null || !settings.value.kvSnapshotEnabled) return;
    // a running reply is changing the cache; its end saves it
    if (_anyGenerating) return;
    await kv.save(owner, fingerprint);
  }

  /// Gives the engine the saved cache of [id], so its prompt is not evaluated again.
  void _restoreKv(String id) {
    final kv = _kv;
    final fingerprint = _kvFingerprint();
    if (kv == null || fingerprint == null || providers.isCloud || !settings.value.kvSnapshotEnabled) return;
    final seen = chat.state.messages.length;
    unawaited(
      kv
          .restore(
            id,
            fingerprint,
            // once the user has written to the model, loading would only throw that work away
            stillWanted: () => conversationId == id && !_anyGenerating && chat.state.messages.length == seen,
          )
          .then((restored) {
        if (restored) _kvOwner = id;
      }),
    );
  }

  /// Size of the saved caches, for the settings screen.
  int get kvSnapshotBytes => _kv?.totalBytes ?? 0;

  /// Whether this build can save caches at all (the device engine of the Android build).
  bool get canSaveKv => _kv != null && NativeEngine.isSupportedPlatform;

  Future<void> clearKvSnapshots() async {
    await _kv?.clear();
    notifyListeners();
  }

  /// The title of the conversation on the screen: the one the history list shows (a model's, once
  /// it has written one), or what the user first typed while the conversation is new.
  String get currentTitle {
    final id = _current.id;
    if (id != null) {
      for (final meta in conversations) {
        if (meta.id == id && meta.title.trim().isNotEmpty) return meta.title;
      }
    }
    for (final m in chat.state.messages) {
      final text = m.text.trim();
      if (m.role == Role.user && text.isNotEmpty) return text.length > 24 ? '${text.substring(0, 24)}…' : text;
    }
    return '新しい会話';
  }

  /// The provider that writes titles: the one named in the settings, or the online model in use.
  /// Null for the device model, which does not write titles by itself: the request would take the
  /// place of the conversation in its cache, and the next reply would start from the beginning.
  AiProvider? _titleProvider() {
    final ref = settings.value.titleModel.trim();
    if (ref.isEmpty) return providers.buildActive();
    final parsed = CodingSettings.parseRef(ref);
    if (parsed == null) return null;
    final (providerId, modelId) = parsed;
    if (providerId == CodingSettings.localProvider) return null;
    final config = providers.byId(providerId);
    if (config == null || !config.isComplete) return null;
    return providers.build(config, model: config.resolveModel(modelId) ?? config.defaultModel);
  }

  /// Once a new conversation has its first answer, a model writes its title (the setting
  /// `autoTitle`). It is tried twice at most; a failure leaves the first question as the title.
  void _maybeTitle(_Session session, String id, ConversationSnapshot snapshot) {
    final s = settings.value;
    if (session.titled || !s.autoTitle || session.titleTries >= 2) return;
    String? question;
    String? answer;
    for (final m in snapshot.messages) {
      if (m.role == Role.user && question == null && m.text.trim().isNotEmpty) question = m.text;
      if (m.role == Role.assistant && answer == null && m.text.trim().isNotEmpty && m.finish != FinishReason.error) answer = m.text;
    }
    if (question == null || answer == null) return;
    final provider = _titleProvider();
    if (provider == null) return;
    session.titleTries++;
    unawaited(() async {
      final title = await TitleMaker.make(provider, question: question!, answer: answer!, maxChars: s.titleMaxChars);
      if (title == null) return;
      session.titled = true;
      try {
        await history.rename(id, title);
        await refreshConversations();
      } catch (e) {
        debugPrint('could not set the title: $e');
      }
    }());
  }

  void _persist(_Session session, ConversationSnapshot snapshot, bool generating) {
    if (snapshot.messages.isEmpty) return;
    if (generating) _noteModelUsed();
    final providerId = providers.activeId;
    final modelId = providers.activeModelId;
    _writer = _writer.then((_) async {
      try {
        final id = await history.save(
          session.id,
          snapshot,
          generating: generating,
          providerId: providerId,
          modelId: modelId,
        );
        if (session.id == null) {
          session.id = id;
          notifyListeners();
        }
        // the device model has just worked on this conversation: its cache is the one to keep
        if (!generating && !providers.isCloud && models.isLoaded) _kvOwner = id;
        await refreshConversations();
        if (!generating) _maybeTitle(session, id, snapshot);
      } catch (e) {
        debugPrint('could not save the conversation: $e');
      }
    });
  }

  @override
  void dispose() {
    _toastTimer?.cancel();
    _lifecycle?.dispose();
    chat.removeListener(_syncForeground);
    chat.dispose();
    for (final session in _sessions) {
      session.chat.removeListener(_syncForeground);
    }
    unawaited(foreground.stop());
    providers.removeListener(_applyProvider);
    unawaited(preview.dispose());
    updates.dispose();
    super.dispose();
  }
}

/// The tools of one chat. Everything goes to the shared runtime except `delegate`, which needs this
/// chat's stop button (the developer model may work for minutes) and, when the developer is the
/// device model, the device lease.
class _SessionToolRuntime implements ToolRuntime {
  _SessionToolRuntime(this._base, this._delegate, this._stop, this._lease, this._meter, this._rounds);

  final ToolRuntime _base;
  final DelegateRunner _delegate;
  final StopSignal _stop;
  final ExclusiveLease _lease;
  final RunMeter _meter;

  /// This chat's rounds of the 分担モード: the last reports, and whether the user has answered since.
  final DelegateSession _rounds;

  @override
  Future<ToolOutcome> run(ToolCall call) {
    if (call is Delegate) {
      return _delegate.run(
        call,
        stop: _stop.future,
        acquireDevice: () => _lease.acquire(this),
        releaseDevice: () => _lease.release(this),
        meter: _meter,
        session: _rounds,
      );
    }
    return _base.run(call);
  }
}

/// One chat: the controller that runs it, and the id of its saved conversation (null until it is saved).
class _Session {
  late final ChatController chat;
  final watch = ReplyWatch();
  String? id;

  /// Names this conversation for an online provider's prompt cache: the same for every request of it. It is
  /// made when the conversation starts and does not change when the conversation is saved and gets its id
  /// (that would start the cache over); a conversation that is opened again uses its id.
  String cacheKey = newCacheKey();

  static final _random = Random();

  /// `arce-` and 16 random hexadecimal digits: nothing about the user or the text.
  static String newCacheKey() => 'arce-${List.generate(16, (_) => _random.nextInt(16).toRadixString(16)).join()}';

  /// Whether this conversation has its title (written by a model, or one it already had when opened).
  bool titled = false;
  int titleTries = 0;
}

/// Stands in until the user adds a provider: a request would reach nobody, so it says so.
class _NoProvider implements AiProvider {
  const _NoProvider();

  @override
  String get id => 'none';

  @override
  String get label => '未設定';

  @override
  String get modelId => '';

  @override
  ModelConfig? get modelConfig => null;

  @override
  ProviderCapabilities get capabilities => const ProviderCapabilities();

  @override
  Stream<Delta> stream(AiRequest request) async* {
    throw const AiProviderException('プロバイダが設定されていません');
  }

  @override
  Future<void> verify() async =>
      throw const AiProviderException('プロバイダが設定されていません');
}

/// What [AppController.promptTokens] says: the tokens of each part of the next request.
class PromptTokens {
  const PromptTokens({required this.system, required this.tools, required this.conversation, required this.draft, this.context});

  final int system;
  final int tools;
  final int conversation;
  final int draft;

  /// The model's context window, or null when it is not known.
  final int? context;

  int get total => system + tools + conversation + draft;

  /// How much of the context the request takes, or null when the context is not known.
  double? get ratio => context == null || context! <= 0 ? null : total / context!;
}

/// Tools read the settings at call time, so a changed SearXNG address or search switch applies at once.
class _SettingsToolRuntime implements ToolRuntime {
  _SettingsToolRuntime(this._settings, this._providers, this._http, this._httpPost, this._mcp);

  final SettingsStore _settings;
  final ProviderStore _providers;
  final HttpGet _http;
  final HttpPost _httpPost;

  /// The MCP tools and the app's own (`run_command`, `ci_status`), built from the current settings: the
  /// same object the chat asks for definitions and approvals, so what runs is what was shown.
  final McpTools Function() _mcp;

  @override
  Future<ToolOutcome> run(call) {
    if (call is McpCall) return _mcp().run(call);
    final s = _settings.value;
    final providers = <SearchProvider>[
      if (s.searxngUrl.trim().isNotEmpty)
        SearXngProvider(s.searxngUrl.trim(), _http),
      for (final api in s.searchApis)
        if (api.enabled) ConfiguredSearchProvider(api, _settings.searchKeyOf(api.id), _http, post: _httpPost),
      DuckDuckGoInstantProvider(_http),
    ];
    // without a search server or a search API, only DuckDuckGo's summaries are left, which answer few questions
    final onlySummaries = s.searxngUrl.trim().isEmpty && !s.searchApis.any((a) => a.enabled);
    return DefaultToolRuntime(
      searchHint: onlySummaries
          ? '検索の設定がありません。設定の「検索 API」か「SearXNG のアドレス」を入れると、普通の検索ができます'
          : null,
      search: s.searchEnabled
          ? SearchService(
              providers,
              retriesPerProvider: s.retryLimit.clamp(0, 3),
              limit: s.searchResultCount.clamp(1, 20),
            )
          : null,
      weather: OpenMeteoWeather(_http),
      settingsValues: () => _settings.value.toJson(),
      extraSettings: _describeConfiguration,
    ).run(call);
  }

  /// Providers and MCP servers for `get_settings`: enough to answer questions about them, with
  /// no key and no token.
  String _describeConfiguration() {
    final b = StringBuffer('プロバイダとモデル（追加は add_provider、編集は詳細設定）:\n');
    final providers = _providers.providers;
    if (providers.isEmpty) {
      b.write('- （なし。ローカルモデルで答えます）\n');
    } else {
      b.write('- ローカルモデル = ${_providers.isCloud ? '使用していません' : '使用中'}\n');
      for (final provider in providers) {
        b.write(
          '- ${provider.label.isEmpty ? provider.id : provider.label} (id=${provider.id})'
          ' = ${provider.baseUrl}、モデル: ${provider.models.map((m) => m.id).join(', ')}'
          '${provider.models.isEmpty ? '（未追加）' : ''}'
          '、APIキー: ${_providers.hasKey(provider.id) ? '設定済み' : '未設定'}',
        );
        if (_providers.activeId == provider.id) {
          b.write('、使用中（モデル ${_providers.activeModelId}）');
        }
        b.write('\n');
      }
    }
    b.write('MCP サーバー（詳細設定から追加・編集できます）:\n');
    final servers = _settings.value.mcpServers;
    if (servers.isEmpty) {
      b.write('- （なし）\n');
    } else {
      for (final server in servers) {
        b.write(
          '- ${server.name.isEmpty ? server.id : server.name} (id=${server.id})'
          ' = ${server.url}、${server.enabled ? '有効' : '無効'}'
          '、書き込み前の確認: ${server.approveWrites ? 'あり' : 'なし'}'
          '、トークン: ${_settings.mcpTokenOf(server.id).isEmpty ? '未設定' : '設定済み'}\n',
        );
      }
    }
    b.write('検索 API（詳細設定から追加・編集できます）:\n');
    final apis = _settings.value.searchApis;
    if (apis.isEmpty) {
      b.write('- （なし。SearXNG のアドレス: ${_settings.value.searxngUrl.trim().isEmpty ? '未設定' : _settings.value.searxngUrl.trim()}）\n');
    } else {
      for (final api in apis) {
        b.write(
          '- ${api.name.isEmpty ? api.id : api.name} (id=${api.id}) = ${api.url.split('?').first}、${api.enabled ? '有効' : '無効'}'
          '${api.needsKey ? '、APIキー: ${_settings.searchKeyOf(api.id).isEmpty ? '未設定' : '設定済み'}' : ''}\n',
        );
      }
    }
    b.write('APIキー・MCPトークン・検索のキーは、このツールでも詳細設定でも読み出せません（チャットからは変更もできません）。');
    return b.toString();
  }
}
