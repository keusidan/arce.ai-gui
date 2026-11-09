import 'dart:convert';

import 'package:arce_ai/core/engine.dart';
import 'package:arce_ai/core/settings_spec.dart';
import 'package:arce_ai/core/search.dart';
import 'package:arce_ai/core/shell_secrets.dart';
import 'package:arce_ai/mcp/mcp_server.dart';
import 'package:arce_ai/core/dangerous_commands.dart';
import 'package:arce_ai/services/desktop_shell.dart';
import 'package:arce_ai/services/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('settings survive a JSON round trip and unknown values fall back', () {
    const original = AppSettings(
      thinking: false,
      theme: ThemeMode.dark,
      thinkingStyle: ThinkingStyle.rotation,
      kvCache: KvCacheType.q8_0,
      gpuOffload: GpuOffload.maxGpu,
      contextLength: 8192,
      updateRepo: 'someone/else',
    );
    final back = AppSettings.fromJson(original.toJson());
    expect(back.toJson(), original.toJson());

    final damaged = AppSettings.fromJson({
      'theme': 'neon',
      'contextLength': 'lots',
      'thinking': 3,
    });
    expect(damaged.theme, ThemeMode.system);
    expect(damaged.contextLength, 4096);
    expect(damaged.thinking, isTrue);
  });

  test('a save from before the move (keusidan/arce.ai) looks for updates and sends reports to keusidan/arce.ai-gui', () {
    final old = AppSettings.fromJson({'updateRepo': 'keusidan/arce.ai', 'errorReportRepo': 'keusidan/arce.ai'});
    expect((old.updateRepo, old.errorReportRepo), ('keusidan/arce.ai-gui', 'keusidan/arce.ai-gui'));
    expect(const AppSettings().updateRepo, 'keusidan/arce.ai-gui');
    final mine = AppSettings.fromJson({'updateRepo': 'me/fork', 'errorReportRepo': 'me/fork'});
    expect((mine.updateRepo, mine.errorReportRepo), ('me/fork', 'me/fork'), reason: 'a repository the user typed is kept');
  });

  test('the commands on a PC: sandboxed and automatic by default, every value survives a save, and a bad one falls back', () {
    const d = AppSettings();
    expect((d.desktopSandbox, d.desktopHostApproval, d.desktopContainerImage), (true, HostApproval.auto, 'ubuntu:24.04'));
    expect(d.desktopDangerPatterns, DangerousCommands.defaults);
    final custom = AppSettings.fromJson(const AppSettings(
      desktopSandbox: false,
      desktopHostApproval: HostApproval.always,
      desktopContainerEngine: 'podman',
      desktopContainerNetwork: false,
      desktopHostShell: 'zsh -c',
      desktopDangerPatterns: [r'\bnpm publish\b'],
    ).toJson());
    expect((custom.desktopSandbox, custom.desktopHostApproval, custom.desktopContainerEngine, custom.desktopContainerNetwork, custom.desktopHostShell),
        (false, HostApproval.always, 'podman', false, 'zsh -c'));
    expect(custom.desktopDangerPatterns, [r'\bnpm publish\b']);
    final bad = AppSettings.fromJson(const {'desktopHostApproval': 'yolo', 'desktopContainerEngine': 'lxc', 'desktopDangerPatterns': 'rm'});
    expect((bad.desktopHostApproval, bad.desktopContainerEngine, bad.desktopDangerPatterns), (HostApproval.auto, 'auto', DangerousCommands.defaults));
  });

  test('the 0.9.0 model settings: defaults, round trip, and the chat may change them', () {
    const d = AppSettings();
    expect(d.thinkingExpanded, isTrue, reason: 'the thinking is shown open unless the user folds it');
    expect(d.tokenPrecheck, isTrue);
    expect(d.fallbackEnabled, isTrue);
    expect(d.maxToolRounds, 30);

    const custom = AppSettings(thinkingExpanded: false, tokenPrecheck: false, fallbackEnabled: false, tokenOverheadPercent: 60, recentModelCount: 3);
    final back = AppSettings.fromJson(custom.toJson());
    expect(back.thinkingExpanded, isFalse);
    expect(back.tokenPrecheck, isFalse);
    expect(back.fallbackEnabled, isFalse);
    expect(back.tokenOverheadPercent, 60);
    expect(back.recentModelCount, 3);
    expect(back.toJson(), custom.toJson());

    expect(d.mcpResultMaxChars, 30000);
    expect(AppSettings.fromJson(const AppSettings(mcpResultMaxChars: 9000).toJson()).mcpResultMaxChars, 9000);
    expect(AppSettings.fromJson({'mcpResultMaxChars': 3}).mcpResultMaxChars, 500, reason: 'kept inside its range');
    expect(AgentSettings.isEditable('mcpResultMaxChars'), isTrue);
    expect(d.errorReportEnabled, isTrue, reason: 'on, but nothing is sent without a token');
    expect(d.errorReportRepo, AppSettings.defaultRepo);
    expect((d.errorReportMinHours, d.errorReportMaxPerHour), (6, 5));
    final reports = AppSettings.fromJson(const AppSettings(errorReportEnabled: false, errorReportRepo: 'me/app', errorReportMinHours: 12, errorReportMaxPerHour: 2).toJson());
    expect((reports.errorReportEnabled, reports.errorReportRepo, reports.errorReportMinHours, reports.errorReportMaxPerHour), (false, 'me/app', 12, 2));
    expect(AppSettings.fromJson({'errorReportMinHours': 0, 'errorReportMaxPerHour': 999}).errorReportMinHours, 1);
    expect(AppSettings.fromJson({'errorReportMaxPerHour': 999}).errorReportMaxPerHour, 60);
    // the on/off and the destination cannot be changed from a chat message (an injected text could
    // otherwise send the reports somewhere else); the rates can
    for (final key in ['errorReportEnabled', 'errorReportRepo']) {
      expect(AgentSettings.isEditable(key), isFalse, reason: key);
      expect(AgentSettings.normalize(key, 'x'), isA<SettingsChangeInvalid>(), reason: key);
    }
    expect(AgentSettings.isEditable('errorReportMinHours') && AgentSettings.isEditable('errorReportMaxPerHour'), isTrue);
    expect(d.codeFoldLines, 0, reason: 'no code block starts folded unless the user asks');
    expect(AppSettings.fromJson(const AppSettings(codeFoldLines: 40).toJson()).codeFoldLines, 40);
    expect(AgentSettings.isEditable('codeFoldLines'), isTrue);
    expect(d.autoTitle, isTrue, reason: 'a model writes the title of a new conversation unless it is turned off');
    expect(d.titleModel, isEmpty, reason: 'empty: the online model in use');
    expect(d.titleMaxChars, 30);
    final titled = AppSettings.fromJson(const AppSettings(autoTitle: false, titleModel: 'host|small', titleMaxChars: 20).toJson());
    expect((titled.autoTitle, titled.titleModel, titled.titleMaxChars), (false, 'host|small', 20));
    expect(AppSettings.fromJson({'titleMaxChars': 1}).titleMaxChars, 8, reason: 'kept inside its range');
    expect(AgentSettings.isEditable('autoTitle') && AgentSettings.isEditable('titleModel') && AgentSettings.isEditable('titleMaxChars'), isTrue);
    expect(AgentSettings.isEditable('thinkingExpanded'), isTrue);
    expect(AgentSettings.normalize('thinkingExpanded', false), isA<SettingsChangeOk>());
  });

  test('the device model and the online models have their own settings', () {
    const s = AppSettings(
      maxTokens: 2048,
      localTemperature: 0.3,
      localTopK: 40,
      localMaxTokens: 512,
      localPrompt: ' 簡潔に ',
      onlineTemperature: 1.2,
      onlineTopP: 0.5,
      onlineMaxTokens: 4096,
    );
    final back = AppSettings.fromJson(s.toJson());
    expect(back.localTemperature, 0.3);
    expect(back.onlineTemperature, 1.2);

    final local = s.toGeneration(null);
    expect(local.temperature, 0.3);
    expect(local.topK, 40);
    expect(local.maxTokens, 512);
    expect(local.extraPrompt, '簡潔に');
    expect(local.topP, isNull, reason: 'not set: the app value applies');

    final online = s.toGeneration(null, cloud: true);
    expect(online.temperature, 1.2);
    expect(online.topP, 0.5);
    expect(online.maxTokens, 4096);
    expect(online.topK, isNull, reason: 'top_k is for the device engine only');
    expect(online.extraPrompt, isEmpty, reason: 'the local prompt never reaches an online model');

    // nothing set: every value is the app's own
    final plain = const AppSettings().toGeneration(null);
    expect(plain.temperature, isNull);
    expect(plain.maxTokens, 2048);
    const base = SamplingParams.qwen3Thinking;
    expect(plain.applyTo(base).temperature, base.temperature);
    expect(local.applyTo(base).temperature, 0.3);
    expect(local.applyTo(base).topP, base.topP);
  });

  test('the tools that are not asked about again are kept as a list, only MCP tools can be on it, and a chat message cannot change it', () {
    final saved = const AppSettings(approvedTools: ['mcp_github__push_files', 'run_command', 'web_search']).toJson();
    expect(AppSettings.fromJson(saved).approvedTools, ['mcp_github__push_files'], reason: 'a command and a built-in tool are never remembered, even if a file says so');
    expect(AppSettings.fromJson(const {}).approvedTools, isEmpty);
    expect(AppSettings.fromJson(const {'approvedTools': 'not a list'}).approvedTools, isEmpty);
    for (final key in ['approvedTools', 'shellConfirmAfterExternal', 'shellConfirm', 'linuxDns', 'linuxRootfsUrl', 'linuxRootfsSha256', 'desktopSandbox', 'desktopHostApproval', 'desktopDangerPatterns', 'desktopHostShell', 'desktopContainerImage', 'desktopContainerEngine']) {
      expect(AgentSettings.isEditable(key), isFalse, reason: '$key must not be reachable from a chat message');
      expect(AgentSettings.blocked, contains(key));
    }
    expect(const AppSettings().shellConfirmAfterExternal, isTrue, reason: 'on by default');
    expect(AppSettings.fromJson(const AppSettings(shellConfirmAfterExternal: false).toJson()).shellConfirmAfterExternal, isFalse);
  });

  test('the secrets a command may be given are kept as names only, bad names are dropped, and a chat message cannot change them', () {
    final saved = const AppSettings(shellSecrets: [
      ShellSecret(name: 'GITHUB_TOKEN', mcpServerId: 'github'),
      ShellSecret(name: 'NPM_TOKEN'),
    ]).toJson();
    expect(jsonEncode(saved), isNot(contains('ghp_')), reason: 'there is no value in the settings');
    final back = AppSettings.fromJson(saved).shellSecrets;
    expect([for (final s in back) (s.name, s.mcpServerId)], [('GITHUB_TOKEN', 'github'), ('NPM_TOKEN', '')]);
    final odd = AppSettings.fromJson({
      'shellSecrets': [
        {'name': 'HOME'},
        {'name': 'OK_ONE'},
        'text',
        {'nothing': 1},
      ],
    }).shellSecrets;
    expect([for (final s in odd) s.name], ['OK_ONE']);
    expect(AppSettings.fromJson(const {'shellSecrets': 'x'}).shellSecrets, isEmpty);
    expect(AgentSettings.isEditable('shellSecrets'), isFalse);
    expect(AgentSettings.blocked, contains('shellSecrets'));
  });

  test('MCP on demand, the notifications and the summary of long conversations are settings, with defaults and ranges', () {
    const d = AppSettings();
    expect((d.mcpOnDemand, d.mcpOnDemandTokens), (true, 2000));
    expect((d.notifyNeedsYou, d.notifyDone, d.notifyFailed, d.notifyOnlyAway), (true, true, true, true));
    expect((d.compactEnabled, d.compactAtPercent, d.compactKeepTurns), (true, 80, 4));
    for (final key in ['mcpOnDemand', 'mcpOnDemandTokens', 'notifyNeedsYou', 'notifyDone', 'notifyFailed', 'notifyOnlyAway', 'compactEnabled', 'compactAtPercent', 'compactKeepTurns', 'compactSummaryChars', 'compactToolResultChars']) {
      expect(AgentSettings.isEditable(key), isTrue, reason: '$key can be changed from the chat');
      expect(d.toJson().containsKey(key), isTrue, reason: '$key is saved');
    }
    final wild = const AppSettings(compactAtPercent: 5, compactKeepTurns: 0, compactSummaryChars: 1, compactToolResultChars: 1).toGeneration(null).compaction;
    expect((wild.atPercent, wild.keepTurns, wild.summaryChars, wild.toolResultChars), (30, 1, 300, 200));
    final huge = const AppSettings(compactAtPercent: 500, compactKeepTurns: 999, compactSummaryChars: 99999999, compactToolResultChars: 99999999).toGeneration(null).compaction;
    expect((huge.atPercent, huge.keepTurns, huge.summaryChars, huge.toolResultChars), (95, 30, 20000, 50000));
    expect(AppSettings.fromJson(const AppSettings(compactEnabled: false, mcpOnDemand: false).toJson()).compactEnabled, isFalse);
  });

  test('the settings of the secrets a model may use by placeholder and of http_request: defaults, ranges, and which ones a chat message cannot change', () {
    const d = AppSettings();
    expect((d.httpRequestEnabled, d.httpRequestConfirm, d.httpRequestMaxResponseChars, d.httpRequestTimeoutSeconds, d.httpRequestAllowInsecure), (true, 'secretOrWrite', 20000, 30, false));
    expect(d.secretsOffForModel, isEmpty);
    final back = AppSettings.fromJson(const AppSettings(secretsOffForModel: ['provider:gem'], httpRequestConfirm: 'all', httpRequestAllowInsecure: true).toJson());
    expect(back.secretsOffForModel, ['provider:gem']);
    expect((back.httpRequestConfirm, back.httpRequestAllowInsecure), ('all', true));
    expect(AppSettings.fromJson(const {'httpRequestConfirm': 'sometimes'}).httpRequestConfirm, 'secretOrWrite', reason: 'an unknown mode is the safe default');
    expect(AppSettings.fromJson(const {'httpRequestMaxResponseChars': 1, 'httpRequestTimeoutSeconds': 99999}).httpRequestMaxResponseChars, 500);
    expect(AppSettings.fromJson(const {'httpRequestTimeoutSeconds': 99999}).httpRequestTimeoutSeconds, 600);
    expect(AppSettings.fromJson(const {'secretsOffForModel': 'x'}).secretsOffForModel, isEmpty);
    expect(d.httpRequestMaxRedirects, 5);
    expect(AppSettings.fromJson(const {'httpRequestMaxRedirects': 99}).httpRequestMaxRedirects, 10);
    expect(AppSettings.fromJson(const {'httpRequestMaxRedirects': -3}).httpRequestMaxRedirects, 0);
    expect(AgentSettings.isEditable('httpRequestMaxRedirects'), isTrue);
    for (final key in ['secretsOffForModel', 'httpRequestConfirm', 'httpRequestAllowInsecure']) {
      expect(AgentSettings.isEditable(key), isFalse, reason: '$key must not be reachable from a chat message');
      expect(AgentSettings.blocked, contains(key));
    }
    for (final key in ['httpRequestEnabled', 'httpRequestMaxResponseChars', 'httpRequestTimeoutSeconds']) {
      expect(AgentSettings.isEditable(key), isTrue, reason: key);
    }
  });

  test('the preview page limit is a setting, kept inside its range', () {
    expect(const AppSettings().previewMaxPages, 50);
    expect(AppSettings.fromJson(const {'previewMaxPages': 0}).previewMaxPages, 1);
    expect(AppSettings.fromJson(const {'previewMaxPages': 99999}).previewMaxPages, 500);
    expect(AgentSettings.isEditable('previewMaxPages'), isTrue);
  });

  test('the planner follows the model in use by default (a saved fixed planner stays fixed), and more developers round-trip', () {
    expect(const AppSettings().coding.plannerFollowsModel, isTrue);
    expect(AppSettings.fromJson(const {}).coding.plannerFollowsModel, isTrue, reason: 'settings saved before this option existed follow the model in use');
    final back = AppSettings.fromJson(const AppSettings(codingPlannerFollows: false, developerModel: 'a|1', developerModelsMore: 'b|2\nc|3, d|4').toJson());
    expect(back.coding.plannerFollowsModel, isFalse);
    expect(back.coding.developers, ['a|1', 'b|2', 'c|3', 'd|4']);
    expect(AgentSettings.isEditable('codingPlannerFollows'), isTrue);
    expect(AgentSettings.isEditable('developerModelsMore'), isTrue);
    expect(const AppSettings().coding.maxTasks, 8, reason: 'jobs are split finely, so the default is higher');
    expect(const AppSettings().coding.parallel, 4);
  });

  test('the coding mode settings round-trip, and are kept inside their limits', () {
    const s = AppSettings(
      codingPlanEnabled: true,
      plannerModel: 'openai|gpt-4o',
      developerModel: 'local|',
      codingMaxTasks: 99,
      codingParallel: 0,
      codingReviewRounds: -3,
      codingDeveloperMaxTokens: 8192,
    );
    final back = AppSettings.fromJson(s.toJson());
    expect(back.coding.enabled, isTrue);
    expect(back.coding.planner, 'openai|gpt-4o');
    expect(back.coding.developer, 'local|');
    expect(back.coding.maxTasks, 16, reason: 'too many tasks is cut to the limit');
    expect(back.coding.parallel, 1);
    expect(back.coding.reviewRounds, 0);
    expect(back.coding.developerMaxTokens, 8192);
    expect(const AppSettings().coding.isReady, isFalse, reason: 'off until the user turns it on');
  });

  test('limits and timeouts are settings, kept inside sane ranges', () {
    final s = const AppSettings(
      attachMaxFiles: 99,
      attachCharsPerFile: 10,
      attachTotalChars: 20000,
      attachImageMb: 8,
      toolRepeatLimit: 1,
      localDryMultiplier: 1.5,
    );
    final back = AppSettings.fromJson(s.toJson());
    expect(back.attachmentLimits.maxFiles, 20, reason: 'cut to the limit');
    expect(back.attachmentLimits.maxCharsPerFile, 500);
    expect(back.attachmentLimits.maxTotalChars, 20000);
    expect(back.attachmentLimits.maxImageBytes, 8 * 1024 * 1024);

    final generation = back.toGeneration(null);
    expect(generation.toolRepeatLimit, 2, reason: 'one identical call is not a loop');
    expect(generation.attachments.maxFiles, 20);
    expect(generation.dryMultiplier, 1.5);
    expect(back.toGeneration(null, cloud: true).dryMultiplier, isNull, reason: 'DRY is the device model\'s');

    // nothing changed: the values the app always had
    const d = AppSettings();
    expect(d.attachmentLimits.maxFiles, 5);
    expect(d.attachmentLimits.maxCharsPerFile, 8000);
    expect(d.attachmentLimits.maxTotalChars, 16000);
    expect(d.searchResultCount, 5);
    expect(d.httpTimeoutSeconds, 20);
    expect(d.mcpTimeoutSeconds, 40);
    expect(d.providerTimeoutSeconds, 120);
    expect(d.toolRepeatLimit, 3);
    expect(d.updateRetryAttempts, 5);
    expect(d.updateStallSeconds, 30);
  });

  test('KV cache saving is off by default, and its limits stay in range', () {
    const d = AppSettings();
    expect(d.kvSnapshotEnabled, isFalse, reason: 'it costs disk space, so the user turns it on');
    expect(d.kvSnapshot.enabled, isFalse);
    expect(d.kvSnapshot.maxBytes, 1024 * 1024 * 1024);
    expect(d.kvSnapshot.minTokens, 512);

    final s = AppSettings.fromJson(const AppSettings(kvSnapshotEnabled: true, kvSnapshotMaxMb: 5, kvSnapshotMinTokens: 1).toJson());
    expect(s.kvSnapshot.enabled, isTrue);
    expect(s.kvSnapshot.maxBytes, 64 * 1024 * 1024, reason: 'too small a limit is raised to the smallest one');
    expect(s.kvSnapshot.minTokens, 64);
    expect(AppSettings.fromJson({'kvCache': 'q4_0'}).kvCache, KvCacheType.q4_0);
  });

  test('the developer token budget is automatic (0) unless the user picked one; 0.8.1 defaults migrate', () {
    expect(const AppSettings().coding.developerMaxTokens, 0);
    // 0.8.1 wrote its fixed default (4096) into every saved settings document
    final old = AppSettings.fromJson({'codingDeveloperMaxTokens': 4096});
    expect(old.coding.developerMaxTokens, 0);
    final chosen = AppSettings.fromJson({'codingDeveloperMaxTokens': 262144});
    expect(chosen.coding.developerMaxTokens, 262144, reason: 'a 256K budget is allowed now');
    expect(AppSettings.fromJson(chosen.toJson()).coding.developerMaxTokens, 262144);
  });

  test('the planner works with its own limit set in the chat: the result length is a setting; the old planner budget is gone', () {
    expect(const AppSettings().coding.resultChars, 12000);
    expect(AppSettings.fromJson(const AppSettings(codingResultChars: 6000).toJson()).coding.resultChars, 6000);
    expect(AppSettings.fromJson({'codingResultChars': 5}).coding.resultChars, 500, reason: 'kept inside its range');
    expect(AppSettings.fromJson({'codingPlannerMaxTokens': 16384}).toJson().containsKey('codingPlannerMaxTokens'), isFalse, reason: 'an old save is read, and the key is dropped');
    expect(AgentSettings.isEditable('codingResultChars'), isTrue);
  });

  test('model info lookup is on by default, and the user-set reply length is passed on', () {
    const d = AppSettings();
    expect(d.autoFetchModelInfo, isTrue);
    expect(d.fetchModelInfoFromHub, isTrue);
    expect(AppSettings.fromJson(const AppSettings(autoFetchModelInfo: false).toJson()).autoFetchModelInfo, isFalse);

    expect(d.toGeneration(null, cloud: true).userMaxTokens, isNull, reason: 'nothing set: the maker\'s recommendation may apply');
    expect(const AppSettings(onlineMaxTokens: 9000).toGeneration(null, cloud: true).userMaxTokens, 9000);
    expect(const AppSettings(localMaxTokens: 500).toGeneration(null).userMaxTokens, 500);
    expect(const AppSettings(onlineMaxTokens: 9000).toGeneration(null).userMaxTokens, isNull, reason: 'the online setting never reaches the device model');

    // each online model's own largest reply is the default; the device model never takes it
    expect(d.onlineUseModelMax, isTrue);
    expect(d.toGeneration(null, cloud: true).useModelMax, isTrue);
    expect(d.toGeneration(null).useModelMax, isFalse);
    expect(const AppSettings(onlineUseModelMax: false).toGeneration(null, cloud: true).useModelMax, isFalse);
    expect(AppSettings.fromJson(const AppSettings(onlineUseModelMax: false).toJson()).onlineUseModelMax, isFalse);
    expect(AgentSettings.isEditable('onlineUseModelMax'), isTrue, reason: 'the chat may change it, like the other lengths');
  });

  test('threads and GPU layers follow HyperLoad and the offload setting', () {
    expect(const AppSettings().effectiveThreads(8), 4);
    expect(const AppSettings(hyperLoad: true).effectiveThreads(8), 8);
    expect(const AppSettings(threads: 3).effectiveThreads(8), 3);
    expect(const AppSettings().gpuLayers(gpuAvailable: true), 20);
    expect(
      const AppSettings(hyperLoad: true).gpuLayers(gpuAvailable: true),
      999,
    );
    expect(
      const AppSettings(gpuOffload: GpuOffload.cpuOnly)
          .gpuLayers(gpuAvailable: true),
      0,
    );
    expect(
      const AppSettings(gpuOffload: GpuOffload.gpuPriority)
          .gpuLayers(gpuAvailable: false),
      0,
    );
  });

  test('the store saves changes and loads them next time', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await SettingsStore.load();
    await store.update(
      (s) => s.copyWith(searxngUrl: 'http://pi:8080', maxChars: 800),
    );

    final again = await SettingsStore.load();
    expect(again.value.searxngUrl, 'http://pi:8080');
    expect(again.value.maxChars, 800);
  });

  test('search services are saved, their keys are not', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await SettingsStore.load();
    final api = SearchApiConfig.presets['Brave Search']!.copyWith(name: 'Brave Search');
    final saved = SearchApiConfig.fromJson({...api.toJson(), 'id': 'brave-search'});
    await store.update((s) => s.copyWith(searchApis: [saved]));
    await store.setSearchKey('brave-search', '  BSA-secret  ');

    expect(store.searchKeyOf('brave-search'), 'BSA-secret');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('settings.v1'), isNot(contains('BSA-secret')));
    expect(jsonEncode(store.value.toJson()), isNot(contains('BSA-secret')));

    final again = await SettingsStore.load();
    expect(again.value.searchApis.single.url, saved.url);

    await store.forgetSearchKey('brave-search');
    expect(store.searchKeyOf('brave-search'), isEmpty);
  });

  test('a damaged save does not stop the app from starting', () async {
    SharedPreferences.setMockInitialValues({'settings.v1': '{not json'});
    final store = await SettingsStore.load();
    expect(store.value.thinking, isTrue);
  });

  test('a single MCP endpoint from an older save becomes one server', () {
    final back = AppSettings.fromJson({
      'mcpEnabled': true,
      'mcpUrl': 'https://mcp.example/v1',
    });
    expect(back.mcpServers, hasLength(1));
    expect(back.mcpServers.single.url, 'https://mcp.example/v1');
    expect(back.mcpServers.single.enabled, isTrue);
    expect(back.mcpServers.single.id, 'default');
  });

  test('several MCP servers and their settings survive a round trip', () {
    const original = AppSettings(
      mcpServers: [
        McpServerConfig(
          id: 'github',
          name: 'GitHub',
          url: 'https://api.githubcopilot.com/mcp/',
        ),
        McpServerConfig(
          id: 'home',
          name: '自宅',
          url: 'http://pi:9000/mcp',
          enabled: false,
          approveWrites: false,
        ),
      ],
    );
    final back = AppSettings.fromJson(original.toJson());
    expect(back.mcpServers.map((s) => s.id), ['github', 'home']);
    expect(back.mcpServers.last.enabled, isFalse);
    expect(back.mcpServers.last.approveWrites, isFalse);
  });
}
