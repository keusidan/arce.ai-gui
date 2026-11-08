/// The address to open for a link that came from a model, a search result or a web page: only a
/// web address. Other schemes would start another app (`intent:`, `tel:`, `sms:`), read a file
/// (`file:`) or run a script (`javascript:`), and a link in a reply is not something the user wrote.
///
/// Returns null for anything else. Text around the address (spaces, line breaks, control characters)
/// is removed; an address with a user name (`https://good.example@evil.example/`, a way to make a
/// bad host look like a good one) is refused.
Uri? safeWebUri(String? raw) {
  if (raw == null) return null;
  final text = raw.replaceAll(RegExp(r'[\u0000-\u001f\u007f\s]'), '');
  if (text.isEmpty || text.length > 4096) return null;
  final uri = Uri.tryParse(text);
  if (uri == null) return null;
  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return null;
  if (uri.host.isEmpty || uri.userInfo.isNotEmpty) return null;
  return uri;
}

/// Whether a key or token sent to [url] would travel in the clear: `http://` to a host that is not on
/// the device or on a home network (localhost, 127.x, 10.x, 192.168.x, 172.16-31.x, `*.local`, a plain
/// name without a dot). Anyone on the path (a café's Wi-Fi) can read it. `https://` and a server in
/// the house are fine; anything else is worth a warning, not a refusal (the user may know better).
bool sendsSecretsInTheClear(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || uri.scheme.toLowerCase() != 'http' || uri.host.isEmpty) return false;
  final host = uri.host.toLowerCase();
  if (host == 'localhost' || host.endsWith('.local') || host.endsWith('.lan') || host.endsWith('.home.arpa')) return false;
  if (!host.contains('.') && !host.contains(':')) return false; // a name of the local network
  final v4 = RegExp(r'^(\d+)\.(\d+)\.(\d+)\.(\d+)$').firstMatch(host);
  if (v4 != null) {
    final a = int.parse(v4.group(1)!);
    final b = int.parse(v4.group(2)!);
    if (a == 127 || a == 10 || (a == 192 && b == 168) || (a == 172 && b >= 16 && b <= 31) || (a == 169 && b == 254)) return false;
    return true;
  }
  if (host == '::1' || host.startsWith('fe80:') || host.startsWith('fc') || host.startsWith('fd')) return false;
  return true;
}
