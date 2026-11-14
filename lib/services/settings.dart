import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/attachments.dart';
import '../core/chat_controller.dart';
import '../core/coding_plan.dart';
import '../core/dangerous_commands.dart';
import '../core/compaction.dart';
import '../core/engine.dart';
import '../core/protocol.dart' show ToolApproval;
import '../core/search.dart';
import '../core/shell_secrets.dart';
import '../core/settings_spec.dart';
import '../mcp/mcp_server.dart';
import 'desktop_shell.dart';
import 'kv_snapshots.dart';

enum GpuOffload { auto, cpuOnly, gpuPriority, maxGpu }

/// Icon shown while the model is working (see the "思考中" designs).
enum ThinkingStyle { brand, basic, ring, pulse, dots, rotation }

/// Every user setting (spec §8, §26). Basic ones first, developer ones after.
class AppSettings {
  const AppSettings({
    this.thinking = true,
    this.searchEnabled = true,
    this.searxngUrl = '',
    this.tone = '',
    this.maxChars = 0,
    this.speedAccuracy = 0.5,
    this.hyperLoad = false,
    this.theme = ThemeMode.system,
    this.thinkingStyle = ThinkingStyle.brand,
    this.agentOverride = '',
    this.aiAgentSelection = true,
    this.lastModelPath = '',
    this.contextLength = 4096,
    this.threads = 0,
    this.batchSize = 0,
    this.gpuOffload = GpuOffload.auto,
    this.kvCache = KvCacheType.f16,
    this.maxTokens = 2048,
    this.retryLimit = 2,
    this.maxToolRounds = 30,
    this.forceExecution = false,
    this.updateRepo = defaultRepo,
    this.autoUpdateCheck = true,
    this.autoInstallUpdate = true,
    this.mcpServers = const [],
    this.searchApis = const [],
    this.updateIntervalHours = 12,
    this.localTemperature = -1,
    this.localTopP = -1,
    this.localTopK = 0,
    this.localMinP = -1,
    this.localMaxTokens = 0,
    this.localPrompt = '',
    this.onlineTemperature = -1,
    this.onlineTopP = -1,
    this.onlineMaxTokens = 0,
    this.onlineUseModelMax = true,
    this.onlinePrompt = '',
    this.codingPlanEnabled = false,
    this.plannerModel = '',
    this.codingPlannerFollows = true,
    this.developerModelsMore = '',
    this.developerModel = '',
    this.codingMaxTasks = 8,
    this.codingParallel = 4,
    this.codingInvestigateFirst = true,
    this.codingMaxWorkers = 4,
    this.codingReviewRounds = 1,
    this.codingDeveloperMaxTokens = 0,
    this.codingResultChars = 12000,
    this.attachMaxFiles = 5,
    this.previewMaxPages = 50,
    this.attachCharsPerFile = 8000,
    this.attachTotalChars = 16000,
    this.attachImageMb = 4,
    this.searchResultCount = 5,
    this.httpTimeoutSeconds = 20,
    this.mcpTimeoutSeconds = 40,
    this.mcpResultMaxChars = 30000,
    this.providerTimeoutSeconds = 120,
    this.flexTimeoutSeconds = 900,
    this.toolRepeatLimit = 3,
    this.updateRetryAttempts = 5,
    this.updateStallSeconds = 30,
    this.downloadConnections = 4,
    this.updateUseDelta = true,
    this.resumeDownloadsOnStart = true,
    this.fontScale = 1.0,
    this.modelListAutoFetch = true,
    this.modelListRefreshHours = 24,
    this.fallbackEnabled = true,
    this.tokenPrecheck = true,
    this.thinkingExpanded = true,
    this.codeFoldLines = 0,
    this.inlinePreviewHeight = 360,
    this.showEnabled = true,
    this.showMaxChars = 200000,
    this.showMaxFileMb = 20,
    this.autoShowPages = false,
    this.errorReportEnabled = true,
    this.errorReportRepo = defaultRepo,
    this.errorReportMinHours = 6,
    this.errorReportMaxPerHour = 5,
    this.autoTitle = true,
    this.titleModel = '',
    this.titleMaxChars = 30,
    this.tokenOverheadPercent = 80,
    this.recentModelCount = 8,
    this.hideUnusableModels = false,
    this.markBlockedModels = true,
    this.autoCheckSelectedModel = true,
    this.modelCheckAsksToo = false,
    this.secretsOffForModel = const [],
    this.httpRequestEnabled = true,
    this.httpRequestConfirm = 'secretOrWrite',
    this.httpRequestMaxResponseChars = 20000,
    this.httpRequestTimeoutSeconds = 30,
    this.httpRequestAllowInsecure = false,
    this.httpRequestMaxRedirects = 5,
    this.modelProbeConcurrency = 3,
    this.modelProbeTimeoutSeconds = 30,
    this.modelAvailabilityTrustDays = 7,
    this.localDryMultiplier = -1,
    this.kvSnapshotEnabled = false,
    this.kvSnapshotMaxMb = 1024,
    this.kvSnapshotMinTokens = 512,
    this.autoFetchModelInfo = true,
    this.fetchModelInfoFromHub = true,
    this.shellEnabled = true,
    this.shellConfirm = false,
    this.shellConfirmAfterExternal = true,
    this.notifyNeedsYou = true,
    this.notifyDone = true,
    this.notifyFailed = true,
    this.notifyOnlyAway = true,
    this.compactEnabled = true,
    this.compactAtPercent = 80,
    this.compactKeepTurns = 4,
    this.compactSummaryChars = 3000,
    this.compactToolResultChars = 1500,
    this.approvedTools = const [],
    this.shellSecrets = const [],
    this.mcpOnDemand = true,
    this.mcpOnDemandTokens = 2000,
    this.shellTimeoutSeconds = 120,
    this.shellMaxTimeoutSeconds = 600,
    this.shellMaxOutputChars = 20000,
    this.shellSessionMax = 3,
    this.shellSessionIdleMinutes = 15,
    this.shellSessionWaitMs = 1500,
    this.shellSessionMaxWaitSeconds = 30,
    this.shellSessionCols = 120,
    this.shellSessionRows = 40,
    this.shellSessionScrollback = 500,
    this.shellSessionBufferKb = 256,
    this.workspaceLimitMb = 2048,
    this.linuxRootfsUrl = defaultLinuxRootfsUrl,
    this.linuxRootfsSha256 = defaultLinuxRootfsSha256,
    this.linuxDns = '1.1.1.1 8.8.8.8',
    this.shellCompatMode = false,
    this.desktopSandbox = true,
    this.desktopContainerEngine = 'auto',
    this.desktopContainerImage = DesktopShellSettings.defaultImage,
    this.desktopContainerName = DesktopShellSettings.defaultContainer,
    this.desktopContainerNetwork = true,
    this.desktopHostApproval = HostApproval.auto,
    this.desktopHostShell = '',
    this.desktopDangerPatterns = DangerousCommands.defaults,
  });

  static const defaultRepo = 'keusidan/arce.ai-gui';

  /// Where the app lived until 1.3.0. A save that still names it (the default then, written into every save) is
  /// read as [defaultRepo], so the installed app finds its updates in the new place; any other repository a user
  /// typed is kept.
  static const formerRepo = 'keusidan/arce.ai';

  static String _movedRepo(String repo) => repo.trim() == formerRepo ? defaultRepo : repo;

  /// The Ubuntu Base 24.04.5 for arm64 that was checked on 2026-10-28 (29,936,675 bytes; the
  /// SHA-256 matches the `SHA256SUMS` beside it and a real download).
  static const defaultLinuxRootfsUrl =
      'https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.5-base-arm64.tar.gz';
  static const defaultLinuxRootfsSha256 = 'a91d5a93010193712d346d761372b7c9db6dfcf093893161c64ca107f05914f2';

  final bool thinking;
  final bool searchEnabled;
  final String searxngUrl;
  final String tone;
  final int maxChars;
  final double speedAccuracy;
  final bool hyperLoad;
  final ThemeMode theme;
  final ThinkingStyle thinkingStyle;
  final String agentOverride;
  final bool aiAgentSelection;
  final String lastModelPath;
  final int contextLength;
  final int threads;
  final int batchSize;
  final GpuOffload gpuOffload;
  final KvCacheType kvCache;
  final int maxTokens;
  final int retryLimit;
  final int maxToolRounds;
  final bool forceExecution;
  final String updateRepo;
  final bool autoUpdateCheck;

  /// Download a newer build as soon as it is found and open the installer without being asked.
  final bool autoInstallUpdate;
  final int updateIntervalHours;

  // ---- model settings, kept apart for the model on the device and for the online models ----
  //
  // For a number, -1 (0 for a token count, empty for a prompt) means "not set": the app's own value
  // applies. An online model's own settings (see `ModelConfig`) win over the online ones here.

  /// Sampling of the model on the device: temperature, top-p, top-k and min-p.
  final double localTemperature;
  final double localTopP;
  final int localTopK;
  final double localMinP;

  /// The reply length the device model starts from, before "速度⇔精度" scales it.
  final int localMaxTokens;

  /// Extra instruction sent only to the device model.
  final String localPrompt;

  /// The same for online models that do not set their own.
  final double onlineTemperature;
  final double onlineTopP;
  final int onlineMaxTokens;

  /// With no length set, an online model's reply may be as long as that model's own largest reply (read from
  /// the provider's list) instead of the one shared default.
  final bool onlineUseModelMax;
  final String onlinePrompt;

  // ---- coding mode: a design model and a developer model share the work ----

  /// Split the coding agent's work between [plannerModel] and [developerModel].
  final bool codingPlanEnabled;

  /// `provider|model` of the model that designs and reviews (`local|` is the model on the device).
  final String plannerModel;

  /// The planner is the model in use (the one picked in the chat). Off: [plannerModel] answers the
  /// coding agent's requests, whatever the chat shows.
  final bool codingPlannerFollows;

  /// `provider|model` of the model that writes the code.
  final String developerModel;

  /// More developer models (`provider|model`, one per line): the jobs of one call are spread over
  /// all the developers, so several models write at the same time.
  final String developerModelsMore;
  final int codingMaxTasks;
  final int codingParallel;

  /// 分担モード: the parts are investigated and reported on first, and built after the user approves the design.
  final bool codingInvestigateFirst;

  /// 分担モード: the most parts that run at the same time (the 分担数 the planner may choose).
  final int codingMaxWorkers;
  final int codingReviewRounds;
  final int codingDeveloperMaxTokens;

  /// How many characters of each developer result the planner reads (the user sees all of it).
  final int codingResultChars;

  // ---- limits and timeouts that used to be fixed in the code ----

  /// How much of the attached files reaches the model (see `AttachmentPolicy`).
  final int attachMaxFiles;

  /// How many generated pages the local preview server keeps (the oldest goes).
  final int previewMaxPages;
  final int attachCharsPerFile;
  final int attachTotalChars;

  /// The biggest picture that is sent, in megabytes.
  final int attachImageMb;

  /// How many web search results a search keeps.
  final int searchResultCount;

  /// Seconds before a web search or a weather request gives up.
  final int httpTimeoutSeconds;

  /// Seconds before a call to an MCP server gives up.
  final int mcpTimeoutSeconds;

  /// How many characters of an MCP tool's result go to the model; the rest is cut.
  final int mcpResultMaxChars;

  /// Seconds an online model may take to answer a request before it gives up.
  final int providerTimeoutSeconds;

  /// How long a request of a model on the flex tier (`service_tier: flex`) may wait: flex answers more slowly.
  final int flexTimeoutSeconds;

  /// How many identical tool calls in a row count as a loop.
  final int toolRepeatLimit;

  /// How many times an update download is tried, and how many silent seconds end a try.
  final int updateRetryAttempts;
  final int updateStallSeconds;

  /// How many connections a download uses at once (1 = one connection, as before).
  final int downloadConnections;

  /// Download only the difference to the installed build when the release has one (Android).
  final bool updateUseDelta;

  /// Carry on with a model download that the app was closed in the middle of, when it starts again.
  final bool resumeDownloadsOnStart;

  /// How large the text is, as a factor of the usual size (1 = usual); it comes on top of the system's own text size.
  final double fontScale;

  /// Read each provider's model list by itself: when the provider is saved, and again when the
  /// list is older than [modelListRefreshHours]. Off keeps the lists as they are until the user
  /// asks.
  final bool modelListAutoFetch;
  final int modelListRefreshHours;

  /// Use the fallback rules (the models to try when one cannot be used). The rules themselves are
  /// set on the model detail screen only: a rule sends the conversation to another provider.
  final bool fallbackEnabled;

  /// Count the instructions and tool definitions before a request and refuse one that cannot fit
  /// the model's context; [tokenOverheadPercent] is how much of the context they may take.
  final bool tokenPrecheck;

  /// Whether the model's thinking is shown open under the reply (true) or folded away (false).
  final bool thinkingExpanded;

  /// A code block longer than this many lines starts folded (0: no block starts folded).
  final int codeFoldLines;

  /// The height of the page an HTML or SVG code block shows inside the chat; 0 leaves out the button that shows it.
  final int inlinePreviewHeight;

  /// The tool `show`, with which the model puts a page on the screen: offered or not, the longest page it may carry,
  /// the largest file of a shown folder, and whether a page opens by itself (instead of by the button).
  final bool showEnabled;
  final int showMaxChars;
  final int showMaxFileMb;
  final bool autoShowPages;

  // ---- error reports: an error goes to a GitHub issue, with the user's own token ----

  /// Whether errors are reported. Nothing is sent without a token (secure storage) as well.
  final bool errorReportEnabled;

  /// `owner/name` of the repository the issues go to. Not reachable from a chat message: a text in a
  /// chat could otherwise send the reports somewhere else.
  final String errorReportRepo;

  /// The same problem is commented on at most this often (hours); in between it is only counted.
  final int errorReportMinHours;

  /// All reports together, per hour.
  final int errorReportMaxPerHour;

  /// Whether a model writes the title of a new conversation (the first question otherwise).
  final bool autoTitle;

  /// The model that writes titles, as `provider|model`; empty uses the online model in use. The
  /// device model never writes titles by itself (it would disturb its cache for the next reply).
  final String titleModel;
  final int titleMaxChars;
  final int tokenOverheadPercent;

  /// How many of the models used last are offered first in the model lists (0 turns it off).
  final int recentModelCount;

  /// Models this key cannot use (a free tier that has no quota for a model, a plan that lacks it): the
  /// lists grey them and put them last, or hide them when [hideUnusableModels] is on. They are found by
  /// a request that failed ([markBlockedModels]) or by the probe (a button on the model list, which asks
  /// [modelProbeConcurrency] models at a time and gives each [modelProbeTimeoutSeconds]). What was found
  /// is believed for [modelAvailabilityTrustDays] days.
  final bool hideUnusableModels;
  final bool markBlockedModels;

  /// When the model that answers is changed, ask that one model once (the shortest question) whether this
  /// key can use it, unless a result is still fresh, and say so when it cannot.
  final bool autoCheckSelectedModel;

  /// A model that the key's model list has is also asked the shortest question (which shows what a list
  /// cannot: that a free tier has no quota for it). Off: the list alone judges, and uses no quota.
  final bool modelCheckAsksToo;

  /// Secrets (by `SecretInfo.stableKey`: `provider:gem`, `mcp:github`, `own:NAME`) that the user does not
  /// let a model use by placeholder. Blocked from the chat.
  final List<String> secretsOffForModel;

  /// The tool `http_request`: a model asks the app to call an address, and the app puts the secrets the model
  /// named by placeholder into the request (only for the hosts each secret is bound to).
  final bool httpRequestEnabled;

  /// When the user approves a call first: `secretOrWrite` (one that uses a secret, or is not a read),
  /// `all`, or `never` (the secret's hosts still bind it). Blocked from the chat.
  final String httpRequestConfirm;
  final int httpRequestMaxResponseChars;
  final int httpRequestTimeoutSeconds;

  /// Allow `http://` (not encrypted) for a call that carries a secret. Blocked from the chat.
  final bool httpRequestAllowInsecure;

  /// How many redirects `http_request` follows (0: none).
  final int httpRequestMaxRedirects;
  final int modelProbeConcurrency;
  final int modelProbeTimeoutSeconds;
  final int modelAvailabilityTrustDays;

  /// DRY, the repetition penalty of the device model; -1 keeps the app's own value.
  final double localDryMultiplier;

  // ---- saving the device model's KV cache to files ----

  /// Keep the work done on a conversation's prompt in a file, so opening it again skips it.
  final bool kvSnapshotEnabled;

  /// All saved caches together stay under this many megabytes (the one used longest ago goes).
  final int kvSnapshotMaxMb;

  /// A prompt shorter than this is not saved.
  final int kvSnapshotMinTokens;

  // ---- finding out what an online model can do ----

  /// Ask the provider (and the Hub) for a model's limits when it is first used.
  final bool autoFetchModelInfo;

  /// Let that also read the context window from the model's `config.json` on huggingface.co
  /// (only the model's name is sent).
  final bool fetchModelInfoFromHub;

  // ---- the Linux environment (Android only) ----

  /// Offer `run_command` to the model at all. Off hides the tool and refuses to run one.
  final bool shellEnabled;

  /// Ask before every command, even one that stays inside the environment. Off by default: a
  /// command inside the sandbox (/workspace and the root file system) runs without asking, and only
  /// one that reaches the device outside it is shown. Not changeable from a chat message.
  final bool shellConfirm;

  /// A command asks first once the model has read something from outside (a search result, an MCP
  /// tool's answer), even when it stays inside the environment: that text may say "now run ...".
  final bool shellConfirmAfterExternal;

  /// Android notifications about a reply: it waits for the user (an approval, a question), it is
  /// finished, it failed. With [notifyOnlyAway] they come only when the chat is not in front.
  final bool notifyNeedsYou;
  final bool notifyDone;
  final bool notifyFailed;
  final bool notifyOnlyAway;

  /// A long conversation is made shorter before the context window is full (see `Compaction`): the
  /// old tool answers are cut, then what came before the last [compactKeepTurns] messages of the user
  /// is replaced by a summary. It starts when the request would take [compactAtPercent] percent of
  /// the context; the summary is at most [compactSummaryChars] characters; an old tool answer keeps
  /// [compactToolResultChars].
  final bool compactEnabled;
  final int compactAtPercent;
  final int compactKeepTurns;
  final int compactSummaryChars;
  final int compactToolResultChars;

  /// MCP tools (`mcp_server__tool`) the user chose not to be asked about again (the approval card's
  /// 「この道具は次から確認しない」). Not reachable from the chat: a message must not switch off a question.
  final List<String> approvedTools;

  /// The secrets a command may be given (by name, with the user's approval of each command). Only the
  /// names and where the values come from are here; the values are in the secure storage.
  final List<ShellSecret> shellSecrets;

  /// Offer `mcp_find` / `mcp_describe` / `mcp_call` instead of every MCP tool's definition when the
  /// definitions would take more than [mcpOnDemandTokens] tokens of every request (0: always).
  final bool mcpOnDemand;
  final int mcpOnDemandTokens;

  /// Seconds a command may run by default (the model may ask for up to [shellMaxTimeoutSeconds]).
  final int shellTimeoutSeconds;

  /// The longest a single command may be allowed to run.
  final int shellMaxTimeoutSeconds;

  /// How many characters of a command's output reach the model (the rest is cut, keeping both ends).
  final int shellMaxOutputChars;

  /// Sessions: programs that are talked to (a pseudo terminal). How many at once, when an unused one is
  /// stopped, how long a start / send / read waits for output (and the most a model may ask for), the size
  /// of the terminal, the lines kept after they scroll off, and what is kept between two reads.
  final int shellSessionMax;
  final int shellSessionIdleMinutes;
  final int shellSessionWaitMs;
  final int shellSessionMaxWaitSeconds;
  final int shellSessionCols;
  final int shellSessionRows;
  final int shellSessionScrollback;
  final int shellSessionBufferKb;

  /// How large the workspace shared by every chat may grow, in megabytes (0 = no limit).
  final int workspaceLimitMb;

  /// Where the root file system comes from, and the SHA-256 it must have (empty: not compared).
  final String linuxRootfsUrl;
  final String linuxRootfsSha256;

  /// The nameservers written into `/etc/resolv.conf`, separated by spaces.
  final String linuxDns;

  /// Start proot without its seccomp filter (`PROOT_NO_SECCOMP=1`), for devices that refuse it.
  final bool shellCompatMode;

  // ---- commands on a PC (Windows, macOS, Linux): see DesktopShellSettings

  /// Run commands in a container of Docker or Podman (true), or on the PC itself with the user's rights.
  final bool desktopSandbox;
  final String desktopContainerEngine;
  final String desktopContainerImage;
  final String desktopContainerName;
  final bool desktopContainerNetwork;

  /// Without the sandbox: run without asking and refuse dangerous commands (auto), ask every time, or neither.
  final HostApproval desktopHostApproval;
  final String desktopHostShell;

  /// The regular expressions of the dangerous commands (one per entry).
  final List<String> desktopDangerPatterns;

  DesktopShellSettings get desktopShell => DesktopShellSettings(
    sandbox: desktopSandbox,
    engine: desktopContainerEngine,
    image: desktopContainerImage.trim().isEmpty ? DesktopShellSettings.defaultImage : desktopContainerImage.trim(),
    container: desktopContainerName.trim().isEmpty ? DesktopShellSettings.defaultContainer : desktopContainerName.trim(),
    network: desktopContainerNetwork,
    approval: desktopHostApproval,
    dangerPatterns: desktopDangerPatterns,
    hostShell: desktopHostShell,
  );

  KvSnapshotConfig get kvSnapshot => KvSnapshotConfig(
    enabled: kvSnapshotEnabled,
    maxBytes: kvSnapshotMaxMb.clamp(64, 65536) * 1024 * 1024,
    minTokens: kvSnapshotMinTokens.clamp(64, 100000),
  );

  AttachmentLimits get attachmentLimits => AttachmentLimits(
    maxFiles: attachMaxFiles.clamp(1, 20),
    maxCharsPerFile: attachCharsPerFile.clamp(500, 200000),
    maxTotalChars: attachTotalChars.clamp(1000, 400000),
    maxImageBytes: attachImageMb.clamp(1, 20) * 1024 * 1024,
  );

  CodingSettings get coding => CodingSettings(
    enabled: codingPlanEnabled,
    planner: plannerModel,
    plannerFollowsModel: codingPlannerFollows,
    moreDevelopers: [
      for (final line in developerModelsMore.split(RegExp(r'[\n,]')))
        if (line.trim().isNotEmpty) line.trim(),
    ],
    developer: developerModel,
    maxTasks: codingMaxTasks.clamp(1, 16),
    parallel: codingParallel.clamp(1, 8),
    investigateFirst: codingInvestigateFirst,
    maxWorkers: codingMaxWorkers.clamp(1, 16),
    reviewRounds: codingReviewRounds.clamp(0, 3),
    developerMaxTokens: codingDeveloperMaxTokens <= 0 ? 0 : codingDeveloperMaxTokens.clamp(256, 1048576),
    resultChars: codingResultChars.clamp(500, 1000000),
  );

  /// The MCP servers the chat may use (Streamable HTTP). Tokens live in secure storage.
  final List<McpServerConfig> mcpServers;

  /// Search services the user set up (their keys are in the secure storage, not here).
  final List<SearchApiConfig> searchApis;

  AppSettings copyWith({
    bool? thinking,
    bool? searchEnabled,
    String? searxngUrl,
    String? tone,
    int? maxChars,
    double? speedAccuracy,
    bool? hyperLoad,
    ThemeMode? theme,
    ThinkingStyle? thinkingStyle,
    String? agentOverride,
    bool? aiAgentSelection,
    String? lastModelPath,
    int? contextLength,
    int? threads,
    int? batchSize,
    GpuOffload? gpuOffload,
    KvCacheType? kvCache,
    int? maxTokens,
    int? retryLimit,
    int? maxToolRounds,
    bool? forceExecution,
    String? updateRepo,
    bool? autoUpdateCheck,
    bool? autoInstallUpdate,
    int? updateIntervalHours,
    List<McpServerConfig>? mcpServers,
    List<SearchApiConfig>? searchApis,
    double? localTemperature,
    double? localTopP,
    int? localTopK,
    double? localMinP,
    int? localMaxTokens,
    String? localPrompt,
    double? onlineTemperature,
    double? onlineTopP,
    int? onlineMaxTokens,
    bool? onlineUseModelMax,
    String? onlinePrompt,
    bool? codingPlanEnabled,
    String? plannerModel,
    bool? codingPlannerFollows,
    String? developerModelsMore,
    String? developerModel,
    int? codingMaxTasks,
    int? codingParallel,
    bool? codingInvestigateFirst,
    int? codingMaxWorkers,
    int? codingReviewRounds,
    int? codingDeveloperMaxTokens,
    int? codingResultChars,
    int? attachMaxFiles,
    int? previewMaxPages,
    int? attachCharsPerFile,
    int? attachTotalChars,
    int? attachImageMb,
    int? searchResultCount,
    int? httpTimeoutSeconds,
    int? mcpTimeoutSeconds,
    int? mcpResultMaxChars,
    int? providerTimeoutSeconds,
    int? flexTimeoutSeconds,
    int? toolRepeatLimit,
    int? updateRetryAttempts,
    int? updateStallSeconds,
    int? downloadConnections,
    bool? updateUseDelta,
    bool? resumeDownloadsOnStart,
    double? fontScale,
    bool? modelListAutoFetch,
    int? modelListRefreshHours,
    bool? fallbackEnabled,
    bool? tokenPrecheck,
    bool? thinkingExpanded,
    int? codeFoldLines,
    int? inlinePreviewHeight,
    bool? showEnabled,
    int? showMaxChars,
    int? showMaxFileMb,
    bool? autoShowPages,
    bool? errorReportEnabled,
    String? errorReportRepo,
    int? errorReportMinHours,
    int? errorReportMaxPerHour,
    bool? autoTitle,
    String? titleModel,
    int? titleMaxChars,
    int? tokenOverheadPercent,
    int? recentModelCount,
    bool? hideUnusableModels,
    bool? markBlockedModels,
    bool? autoCheckSelectedModel,
    bool? modelCheckAsksToo,
    List<String>? secretsOffForModel,
    bool? httpRequestEnabled,
    String? httpRequestConfirm,
    int? httpRequestMaxResponseChars,
    int? httpRequestTimeoutSeconds,
    bool? httpRequestAllowInsecure,
    int? httpRequestMaxRedirects,
    int? modelProbeConcurrency,
    int? modelProbeTimeoutSeconds,
    int? modelAvailabilityTrustDays,
    double? localDryMultiplier,
    bool? kvSnapshotEnabled,
    int? kvSnapshotMaxMb,
    int? kvSnapshotMinTokens,
    bool? autoFetchModelInfo,
    bool? fetchModelInfoFromHub,
    bool? shellEnabled,
    bool? shellConfirm,
    bool? shellConfirmAfterExternal,
    bool? notifyNeedsYou,
    bool? notifyDone,
    bool? notifyFailed,
    bool? notifyOnlyAway,
    bool? compactEnabled,
    int? compactAtPercent,
    int? compactKeepTurns,
    int? compactSummaryChars,
    int? compactToolResultChars,
    List<String>? approvedTools,
    List<ShellSecret>? shellSecrets,
    bool? mcpOnDemand,
    int? mcpOnDemandTokens,
    int? shellTimeoutSeconds,
    int? shellMaxTimeoutSeconds,
    int? shellMaxOutputChars,
    int? shellSessionMax,
    int? shellSessionIdleMinutes,
    int? shellSessionWaitMs,
    int? shellSessionMaxWaitSeconds,
    int? shellSessionCols,
    int? shellSessionRows,
    int? shellSessionScrollback,
    int? shellSessionBufferKb,
    int? workspaceLimitMb,
    String? linuxRootfsUrl,
    String? linuxRootfsSha256,
    String? linuxDns,
    bool? shellCompatMode,
    bool? desktopSandbox,
    String? desktopContainerEngine,
    String? desktopContainerImage,
    String? desktopContainerName,
    bool? desktopContainerNetwork,
    HostApproval? desktopHostApproval,
    String? desktopHostShell,
    List<String>? desktopDangerPatterns,
  }) => AppSettings(
    thinking: thinking ?? this.thinking,
    searchEnabled: searchEnabled ?? this.searchEnabled,
    searxngUrl: searxngUrl ?? this.searxngUrl,
    tone: tone ?? this.tone,
    maxChars: maxChars ?? this.maxChars,
    speedAccuracy: speedAccuracy ?? this.speedAccuracy,
    hyperLoad: hyperLoad ?? this.hyperLoad,
    theme: theme ?? this.theme,
    thinkingStyle: thinkingStyle ?? this.thinkingStyle,
    agentOverride: agentOverride ?? this.agentOverride,
    aiAgentSelection: aiAgentSelection ?? this.aiAgentSelection,
    lastModelPath: lastModelPath ?? this.lastModelPath,
    contextLength: contextLength ?? this.contextLength,
    threads: threads ?? this.threads,
    batchSize: batchSize ?? this.batchSize,
    gpuOffload: gpuOffload ?? this.gpuOffload,
    kvCache: kvCache ?? this.kvCache,
    maxTokens: maxTokens ?? this.maxTokens,
    retryLimit: retryLimit ?? this.retryLimit,
    maxToolRounds: maxToolRounds ?? this.maxToolRounds,
    forceExecution: forceExecution ?? this.forceExecution,
    updateRepo: updateRepo ?? this.updateRepo,
    autoUpdateCheck: autoUpdateCheck ?? this.autoUpdateCheck,
    autoInstallUpdate: autoInstallUpdate ?? this.autoInstallUpdate,
    updateIntervalHours: updateIntervalHours ?? this.updateIntervalHours,
    mcpServers: mcpServers ?? this.mcpServers,
    searchApis: searchApis ?? this.searchApis,
    localTemperature: localTemperature ?? this.localTemperature,
    localTopP: localTopP ?? this.localTopP,
    localTopK: localTopK ?? this.localTopK,
    localMinP: localMinP ?? this.localMinP,
    localMaxTokens: localMaxTokens ?? this.localMaxTokens,
    localPrompt: localPrompt ?? this.localPrompt,
    onlineTemperature: onlineTemperature ?? this.onlineTemperature,
    onlineTopP: onlineTopP ?? this.onlineTopP,
    onlineMaxTokens: onlineMaxTokens ?? this.onlineMaxTokens,
    onlineUseModelMax: onlineUseModelMax ?? this.onlineUseModelMax,
    onlinePrompt: onlinePrompt ?? this.onlinePrompt,
    codingPlanEnabled: codingPlanEnabled ?? this.codingPlanEnabled,
    plannerModel: plannerModel ?? this.plannerModel,
    codingPlannerFollows: codingPlannerFollows ?? this.codingPlannerFollows,
    developerModelsMore: developerModelsMore ?? this.developerModelsMore,
    developerModel: developerModel ?? this.developerModel,
    codingMaxTasks: codingMaxTasks ?? this.codingMaxTasks,
    codingParallel: codingParallel ?? this.codingParallel,
    codingInvestigateFirst: codingInvestigateFirst ?? this.codingInvestigateFirst,
    codingMaxWorkers: codingMaxWorkers ?? this.codingMaxWorkers,
    codingReviewRounds: codingReviewRounds ?? this.codingReviewRounds,
    codingDeveloperMaxTokens: codingDeveloperMaxTokens ?? this.codingDeveloperMaxTokens,
    codingResultChars: codingResultChars ?? this.codingResultChars,
    attachMaxFiles: attachMaxFiles ?? this.attachMaxFiles,
    previewMaxPages: previewMaxPages ?? this.previewMaxPages,
    attachCharsPerFile: attachCharsPerFile ?? this.attachCharsPerFile,
    attachTotalChars: attachTotalChars ?? this.attachTotalChars,
    attachImageMb: attachImageMb ?? this.attachImageMb,
    searchResultCount: searchResultCount ?? this.searchResultCount,
    httpTimeoutSeconds: httpTimeoutSeconds ?? this.httpTimeoutSeconds,
    mcpTimeoutSeconds: mcpTimeoutSeconds ?? this.mcpTimeoutSeconds,
    mcpResultMaxChars: mcpResultMaxChars ?? this.mcpResultMaxChars,
    providerTimeoutSeconds: providerTimeoutSeconds ?? this.providerTimeoutSeconds,
    flexTimeoutSeconds: flexTimeoutSeconds ?? this.flexTimeoutSeconds,
    toolRepeatLimit: toolRepeatLimit ?? this.toolRepeatLimit,
    updateRetryAttempts: updateRetryAttempts ?? this.updateRetryAttempts,
    updateStallSeconds: updateStallSeconds ?? this.updateStallSeconds,
    downloadConnections: downloadConnections ?? this.downloadConnections,
    updateUseDelta: updateUseDelta ?? this.updateUseDelta,
    resumeDownloadsOnStart: resumeDownloadsOnStart ?? this.resumeDownloadsOnStart,
    fontScale: fontScale ?? this.fontScale,
    modelListAutoFetch: modelListAutoFetch ?? this.modelListAutoFetch,
    modelListRefreshHours: modelListRefreshHours ?? this.modelListRefreshHours,
    fallbackEnabled: fallbackEnabled ?? this.fallbackEnabled,
    tokenPrecheck: tokenPrecheck ?? this.tokenPrecheck,
    thinkingExpanded: thinkingExpanded ?? this.thinkingExpanded,
    codeFoldLines: codeFoldLines ?? this.codeFoldLines,
    inlinePreviewHeight: inlinePreviewHeight ?? this.inlinePreviewHeight,
    showEnabled: showEnabled ?? this.showEnabled,
    showMaxChars: showMaxChars ?? this.showMaxChars,
    showMaxFileMb: showMaxFileMb ?? this.showMaxFileMb,
    autoShowPages: autoShowPages ?? this.autoShowPages,
    errorReportEnabled: errorReportEnabled ?? this.errorReportEnabled,
    errorReportRepo: errorReportRepo ?? this.errorReportRepo,
    errorReportMinHours: errorReportMinHours ?? this.errorReportMinHours,
    errorReportMaxPerHour: errorReportMaxPerHour ?? this.errorReportMaxPerHour,
    autoTitle: autoTitle ?? this.autoTitle,
    titleModel: titleModel ?? this.titleModel,
    titleMaxChars: titleMaxChars ?? this.titleMaxChars,
    tokenOverheadPercent: tokenOverheadPercent ?? this.tokenOverheadPercent,
    recentModelCount: recentModelCount ?? this.recentModelCount,
    hideUnusableModels: hideUnusableModels ?? this.hideUnusableModels,
    markBlockedModels: markBlockedModels ?? this.markBlockedModels,
    autoCheckSelectedModel: autoCheckSelectedModel ?? this.autoCheckSelectedModel,
    modelCheckAsksToo: modelCheckAsksToo ?? this.modelCheckAsksToo,
    secretsOffForModel: secretsOffForModel ?? this.secretsOffForModel,
    httpRequestEnabled: httpRequestEnabled ?? this.httpRequestEnabled,
    httpRequestConfirm: httpRequestConfirm ?? this.httpRequestConfirm,
    httpRequestMaxResponseChars: httpRequestMaxResponseChars ?? this.httpRequestMaxResponseChars,
    httpRequestTimeoutSeconds: httpRequestTimeoutSeconds ?? this.httpRequestTimeoutSeconds,
    httpRequestAllowInsecure: httpRequestAllowInsecure ?? this.httpRequestAllowInsecure,
    httpRequestMaxRedirects: httpRequestMaxRedirects ?? this.httpRequestMaxRedirects,
    modelProbeConcurrency: modelProbeConcurrency ?? this.modelProbeConcurrency,
    modelProbeTimeoutSeconds: modelProbeTimeoutSeconds ?? this.modelProbeTimeoutSeconds,
    modelAvailabilityTrustDays: modelAvailabilityTrustDays ?? this.modelAvailabilityTrustDays,
    localDryMultiplier: localDryMultiplier ?? this.localDryMultiplier,
    kvSnapshotEnabled: kvSnapshotEnabled ?? this.kvSnapshotEnabled,
    kvSnapshotMaxMb: kvSnapshotMaxMb ?? this.kvSnapshotMaxMb,
    kvSnapshotMinTokens: kvSnapshotMinTokens ?? this.kvSnapshotMinTokens,
    autoFetchModelInfo: autoFetchModelInfo ?? this.autoFetchModelInfo,
    fetchModelInfoFromHub: fetchModelInfoFromHub ?? this.fetchModelInfoFromHub,
    shellEnabled: shellEnabled ?? this.shellEnabled,
    shellConfirm: shellConfirm ?? this.shellConfirm,
    shellConfirmAfterExternal: shellConfirmAfterExternal ?? this.shellConfirmAfterExternal,
    notifyNeedsYou: notifyNeedsYou ?? this.notifyNeedsYou,
    notifyDone: notifyDone ?? this.notifyDone,
    notifyFailed: notifyFailed ?? this.notifyFailed,
    notifyOnlyAway: notifyOnlyAway ?? this.notifyOnlyAway,
    compactEnabled: compactEnabled ?? this.compactEnabled,
    compactAtPercent: compactAtPercent ?? this.compactAtPercent,
    compactKeepTurns: compactKeepTurns ?? this.compactKeepTurns,
    compactSummaryChars: compactSummaryChars ?? this.compactSummaryChars,
    compactToolResultChars: compactToolResultChars ?? this.compactToolResultChars,
    approvedTools: approvedTools ?? this.approvedTools,
    shellSecrets: shellSecrets ?? this.shellSecrets,
    mcpOnDemand: mcpOnDemand ?? this.mcpOnDemand,
    mcpOnDemandTokens: mcpOnDemandTokens ?? this.mcpOnDemandTokens,
    shellTimeoutSeconds: shellTimeoutSeconds ?? this.shellTimeoutSeconds,
    shellMaxTimeoutSeconds: shellMaxTimeoutSeconds ?? this.shellMaxTimeoutSeconds,
    shellMaxOutputChars: shellMaxOutputChars ?? this.shellMaxOutputChars,
    shellSessionMax: shellSessionMax ?? this.shellSessionMax,
    shellSessionIdleMinutes: shellSessionIdleMinutes ?? this.shellSessionIdleMinutes,
    shellSessionWaitMs: shellSessionWaitMs ?? this.shellSessionWaitMs,
    shellSessionMaxWaitSeconds: shellSessionMaxWaitSeconds ?? this.shellSessionMaxWaitSeconds,
    shellSessionCols: shellSessionCols ?? this.shellSessionCols,
    shellSessionRows: shellSessionRows ?? this.shellSessionRows,
    shellSessionScrollback: shellSessionScrollback ?? this.shellSessionScrollback,
    shellSessionBufferKb: shellSessionBufferKb ?? this.shellSessionBufferKb,
    workspaceLimitMb: workspaceLimitMb ?? this.workspaceLimitMb,
    linuxRootfsUrl: linuxRootfsUrl ?? this.linuxRootfsUrl,
    linuxRootfsSha256: linuxRootfsSha256 ?? this.linuxRootfsSha256,
    linuxDns: linuxDns ?? this.linuxDns,
    shellCompatMode: shellCompatMode ?? this.shellCompatMode,
    desktopSandbox: desktopSandbox ?? this.desktopSandbox,
    desktopContainerEngine: desktopContainerEngine ?? this.desktopContainerEngine,
    desktopContainerImage: desktopContainerImage ?? this.desktopContainerImage,
    desktopContainerName: desktopContainerName ?? this.desktopContainerName,
    desktopContainerNetwork: desktopContainerNetwork ?? this.desktopContainerNetwork,
    desktopHostApproval: desktopHostApproval ?? this.desktopHostApproval,
    desktopHostShell: desktopHostShell ?? this.desktopHostShell,
    desktopDangerPatterns: desktopDangerPatterns ?? this.desktopDangerPatterns,
  );

  Map<String, Object?> toJson() => {
    'thinking': thinking,
    'searchEnabled': searchEnabled,
    'searxngUrl': searxngUrl,
    'tone': tone,
    'maxChars': maxChars,
    'speedAccuracy': speedAccuracy,
    'hyperLoad': hyperLoad,
    'theme': theme.name,
    'thinkingStyle': thinkingStyle.name,
    'agentOverride': agentOverride,
    'aiAgentSelection': aiAgentSelection,
    'lastModelPath': lastModelPath,
    'contextLength': contextLength,
    'threads': threads,
    'batchSize': batchSize,
    'gpuOffload': gpuOffload.name,
    'kvCache': kvCache.name,
    'maxTokens': maxTokens,
    'retryLimit': retryLimit,
    'maxToolRounds': maxToolRounds,
    'forceExecution': forceExecution,
    'updateRepo': updateRepo,
    'autoUpdateCheck': autoUpdateCheck,
    'autoInstallUpdate': autoInstallUpdate,
    'updateIntervalHours': updateIntervalHours,
    'mcpServers': [for (final server in mcpServers) server.toJson()],
    'searchApis': [for (final api in searchApis) api.toJson()],
    'localTemperature': localTemperature,
    'localTopP': localTopP,
    'localTopK': localTopK,
    'localMinP': localMinP,
    'localMaxTokens': localMaxTokens,
    'localPrompt': localPrompt,
    'onlineTemperature': onlineTemperature,
    'onlineTopP': onlineTopP,
    'onlineMaxTokens': onlineMaxTokens,
    'onlineUseModelMax': onlineUseModelMax,
    'onlinePrompt': onlinePrompt,
    'codingPlanEnabled': codingPlanEnabled,
    'plannerModel': plannerModel,
    'codingPlannerFollows': codingPlannerFollows,
    'developerModelsMore': developerModelsMore,
    'developerModel': developerModel,
    'codingMaxTasks': codingMaxTasks,
    'codingParallel': codingParallel,
    'codingInvestigateFirst': codingInvestigateFirst,
    'codingMaxWorkers': codingMaxWorkers,
    'codingReviewRounds': codingReviewRounds,
    'codingDeveloperMaxTokens': codingDeveloperMaxTokens,
    'codingResultChars': codingResultChars,
    'attachMaxFiles': attachMaxFiles,
    'previewMaxPages': previewMaxPages,
    'attachCharsPerFile': attachCharsPerFile,
    'attachTotalChars': attachTotalChars,
    'attachImageMb': attachImageMb,
    'searchResultCount': searchResultCount,
    'httpTimeoutSeconds': httpTimeoutSeconds,
    'mcpTimeoutSeconds': mcpTimeoutSeconds,
    'mcpResultMaxChars': mcpResultMaxChars,
    'providerTimeoutSeconds': providerTimeoutSeconds,
    'flexTimeoutSeconds': flexTimeoutSeconds,
    'toolRepeatLimit': toolRepeatLimit,
    'updateRetryAttempts': updateRetryAttempts,
    'updateStallSeconds': updateStallSeconds,
    'downloadConnections': downloadConnections,
    'updateUseDelta': updateUseDelta,
    'resumeDownloadsOnStart': resumeDownloadsOnStart,
    'fontScale': fontScale,
    'modelListAutoFetch': modelListAutoFetch,
    'modelListRefreshHours': modelListRefreshHours,
    'fallbackEnabled': fallbackEnabled,
    'tokenPrecheck': tokenPrecheck,
    'thinkingExpanded': thinkingExpanded,
    'codeFoldLines': codeFoldLines,
    'inlinePreviewHeight': inlinePreviewHeight,
    'showEnabled': showEnabled,
    'showMaxChars': showMaxChars,
    'showMaxFileMb': showMaxFileMb,
    'autoShowPages': autoShowPages,
    'errorReportEnabled': errorReportEnabled,
    'errorReportRepo': errorReportRepo,
    'errorReportMinHours': errorReportMinHours,
    'errorReportMaxPerHour': errorReportMaxPerHour,
    'autoTitle': autoTitle,
    'titleModel': titleModel,
    'titleMaxChars': titleMaxChars,
    'tokenOverheadPercent': tokenOverheadPercent,
    'recentModelCount': recentModelCount,
    'hideUnusableModels': hideUnusableModels,
    'markBlockedModels': markBlockedModels,
    'autoCheckSelectedModel': autoCheckSelectedModel,
    'modelCheckAsksToo': modelCheckAsksToo,
    'secretsOffForModel': secretsOffForModel,
    'httpRequestEnabled': httpRequestEnabled,
    'httpRequestConfirm': httpRequestConfirm,
    'httpRequestMaxResponseChars': httpRequestMaxResponseChars,
    'httpRequestTimeoutSeconds': httpRequestTimeoutSeconds,
    'httpRequestAllowInsecure': httpRequestAllowInsecure,
    'httpRequestMaxRedirects': httpRequestMaxRedirects,
    'modelProbeConcurrency': modelProbeConcurrency,
    'modelProbeTimeoutSeconds': modelProbeTimeoutSeconds,
    'modelAvailabilityTrustDays': modelAvailabilityTrustDays,
    'localDryMultiplier': localDryMultiplier,
    'kvSnapshotEnabled': kvSnapshotEnabled,
    'kvSnapshotMaxMb': kvSnapshotMaxMb,
    'kvSnapshotMinTokens': kvSnapshotMinTokens,
    'autoFetchModelInfo': autoFetchModelInfo,
    'fetchModelInfoFromHub': fetchModelInfoFromHub,
    'shellEnabled': shellEnabled,
    'shellConfirm': shellConfirm,
    'shellConfirmAlways': shellConfirm,
    'shellConfirmAfterExternal': shellConfirmAfterExternal,
    'notifyNeedsYou': notifyNeedsYou,
    'notifyDone': notifyDone,
    'notifyFailed': notifyFailed,
    'notifyOnlyAway': notifyOnlyAway,
    'compactEnabled': compactEnabled,
    'compactAtPercent': compactAtPercent,
    'compactKeepTurns': compactKeepTurns,
    'compactSummaryChars': compactSummaryChars,
    'compactToolResultChars': compactToolResultChars,
    'approvedTools': approvedTools,
    'shellSecrets': [for (final s in shellSecrets) s.toJson()],
    'mcpOnDemand': mcpOnDemand,
    'mcpOnDemandTokens': mcpOnDemandTokens,
    'shellTimeoutSeconds': shellTimeoutSeconds,
    'shellMaxTimeoutSeconds': shellMaxTimeoutSeconds,
    'shellMaxOutputChars': shellMaxOutputChars,
    'shellSessionMax': shellSessionMax,
    'shellSessionIdleMinutes': shellSessionIdleMinutes,
    'shellSessionWaitMs': shellSessionWaitMs,
    'shellSessionMaxWaitSeconds': shellSessionMaxWaitSeconds,
    'shellSessionCols': shellSessionCols,
    'shellSessionRows': shellSessionRows,
    'shellSessionScrollback': shellSessionScrollback,
    'shellSessionBufferKb': shellSessionBufferKb,
    'workspaceLimitMb': workspaceLimitMb,
    'linuxRootfsUrl': linuxRootfsUrl,
    'linuxRootfsSha256': linuxRootfsSha256,
    'linuxDns': linuxDns,
    'shellCompatMode': shellCompatMode,
    'desktopSandbox': desktopSandbox,
    'desktopContainerEngine': desktopContainerEngine,
    'desktopContainerImage': desktopContainerImage,
    'desktopContainerName': desktopContainerName,
    'desktopContainerNetwork': desktopContainerNetwork,
    'desktopHostApproval': desktopHostApproval.name,
    'desktopHostShell': desktopHostShell,
    'desktopDangerPatterns': desktopDangerPatterns,
  };

  /// Unknown, missing or wrongly typed values fall back to the defaults, so older or damaged
  /// saves keep loading (one bad value must not reset everything else).
  factory AppSettings.fromJson(Map<String, Object?> json) {
    const d = AppSettings();
    bool flag(String key, bool fallback) =>
        json[key] is bool ? json[key]! as bool : fallback;
    int whole(String key, int fallback) =>
        json[key] is num ? (json[key]! as num).toInt() : fallback;
    String text(String key, String fallback) =>
        json[key] is String ? json[key]! as String : fallback;
    double decimal(String key, double fallback) =>
        json[key] is num ? (json[key]! as num).toDouble() : fallback;
    T option<T extends Enum>(List<T> values, String key, T fallback) {
      for (final v in values) {
        if (v.name == json[key]) return v;
      }
      return fallback;
    }

    return AppSettings(
      thinking: flag('thinking', d.thinking),
      searchEnabled: flag('searchEnabled', d.searchEnabled),
      searxngUrl: text('searxngUrl', d.searxngUrl),
      tone: text('tone', d.tone),
      maxChars: whole('maxChars', d.maxChars),
      speedAccuracy: json['speedAccuracy'] is num
          ? (json['speedAccuracy']! as num).toDouble()
          : d.speedAccuracy,
      hyperLoad: flag('hyperLoad', d.hyperLoad),
      theme: option(ThemeMode.values, 'theme', d.theme),
      thinkingStyle: option(
        ThinkingStyle.values,
        'thinkingStyle',
        d.thinkingStyle,
      ),
      agentOverride: text('agentOverride', d.agentOverride),
      aiAgentSelection: flag('aiAgentSelection', d.aiAgentSelection),
      lastModelPath: text('lastModelPath', d.lastModelPath),
      contextLength: whole('contextLength', d.contextLength),
      threads: whole('threads', d.threads),
      batchSize: whole('batchSize', d.batchSize),
      gpuOffload: option(GpuOffload.values, 'gpuOffload', d.gpuOffload),
      kvCache: option(KvCacheType.values, 'kvCache', d.kvCache),
      maxTokens: whole('maxTokens', d.maxTokens),
      retryLimit: whole('retryLimit', d.retryLimit),
      // 4 was the old default and no longer one of the choices; it stopped a run of searches with
      // different words, so a save that still has it gets the new default
      maxToolRounds: whole('maxToolRounds', d.maxToolRounds) == 4 ? d.maxToolRounds : whole('maxToolRounds', d.maxToolRounds),
      forceExecution: flag('forceExecution', d.forceExecution),
      updateRepo: _movedRepo(text('updateRepo', d.updateRepo)),
      autoUpdateCheck: flag('autoUpdateCheck', d.autoUpdateCheck),
      autoInstallUpdate: flag('autoInstallUpdate', d.autoInstallUpdate),
      updateIntervalHours: whole('updateIntervalHours', d.updateIntervalHours),
      localTemperature: decimal('localTemperature', d.localTemperature),
      localTopP: decimal('localTopP', d.localTopP),
      localTopK: whole('localTopK', d.localTopK),
      localMinP: decimal('localMinP', d.localMinP),
      localMaxTokens: whole('localMaxTokens', d.localMaxTokens),
      localPrompt: text('localPrompt', d.localPrompt),
      onlineTemperature: decimal('onlineTemperature', d.onlineTemperature),
      onlineTopP: decimal('onlineTopP', d.onlineTopP),
      onlineMaxTokens: whole('onlineMaxTokens', d.onlineMaxTokens),
      onlineUseModelMax: flag('onlineUseModelMax', d.onlineUseModelMax),
      onlinePrompt: text('onlinePrompt', d.onlinePrompt),
      codingPlanEnabled: flag('codingPlanEnabled', d.codingPlanEnabled),
      plannerModel: text('plannerModel', d.plannerModel),
      codingPlannerFollows: flag('codingPlannerFollows', d.codingPlannerFollows),
      developerModelsMore: text('developerModelsMore', d.developerModelsMore),
      developerModel: text('developerModel', d.developerModel),
      codingMaxTasks: whole('codingMaxTasks', d.codingMaxTasks),
      codingParallel: whole('codingParallel', d.codingParallel),
      codingInvestigateFirst: flag('codingInvestigateFirst', d.codingInvestigateFirst),
      codingMaxWorkers: whole('codingMaxWorkers', d.codingMaxWorkers),
      codingReviewRounds: whole('codingReviewRounds', d.codingReviewRounds),
      // 0.8.1 saved its fixed default (4096) with every settings write; it was never a choice, and it
      // is far too small for a reasoning model, so it means "decide" now
      codingDeveloperMaxTokens: whole('codingDeveloperMaxTokens', d.codingDeveloperMaxTokens) == 4096
          ? 0
          : whole('codingDeveloperMaxTokens', d.codingDeveloperMaxTokens),
      codingResultChars: whole('codingResultChars', d.codingResultChars),
      attachMaxFiles: whole('attachMaxFiles', d.attachMaxFiles),
      previewMaxPages: whole('previewMaxPages', d.previewMaxPages).clamp(1, 500),
      attachCharsPerFile: whole('attachCharsPerFile', d.attachCharsPerFile),
      attachTotalChars: whole('attachTotalChars', d.attachTotalChars),
      attachImageMb: whole('attachImageMb', d.attachImageMb),
      searchResultCount: whole('searchResultCount', d.searchResultCount),
      httpTimeoutSeconds: whole('httpTimeoutSeconds', d.httpTimeoutSeconds),
      mcpTimeoutSeconds: whole('mcpTimeoutSeconds', d.mcpTimeoutSeconds),
      mcpResultMaxChars: whole('mcpResultMaxChars', d.mcpResultMaxChars).clamp(500, 1000000),
      providerTimeoutSeconds: whole('providerTimeoutSeconds', d.providerTimeoutSeconds),
      flexTimeoutSeconds: whole('flexTimeoutSeconds', d.flexTimeoutSeconds).clamp(60, 3600),
      toolRepeatLimit: whole('toolRepeatLimit', d.toolRepeatLimit),
      updateRetryAttempts: whole('updateRetryAttempts', d.updateRetryAttempts),
      updateStallSeconds: whole('updateStallSeconds', d.updateStallSeconds),
      downloadConnections: whole('downloadConnections', d.downloadConnections),
      updateUseDelta: flag('updateUseDelta', d.updateUseDelta),
      resumeDownloadsOnStart: flag('resumeDownloadsOnStart', d.resumeDownloadsOnStart),
      fontScale: decimal('fontScale', d.fontScale).clamp(0.7, 2.0),
      modelListAutoFetch: flag('modelListAutoFetch', d.modelListAutoFetch),
      modelListRefreshHours: whole('modelListRefreshHours', d.modelListRefreshHours).clamp(1, 720),
      fallbackEnabled: flag('fallbackEnabled', d.fallbackEnabled),
      tokenPrecheck: flag('tokenPrecheck', d.tokenPrecheck),
      thinkingExpanded: flag('thinkingExpanded', d.thinkingExpanded),
      codeFoldLines: whole('codeFoldLines', d.codeFoldLines).clamp(0, 1000),
      inlinePreviewHeight: whole('inlinePreviewHeight', d.inlinePreviewHeight).clamp(0, 2000),
      showEnabled: flag('showEnabled', d.showEnabled),
      showMaxChars: whole('showMaxChars', d.showMaxChars).clamp(1000, 2000000),
      showMaxFileMb: whole('showMaxFileMb', d.showMaxFileMb).clamp(1, 500),
      autoShowPages: flag('autoShowPages', d.autoShowPages),
      errorReportEnabled: flag('errorReportEnabled', d.errorReportEnabled),
      errorReportRepo: _movedRepo(text('errorReportRepo', d.errorReportRepo).trim()),
      errorReportMinHours: whole('errorReportMinHours', d.errorReportMinHours).clamp(1, 168),
      errorReportMaxPerHour: whole('errorReportMaxPerHour', d.errorReportMaxPerHour).clamp(1, 60),
      autoTitle: flag('autoTitle', d.autoTitle),
      titleModel: text('titleModel', d.titleModel),
      titleMaxChars: whole('titleMaxChars', d.titleMaxChars).clamp(8, 80),
      tokenOverheadPercent: whole('tokenOverheadPercent', d.tokenOverheadPercent).clamp(10, 100),
      recentModelCount: whole('recentModelCount', d.recentModelCount).clamp(0, 30),
      hideUnusableModels: flag('hideUnusableModels', d.hideUnusableModels),
      markBlockedModels: flag('markBlockedModels', d.markBlockedModels),
      autoCheckSelectedModel: flag('autoCheckSelectedModel', d.autoCheckSelectedModel),
      modelCheckAsksToo: flag('modelCheckAsksToo', d.modelCheckAsksToo),
      secretsOffForModel: [
        if (json['secretsOffForModel'] is List)
          for (final k in json['secretsOffForModel'] as List)
            if (k is String && k.trim().isNotEmpty) k.trim(),
      ],
      httpRequestEnabled: flag('httpRequestEnabled', d.httpRequestEnabled),
      httpRequestConfirm: const ['secretOrWrite', 'all', 'never'].contains(json['httpRequestConfirm']) ? json['httpRequestConfirm']! as String : d.httpRequestConfirm,
      httpRequestMaxResponseChars: whole('httpRequestMaxResponseChars', d.httpRequestMaxResponseChars).clamp(500, 1000000),
      httpRequestTimeoutSeconds: whole('httpRequestTimeoutSeconds', d.httpRequestTimeoutSeconds).clamp(3, 600),
      httpRequestAllowInsecure: flag('httpRequestAllowInsecure', d.httpRequestAllowInsecure),
      httpRequestMaxRedirects: whole('httpRequestMaxRedirects', d.httpRequestMaxRedirects).clamp(0, 10),
      modelProbeConcurrency: whole('modelProbeConcurrency', d.modelProbeConcurrency).clamp(1, 8),
      modelProbeTimeoutSeconds: whole('modelProbeTimeoutSeconds', d.modelProbeTimeoutSeconds).clamp(5, 120),
      modelAvailabilityTrustDays: whole('modelAvailabilityTrustDays', d.modelAvailabilityTrustDays).clamp(1, 90),
      localDryMultiplier: decimal('localDryMultiplier', d.localDryMultiplier),
      kvSnapshotEnabled: flag('kvSnapshotEnabled', d.kvSnapshotEnabled),
      kvSnapshotMaxMb: whole('kvSnapshotMaxMb', d.kvSnapshotMaxMb),
      kvSnapshotMinTokens: whole('kvSnapshotMinTokens', d.kvSnapshotMinTokens),
      autoFetchModelInfo: flag('autoFetchModelInfo', d.autoFetchModelInfo),
      fetchModelInfoFromHub: flag('fetchModelInfoFromHub', d.fetchModelInfoFromHub),
      shellEnabled: flag('shellEnabled', d.shellEnabled),
      // 0.12.1 saved its own default (true) with every settings write; that was never a choice, and the
      // user asked for commands inside the environment to run without asking
      shellConfirm: json.containsKey('shellConfirmAlways')
          ? flag('shellConfirmAlways', d.shellConfirm)
          : d.shellConfirm,
      shellTimeoutSeconds: whole('shellTimeoutSeconds', d.shellTimeoutSeconds).clamp(1, 3600),
      shellMaxTimeoutSeconds: whole('shellMaxTimeoutSeconds', d.shellMaxTimeoutSeconds).clamp(1, 3600),
      shellMaxOutputChars: whole('shellMaxOutputChars', d.shellMaxOutputChars).clamp(500, 1000000),
      shellSessionMax: whole('shellSessionMax', d.shellSessionMax).clamp(1,20),
      shellSessionIdleMinutes: whole('shellSessionIdleMinutes', d.shellSessionIdleMinutes).clamp(0,1440),
      shellSessionWaitMs: whole('shellSessionWaitMs', d.shellSessionWaitMs).clamp(0,120000),
      shellSessionMaxWaitSeconds: whole('shellSessionMaxWaitSeconds', d.shellSessionMaxWaitSeconds).clamp(1,120),
      shellSessionCols: whole('shellSessionCols', d.shellSessionCols).clamp(20,400),
      shellSessionRows: whole('shellSessionRows', d.shellSessionRows).clamp(5,200),
      shellSessionScrollback: whole('shellSessionScrollback', d.shellSessionScrollback).clamp(0,5000),
      shellSessionBufferKb: whole('shellSessionBufferKb', d.shellSessionBufferKb).clamp(16,8192),
      workspaceLimitMb: whole('workspaceLimitMb', d.workspaceLimitMb).clamp(0, 65536),
      linuxRootfsUrl: text('linuxRootfsUrl', d.linuxRootfsUrl),
      linuxRootfsSha256: text('linuxRootfsSha256', d.linuxRootfsSha256),
      linuxDns: text('linuxDns', d.linuxDns),
      shellCompatMode: flag('shellCompatMode', d.shellCompatMode),
      desktopSandbox: flag('desktopSandbox', d.desktopSandbox),
      desktopContainerEngine: const {'auto', 'docker', 'podman'}.contains(json['desktopContainerEngine']) ? json['desktopContainerEngine']! as String : d.desktopContainerEngine,
      desktopContainerImage: text('desktopContainerImage', d.desktopContainerImage),
      desktopContainerName: text('desktopContainerName', d.desktopContainerName),
      desktopContainerNetwork: flag('desktopContainerNetwork', d.desktopContainerNetwork),
      desktopHostApproval: option(HostApproval.values, 'desktopHostApproval', d.desktopHostApproval),
      desktopHostShell: text('desktopHostShell', d.desktopHostShell),
      desktopDangerPatterns: json['desktopDangerPatterns'] is List
          ? [for (final p in json['desktopDangerPatterns'] as List) if (p is String) p]
          : d.desktopDangerPatterns,
      shellConfirmAfterExternal: flag('shellConfirmAfterExternal', d.shellConfirmAfterExternal),
      notifyNeedsYou: flag('notifyNeedsYou', d.notifyNeedsYou),
      notifyDone: flag('notifyDone', d.notifyDone),
      notifyFailed: flag('notifyFailed', d.notifyFailed),
      notifyOnlyAway: flag('notifyOnlyAway', d.notifyOnlyAway),
      compactEnabled: flag('compactEnabled', d.compactEnabled),
      compactAtPercent: whole('compactAtPercent', d.compactAtPercent),
      compactKeepTurns: whole('compactKeepTurns', d.compactKeepTurns),
      compactSummaryChars: whole('compactSummaryChars', d.compactSummaryChars),
      compactToolResultChars: whole('compactToolResultChars', d.compactToolResultChars),
      approvedTools: [
        if (json['approvedTools'] is List)
          for (final t in json['approvedTools'] as List)
            if (t is String && ToolApproval.canRemember(t)) t,
      ],
      shellSecrets: [
        if (json['shellSecrets'] is List)
          for (final item in json['shellSecrets'] as List)
            ?ShellSecret.fromJson(item),
      ],
      mcpOnDemand: flag('mcpOnDemand', d.mcpOnDemand),
      mcpOnDemandTokens: whole('mcpOnDemandTokens', d.mcpOnDemandTokens),
      searchApis: SearchApis.decode(json['searchApis']),
      // a save from before multiple servers keeps its one endpoint
      mcpServers: (() {
        final parsed = McpServers.decode(json['mcpServers']);
        if (parsed.isNotEmpty) return parsed;
        final url = text('mcpUrl', '');
        if (url.trim().isEmpty) return const <McpServerConfig>[];
        return [
          McpServerConfig(
            id: 'default',
            name: 'MCP',
            url: url.trim(),
            enabled: flag('mcpEnabled', false),
          ),
        ];
      })(),
    );
  }

  /// The settings of one generation. [cloud] picks the online model settings instead of the
  /// device model's: the two are separate, so a change to one never touches the other.
  GenerationSettings toGeneration(double? modelParamsB, {bool cloud = false}) => GenerationSettings(
    tone: tone.trim().isEmpty ? null : tone,
    maxChars: maxChars,
    maxTokens: (cloud ? onlineMaxTokens : localMaxTokens) > 0
        ? (cloud ? onlineMaxTokens : localMaxTokens)
        : maxTokens,
    temperature: _set(cloud ? onlineTemperature : localTemperature),
    topP: _set(cloud ? onlineTopP : localTopP),
    // top-k and min-p are the device engine's; a provider takes only temperature and top-p
    topK: cloud || localTopK <= 0 ? null : localTopK,
    minP: cloud ? null : _set(localMinP),
    extraPrompt: (cloud ? onlinePrompt : localPrompt).trim(),
    dryMultiplier: cloud ? null : _set(localDryMultiplier),
    userMaxTokens: (cloud ? onlineMaxTokens : localMaxTokens) > 0 ? (cloud ? onlineMaxTokens : localMaxTokens) : null,
    useModelMax: cloud && onlineUseModelMax,
    toolRepeatLimit: toolRepeatLimit.clamp(2, 10),
    compaction: CompactionSettings(
      enabled: compactEnabled,
      atPercent: compactAtPercent.clamp(30, 95),
      keepTurns: compactKeepTurns.clamp(1, 30),
      summaryChars: compactSummaryChars.clamp(300, 20000),
      toolResultChars: compactToolResultChars.clamp(200, 50000),
    ),
    attachments: attachmentLimits,
    searchEnabled: searchEnabled,
    retryLimit: retryLimit,
    maxToolRounds: maxToolRounds,
    speedAccuracy: speedAccuracy,
    modelParamsB: modelParamsB,
    agentOverride: agentOverride.isEmpty ? null : agentOverride,
    aiAgentSelection: aiAgentSelection,
  );

  static double? _set(double value) => value < 0 ? null : value;

  /// Threads: explicit value, else all cores under HyperLoad, else half (spec §4 HyperLoad).
  int effectiveThreads(int cores) {
    if (threads > 0) return threads;
    if (hyperLoad) return cores < 1 ? 1 : cores;
    return (cores ~/ 2).clamp(2, 6);
  }

  int gpuLayers({required bool gpuAvailable}) => switch (gpuOffload) {
    GpuOffload.cpuOnly => 0,
    GpuOffload.gpuPriority => gpuAvailable ? 999 : 0,
    GpuOffload.maxGpu => 999,
    GpuOffload.auto => gpuAvailable ? (hyperLoad ? 999 : 20) : 0,
  };
}

/// One approved patch, written into the settings document.
///
/// [AgentSettings.normalize] has already checked every value, so writing it and letting
/// [AppSettings.fromJson] type it keeps this free of per-key code.
AppSettings withSettings(AppSettings current, List<SettingsChangeOk> changes) {
  final json = current.toJson();
  for (final change in changes) {
    json[change.key] = change.value;
  }
  return AppSettings.fromJson(json);
}

/// Settings are one JSON document in shared preferences; the GitHub token lives in the
/// platform's secure storage instead, because it can read a private repository.
class SettingsStore extends ChangeNotifier {
  SettingsStore(this._prefs, {FlutterSecureStorage? secure})
    : _secure =
          secure ??
          // the legacy keychain needs no entitlement or provisioning profile, so unsigned builds can use it
          const FlutterSecureStorage(
            mOptions: MacOsOptions(usesDataProtectionKeychain: false),
          );

  static const _key = 'settings.v1';
  static const _tokenKey = 'github_token';
  static const _issueTokenKey = 'github_issue_token';
  static const _legacyBraveKey = 'brave_api_key'; // 0.8.6, before the search services were a list
  static const _mcpTokenKey =
      'mcp_token'; // one server, before the list existed

  final SharedPreferences _prefs;
  final FlutterSecureStorage _secure;

  AppSettings _value = const AppSettings();
  AppSettings get value => _value;

  String _token = '';

  /// Empty when none is set (or secure storage is unavailable on this system).
  String get githubToken => _token;

  String _issueToken = '';

  /// The token that writes issues for the error reports (a separate one from [githubToken], which only
  /// needs to read releases: each has the rights it needs and no more). Empty when none is set.
  String get issueToken => _issueToken;

  final Map<String, String> _searchKeys = {};

  /// The key of the search service [id]; empty when none is set. Kept in the secure storage only.
  String searchKeyOf(String id) => _searchKeys[id] ?? '';

  final Map<String, String> _mcpTokens = {};

  final Map<String, String> _shellSecretValues = {};

  static String _shellSecretRef(String name) => 'shell_secret.$name';

  /// The value of a secret a command may be given: an MCP server's token, or the value kept under its
  /// own name. Empty when there is none (then the command cannot be given it).
  String shellSecretValue(ShellSecret secret) =>
      secret.fromMcp ? mcpTokenOf(secret.mcpServerId) : (_shellSecretValues[secret.name] ?? '');

  /// The bearer token of [id]; empty when none is set.
  String mcpTokenOf(String id) => _mcpTokens[id] ?? '';

  /// Kept for a save from before multiple servers.
  String get mcpToken => mcpTokenOf('default');

  static Future<SettingsStore> load({FlutterSecureStorage? secure}) async {
    final store = SettingsStore(
      await SharedPreferences.getInstance(),
      secure: secure,
    );
    final raw = store._prefs.getString(_key);
    if (raw != null) {
      try {
        store._value = AppSettings.fromJson((jsonDecode(raw) as Map).cast());
      } catch (_) {
        // a damaged save must not block the app; the defaults apply
      }
    }
    try {
      store._token = await store._secure.read(key: _tokenKey) ?? '';
      store._issueToken = await store._secure.read(key: _issueTokenKey) ?? '';
      for (final api in store._value.searchApis) {
        store._searchKeys[api.id] = await store._secure.read(key: api.keyRef) ?? '';
      }
      await store._migrateBraveKey();
      final legacy = await store._secure.read(key: _mcpTokenKey) ?? '';
      for (final server in store._value.mcpServers) {
        store._mcpTokens[server.id] =
            await store._secure.read(key: server.tokenRef) ?? '';
      }
      for (final secret in store._value.shellSecrets) {
        if (secret.fromMcp) continue;
        store._shellSecretValues[secret.name] = await store._secure.read(key: _shellSecretRef(secret.name)) ?? '';
      }
      if (legacy.isNotEmpty &&
          store.mcpTokenOf('default').isEmpty &&
          store._value.mcpServers.any((s) => s.id == 'default')) {
        store._mcpTokens['default'] = legacy;
        await store._secure.write(
          key: store._value.mcpServers
              .firstWhere((s) => s.id == 'default')
              .tokenRef,
          value: legacy,
        );
      }
    } catch (_) {
      store._token = '';
      store._searchKeys.clear();
      store._mcpTokens.clear();
      store._shellSecretValues.clear();
    }
    return store;
  }

  Future<void> update(AppSettings Function(AppSettings) change) async {
    _value = change(_value);
    notifyListeners();
    await _prefs.setString(_key, jsonEncode(_value.toJson()));
  }

  /// Adds or replaces a secret commands may be given. [value] is kept in the secure storage (for this
  /// run only when the system has none); for a secret that is an MCP server's token it is not used.
  Future<void> setShellSecret(ShellSecret secret, String value) async {
    await update((s) => s.copyWith(shellSecrets: [
          for (final existing in s.shellSecrets)
            if (existing.name != secret.name) existing,
          secret,
        ]));
    if (secret.fromMcp) {
      await _forgetShellSecretValue(secret.name);
      return;
    }
    _shellSecretValues[secret.name] = value.trim();
    notifyListeners();
    try {
      if (value.trim().isEmpty) {
        await _secure.delete(key: _shellSecretRef(secret.name));
      } else {
        await _secure.write(key: _shellSecretRef(secret.name), value: value.trim());
      }
    } catch (_) {
      // kept for this run only when the system keyring is missing
    }
  }

  /// Takes a secret away: from the list and from the secure storage.
  Future<void> removeShellSecret(String name) async {
    await update((s) => s.copyWith(shellSecrets: [for (final e in s.shellSecrets) if (e.name != name) e]));
    await _forgetShellSecretValue(name);
  }

  Future<void> _forgetShellSecretValue(String name) async {
    _shellSecretValues.remove(name);
    notifyListeners();
    try {
      await _secure.delete(key: _shellSecretRef(name));
    } catch (_) {
      // already gone
    }
  }

  Future<void> setMcpToken(String id, String token) async {
    _mcpTokens[id] = token.trim();
    notifyListeners();
    try {
      final ref = McpServerConfig(id: id, name: '', url: '').tokenRef;
      if (token.trim().isEmpty) {
        await _secure.delete(key: ref);
      } else {
        await _secure.write(key: ref, value: token.trim());
      }
    } catch (_) {
      // keep the token for this run only when the system keyring is missing
    }
  }

  /// Removes the token of a server that was deleted.
  Future<void> forgetMcpToken(String id) async {
    _mcpTokens.remove(id);
    notifyListeners();
    try {
      await _secure.delete(
        key: McpServerConfig(id: id, name: '', url: '').tokenRef,
      );
    } catch (_) {
      // nothing was stored
    }
  }

  Future<void> setSearchKey(String id, String key) async {
    _searchKeys[id] = key.trim();
    notifyListeners();
    try {
      final ref = SearchApiConfig(id: id, name: '', url: '').keyRef;
      if (key.trim().isEmpty) {
        await _secure.delete(key: ref);
      } else {
        await _secure.write(key: ref, value: key.trim());
      }
    } catch (_) {
      // keep the key for this run only when the system keyring is missing
    }
  }

  /// Removes the key of a search service that was deleted.
  Future<void> forgetSearchKey(String id) async {
    _searchKeys.remove(id);
    notifyListeners();
    try {
      await _secure.delete(key: SearchApiConfig(id: id, name: '', url: '').keyRef);
    } catch (_) {
      // nothing was stored
    }
  }

  /// 0.8.6 kept one Brave key of its own; it becomes the first entry of the list.
  Future<void> _migrateBraveKey() async {
    final legacy = await _secure.read(key: _legacyBraveKey) ?? '';
    if (legacy.isEmpty) return;
    if (!_value.searchApis.any((a) => a.id == 'brave-search')) {
      final preset = SearchApiConfig.presets['Brave Search']!;
      _value = _value.copyWith(searchApis: [..._value.searchApis, SearchApiConfig.fromJson({...preset.toJson(), 'id': 'brave-search'})]);
      await _prefs.setString(_key, jsonEncode(_value.toJson()));
    }
    if (searchKeyOf('brave-search').isEmpty) {
      _searchKeys['brave-search'] = legacy;
      await _secure.write(key: SearchApiConfig(id: 'brave-search', name: '', url: '').keyRef, value: legacy);
    }
    await _secure.delete(key: _legacyBraveKey);
  }

  Future<void> setIssueToken(String token) async {
    _issueToken = token.trim();
    notifyListeners();
    try {
      if (_issueToken.isEmpty) {
        await _secure.delete(key: _issueTokenKey);
      } else {
        await _secure.write(key: _issueTokenKey, value: _issueToken);
      }
    } catch (_) {
      // keep the token for this run only when the system keyring is missing
    }
  }

  Future<void> setGithubToken(String token) async {
    _token = token.trim();
    notifyListeners();
    try {
      if (_token.isEmpty) {
        await _secure.delete(key: _tokenKey);
      } else {
        await _secure.write(key: _tokenKey, value: _token);
      }
    } catch (_) {
      // keep the token for this run only when the system keyring is missing
    }
  }
}
