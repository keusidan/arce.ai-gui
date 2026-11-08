import 'model_info.dart';

/// What the model list of a provider says about one model, for the key that read it.
enum ListFinding {
  /// The key's list does not have it: this key cannot use it (or the name is wrong).
  absent,

  /// The list has it, and says it does not do chat (an embedding or an image model).
  notChat,

  /// The list has it. That says nothing about the key's quota: a free tier lists models it cannot answer with.
  listed,
}

class ListVerdict {
  const ListVerdict(this.finding, this.reason);

  final ListFinding finding;

  /// One short Japanese line.
  final String reason;

  bool get isBlocked => finding != ListFinding.listed;
}

/// Judges a model by the list the key can read (`models.list`): no question to the model, no use of the
/// quota. What it can tell is limited: a model that is not in the list, or that does not do chat, is out;
/// one that is in the list may still be refused for the plan (a free tier), which only a real request shows.
abstract final class ModelListCheck {
  /// The id as the list writes it (`models/gemini-2.5-pro` and `gemini-2.5-pro` are one model).
  static String normalize(String id) => id.startsWith('models/') ? id.substring('models/'.length) : id;

  /// Null when the list could not be read or is empty: nothing is known, so nothing is said.
  static ListVerdict? judge(String modelId, List<ModelInfo>? list) {
    if (list == null || list.isEmpty) return null;
    final wanted = normalize(modelId);
    ModelInfo? found;
    for (final info in list) {
      if (normalize(info.id) == wanted) {
        found = info;
        break;
      }
    }
    if (found == null) return const ListVerdict(ListFinding.absent, 'このキーのモデル一覧にありません（名前が違うか、このキーでは使えません）');
    if (found.chat == false) return const ListVerdict(ListFinding.notChat, 'このモデルは、チャットの生成（generateContent）に対応していません');
    return const ListVerdict(ListFinding.listed, '');
  }
}

/// Gemini's own model list (`models.list` of the Gemini API), which says more than the OpenAI-compatible
/// one: for each model the methods it supports and its token limits.
abstract final class GeminiModels {
  static const host = 'generativelanguage.googleapis.com';

  /// Whether [baseUrl] is Google's Gemini endpoint (its OpenAI-compatible path, or the native one).
  static bool isGemini(String baseUrl) => Uri.tryParse(baseUrl.trim())?.host.toLowerCase() == host;

  /// The native list's address for a Gemini [baseUrl] (`.../v1beta/openai` -> `.../v1beta/models`), or null
  /// when [baseUrl] is not Gemini's. [pageToken] continues a list that did not fit in one answer.
  static Uri? listUri(String baseUrl, {String? pageToken}) {
    final base = Uri.tryParse(baseUrl.trim());
    if (base == null || !isGemini(baseUrl)) return null;
    var path = base.path.replaceAll(RegExp(r'/+$'), '');
    if (path.endsWith('/openai')) path = path.substring(0, path.length - '/openai'.length);
    if (!path.endsWith('/v1beta') && !path.endsWith('/v1')) path = '/v1beta';
    return Uri(
      scheme: 'https',
      host: host,
      path: '$path/models',
      queryParameters: {'pageSize': '1000', if (pageToken != null && pageToken.isNotEmpty) 'pageToken': pageToken},
    );
  }
}
