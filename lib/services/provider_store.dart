import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../ai/fallback.dart';
import '../ai/model_info.dart';
import '../ai/openai_compatible.dart';
import '../ai/provider.dart';
import '../ai/provider_config.dart';

/// The providers the user added, which one is in use, and their keys.
///
/// The list and the choice are one JSON document in shared preferences. The keys are kept apart
/// in the platform's secure storage (`provider_key.<id>`), so nothing secret ends up in a file
/// that can be copied, backed up or exported.
class ProviderStore extends ChangeNotifier {
  ProviderStore(this._prefs, {FlutterSecureStorage? secure})
    : _secure =
          secure ??
          // the legacy keychain needs no entitlement or provisioning profile, so unsigned builds can use it
          const FlutterSecureStorage(
            mOptions: MacOsOptions(usesDataProtectionKeychain: false),
          );

  static const _listKey = 'providers.v1';
  static const _activeKey = 'providers.active';
  static const _activeModelKey = 'providers.activeModel';
  static const _chosenKey = 'providers.chosen';
  static const _fallbackKey = 'providers.fallback.v1';
  static const _recentKey = 'providers.recent';

  final SharedPreferences _prefs;
  final FlutterSecureStorage _secure;

  List<ProviderConfig> _providers = const [];
  final Map<String, String> _keys = {};
  String _active = ProviderList.localId;
  /// The model chosen in each provider (provider id -> model id). Each provider keeps its own, so
  /// going to another provider and back finds the model that was chosen, and saving a provider that
  /// is not in use never changes the one in use.
  final Map<String, String> _chosen = {};

  String get _activeModel => _chosen[_active] ?? '';
  List<FallbackRule> _fallback = const [];
  List<String> _recent = const [];

  List<ProviderConfig> get providers => List.unmodifiable(_providers);

  /// `local` for the device model, otherwise the id of a provider the user added.
  String get activeId => _active;

  /// True when replies go to a cloud provider rather than the model on the device.
  bool get isCloud => _active != ProviderList.localId;

  /// The provider in use, or null for the device model.
  ProviderConfig? get active => byId(_active);

  /// The model of [active] in use, or null for the device model (or a provider without models).
  ModelConfig? get activeModel {
    final provider = active;
    if (provider == null) return null;
    return provider.modelById(_activeModel) ?? provider.defaultModel;
  }

  /// The model chosen for provider [id]; its first one when nothing was picked yet.
  ModelConfig? modelOf(String id) {
    final provider = byId(id);
    if (provider == null) return null;
    return provider.modelById(_chosen[id] ?? '') ?? provider.defaultModel;
  }

  String get activeModelId => activeModel?.id ?? '';

  ProviderConfig? byId(String id) {
    for (final provider in _providers) {
      if (provider.id == id) return provider;
    }
    return null;
  }

  /// The key of [id]; empty when none is set, or when secure storage is unavailable here.
  String keyOf(String id) => _keys[id] ?? '';

  bool hasKey(String id) => keyOf(id).trim().isNotEmpty;

  static Future<ProviderStore> load({FlutterSecureStorage? secure}) async {
    final store = ProviderStore(
      await SharedPreferences.getInstance(),
      secure: secure,
    );
    store._providers = ProviderList.decode(store._prefs.getString(_listKey));
    final saved = store._prefs.getString(_activeKey);
    // a provider that was removed must not stay selected
    store._active = store.byId(saved ?? '') != null
        ? saved!
        : ProviderList.localId;
    try {
      final chosen = jsonDecode(store._prefs.getString(_chosenKey) ?? '{}');
      if (chosen is Map) {
        for (final entry in chosen.entries) {
          if (entry.key is String && entry.value is String) store._chosen[entry.key as String] = entry.value as String;
        }
      }
    } catch (_) {
      // a damaged note only means each provider starts at its first model
    }
    // an older save kept the one model of the provider in use
    final legacy = store._prefs.getString(_activeModelKey) ?? '';
    if (legacy.isNotEmpty && store._chosen[store._active] == null) store._chosen[store._active] = legacy;
    try {
      final raw = store._prefs.getString(_fallbackKey);
      if (raw != null && raw.isNotEmpty) store._fallback = FallbackRule.decodeList(jsonDecode(raw));
    } catch (_) {
      // a damaged list of rules only means no fallback until the user sets it again
    }
    store._recent = store._prefs.getStringList(_recentKey) ?? const [];
    // a model that was removed from its provider is not chosen any more
    store._chosen.removeWhere((id, model) => store.byId(id)?.modelById(model) == null);
    for (final provider in store._providers) {
      try {
        store._keys[provider.id] =
            await store._secure.read(key: provider.keyRef) ?? '';
      } catch (_) {
        store._keys[provider.id] = '';
      }
    }
    return store;
  }

  /// Adds [config] or replaces the provider with the same id.
  Future<void> save(ProviderConfig config) async {
    _providers = [
      for (final provider in _providers)
        if (provider.id != config.id) provider,
      config,
    ];
    // only this provider's own choice can be affected: a model that is gone is no longer chosen
    final lostChoice = _chosen[config.id] != null && config.modelById(_chosen[config.id]!) == null;
    if (lostChoice) _chosen.remove(config.id);
    notifyListeners();
    await _persistList();
    if (lostChoice) await _persistActive();
  }

  Future<void> remove(String id) async {
    _providers = [
      for (final provider in _providers)
        if (provider.id != id) provider,
    ];
    _keys.remove(id);
    _chosen.remove(id);
    if (_active == id) _active = ProviderList.localId;
    notifyListeners();
    await _persistList();
    await _persistActive();
    try {
      await _secure.delete(
        key: ProviderConfig(id: id, label: '', baseUrl: '').keyRef,
      );
    } catch (_) {
      // without a keyring the key was only in memory
    }
  }

  /// Selects [id], or the device model when it is [ProviderList.localId].
  Future<void> setActive(String id) async {
    _active = id == ProviderList.localId || byId(id) == null
        ? ProviderList.localId
        : id;
    notifyListeners();
    await _persistActive();
  }

  /// Chooses the model [id] of [providerId], and makes that provider the one in use.
  Future<void> setActiveModel(String providerId, String id) async {
    final provider = byId(providerId);
    if (provider == null || provider.modelById(id) == null) return;
    _active = providerId;
    _chosen[providerId] = id;
    notifyListeners();
    await _persistActive();
  }

  /// Chooses the model [modelId] of [providerId] and makes that provider the one in use. A model
  /// that is only in the provider's catalog is set up first (with what the provider says about it),
  /// so it keeps its own settings from then on.
  Future<bool> selectModel(String providerId, String modelId) async {
    final provider = byId(providerId);
    if (provider == null) return false;
    if (provider.modelById(modelId) == null) {
      final made = provider.resolveModel(modelId);
      if (made == null) return false;
      await save(provider.copyWith(models: [...provider.models, made]));
    }
    await setActiveModel(providerId, modelId);
    return true;
  }

  /// Replaces the catalog of [providerId] with what its model list offered now, and fills in the
  /// limits of the models already set up (nothing the user typed is replaced). Returns how many
  /// models are new to the catalog; null when the provider is gone.
  Future<int?> updateCatalog(String providerId, List<ModelInfo> infos, {int? now}) async {
    final provider = byId(providerId);
    if (provider == null) return null;
    final before = {for (final info in provider.catalog) info.id};
    final byIdInfo = {for (final info in infos) info.id: info};
    await save(
      provider.copyWith(
        catalog: infos,
        catalogAt: now ?? DateTime.now().millisecondsSinceEpoch,
        models: [
          for (final model in provider.models)
            byIdInfo.containsKey(model.id) ? model.mergeInfo(byIdInfo[model.id]!) : model,
        ],
      ),
    );
    return infos.where((info) => !before.contains(info.id)).length;
  }

  /// The models used last, newest first, as `provider|model`.
  List<String> get recentRefs => List.unmodifiable(_recent);

  /// Notes that [modelId] of [providerId] answered, keeping the [keep] newest. Listeners are told
  /// only when the order changed, so answering again with the same model costs nothing.
  Future<void> markUsed(String providerId, String modelId, {int keep = 8}) async {
    if (providerId.isEmpty || modelId.isEmpty || keep <= 0) return;
    final ref = '$providerId|$modelId';
    if (_recent.isNotEmpty && _recent.first == ref && _recent.length <= keep) return;
    _recent = [ref, for (final r in _recent) if (r != ref) r].take(keep).toList();
    notifyListeners();
    await _prefs.setStringList(_recentKey, _recent);
  }

  Future<void> clearRecent() async {
    if (_recent.isEmpty) return;
    _recent = const [];
    notifyListeners();
    await _prefs.remove(_recentKey);
  }

  List<FallbackRule> get fallbackRules => List.unmodifiable(_fallback);

  Future<void> setFallbackRules(List<FallbackRule> rules) async {
    _fallback = List.of(rules);
    notifyListeners();
    await _prefs.setString(_fallbackKey, jsonEncode([for (final r in _fallback) r.toJson()]));
  }

  /// The models to try after [primary] fails, from the most specific rule that covers it; null
  /// when no rule does, or none of its models can be used (a removed or incomplete provider).
  FallbackPlan? fallbackPlanFor(AiProvider primary) {
    final rule = FallbackPolicy.ruleFor(_fallback, primary.id, primary.modelId);
    if (rule == null) return null;
    final targets = <AiProvider>[];
    for (final ref in rule.targets) {
      final parsed = FallbackRule.parseRef(ref);
      if (parsed == null) continue;
      final (providerId, modelId) = parsed;
      final config = byId(providerId);
      if (config == null || !config.isComplete) continue;
      final model = modelId.isEmpty || modelId == '*' ? config.defaultModel : config.resolveModel(modelId);
      if (model == null || (providerId == primary.id && model.id == primary.modelId)) continue;
      targets.add(build(config, model: model));
    }
    if (targets.isEmpty) return null;
    return FallbackPlan(
      targets: targets,
      statuses: rule.statuses.isEmpty ? FallbackPolicy.defaultStatuses : rule.statuses,
    );
  }

  Future<void> setKey(String id, String key) async {
    _keys[id] = key.trim();
    notifyListeners();
    try {
      final ref = ProviderConfig(id: id, label: '', baseUrl: '').keyRef;
      if (key.trim().isEmpty) {
        await _secure.delete(key: ref);
      } else {
        await _secure.write(key: ref, value: key.trim());
      }
    } catch (_) {
      // keep the key for this run only when the system keyring is missing
    }
  }

  /// The provider in use, ready to send requests; null for the device model, or when the stored
  /// settings are not usable yet (the screen then shows what is missing instead of sending).
  /// How long a request to an online model may take before it gives up (a setting). Providers
  /// built after it changes use the new value.
  Duration requestTimeout = const Duration(seconds: 120);

  /// Makes the HTTP client of a provider that is built without one (tests give a scripted one).
  http.Client Function()? clientFactory;

  /// Told something the user should read that happened outside any screen (the app turned a provider's
  /// cache switch off because the server refused it). The app shows it as a toast.
  void Function(String message)? onNotice;

  /// Sets the prompt-cache switch of provider [id] without moving it in the list (a [save] puts the
  /// provider last). A provider that is not there is left alone.
  Future<void> setPromptCache(String id, bool on) async {
    final at = _providers.indexWhere((p) => p.id == id);
    if (at < 0 || _providers[at].promptCache == on) return;
    _providers = [..._providers]..[at] = _providers[at].copyWith(promptCache: on);
    notifyListeners();
    await _persistList();
  }

  AiProvider? buildActive({http.Client? client}) {
    final config = active;
    if (config == null || !config.isComplete) return null;
    return build(config, model: activeModel, client: client);
  }

  /// A provider built from [config] and its saved key; used by the connection check as well.
  AiProvider build(
    ProviderConfig config, {
    ModelConfig? model,
    http.Client? client,
  }) {
    final chosen = model ?? config.defaultModel;
    return OpenAiCompatibleProvider(
      id: config.id,
      label: config.label,
      baseUrl: config.baseUrl,
      model: chosen?.id ?? '',
      modelConfig: chosen,
      apiKey: keyOf(config.id),
      headers: config.headers,
      body: config.body,
      supportsTools: config.supportsTools,
      promptCache: config.promptCache,
      promptCacheField: config.promptCacheField,
      // the server refused the cache field: the switch goes off, and the user is told why
      onCacheRefused: (reason) {
        unawaited(setPromptCache(config.id, false));
        onNotice?.call('${config.label}: $reason');
      },
      client: client ?? clientFactory?.call(),
      timeout: requestTimeout,
    );
  }

  Future<void> _persistList() =>
      _prefs.setString(_listKey, ProviderList.encode(_providers));

  Future<void> _persistActive() async {
    await _prefs.setString(_activeKey, _active);
    await _prefs.setString(_activeModelKey, _activeModel);
    await _prefs.setString(_chosenKey, jsonEncode(_chosen));
  }
}
