import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../ai/model_info.dart';
import '../ai/openai_compatible.dart';
import '../ai/provider_config.dart';

/// Finds out what a model can do (its context window, its longest reply, whether it sees images)
/// so the user does not have to look it up.
///
/// Two places are asked, in this order:
/// 1. the provider's own model list (`GET /models`), which several services extend with limits;
/// 2. for a model named like a Hugging Face repository (`deepseek-ai/DeepSeek-V4.1-Flash`), the
///    `config.json` of that repository, for the context window. Only the model's name is sent,
///    and only to huggingface.co; the setting `fetchFromHub` turns it off.
class ModelInfoFetcher {
  ModelInfoFetcher({http.Client? client, this.hubBase = 'https://huggingface.co'}) : _client = client ?? http.Client();

  final http.Client _client;
  final String hubBase;

  /// The context window of a Hub repository, or null when it is not a Hub name, not public, or
  /// has no such field.
  Future<int?> contextFromHub(String modelId) async {
    if (!ModelInfoParser.isHubId(modelId)) return null;
    try {
      final response = await _client
          .get(Uri.parse('$hubBase/$modelId/raw/main/config.json'), headers: const {'Accept': 'application/json', 'User-Agent': 'ARCE.AI'})
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return null;
      return ModelInfoParser.contextFromHubConfig(jsonDecode(response.body));
    } catch (e) {
      debugPrint('could not read the Hub config of $modelId: $e');
      return null;
    }
  }

  /// [model] with what is found. [listed] is the provider's list when it has been read already.
  /// Known values stay unless [overwrite]. Returns the same model when nothing was found.
  Future<ModelConfig> enrich(
    ModelConfig model, {
    required List<ModelInfo> listed,
    required bool useHub,
    bool overwrite = false,
  }) async {
    var result = model;
    for (final info in listed) {
      if (info.id == model.id) {
        result = result.mergeInfo(info, overwrite: overwrite);
        break;
      }
    }
    if (useHub && (result.contextTokens == null || overwrite && result.contextTokens == model.contextTokens)) {
      final context = await contextFromHub(model.id);
      if (context != null) {
        result = result.mergeInfo(ModelInfo(model.id, contextTokens: context), overwrite: overwrite);
      }
    }
    return result;
  }

  /// Reads the provider's list (or takes it from [readList], which may have it already) and enriches [model] from it (and the Hub). Errors are not
  /// thrown: a provider that does not list its models (or a missing key) just yields no news.
  Future<ModelConfig> fetchFor(
    OpenAiCompatibleProvider provider,
    ModelConfig model, {
    required bool useHub,
    bool overwrite = false,
    Future<List<ModelInfo>?> Function()? readList,
  }) async {
    List<ModelInfo> listed = const [];
    try {
      listed = await readList?.call() ?? await provider.fetchModelInfos();
    } catch (e) {
      debugPrint('could not read the model list of ${provider.label}: $e');
    }
    return enrich(model, listed: listed, useHub: useHub, overwrite: overwrite);
  }
}
