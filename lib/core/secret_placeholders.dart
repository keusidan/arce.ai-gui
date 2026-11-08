import 'dart:convert';
import 'dart:io' show InternetAddress, InternetAddressType;

/// Ids made from names: every item that holds a key or a token gets one, so a model can point at it
/// (`{{secret:gemini}}`) without ever seeing what is in it.
abstract final class SecretIds {
  /// `Gemini (無料枠)` -> `gemini`; a name with no letter or digit of ours (a Japanese name) -> ''.
  static String slug(String name) => _fullWidthToHalf(name)
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');

  /// [base] if nobody has it, else `base-2`, `base-3` ...
  static String unique(String base, Iterable<String> taken) {
    final used = taken.toSet();
    if (!used.contains(base)) return base;
    for (var n = 2;; n++) {
      final candidate = '$base-$n';
      if (!used.contains(candidate)) return candidate;
    }
  }

  /// The id of an item called [name]; [fallback] (`provider`, `mcp` ...) when the name has nothing to make
  /// an id of.
  static String fromName(String name, {required String fallback, required Iterable<String> taken}) {
    final stem = slug(name);
    return unique(stem.isEmpty ? fallback : stem, taken);
  }

  static String _fullWidthToHalf(String text) => String.fromCharCodes([
        for (final unit in text.runes)
          if (unit >= 0xff01 && unit <= 0xff5e) unit - 0xfee0 else if (unit == 0x3000) 0x20 else unit,
      ]);

  /// The shape of an id that may appear in a placeholder.
  static final valid = RegExp(r'^[a-z0-9][a-z0-9_.\-]{0,63}$');
}

/// `{{secret:NAME}}` in a text a model wrote. The model writes the name; the app puts the value in at the
/// moment of use and nowhere else.
abstract final class SecretPlaceholders {
  static final _pattern = RegExp(r'\{\{\s*secret\s*:\s*([A-Za-z0-9][A-Za-z0-9_.\-]{0,63})\s*\}\}');

  static bool hasAny(String text) => _pattern.hasMatch(text);

  /// The ids in [text], lower-case, each once, in the order they appear.
  static List<String> idsIn(String text) {
    final out = <String>[];
    for (final match in _pattern.allMatches(text)) {
      final id = match.group(1)!.toLowerCase();
      if (!out.contains(id)) out.add(id);
    }
    return out;
  }

  /// [text] with each placeholder replaced by what [valueOf] says (a placeholder it does not know is left
  /// as it is: the caller has refused such a text before it got here).
  static String substitute(String text, String? Function(String id) valueOf) =>
      text.replaceAllMapped(_pattern, (match) => valueOf(match.group(1)!.toLowerCase()) ?? match.group(0)!);
}

/// Where a secret may be sent. A secret is bound to hosts the user chose; anything else is refused before a
/// byte leaves. Every rule here has a test with the way an attacker would write the address.
abstract final class SecretHosts {
  /// Why [url] may not carry a secret to [allowed] hosts, or null when it may. With a secret the address
  /// must be https (http only when [allowInsecure]), plain (no user name, no odd characters, no encoded or
  /// non-ASCII host), not an address inside the device or the local network, and its host must be one of
  /// [allowed].
  static String? problem(String url, List<String> allowed, {bool allowInsecure = false}) {
    final text = url.trim();
    if (text.isEmpty) return 'the address is empty';
    if (RegExp(r'[\s\\\u0000-\u001f\u007f]').hasMatch(text)) return 'the address has a space, a backslash or a control character';
    final uri = Uri.tryParse(text);
    if (uri == null || !uri.hasScheme) return 'the address is not a full URL (https://…)';
    // an encoded character in the part before the path (%2e for a dot, %40 for @): another reader of the same
    // text may take it differently, so it is not accepted at all
    final afterScheme = text.contains('://') ? text.substring(text.indexOf('://') + 3) : '';
    final authority = afterScheme.split(RegExp(r'[/?#]')).first;
    if (authority.contains('%')) return 'the host of the address has an encoded character (%…)';
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'https' && !(allowInsecure && scheme == 'http')) {
      return scheme == 'http' ? 'http (not encrypted) is not allowed with a secret' : 'only https addresses may carry a secret';
    }
    if (uri.userInfo.isNotEmpty) return 'the address carries a user name (user@host): the real host is not the one that looks like it';
    final host = normalizeHost(uri.host);
    if (host == null) return 'the host of the address is empty or written in a way that is not accepted';
    if (isPrivate(host)) return 'the host ($host) is inside this device or its network';
    if (!allows(host, allowed)) return 'the secret may not be sent to $host (allowed: ${allowed.isEmpty ? 'none' : allowed.join(', ')})';
    return null;
  }

  /// The host in lower case without the dot of a full name, or null for one that is empty or has anything
  /// but letters, digits, dots, hyphens (and the colons of an IPv6 address).
  static String? normalizeHost(String host) {
    var h = host.trim().toLowerCase();
    while (h.endsWith('.')) {
      h = h.substring(0, h.length - 1);
    }
    if (h.isEmpty) return null;
    if (h.contains(':')) return RegExp(r'^[0-9a-f:.]+$').hasMatch(h) ? h : null; // an IPv6 literal
    return RegExp(r'^[a-z0-9]([a-z0-9\-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9\-]*[a-z0-9])?)*$').hasMatch(h) ? h : null;
  }

  /// Whether [host] (already normalized) is one of [allowed]: the same name, `*.example.com` for any name
  /// under it (not example.com itself), or `*` for any. An entry may be written as a URL.
  static bool allows(String host, List<String> allowed) {
    for (final raw in allowed) {
      var entry = raw.trim().toLowerCase();
      if (entry.isEmpty) continue;
      if (entry == '*') return true;
      if (entry.contains('://')) entry = normalizeHost(Uri.tryParse(entry)?.host ?? '') ?? '';
      if (entry.isEmpty) continue;
      if (entry.startsWith('*.')) {
        final suffix = entry.substring(1); // .example.com
        if (host.endsWith(suffix) && host.length > suffix.length) return true;
      } else if (normalizeHost(entry) == host) {
        return true;
      }
    }
    return false;
  }

  /// Inside the device or the local network, or written so that it cannot be told: `localhost`, a name with
  /// no dot, `.local`/`.internal`/`.lan`, loopback, private, link-local, shared and reserved IPv4 and IPv6
  /// addresses, and numbers written as one integer, in hex or in octal (which a client may read as an address).
  static bool isPrivate(String host) {
    final h = host.toLowerCase();
    if (h == 'localhost' || h.endsWith('.localhost')) return true;
    if (h.contains(':')) return _privateV6(h);
    if (RegExp(r'^[0-9a-fx.]+$').hasMatch(h) && RegExp(r'^[0-9x]').hasMatch(h) && !RegExp(r'^[a-f]+$').hasMatch(h)) {
      // looks like a number: only a plain dotted quad of decimal numbers is read as one; anything else is refused
      final parts = h.split('.');
      final plain = parts.length == 4 && parts.every((p) => RegExp(r'^(0|[1-9][0-9]{0,2})$').hasMatch(p) && int.parse(p) <= 255);
      if (!plain) return true;
      return _privateV4([for (final p in parts) int.parse(p)]);
    }
    if (!h.contains('.')) return true; // a single name: a machine of the local network
    for (final suffix in const ['.local', '.internal', '.lan', '.home', '.corp', '.intranet', '.private']) {
      if (h.endsWith(suffix)) return true;
    }
    return false;
  }

  static bool _privateV4(List<int> o) {
    final a = o[0];
    final b = o[1];
    return a == 0 ||
        a == 10 ||
        a == 127 ||
        (a == 100 && b >= 64 && b <= 127) ||
        (a == 169 && b == 254) ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && b == 0 && o[2] == 0) ||
        (a == 192 && b == 168) ||
        (a == 198 && (b == 18 || b == 19)) ||
        a >= 224;
  }

  static bool _privateV6(String h) {
    final address = InternetAddress.tryParse(h);
    if (address == null || address.type != InternetAddressType.IPv6) return true; // not an address we can read: refuse
    final bytes = address.rawAddress;
    if (bytes.every((b) => b == 0)) return true; // ::
    if (bytes.sublist(0, 15).every((b) => b == 0) && bytes[15] == 1) return true; // ::1
    if ((bytes[0] & 0xfe) == 0xfc) return true; // fc00::/7 unique local
    if (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80) return true; // fe80::/10 link local
    if (bytes[0] == 0xff) return true; // multicast
    // ::ffff:a.b.c.d (an IPv4 address in IPv6 clothes) and the deprecated ::a.b.c.d
    final mapped = bytes.sublist(0, 10).every((b) => b == 0) && bytes[10] == 0xff && bytes[11] == 0xff;
    final compatible = bytes.sublist(0, 12).every((b) => b == 0);
    if (mapped || compatible) return _privateV4([bytes[12], bytes[13], bytes[14], bytes[15]]);
    return false;
  }

  /// The hosts of the `http://…` and `https://…` addresses written in [text] (a command, a script line),
  /// lower case, each once. Hosts that cannot be read are returned as they are written, so that the caller
  /// refuses them. It finds what is written plainly; it cannot see an address a script builds.
  static List<String> hostsInText(String text) {
    final out = <String>[];
    for (final match in RegExp(r'''[a-zA-Z][a-zA-Z0-9+.\-]*://[^\s'"`<>)\]}|;,]+''').allMatches(text)) {
      final raw = match.group(0)!;
      final uri = Uri.tryParse(raw);
      final host = uri == null || uri.host.isEmpty ? raw : (normalizeHost(uri.host) ?? uri.host);
      if (!out.contains(host)) out.add(host);
    }
    return out;
  }
}

/// Takes the values of secrets out of a text, in the forms they turn up in: as they are, URL-encoded,
/// escaped for JSON (also with `\/` and with `\uXXXX`), as HTML entities, in hex, and in base64 (both
/// alphabets, with and without padding, and at the three alignments a value may have inside a longer
/// base64 text). A value that was cut, mixed with other text or encoded some other way is not found: this
/// is for a command that prints its environment or a server that echoes a header, not for a program that
/// hides what it does.
///
/// The forms and the cut-off tail follow what the open-source agent credential proxies check (CrimsonWorks
/// agent-vault: encodings, base64 at 3 alignments, a secret split at a chunk boundary).
abstract final class SecretRedaction {
  /// A value shorter than this is not looked for: it would mangle ordinary text.
  static const minLength = 4;

  /// A piece of a base64 text (a value in the middle of a longer one) is looked for only when it is this
  /// long: a short piece would turn up in ordinary text.
  static const minAlignedLength = 8;

  /// The forms of [value] that are looked for, longest first.
  static List<String> variants(String value) {
    if (value.length < minLength) return const [];
    final bytes = utf8.encode(value);
    final standard = base64.encode(bytes);
    final url = base64Url.encode(bytes);
    final escaped = jsonEncode(value).substring(1, jsonEncode(value).length - 1);
    final forms = <String>{
      value,
      Uri.encodeComponent(value),
      Uri.encodeQueryComponent(value),
      escaped,
      escaped.replaceAll('/', r'\/'),
      standard,
      standard.replaceAll('=', ''),
      url,
      url.replaceAll('=', ''),
      _unicodeEscaped(value),
      _hex(bytes, upper: false),
      _hex(bytes, upper: true),
      [for (final rune in value.runes) '&#$rune;'].join(),
      [for (final rune in value.runes) '&#x${rune.toRadixString(16)};'].join(),
    }..removeWhere((form) => form.length < minLength);
    for (final alphabet in [base64, base64Url]) {
      for (final offset in [0, 1, 2]) {
        final piece = _alignedBase64(alphabet, bytes, offset);
        if (piece.length >= minAlignedLength) forms.add(piece);
      }
    }
    // the longest first, so that a form that contains another is replaced whole
    return forms.toList()..sort((a, b) => b.length.compareTo(a.length));
  }

  static String _unicodeEscaped(String value) {
    final b = StringBuffer();
    for (final unit in value.codeUnits) {
      b.write('\\u${unit.toRadixString(16).padLeft(4, '0')}');
    }
    return b.toString();
  }

  static String _hex(List<int> bytes, {required bool upper}) {
    final text = [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')].join();
    return upper ? text.toUpperCase() : text;
  }

  /// The base64 characters that are the same whatever bytes come before and after [bytes] when [bytes] start
  /// [offset] bytes into a group of three: the characters that mix in a neighbour's bits are left out.
  static String _alignedBase64(Codec<List<int>, String> alphabet, List<int> bytes, int offset) {
    final text = alphabet.encode([...List.filled(offset, 0), ...bytes]).replaceAll('=', '');
    final head = const [0, 2, 3][offset]; // the characters that hold the padding bytes' bits
    final tail = (bytes.length + offset) % 3 == 0 ? 0 : 1; // the last character holds bits of the next byte
    if (text.length <= head + tail) return '';
    return text.substring(head, text.length - tail);
  }

  /// [text] with every form of every value of [idToValue] replaced by `[secret:<id>]`. With [trimTail], a
  /// tail of [text] that is the beginning of a form (a value that was cut off, or that is still being written)
  /// is removed too: the rest of it may come in the next piece, and the two halves must not be put together
  /// by whoever reads them.
  static String redact(String text, Map<String, String> idToValue, {bool trimTail = false}) {
    var out = text;
    final all = <(String, String)>[
      for (final entry in idToValue.entries)
        for (final form in variants(entry.value)) (form, entry.key),
    ]..sort((a, b) => b.$1.length.compareTo(a.$1.length));
    for (final (form, id) in all) {
      out = out.replaceAll(form, '[secret:$id]');
    }
    if (!trimTail) return out;
    var cut = 0;
    for (final (form, _) in all) {
      final most = form.length - 1 < out.length ? form.length - 1 : out.length;
      for (var k = most; k >= minLength && k > cut; k--) {
        if (out.endsWith(form.substring(0, k))) {
          cut = k;
          break;
        }
      }
    }
    return cut == 0 ? out : out.substring(0, out.length - cut);
  }
}
