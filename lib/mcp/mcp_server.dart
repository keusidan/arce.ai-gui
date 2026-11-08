/// One MCP server the user added, as it is stored in the settings document.
///
/// The token is not here: it lives in the platform's secure storage under
/// `mcp_token_<id>` ([tokenRef]), so a settings file or a backup never carries it.
class McpServerConfig {
  const McpServerConfig({
    required this.id,
    required this.name,
    required this.url,
    this.enabled = true,
    this.approveWrites = true,
  });

  /// Stable id, also part of every tool name (`mcp_<id>__<tool>`). Never contains `__`.
  final String id;

  /// What the settings screen shows.
  final String name;

  /// The Streamable HTTP endpoint.
  final String url;
  final bool enabled;

  /// Ask the user before running a tool that changes something outside the device.
  final bool approveWrites;

  String get tokenRef => 'mcp_token_$id';

  bool get isComplete =>
      id.trim().isNotEmpty &&
      url.trim().isNotEmpty &&
      (Uri.tryParse(url.trim())?.hasScheme ?? false);

  McpServerConfig copyWith({
    String? name,
    String? url,
    bool? enabled,
    bool? approveWrites,
  }) => McpServerConfig(
    id: id,
    name: name ?? this.name,
    url: url ?? this.url,
    enabled: enabled ?? this.enabled,
    approveWrites: approveWrites ?? this.approveWrites,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'url': url,
    'enabled': enabled,
    'approveWrites': approveWrites,
  };

  factory McpServerConfig.fromJson(Map<String, Object?> json) {
    String text(String key) => json[key] is String ? json[key]! as String : '';
    return McpServerConfig(
      id: text('id'),
      name: text('name'),
      url: text('url'),
      enabled: json['enabled'] is bool ? json['enabled']! as bool : true,
      approveWrites: json['approveWrites'] is bool
          ? json['approveWrites']! as bool
          : true,
    );
  }
}

/// Helpers for the list of servers in the settings document.
abstract final class McpServers {
  /// A readable id from the name; `__` is reserved for splitting tool names, so it never appears.
  static String idFor(String name, Iterable<McpServerConfig> existing) {
    final stem = name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '')
        .replaceAll('_', '-');
    final base = stem.isEmpty ? 'mcp' : stem;
    final taken = {for (final server in existing) server.id};
    if (!taken.contains(base)) return base;
    for (var n = 2; ; n++) {
      final candidate = '$base-$n';
      if (!taken.contains(candidate)) return candidate;
    }
  }

  static List<McpServerConfig> decode(Object? raw) {
    if (raw is! List) return const [];
    final out = <McpServerConfig>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final config = McpServerConfig.fromJson(entry.cast<String, Object?>());
      if (config.id.trim().isEmpty || config.id.contains('__')) continue;
      out.add(config);
    }
    return out;
  }
}
