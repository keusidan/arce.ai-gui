import 'dart:convert';

import 'http_get.dart';

class SearchHit {
  const SearchHit(this.title, this.url, this.snippet);
  final String title;
  final String url;
  final String snippet;
}

abstract interface class SearchProvider {
  String get name;
  Future<List<SearchHit>> search(String query, int limit);
}

String? _string(Object? value) => value is String ? value : null;

/// SearXNG's JSON API (`search.formats` must include `json` in its settings.yml).
class SearXngProvider implements SearchProvider {
  SearXngProvider(this.baseUrl, this._get);

  final String baseUrl;
  final HttpGet _get;

  @override
  String get name => 'SearXNG';

  @override
  Future<List<SearchHit>> search(String query, int limit) async {
    final base = baseUrl.replaceFirst(RegExp(r'/+$'), '');
    final body = await _get('$base/search?q=${Uri.encodeQueryComponent(query)}&format=json', const {});
    final root = jsonDecode(body);
    final results = root is Map ? root['results'] : null;
    final hits = <SearchHit>[];
    for (final element in (results is List ? results : const [])) {
      if (element is! Map) continue;
      final url = _string(element['url']);
      if (url == null) continue;
      hits.add(SearchHit(_string(element['title']) ?? url, url, _string(element['content']) ?? ''));
    }
    return hits.take(limit).toList();
  }
}

/// A search service the user set up: an address with `{query}` (and `{count}`, `{key}`) in it, the
/// method (GET, or POST with a JSON body), extra headers, and where in the JSON answer the results are.
///
/// The API key is not here. It lives in the platform's secure storage under [keyRef] and is put
/// in wherever `{key}` stands (the address, a header value or the body), so a settings file or a
/// backup never carries it.
class SearchApiConfig {
  const SearchApiConfig({
    required this.id,
    required this.name,
    required this.url,
    this.method = 'GET',
    this.body = '',
    this.headers = const {},
    this.resultsPath = '',
    this.titleField = 'title',
    this.urlField = 'url',
    this.snippetField = 'description',
    this.maxCount = 50,
    this.enabled = true,
  });

  static const queryMark = '{query}';
  static const countMark = '{count}';
  static const keyMark = '{key}';
  static const methods = ['GET', 'POST'];

  final String id;
  final String name;

  /// e.g. `https://api.example.com/search?q={query}&count={count}`.
  final String url;

  /// `GET` or `POST`.
  final String method;

  /// The JSON sent with a POST; `{query}` and `{key}` are put in as JSON strings (without their quotes
  /// in the template: `{"query": "{query}"}`), `{count}` as a number (`{"max_results": {count}}`).
  final String body;

  /// Values may contain `{key}`.
  final Map<String, String> headers;

  /// Dot path to the list of results in the answer (`web.results`); empty when the answer is the list.
  final String resultsPath;

  /// Dot paths inside one result.
  final String titleField;
  final String urlField;
  final String snippetField;

  /// The most results the service accepts in one request (some answer an error above it).
  final int maxCount;
  final bool enabled;

  bool get isPost => method.toUpperCase() == 'POST';

  String get keyRef => 'search_key_$id';

  /// True when a key has to be set for the service to work.
  bool get needsKey =>
      url.contains(keyMark) || body.contains(keyMark) || headers.values.any((v) => v.contains(keyMark));

  /// The reason this configuration cannot be used, or null.
  String? get problem {
    if (id.trim().isEmpty) return '名前がありません';
    final uri = Uri.tryParse(url.replaceAll(RegExp(r'\{\w+\}'), 'x'));
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https')) || uri.host.isEmpty) {
      return 'URL は http(s) で入れてください';
    }
    if (isPost) {
      if (!url.contains(queryMark) && !body.contains(queryMark)) return 'URL か本文に {query} を入れてください';
      return checkBody(body);
    }
    return url.contains(queryMark) ? null : 'URL に {query} を入れてください';
  }

  bool get isComplete => problem == null;

  /// `null` when [template] is JSON once its marks are filled in, else what is wrong with it.
  static String? checkBody(String template) {
    if (template.trim().isEmpty) return null;
    try {
      jsonDecode(template.replaceAll(queryMark, 'q').replaceAll(keyMark, 'k').replaceAll(countMark, '1'));
      return null;
    } on FormatException {
      return '本文が JSON になっていません（{query} と {key} は "" の中、{count} は数字として書きます）';
    }
  }

  SearchApiConfig copyWith({
    String? name,
    String? url,
    String? method,
    String? body,
    Map<String, String>? headers,
    String? resultsPath,
    String? titleField,
    String? urlField,
    String? snippetField,
    int? maxCount,
    bool? enabled,
  }) => SearchApiConfig(
    id: id,
    name: name ?? this.name,
    url: url ?? this.url,
    method: method ?? this.method,
    body: body ?? this.body,
    headers: headers ?? this.headers,
    resultsPath: resultsPath ?? this.resultsPath,
    titleField: titleField ?? this.titleField,
    urlField: urlField ?? this.urlField,
    snippetField: snippetField ?? this.snippetField,
    maxCount: maxCount ?? this.maxCount,
    enabled: enabled ?? this.enabled,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'url': url,
    if (isPost) 'method': 'POST',
    if (body.isNotEmpty) 'body': body,
    if (headers.isNotEmpty) 'headers': headers,
    'resultsPath': resultsPath,
    'titleField': titleField,
    'urlField': urlField,
    'snippetField': snippetField,
    'maxCount': maxCount,
    'enabled': enabled,
  };

  factory SearchApiConfig.fromJson(Map<String, Object?> json) {
    String text(String key, [String fallback = '']) => json[key] is String ? json[key]! as String : fallback;
    final rawHeaders = json['headers'];
    final count = json['maxCount'];
    return SearchApiConfig(
      id: text('id'),
      name: text('name'),
      url: text('url'),
      method: text('method', 'GET').toUpperCase() == 'POST' ? 'POST' : 'GET',
      body: text('body'),
      headers: {
        if (rawHeaders is Map)
          for (final entry in rawHeaders.entries)
            if (entry.key is String && entry.value is String) entry.key as String: entry.value as String,
      },
      resultsPath: text('resultsPath'),
      titleField: text('titleField', 'title'),
      urlField: text('urlField', 'url'),
      snippetField: text('snippetField', 'description'),
      maxCount: count is int && count > 0 ? count : 50,
      enabled: json['enabled'] is bool ? json['enabled']! as bool : true,
    );
  }

  /// Ready-made entries the editor offers. The request and answer formats are the ones the services'
  /// documentation (and the integrations that use them) describe; the ones marked 要確認 could not be
  /// checked against the service's own page, so run 「試す」 with a key before relying on them. Every
  /// field can be changed afterwards.
  static const presets = <String, SearchApiConfig>{
    'Brave Search': SearchApiConfig(
      id: '',
      name: 'Brave Search',
      url: 'https://api.search.brave.com/res/v1/web/search?q={query}&count={count}',
      headers: {'Accept': 'application/json', 'X-Subscription-Token': '{key}'},
      resultsPath: 'web.results',
      maxCount: 20,
    ),
    'Google カスタム検索': SearchApiConfig(
      id: '',
      name: 'Google カスタム検索',
      url: 'https://www.googleapis.com/customsearch/v1?key={key}&cx=（検索エンジンID）&q={query}&num={count}',
      resultsPath: 'items',
      urlField: 'link',
      snippetField: 'snippet',
      maxCount: 10,
    ),
    'Tavily': SearchApiConfig(
      id: '',
      name: 'Tavily',
      url: 'https://api.tavily.com/search',
      method: 'POST',
      body: '{"query": "{query}", "max_results": {count}, "search_depth": "basic"}',
      headers: {'Authorization': 'Bearer {key}'},
      resultsPath: 'results',
      snippetField: 'content',
      maxCount: 20,
    ),
    'Exa': SearchApiConfig(
      id: '',
      name: 'Exa',
      url: 'https://api.exa.ai/search',
      method: 'POST',
      body: '{"query": "{query}", "numResults": {count}, "contents": {"text": {"maxCharacters": 500}}}',
      headers: {'x-api-key': '{key}'},
      resultsPath: 'results',
      snippetField: 'text',
      maxCount: 100,
    ),
    'Serper': SearchApiConfig(
      id: '',
      name: 'Serper',
      url: 'https://google.serper.dev/search',
      method: 'POST',
      body: '{"q": "{query}", "num": {count}}',
      headers: {'X-API-KEY': '{key}'},
      resultsPath: 'organic',
      urlField: 'link',
      snippetField: 'snippet',
      maxCount: 100,
    ),
    'Perplexity 検索': SearchApiConfig(
      id: '',
      name: 'Perplexity 検索',
      url: 'https://api.perplexity.ai/search',
      method: 'POST',
      body: '{"query": "{query}", "max_results": {count}}',
      headers: {'Authorization': 'Bearer {key}'},
      resultsPath: 'results',
      snippetField: 'snippet',
      maxCount: 20,
    ),
    'Ollama 検索': SearchApiConfig(
      id: '',
      name: 'Ollama 検索',
      url: 'https://ollama.com/api/web_search',
      method: 'POST',
      body: '{"query": "{query}", "max_results": {count}}',
      headers: {'Authorization': 'Bearer {key}'},
      resultsPath: 'results',
      snippetField: 'content',
      maxCount: 10,
    ),
    '智谱（Zhipu）': SearchApiConfig(
      id: '',
      name: '智谱（Zhipu）',
      url: 'https://open.bigmodel.cn/api/paas/v4/web_search',
      method: 'POST',
      body: '{"search_query": "{query}", "search_engine": "search_std", "search_intent": false, "count": {count}}',
      headers: {'Authorization': 'Bearer {key}'},
      resultsPath: 'search_result',
      urlField: 'link',
      snippetField: 'content',
      maxCount: 50,
    ),
    'Firecrawl（要確認）': SearchApiConfig(
      id: '',
      name: 'Firecrawl',
      url: 'https://api.firecrawl.dev/v2/search',
      method: 'POST',
      body: '{"query": "{query}", "limit": {count}}',
      headers: {'Authorization': 'Bearer {key}'},
      resultsPath: 'data.web',
      maxCount: 100,
    ),
    'LinkUp（要確認）': SearchApiConfig(
      id: '',
      name: 'LinkUp',
      url: 'https://api.linkup.so/v1/search',
      method: 'POST',
      body: '{"q": "{query}", "depth": "standard", "outputType": "searchResults", "maxResults": {count}}',
      headers: {'Authorization': 'Bearer {key}'},
      resultsPath: 'results',
      titleField: 'name',
      snippetField: 'content',
      maxCount: 50,
    ),
    '博查 Bocha（要確認）': SearchApiConfig(
      id: '',
      name: '博查 Bocha',
      url: 'https://api.bochaai.com/v1/web-search',
      method: 'POST',
      body: '{"query": "{query}", "count": {count}, "summary": true}',
      headers: {'Authorization': 'Bearer {key}'},
      resultsPath: 'data.webPages.value',
      titleField: 'name',
      snippetField: 'summary',
      maxCount: 50,
    ),
    'Jina（要確認）': SearchApiConfig(
      id: '',
      name: 'Jina',
      url: 'https://s.jina.ai/',
      method: 'POST',
      body: '{"q": "{query}"}',
      headers: {'Authorization': 'Bearer {key}', 'Accept': 'application/json'},
      resultsPath: 'data',
      snippetField: 'description',
      maxCount: 50,
    ),
    '秘塔 Metaso（要確認）': SearchApiConfig(
      id: '',
      name: '秘塔 Metaso',
      url: 'https://metaso.cn/api/v1/search',
      method: 'POST',
      body: '{"q": "{query}", "scope": "webpage", "size": {count}}',
      headers: {'Authorization': 'Bearer {key}', 'Accept': 'application/json'},
      resultsPath: 'webpages',
      urlField: 'link',
      snippetField: 'snippet',
      maxCount: 50,
    ),
  };

  /// `{"Accept": "application/json", "X-Token": "{key}"}` → the map; empty text → none. A header whose
  /// name says it carries a secret must take it from `{key}`, because settings are kept in plain
  /// storage and travel in backups. Throws a [FormatException] whose message can be shown as it is.
  static Map<String, String> parseHeaders(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return const {};
    final Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } on FormatException {
      throw const FormatException('ヘッダーは JSON のオブジェクトで書いてください（例: {"名前": "値"}）');
    }
    if (decoded is! Map) throw const FormatException('ヘッダーは JSON のオブジェクトで書いてください（例: {"名前": "値"}）');
    final secretName = RegExp(r'authorization|api[-_ ]?key|token|secret|password|cookie', caseSensitive: false);
    final out = <String, String>{};
    for (final entry in decoded.entries) {
      final name = '${entry.key}';
      if (entry.value is! String) throw FormatException('ヘッダー $name の値は文字列にしてください');
      final value = entry.value as String;
      if (secretName.hasMatch(name) && !value.contains(keyMark)) {
        throw FormatException('ヘッダー $name は機密情報になりえます。値は $keyMark にして、キーは「APIキー」の欄に入れてください');
      }
      out[name] = value;
    }
    return out;
  }
}

/// Searches with a [SearchApiConfig]: fills in the address, headers and body, reads the answer's JSON.
class ConfiguredSearchProvider implements SearchProvider {
  ConfiguredSearchProvider(this.config, this.apiKey, this._get, {this.post});

  final SearchApiConfig config;
  final String apiKey;
  final HttpGet _get;

  /// Sends the POST of a service that takes one; without it such a service reports an error.
  final HttpPost? post;

  @override
  String get name => config.name;

  /// [text] as the inside of a JSON string.
  static String _jsonText(String text) {
    final quoted = jsonEncode(text);
    return quoted.substring(1, quoted.length - 1);
  }

  @override
  Future<List<SearchHit>> search(String query, int limit) async {
    if (config.needsKey && apiKey.trim().isEmpty) throw StateError('APIキーが未設定です');
    final key = apiKey.trim();
    final count = limit.clamp(1, config.maxCount < 1 ? 1 : config.maxCount);
    final url = config.url
        .replaceAll(SearchApiConfig.queryMark, Uri.encodeQueryComponent(query))
        .replaceAll(SearchApiConfig.countMark, '$count')
        .replaceAll(SearchApiConfig.keyMark, Uri.encodeQueryComponent(key));
    final headers = {
      for (final entry in config.headers.entries) entry.key: entry.value.replaceAll(SearchApiConfig.keyMark, key),
    };

    final String answer;
    if (config.isPost) {
      final send = post;
      if (send == null) throw StateError('この環境では POST を送れません');
      final body = config.body
          .replaceAll(SearchApiConfig.queryMark, _jsonText(query))
          .replaceAll(SearchApiConfig.countMark, '$count')
          .replaceAll(SearchApiConfig.keyMark, _jsonText(key));
      final withType = {
        if (!headers.keys.any((k) => k.toLowerCase() == 'content-type')) 'Content-Type': 'application/json',
        ...headers,
      };
      answer = await send(url, withType, body);
    } else {
      answer = await _get(url, headers);
    }

    final root = jsonDecode(answer);
    final results = _at(root, config.resultsPath);
    final hits = <SearchHit>[];
    for (final element in (results is List ? results : const [])) {
      final link = _string(_at(element, config.urlField));
      if (link == null || link.trim().isEmpty) continue;
      hits.add(SearchHit(
        _plain(_string(_at(element, config.titleField))) ?? link,
        link,
        _plain(_string(_at(element, config.snippetField))) ?? '',
      ));
    }
    return hits.take(limit).toList();
  }

  /// `a.b.c` into nested maps; an empty path is the value itself.
  static Object? _at(Object? value, String path) {
    var current = value;
    for (final part in path.split('.')) {
      if (part.trim().isEmpty) continue;
      if (current is! Map) return null;
      current = current[part.trim()];
    }
    return current;
  }

  /// The snippets of some services mark the matched words with tags and entities; the model needs only the text.
  static String? _plain(String? html) {
    if (html == null) return null;
    final text = html
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#x27;', "'")
        .replaceAll('&#39;', "'")
        .trim();
    return text.isEmpty ? null : text;
  }
}

/// Helpers for the list of search services in the settings document.
abstract final class SearchApis {
  /// A readable id from the name, unique among [existing].
  static String idFor(String name, Iterable<SearchApiConfig> existing) {
    final stem = name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final base = stem.isEmpty ? 'search' : stem;
    final taken = {for (final api in existing) api.id};
    if (!taken.contains(base)) return base;
    for (var n = 2; ; n++) {
      final candidate = '$base-$n';
      if (!taken.contains(candidate)) return candidate;
    }
  }

  static List<SearchApiConfig> decode(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final entry in raw)
        if (entry is Map)
          if (SearchApiConfig.fromJson(entry.cast<String, Object?>()) case final config when config.id.trim().isNotEmpty) config,
    ];
  }
}

/// DuckDuckGo's Instant Answer API: no key, but only abstracts and related topics, not a
/// full result list. Used as a fallback when the SearXNG server cannot be reached.
class DuckDuckGoInstantProvider implements SearchProvider {
  DuckDuckGoInstantProvider(this._get);

  final HttpGet _get;

  @override
  String get name => 'DuckDuckGo Instant Answer';

  @override
  Future<List<SearchHit>> search(String query, int limit) async {
    final body = await _get(
      'https://api.duckduckgo.com/?q=${Uri.encodeQueryComponent(query)}&format=json&no_html=1&skip_disambig=1',
      const {},
    );
    final root = jsonDecode(body);
    if (root is! Map) return const [];
    final hits = <SearchHit>[];
    final abstractUrl = _string(root['AbstractURL']);
    if (abstractUrl != null && abstractUrl.trim().isNotEmpty) {
      hits.add(SearchHit(_string(root['Heading']) ?? abstractUrl, abstractUrl, _string(root['AbstractText']) ?? ''));
    }
    void collect(Object? topics) {
      if (topics is! List) return;
      for (final t in topics) {
        if (t is! Map) continue;
        if (t['Topics'] != null) {
          collect(t['Topics']);
          continue;
        }
        final url = _string(t['FirstURL']);
        if (url == null) continue;
        final text = _string(t['Text']) ?? '';
        final title = text.split(' - ').first;
        hits.add(SearchHit(title.trim().isEmpty ? url : title, url, text));
      }
    }

    collect(root['RelatedTopics']);
    return hits.take(limit).toList();
  }
}

sealed class SearchOutcome {
  const SearchOutcome();
}

class SearchFound extends SearchOutcome {
  const SearchFound(this.provider, this.hits);
  final String provider;
  final List<SearchHit> hits;
}

class SearchFailed extends SearchOutcome {
  const SearchFailed(this.errors);
  final List<String> errors;
}

/// Tries providers in priority order (spec §10.1), retrying each up to [retriesPerProvider]
/// times, and removes duplicate pages. When every provider fails the caller continues with
/// the local model only.
class SearchService {
  SearchService(this.providers, {this.retriesPerProvider = 1, this.limit = 5});

  final List<SearchProvider> providers;
  final int retriesPerProvider;
  final int limit;

  Future<SearchOutcome> search(String query) async {
    final errors = <String>[];
    providers:
    for (final provider in providers) {
      for (var attempt = 0; attempt <= retriesPerProvider; attempt++) {
        try {
          final seen = <String>{};
          final hits = (await provider.search(query, limit * 2))
              .where((h) => seen.add(_normalize(h.url)))
              .take(limit)
              .toList();
          if (hits.isNotEmpty) return SearchFound(provider.name, hits);
          // an empty answer is not an error; retrying the same provider would not help
          errors.add('${provider.name}: no results');
          continue providers;
        } catch (e) {
          errors.add('${provider.name}: $e');
        }
      }
    }
    return SearchFailed(errors);
  }

  static String _normalize(String url) {
    var u = url.toLowerCase();
    if (u.endsWith('/')) u = u.substring(0, u.length - 1);
    return u.replaceFirst(RegExp(r'^https?://(www\.)?'), '');
  }
}
