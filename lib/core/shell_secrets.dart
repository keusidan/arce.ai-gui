/// A secret a command may be given as an environment variable (`GITHUB_TOKEN`, `NPM_TOKEN` ...).
///
/// Only the name, and where the value comes from, is a setting. The value itself is in the secure
/// storage like every key and token of the app: never in the settings JSON, a backup or the chat. It
/// is [mcpServerId] when the secret is the token already typed for an MCP server (so one token serves
/// the server and the commands), and an own value otherwise.
class ShellSecret {
  const ShellSecret({required this.name, this.mcpServerId = '', this.hosts = const []});

  /// The variable the command sees.
  final String name;

  /// The MCP server whose token is the value; empty for a value of its own.
  final String mcpServerId;

  /// The hosts this secret may be sent to when a model uses it by its placeholder (`{{secret:ID}}`): names,
  /// `*.example.com`, or `*` (anywhere; the settings screen warns). Empty: a model cannot use it that way.
  final List<String> hosts;

  bool get fromMcp => mcpServerId.isNotEmpty;

  Map<String, Object?> toJson() => {'name': name, if (fromMcp) 'mcpServerId': mcpServerId, if (hosts.isNotEmpty) 'hosts': hosts};

  static ShellSecret? fromJson(Object? json) {
    if (json is! Map) return null;
    final name = json['name'];
    if (name is! String || !ShellSecrets.validName(name)) return null;
    final server = json['mcpServerId'];
    final hosts = json['hosts'];
    return ShellSecret(
      name: name,
      mcpServerId: server is String ? server : '',
      hosts: [if (hosts is List) for (final h in hosts) if (h is String && h.trim().isNotEmpty) h.trim()],
    );
  }
}

/// What the app does around a secret that a command was given.
///
/// proot is not a security boundary: a command that has a secret can send it anywhere the
/// network reaches. So a secret is never there unless the user approved *that command* with the names
/// shown on the card, and the model only ever sees names, never values. Redaction below is for the
/// accident (a command that prints its environment); it does not stop a command that encodes the
/// value first, and nothing here pretends it does.
abstract final class ShellSecrets {
  /// Variables the app sets itself, or that change how a program loads: a secret may not take them.
  static const reserved = {
    'HOME', 'PATH', 'LANG', 'TERM', 'TMPDIR', 'SHELL', 'USER', 'PWD',
    'PROOT_LOADER', 'PROOT_TMP_DIR', 'PROOT_NO_SECCOMP', 'LD_PRELOAD', 'LD_LIBRARY_PATH', 'BASH_ENV', 'ENV',
  };

  static final _name = RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,63}$');

  static bool validName(String name) => _name.hasMatch(name) && !reserved.contains(name.toUpperCase());

  /// A value shorter than this is not replaced in the output: it would mangle ordinary text.
  static const minRedactLength = 4;

  /// [text] with every value of [values] (name -> value) replaced by `[name]`.
  static String redact(String text, Map<String, String> values) {
    var out = text;
    // the longest first, so a value that contains another one is replaced whole
    final entries = values.entries.where((e) => e.value.length >= minRedactLength).toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));
    for (final entry in entries) {
      out = out.replaceAll(entry.value, '[${entry.key}]');
    }
    return out;
  }

  /// The names a tool call asked for (`secrets`): strings, trimmed, each once; null when the argument
  /// is not a list of strings.
  static List<String>? names(Object? raw) {
    if (raw == null) return const [];
    if (raw is! List) return null;
    final out = <String>[];
    for (final item in raw) {
      if (item is! String) return null;
      final name = item.trim();
      if (name.isNotEmpty && !out.contains(name)) out.add(name);
    }
    return out;
  }
}
