import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'provider.dart';

/// Whether a provider's model can be used with this key and plan.
///
/// A model list says what the provider *has*, not what this key may *use*: a free tier of Gemini lists
/// models it answers with "limit: 0", and a plain key lists models of a plan it does not have. The
/// list is shown as it is, so the app finds out from the answers instead.
enum ModelAvailability {
  /// A request was answered.
  usable,

  /// This key or plan cannot use this model: it will not pass by waiting.
  blocked,

  /// A failure that passes (a rate limit of the minute, a busy server, no connection). Nothing to remember.
  temporary,

  /// The key itself was refused: it says nothing about the model, and trying more models is pointless.
  keyRejected,

  /// A failure that says nothing sure (a request the model did not like, an unknown shape).
  unknown,
}

/// What a failed (or answered) request says about a model, with a short reason to show.
class AvailabilityVerdict {
  const AvailabilityVerdict(this.availability, this.reason);

  final ModelAvailability availability;

  /// One short Japanese line; empty for [ModelAvailability.usable].
  final String reason;

  static const usable = AvailabilityVerdict(ModelAvailability.usable, '');

  bool get isBlocked => availability == ModelAvailability.blocked;

  /// Worth keeping: the next time the list is shown the mark is still true (or true for a while).
  bool get isRemembered => availability == ModelAvailability.usable || availability == ModelAvailability.blocked;

  @override
  String toString() => '${availability.name}: $reason';
}

/// Reads the HTTP status and the body of a provider's answer to tell a model this key cannot use from a
/// failure that will pass.
///
/// The status code decides first; a phrase in the body only decides what the code leaves open, and only a
/// phrase every service uses in some form (not an exact message of one of them): "quota", "limit: 0",
/// "not found", "billing", "free tier". Services change their wording; what is certain is written down in
/// the tests, and anything else comes out as [ModelAvailability.unknown], which marks nothing.
abstract final class AvailabilityClassifier {
  /// [status] is the HTTP status (null when there was none: no connection, a time out); [body] is what the
  /// provider answered with.
  static AvailabilityVerdict classify({int? status, String body = ''}) {
    if (status == null) return const AvailabilityVerdict(ModelAvailability.temporary, '接続できませんでした');
    if (status >= 200 && status < 300) return AvailabilityVerdict.usable;
    final text = body.toLowerCase();
    bool has(Pattern p) => text.contains(p);
    bool matches(String pattern) => RegExp(pattern).hasMatch(text);

    // a key that is not accepted, whatever the model
    final keyWords = matches(r'api[ _-]?key (is )?(not valid|invalid|missing|expired)|api_key_invalid|invalid[ _-]?api[ _-]?key|incorrect api key|invalid_api_key|authentication|unauthenticated|unauthorized|invalid (bearer )?token|no auth');
    if (status == 401 || (status == 400 && keyWords) || (status == 403 && keyWords)) {
      return const AvailabilityVerdict(ModelAvailability.keyRejected, 'APIキーが受け付けられませんでした');
    }

    // the plan: free tier, billing, credits
    final freeTier = has('free tier') || has('free_tier') || has('free plan');
    final planWords = matches(r'billing|paid plan|paid tier|upgrade|payment|credit|insufficient[ _]funds|insufficient_quota|not enabled|isn.t enabled|requires? (a )?(paid|pro|premium)');
    final modelWords = matches(r'model|models/');

    if (status == 402) return const AvailabilityVerdict(ModelAvailability.blocked, '残高（クレジット）が足りません');

    if (status == 429) {
      // "limit: 0": the plan gives this model no quota at all (the free tier of a model that is paid only)
      if (matches(r'limit:\s*0\b|"limit":\s*0\b|limit of 0\b')) {
        return const AvailabilityVerdict(ModelAvailability.blocked, 'このキー（無料枠）では、このモデルの利用枠が 0 です');
      }
      // the code of a key that has no credit left (the sentence "you exceeded your current quota" alone is
      // also what a limit of the minute says, so it is not enough)
      if (has('insufficient_quota') || matches(r'insufficient (credits|balance|funds)')) {
        return const AvailabilityVerdict(ModelAvailability.blocked, '利用枠（クレジット）を使い切っています。プランや請求を確認してください');
      }
      if (freeTier && matches(r'not (available|supported|allowed)|isn.t available|only available|requires? (a )?paid')) {
        return const AvailabilityVerdict(ModelAvailability.blocked, '無料枠では使えないモデルです');
      }
      if (matches(r'per[ _-]?day|daily')) {
        return const AvailabilityVerdict(ModelAvailability.temporary, '今日の分の回数制限に達しました（日が変わると戻ります）');
      }
      return const AvailabilityVerdict(ModelAvailability.temporary, '回数制限です（少し待てば使えます）');
    }

    if (status == 403) {
      if (planWords || freeTier || matches(r'permission|not allowed|forbidden|access|not authorized|denied|region|country|territory')) {
        return AvailabilityVerdict(ModelAvailability.blocked, freeTier ? '無料枠では使えないモデルです' : (planWords ? 'このキー（プラン）では使えません（請求や有効化が必要です）' : 'このキーには、このモデルを使う権限がありません'));
      }
      return const AvailabilityVerdict(ModelAvailability.unknown, '拒否されました（HTTP 403）');
    }

    if (status == 404) {
      // a wrong address also answers 404, but without a word about a model
      if (modelWords || has('no endpoints')) {
        return const AvailabilityVerdict(ModelAvailability.blocked, 'このモデルは、この提供元・このキーにはありません（またはもう使えません）');
      }
      return const AvailabilityVerdict(ModelAvailability.unknown, '接続先が見つかりません（URL を確認してください）');
    }

    if (status == 400 || status == 422) {
      // "the model is not supported / does not exist / is not available" in a bad request
      if (matches(r'(model|models/[\w.\-:]+)[^.]{0,80}(not found|does not exist|not supported|unsupported|is not available|isn.t available|no longer available|deprecated|decommissioned|not enabled|not a valid model)') ||
          matches(r'(invalid|unknown|unsupported) model')) {
        return const AvailabilityVerdict(ModelAvailability.blocked, 'このモデルは使えません（提供元が受け付けませんでした）');
      }
      if (freeTier && matches(r'not (available|supported|allowed)')) {
        return const AvailabilityVerdict(ModelAvailability.blocked, '無料枠では使えないモデルです');
      }
      return const AvailabilityVerdict(ModelAvailability.unknown, 'リクエストの形が、このモデルに合いませんでした（HTTP 400）');
    }

    if (status == 408) return const AvailabilityVerdict(ModelAvailability.temporary, '時間切れです');
    if (status >= 500) return AvailabilityVerdict(ModelAvailability.temporary, '提供元の側で失敗しました（HTTP $status）。あとで試してください');
    return AvailabilityVerdict(ModelAvailability.unknown, '失敗しました（HTTP $status）');
  }

  /// The same for a thrown error: a provider's failure carries its status and body, the rest is a
  /// connection or time out problem.
  static AvailabilityVerdict classifyError(Object error) {
    if (error is AiProviderException) {
      if (error.statusCode == null) return const AvailabilityVerdict(ModelAvailability.unknown, '失敗しました');
      return classify(status: error.statusCode, body: error.body.isEmpty ? error.message : error.body);
    }
    if (error is TimeoutException) return const AvailabilityVerdict(ModelAvailability.temporary, '時間切れです');
    if (error is SocketException || error is http.ClientException) {
      return const AvailabilityVerdict(ModelAvailability.temporary, '接続できませんでした');
    }
    return const AvailabilityVerdict(ModelAvailability.unknown, '失敗しました');
  }

  /// The message shown when a real request failed with a model this key cannot use: which model, why,
  /// what to do, and what the provider said.
  static String blockedMessage({
    required String providerLabel,
    required String modelId,
    required AvailabilityVerdict verdict,
    required String original,
    bool marked = true,
  }) =>
      '$providerLabel の $modelId は、いまのキー（プラン）では使えないようです：${verdict.reason}。別のモデルを選んでください'
      '${marked ? '（モデルの一覧に、使えない印が付きました）' : ''}。提供元の答え: $original';

  /// What the provider said, from an error body: the `error.message` (also in the list Gemini wraps it
  /// in), cut to [max] characters; null when there is none. This is the provider's own text about its own
  /// refusal, shown beside the app's reason; it never holds anything of the chat.
  static String? providerMessage(String body, {int max = 200}) {
    try {
      var decoded = jsonDecode(body);
      if (decoded is List && decoded.isNotEmpty) decoded = decoded.first;
      if (decoded is Map) {
        final error = decoded['error'];
        final text = error is Map ? error['message'] : (error is String ? error : decoded['message']);
        if (text is String && text.trim().isNotEmpty) {
          final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
          return flat.length <= max ? flat : '${flat.substring(0, max)}…';
        }
      }
    } catch (_) {
      // not JSON: nothing to quote
    }
    return null;
  }

  /// Whether the id looks like a model that answers chat. A provider's list also holds embedding, speech,
  /// image and moderation models, which fail a chat request for a reason that says nothing about the key:
  /// the probe leaves them out. A guess from the name; a model it wrongly leaves out can still be probed
  /// by hand (it is only left out of "probe everything").
  static bool looksLikeChatModel(String id) => !_notChat.hasMatch(id.toLowerCase());

  static final _notChat = RegExp(
    r'embed|text-embedding|tts|text-to-speech|whisper|transcribe|speech|imagen|veo|dall-e|gpt-image|image-generation|-image(-|$)|moderation|rerank|aqa|guard|safeguard',
  );
}

/// What was found out about one model, as it is kept.
class AvailabilityRecord {
  const AvailabilityRecord(this.availability, this.reason, this.at);

  final ModelAvailability availability;
  final String reason;

  /// When (milliseconds since the epoch).
  final int at;

  bool get isBlocked => availability == ModelAvailability.blocked;
  bool get isUsable => availability == ModelAvailability.usable;

  /// Whether the result is still to be believed: plans change, so a result is trusted for [days] only.
  bool isFresh(int now, int days) => now - at <= days * Duration.millisecondsPerDay;
}

/// What a model list needs to mark models: how to look a result up (null: nothing is known) and whether
/// models known to be unusable are hidden or only greyed and put last.
class ModelMarks {
  const ModelMarks({this.lookup, this.hideBlocked = false});

  /// The result for `(provider id, model id)`, already checked for freshness; null when none is known.
  final AvailabilityRecord? Function(String providerId, String modelId)? lookup;
  final bool hideBlocked;

  static const none = ModelMarks();

  AvailabilityRecord? of(String providerId, String modelId) => lookup?.call(providerId, modelId);
}
