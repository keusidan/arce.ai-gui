import 'dart:convert';

import 'cloudflare_gateway.dart';
import 'provider_config.dart';

/// One provider read from a pasted JSON, with the API key it carried (kept apart: it goes to the secure storage,
/// never into the settings).
class ImportedProvider {
  const ImportedProvider(this.config, {this.key});
  final ProviderConfig config;
  final String? key;
}

/// A provider (or several) written as JSON, as the editor's 「JSON」 takes it: the app's own form (what
/// 「JSON をコピー」 gives) and the names other tools use for the same things.
///
/// * One object, a list of objects, or `{"providers": [...]}`.
/// * Name: `label` or `name`. Address: `baseUrl`, `base_url`, `url` or `endpoint` (everything before
///   `/chat/completions`; a pasted `/chat/completions` is cut off). Models: `models` as names or as objects
///   (`id`, `name`, `serviceTier` / `service_tier` …), or one `model`.
/// * `headers`, `body` (or `extra_body`), `tools` (or `supportsTools`), `autoFetch` (or `autoFetchModels`),
///   `promptCache`, `promptCacheField`.
/// * The key: `apiKey`, `api_key` or `key`, or a header `Authorization: Bearer …`. Any other header that would
///   carry a secret is refused, as in the editor.
/// * Cloudflare AI Gateway: `"type": "cloudflare"` with `account_id` (and `gateway_id`) instead of an address.
abstract final class ProviderImport {
  /// The providers in [text]; their ids are new ones made from their names (not taken by [existing] or by one
  /// another), unless [keepId] is given (editing one provider: it stays that provider). Throws a
  /// [FormatException] whose message can be shown as it is.
  static List<ImportedProvider> parse(String text, Iterable<ProviderConfig> existing, {String? keepId}) {
    final Object? decoded;
    try {
      decoded = jsonDecode(text.trim());
    } on FormatException catch (e) {
      throw FormatException('JSON として読めません（${e.message}）');
    }
    final entries = switch (decoded) {
      final Map<String, Object?> m when m['providers'] is List => m['providers']! as List,
      final Map<String, Object?> m => [m],
      final List<Object?> l => l,
      _ => throw const FormatException('JSON はプロバイダのオブジェクトか、その配列にしてください'),
    };
    if (entries.isEmpty) throw const FormatException('プロバイダが 1 つもありません');
    if (keepId != null && entries.length != 1) throw const FormatException('編集では、プロバイダは 1 つだけにしてください');
    final taken = [...existing];
    final out = <ImportedProvider>[];
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      if (entry is! Map) throw FormatException('${i + 1} 番目がオブジェクトではありません');
      final read = _one(entry.cast<String, Object?>(), i + 1);
      final label = read.config.label.trim().isEmpty ? 'プロバイダ' : read.config.label.trim();
      final id = keepId ?? ProviderList.idFor(label, taken);
      final config = read.config.copyWith(label: label);
      final withId = ProviderConfig.fromJson({...config.toJson(), 'id': id});
      taken.add(withId);
      out.add(ImportedProvider(withId, key: read.key));
    }
    return out;
  }

  static ImportedProvider _one(Map<String, Object?> json, int n) {
    String text(List<String> keys) {
      for (final k in keys) {
        final v = json[k];
        if (v is String && v.trim().isNotEmpty) return v.trim();
      }
      return '';
    }

    var key = text(['apiKey', 'api_key', 'key']);
    final type = text(['type', 'kind']).toLowerCase();

    // the headers: Authorization becomes the key, any other secret is refused
    final headers = <String, String>{};
    final rawHeaders = json['headers'];
    if (rawHeaders != null && rawHeaders is! Map) throw FormatException('$n 番目の headers はオブジェクトにしてください');
    if (rawHeaders is Map) {
      for (final entry in rawHeaders.entries) {
        final name = '${entry.key}';
        final value = entry.value;
        if (value is! String) throw FormatException('$n 番目のヘッダー $name の値は文字列にしてください');
        if (name.toLowerCase() == 'authorization') {
          final bearer = RegExp(r'^bearer\s+(.+)$', caseSensitive: false).firstMatch(value.trim());
          if (bearer == null) throw FormatException('$n 番目の Authorization は「Bearer キー」の形にしてください');
          if (key.isEmpty) key = bearer.group(1)!.trim();
          continue;
        }
        headers[name] = value;
      }
      // the editor's own check: a name that would carry a secret does not go into the settings
      ProviderExtras.parseHeaders(jsonEncode(headers));
    }

    var baseUrl = text(['baseUrl', 'base_url', 'url', 'endpoint', 'baseURL']);
    var inferredResponses = false;
    if (type == 'cloudflare') {
      final account = text(['account_id', 'accountId', 'account']);
      if (!CloudflareGateway.isAccountId(account)) throw FormatException('$n 番目の Cloudflare には account_id（英数字）が要ります');
      baseUrl = CloudflareGateway.baseUrl(account);
      final withGateway = CloudflareGateway.withGateway(headers, text(['gateway_id', 'gatewayId', 'gateway']));
      headers
        ..clear()
        ..addAll(withGateway);
    } else {
      inferredResponses = RegExp(r'/responses/?$').hasMatch(baseUrl);
    }
    baseUrl = baseUrl
        .replaceAll(RegExp(r'/(?:chat/completions|responses)/?$'), '')
        .replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(baseUrl);
    if (baseUrl.isEmpty || uri == null || !(uri.isScheme('https') || uri.isScheme('http')) || uri.host.isEmpty) {
      throw FormatException('$n 番目の baseUrl（https://…）が読めません');
    }

    final models = <Map<String, Object?>>[];
    final rawModels = json['models'];
    if (rawModels is List) {
      for (final m in rawModels) {
        if (m is String && m.trim().isNotEmpty) {
          models.add({'id': m.trim(), 'name': m.trim()});
        } else if (m is Map && m['id'] is String && (m['id']! as String).trim().isNotEmpty) {
          models.add(m.cast<String, Object?>());
        }
      }
    }
    final single = text(['model']);
    if (models.isEmpty && single.isNotEmpty) models.add({'id': single, 'name': single});

    final body = json['body'] ?? json['extra_body'];
    if (body != null && body is! Map) throw FormatException('$n 番目の body はオブジェクトにしてください');
    bool? flag(List<String> keys) {
      for (final k in keys) {
        if (json[k] is bool) return json[k]! as bool;
      }
      return null;
    }

    final rawApi = text(['api', 'protocol']).toLowerCase();
    final api = switch (rawApi) {
      'responses' => 'responses',
      'chatcompletions' || 'chat_completions' || 'chat' => 'chatCompletions',
      '' => inferredResponses ? 'responses' : null,
      _ => null,
    };

    final config = ProviderConfig.fromJson({
      'id': 'imported',
      'label': text(['label', 'name']),
      'baseUrl': baseUrl,
      'models': models,
      'headers': headers,
      if (body is Map) 'body': body,
      if (flag(['tools', 'supportsTools']) == false) 'tools': false,
      // Cloudflare has no list to read
      if (flag(['autoFetch', 'autoFetchModels']) == false || type == 'cloudflare') 'autoFetch': false,
      if (flag(['promptCache']) == true) 'promptCache': true,
      if (json['promptCacheField'] is String) 'promptCacheField': json['promptCacheField'],
      'api': ?api,
      if (flag(['background', 'responsesBackground']) == true) 'background': true,
    });
    return ImportedProvider(config, key: key.isEmpty ? null : key);
  }

  /// The JSON 「JSON をコピー」 gives for [config]: the app's own form, without its id, its model list (the
  /// catalog, which is read again) and its key.
  static String export(ProviderConfig config) {
    final json = config.toJson()
      ..remove('id')
      ..remove('catalog')
      ..remove('catalogAt');
    return const JsonEncoder.withIndent('  ').convert(json);
  }
}
