import '../core/secret_book.dart';
import '../core/secret_placeholders.dart';

/// A command (or a line typed into a session) after its placeholders were dealt with.
class PreparedCommand {
  const PreparedCommand({
    required this.command,
    this.env = const {},
    this.ids = const [],
    this.idValues = const {},
    this.hostsById = const {},
    this.addresses = const [],
    this.unchecked = false,
    this.problem,
  });

  /// What is run: each `{{secret:ID}}` replaced by a reference to an environment variable (never the value).
  final String command;

  /// Environment variable name -> value, for the process of this one command.
  final Map<String, String> env;

  /// The ids of the secrets that were used, for the approval card and the log.
  final List<String> ids;

  /// id -> value, for taking the values out of what the command printed (see `SecretRedaction`).
  final Map<String, String> idValues;

  /// id -> the hosts that secret is bound to, for the card.
  final Map<String, List<String>> hostsById;

  /// The addresses written in the command, as written.
  final List<String> addresses;

  /// A secret is used and the command has no address written in it (a script file runs, or a tool talks to
  /// a host of its own): where the secret goes cannot be checked here, and the card says so.
  final bool unchecked;

  /// Why the command may not run (an unknown or unusable secret, an address the secret may not go to), or null.
  final String? problem;

  bool get usesSecrets => ids.isNotEmpty;
}

/// Path B: `{{secret:ID}}` in a command that runs in proot.
///
/// The app never puts a value into the text. It rewrites each placeholder into a reference to an environment
/// variable (`${ARCE_SECRET_ID}`) and passes the value in that variable to this one command. The rewrite is
/// made so that it is right wherever the placeholder stands:
///
///  - in the open or in double quotes it expands as it is (in the open it is quoted, so that a value is never
///    split into words or taken for a pattern);
///  - in single quotes, where nothing expands, the quote is closed and opened again around it:
///    `'a{{secret:k}}b'` becomes `'a'"${ARCE_SECRET_K}"'b'`, which is the same string with the value in it
///    (a `$'…'` string, where that trick would change the meaning of the rest, is refused);
///  - in a comment, and in the body of a here-document, it is **not** rewritten: a comment does not run, and
///    a body is a file the command writes: the value must not be written into the workspace, so the text stays
///    as it is (the program that reads the file takes the value from the environment variable).
///
/// proot is not a security boundary: what a program does with the value cannot be checked. What this checks
/// is the text: every address written in it must be one every used secret may be sent to, and a command with no
/// address in it is marked as one whose destination cannot be checked.
abstract final class PlaceholderCommands {
  static final _placeholder = RegExp(r'\{\{\s*secret\s*:\s*([A-Za-z0-9][A-Za-z0-9_.\-]{0,63})\s*\}\}');

  /// An address with a scheme, as it is written (a placeholder inside it is allowed).
  static final _address = RegExp(r'''[a-zA-Z][a-zA-Z0-9+.\-]*://[^\s'"`<>)\]|;,]+''');

  /// Programs that talk to a host named in their arguments.
  static const _networkTools = {
    'curl', 'wget', 'http', 'https', 'xh', 'nc', 'ncat', 'netcat', 'telnet', 'ssh', 'scp', 'sftp', 'rsync', 'ftp',
  };

  /// Options of curl and wget whose next word is a value, not an address.
  static const _valueOptions = {
    '-o', '-h', '-d', '-x', '-u', '-a', '-e', '-b', '-c', '-t', '-f', '-m', '-w', '-p', '-l', '-i',
    '--output', '--header', '--data', '--data-raw', '--data-binary', '--data-urlencode', '--request', '--user',
    '--user-agent', '--referer', '--cookie', '--cookie-jar', '--upload-file', '--form', '--max-time',
    '--connect-timeout', '--write-out', '--output-document', '--post-data', '--post-file', '--tries', '--timeout',
  };

  /// The ends of names that are files, not hosts (`out.json`).
  static const _fileEnds = {
    'json', 'txt', 'py', 'sh', 'js', 'ts', 'md', 'csv', 'log', 'xml', 'html', 'htm', 'yml', 'yaml', 'pdf', 'png', 'jpg',
    'jpeg', 'gif', 'zip', 'gz', 'tar', 'tgz', 'out', 'conf', 'cfg', 'ini', 'toml', 'key', 'pem', 'crt', 'dart', 'kt',
    'java', 'c', 'h', 'cpp', 'rs', 'go', 'rb', 'php', 'sql', 'db', 'bin', 'tmp', 'bak', 'lock', 'env', 'jsonl', 'svg',
  };

  /// The ids written in [text] (lower case, once each).
  static List<String> idsIn(String text) => SecretPlaceholders.idsIn(text);

  /// Deals with the placeholders in [command] (and with [extraIds]: secrets the model named in `secrets`, which
  /// are passed as environment variables without being written in the text). With [onlyIds] (a line typed into a
  /// session that was started with those secrets) a secret outside it is refused: that session's process does not
  /// have it. Nothing named: the same command, no secret.
  static PreparedCommand prepare(
    String command,
    SecretBook book, {
    Iterable<String> extraIds = const [],
    Set<String>? onlyIds,
    bool allowInsecure = false,
  }) {
    final written = idsIn(command);
    final ids = [
      ...written,
      for (final id in extraIds.map((e) => e.toLowerCase()))
        if (!written.contains(id)) id,
    ];
    if (ids.isEmpty) return PreparedCommand(command: command);

    // each id must be known, have a value, a place to go, and be one the model may use
    final problems = <String>[];
    for (final id in ids) {
      final info = book.byId(id);
      if (info == null) {
        final known = book.entries.where((e) => e.modelMayUse).map((e) => e.id).toList();
        problems.add('No secret has the id "$id". ${known.isEmpty ? 'None can be used by a model now.' : 'Available: ${known.join(', ')}.'}');
      } else if (info.unusableReason != null || book.valueOf(id) == null) {
        problems.add('The secret "$id" cannot be used: ${info.unusableReason ?? '値がありません'}.');
      } else if (onlyIds != null && !onlyIds.contains(id)) {
        problems.add('The secret "$id" was not given to this session when it started (give it with a placeholder or in secrets when you start the session).');
      }
    }
    if (problems.isNotEmpty) return PreparedCommand(command: command, ids: ids, problem: '${problems.join(' ')} Nothing was run.');

    final infos = {for (final id in ids) id: book.byId(id)!};
    // two ids can make one variable name (`a-b` and `a.b`): one would take the other's place
    final owner = <String, String>{};
    for (final id in ids) {
      final taken = owner[infos[id]!.envName];
      if (taken != null) {
        return PreparedCommand(
          command: command,
          ids: ids,
          problem: 'The secrets "$taken" and "$id" would be passed under the same variable name ${infos[id]!.envName}; use them in separate commands. Nothing was run.',
        );
      }
      owner[infos[id]!.envName!] = id;
    }
    final env ={for (final id in ids) infos[id]!.envName!: book.valueOf(id)!};
    final idValues = {for (final id in ids) id: book.valueOf(id)!};
    final hostsById = {for (final id in ids) id: infos[id]!.hosts};

    // addresses written in the text: each one must be allowed to every secret used
    final addresses = [
      for (final match in _address.allMatches(command)) match.group(0)!,
    ];
    for (final address in addresses) {
      final checkable = address.replaceAll(_placeholder, 'x');
      for (final id in ids) {
        final why = SecretHosts.problem(checkable, infos[id]!.hosts, allowInsecure: allowInsecure);
        if (why != null) {
          return PreparedCommand(
            command: command,
            ids: ids,
            addresses: addresses,
            problem: 'The secret "$id" may not go with the address $address: $why. Nothing was run.',
          );
        }
      }
    }
    // a network tool given a host with no https:// in front (curl takes it for http): the address cannot be checked
    final bare = _bareHostsAfterNetworkTools(command);
    if (bare.isNotEmpty) {
      return PreparedCommand(
        command: command,
        ids: ids,
        addresses: addresses,
        problem: 'With a secret, write the whole https:// address so that it can be checked (found: ${bare.join(', ')}). Nothing was run.',
      );
    }

    final rewritten = _rewrite(command, (id) => infos[id]?.envName);
    if (rewritten.problem != null) {
      return PreparedCommand(command: command, ids: ids, addresses: addresses, problem: '${rewritten.problem} Nothing was run.');
    }
    return PreparedCommand(
      command: rewritten.text,
      env: env,
      ids: ids,
      idValues: idValues,
      hostsById: hostsById,
      addresses: addresses,
      unchecked: addresses.isEmpty,
    );
  }

  /// The lines the approval card adds to the command (shown with the placeholders as written): which secrets,
  /// where each may go, the addresses found, and a warning when the destination cannot be checked. Null when
  /// no secret is used.
  static String? cardDetails(PreparedCommand prepared) {
    if (!prepared.usesSecrets || prepared.problem != null) return null;
    final lines = <String>[
      '使う秘密：${[for (final id in prepared.ids) '$id（送ってよいホスト：${prepared.hostsById[id]!.join('、')}）'].join('、')}',
      if (prepared.addresses.isNotEmpty) '宛先（コマンドに書かれたもの。すべて、上のホストに入っています）：${prepared.addresses.join('、')}',
      if (prepared.unchecked) '宛先を確かめられません：コマンドに宛先が書かれていません。スクリプトの中身は検査できないので、送り先を、自分で確かめてください',
    ];
    return lines.join('\n');
  }

  // ------------------------------------------------------------------ the rewrite

  /// [text] with each placeholder replaced by a reference to its environment variable, by the rules above.
  static ({String text, String? problem}) _rewrite(String text, String? Function(String id) envOf) {
    final out = StringBuffer();
    var i = 0;
    var state = 0; // 0 open, 1 single quotes, 2 double quotes
    var ansiC = false; // the single quotes of this string opened as $'
    final pending = <(String delimiter, bool stripTabs)>[];

    while (i < text.length) {
      final ch = text[i];

      // the end of a line that opened here-documents: their bodies follow, and are copied as they are
      if (ch == '\n' && state == 0 && pending.isNotEmpty) {
        out.write('\n');
        i++;
        for (final (delimiter, stripTabs) in pending) {
          while (i < text.length) {
            var end = text.indexOf('\n', i);
            if (end < 0) end = text.length;
            final line = text.substring(i, end);
            out.write(line);
            if (end < text.length) out.write('\n');
            i = end < text.length ? end + 1 : end;
            if ((stripTabs ? line.replaceFirst(RegExp(r'^\t+'), '') : line) == delimiter) break;
          }
        }
        pending.clear();
        continue;
      }

      final match = _placeholder.matchAsPrefix(text, i);
      if (match != null) {
        final env = envOf(match.group(1)!.toLowerCase());
        if (env == null) {
          out.write(match.group(0));
        } else if (state == 0) {
          out.write('"\${$env}"');
        } else if (state == 2) {
          out.write('\${$env}');
        } else {
          if (ansiC) {
            return (text: text, problem: 'A secret inside a \$\'…\' string cannot be put in; use double quotes ("…") around it');
          }
          out.write('\'"\${$env}"\'');
        }
        i = match.end;
        continue;
      }

      switch (state) {
        case 0:
          if (ch == '\\' && i + 1 < text.length) {
            out.write(ch);
            out.write(text[i + 1]);
            i += 2;
            continue;
          }
          if (ch == "'") {
            ansiC = i > 0 && text[i - 1] == r'$';
            state = 1;
          } else if (ch == '"') {
            state = 2;
          } else if (ch == '#' && (i == 0 || ' \t\n;|&()'.contains(text[i - 1]))) {
            // a comment runs to the end of the line and is copied as it is
            var end = text.indexOf('\n', i);
            if (end < 0) end = text.length;
            out.write(text.substring(i, end));
            i = end;
            continue;
          } else if (ch == '<' && text.startsWith('<<', i) && !text.startsWith('<<<', i) && (i == 0 || text[i - 1] != '<')) {
            final heredoc = _heredocAt(text, i);
            if (heredoc != null) {
              out.write(text.substring(i, heredoc.end));
              pending.add((heredoc.delimiter, heredoc.stripTabs));
              i = heredoc.end;
              continue;
            }
          }
        case 1:
          if (ch == "'") state = 0;
        case 2:
          if (ch == '\\' && i + 1 < text.length) {
            out.write(ch);
            out.write(text[i + 1]);
            i += 2;
            continue;
          }
          if (ch == '"') state = 0;
      }
      out.write(ch);
      i++;
    }
    return (text: out.toString(), problem: null);
  }

  /// The here-document operator at [at] (`<<EOF`, `<<-'EOF'`, `<< "EOF"`): its delimiter and where it ends.
  static ({String delimiter, bool stripTabs, int end})? _heredocAt(String text, int at) {
    var j = at + 2;
    final stripTabs = j < text.length && text[j] == '-';
    if (stripTabs) j++;
    while (j < text.length && (text[j] == ' ' || text[j] == '\t')) {
      j++;
    }
    if (j >= text.length) return null;
    String delimiter;
    if (text[j] == "'" || text[j] == '"') {
      final quote = text[j];
      final close = text.indexOf(quote, j + 1);
      if (close < 0) return null;
      delimiter = text.substring(j + 1, close);
      j = close + 1;
    } else {
      if (text[j] == '\\') j++;
      final start = j;
      while (j < text.length && RegExp(r'[A-Za-z0-9_]').hasMatch(text[j])) {
        j++;
      }
      delimiter = text.substring(start, j);
    }
    if (delimiter.isEmpty) return null;
    return (delimiter: delimiter, stripTabs: stripTabs, end: j);
  }

  // ------------------------------------------------------------------ hosts written without a scheme

  /// Words after `curl`, `wget`, `ssh` ... that look like a host or an address (`api.example.com`,
  /// `user@host`, `1.2.3.4:80/x`) and have no `scheme://`: curl takes such a word for http. Words that are
  /// options, values of options, files (`out.json`) and parts of quoted headers are not taken.
  static List<String> _bareHostsAfterNetworkTools(String command) {
    final found = <String>[];
    final hostLike = RegExp(r'^([a-z0-9._%+\-]+@)?([a-z0-9\-]+(\.[a-z0-9\-]+)+|localhost)(:\d+)?([/?#].*)?$', caseSensitive: false);
    for (final part in command.replaceAll(_address, ' ').split(RegExp(r'[|;&\n]'))) {
      final words = part.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
      final toolAt = words.indexWhere((w) => _networkTools.contains(w.split('/').last.toLowerCase()));
      if (toolAt < 0) continue;
      var skipNext = false;
      for (final raw in words.sublist(toolAt + 1)) {
        if (skipNext) {
          skipNext = false;
          continue;
        }
        if (raw.startsWith('-')) {
          if (_valueOptions.contains(raw.toLowerCase()) && !raw.contains('=')) skipNext = true;
          continue;
        }
        final word = raw.replaceAll(RegExp(r'''^['"]+|['"]+$'''), '');
        if (word.isEmpty || word.contains('{{') || word.contains(r'$')) continue;
        if (!hostLike.hasMatch(word)) continue;
        final hostPart = word.split(RegExp(r'[/?#]')).first.split('@').last.split(':').first;
        final end = hostPart.split('.').last.toLowerCase();
        if (_fileEnds.contains(end)) continue;
        if (RegExp(r'^[0-9.]+$').hasMatch(hostPart) && hostPart.split('.').length != 4) continue; // a number such as 1.5
        found.add(word);
      }
    }
    return found;
  }
}
