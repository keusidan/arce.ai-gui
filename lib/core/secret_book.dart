import 'secret_placeholders.dart';

/// Where a secret comes from. The value is always in the secure storage; only the model's way to name it is here.
enum SecretKind { own, provider, mcp, search, github }

/// One item that holds a key or a token, as a model may point at it: an id made from its name, a label
/// for people, the hosts it may be sent to. Never the value.
class SecretInfo {
  const SecretInfo({
    required this.id,
    required this.label,
    required this.kind,
    required this.hosts,
    required this.stableKey,
    required this.hasValue,
    required this.modelMayUse,
    this.envName,
  });

  /// `gemini`, `github-token`: made from the name; what goes in `{{secret:ID}}`.
  final String id;
  final String label;
  final SecretKind kind;

  /// Where it may be sent (hosts, `*.example.com`, `*`). Empty: nowhere, so a model cannot use it.
  final List<String> hosts;

  /// `provider:gem`, `mcp:github`, `own:GITHUB_TOKEN`: stays the same when an id has to change
  /// (two items with one name); what the "not for the model" list in the settings keeps.
  final String stableKey;
  final bool hasValue;

  /// Has a value, has somewhere to send it, and the user has not shut it off for the model.
  final bool modelMayUse;

  /// For a command in proot: the environment variable it is passed as (`ARCE_SECRET_<ID>`).
  final String? envName;

  /// Why a model cannot use it, or null when it can.
  String? get unusableReason {
    if (!hasValue) return '値が入っていません';
    if (hosts.isEmpty) return '送ってよいホストが決まっていません';
    if (!modelMayUse) return 'モデルには使わせない設定です';
    return null;
  }
}

/// Every secret by id. The tools ask it for what a model named; it hands out a value only for one the model
/// may use, and only to code that is about to use it.
abstract interface class SecretBook {
  List<SecretInfo> get entries;

  SecretInfo? byId(String id);

  /// The value of [id], or null when there is none or the model may not use it.
  String? valueOf(String id);
}

/// A book with nothing in it (a test, or an app with no key set).
class EmptySecretBook implements SecretBook {
  const EmptySecretBook();

  @override
  List<SecretInfo> get entries => const [];

  @override
  SecretInfo? byId(String id) => null;

  @override
  String? valueOf(String id) => null;
}

/// What the registry reads, as plain values (so it is built without the stores and tested without them).
class SecretSource {
  const SecretSource({
    required this.kind,
    required this.name,
    required this.source,
    required this.hosts,
    required this.value,
  });

  final SecretKind kind;

  /// The name an id is made from (a provider's label, an MCP server's name, the secret's own name).
  final String name;

  /// The id of the thing in its own list (the provider's id ...): `stableKey` is `kind:source`.
  final String source;
  final List<String> hosts;
  final String value;
}

/// The book made from a list of sources, plus the keys the user shut off for the model.
class SecretRegistry implements SecretBook {
  SecretRegistry(List<SecretSource> sources, {Set<String> off = const {}}) : _values = {} {
    final taken = <String>[];
    final entries = <SecretInfo>[];
    for (final source in sources) {
      final fallback = switch (source.kind) {
        SecretKind.own => 'secret',
        SecretKind.provider => 'provider',
        SecretKind.mcp => 'mcp',
        SecretKind.search => 'search',
        SecretKind.github => 'github-token',
      };
      final id = SecretIds.fromName(source.name, fallback: fallback, taken: taken);
      taken.add(id);
      final key = '${source.kind.name}:${source.source}';
      final hasValue = source.value.isNotEmpty;
      final hosts = [for (final host in source.hosts) if (host.trim().isNotEmpty) host.trim()];
      final info = SecretInfo(
        id: id,
        label: source.name,
        kind: source.kind,
        hosts: hosts,
        stableKey: key,
        hasValue: hasValue,
        modelMayUse: hasValue && hosts.isNotEmpty && !off.contains(key),
        envName: 'ARCE_SECRET_${id.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '_')}',
      );
      entries.add(info);
      if (info.modelMayUse) _values[id] = source.value;
    }
    this.entries = List.unmodifiable(entries);
  }

  final Map<String, String> _values;

  @override
  late final List<SecretInfo> entries;

  @override
  SecretInfo? byId(String id) {
    final wanted = id.toLowerCase();
    for (final entry in entries) {
      if (entry.id == wanted) return entry;
    }
    return null;
  }

  @override
  String? valueOf(String id) => _values[id.toLowerCase()];

  /// The host of an address, for a source's host list; null when it has none or cannot be read.
  static String? hostOfUrl(String url) {
    final host = SecretHosts.normalizeHost(Uri.tryParse(url.trim())?.host ?? '');
    return host;
  }
}
