import 'dart:convert';

/// What a page the model shows (`show`) is made of: the page itself (html, svg), a file of the shared workspace, or
/// a program of this device that serves one on a port. It is kept in the reply as a fenced block
///
/// ```arce-view
/// {"html": "<h1>…"}
/// ```
///
/// so that it is saved with the conversation like any other text, and drawn by the code block of the chat.
/// The page of a file or a port is looked up when it is shown, not when it was written: the address of a page
/// is made by the app each time it runs.
sealed class PageSource {
  const PageSource({this.title = ''});

  /// A few words for the card.
  final String title;
}

/// The text of a page.
class HtmlSource extends PageSource {
  const HtmlSource(this.html, {super.title});
  final String html;
}

/// An SVG picture; it is laid in a plain page.
class SvgSource extends PageSource {
  const SvgSource(this.svg, {super.title});
  final String svg;
}

/// A file of the workspace (`/workspace` of the Linux environment), by the path below it; the page of a folder is its
/// `index.html`.
class WorkspaceSource extends PageSource {
  const WorkspaceSource(this.path, {super.title});
  final String path;
}

/// A page served on this device: `http://127.0.0.1:[port][path]`.
class PortSource extends PageSource {
  const PortSource(this.port, {this.path = '/', super.title});
  final int port;
  final String path;
}

abstract final class PageBlocks {
  /// The language of the fence.
  static const language = 'arce-view';

  /// The ports a program of the user may serve on: below 1024 are the system's.
  static const minPort = 1024;
  static const maxPort = 65535;

  /// The block for [source], as the text the reply holds. Backticks inside the page are written as ```, so that
  /// nothing in a page can close the fence (the text is JSON: the escape is read back as the same character).
  static String encode(PageSource source) {
    final map = <String, Object?>{
      if (source.title.isNotEmpty) 'title': source.title,
      ...switch (source) {
        HtmlSource() => {'html': source.html},
        SvgSource() => {'svg': source.svg},
        WorkspaceSource() => {'workspace': source.path},
        PortSource() => {'port': source.port, if (source.path != '/') 'path': source.path},
      },
    };
    final json = jsonEncode(map).replaceAll('`', '\\u0060');
    return '```$language\n$json\n```';
  }

  /// The page that [code] (the inside of an `arce-view` block) describes, or null when it describes none that is
  /// allowed (not JSON, no source, two sources, a port the user may not serve on, a path that leaves the workspace).
  static PageSource? decode(String code) {
    final Object? decoded;
    try {
      decoded = jsonDecode(code);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final title = decoded['title'] is String ? (decoded['title'] as String).trim() : '';
    final kinds = [for (final key in const ['html', 'svg', 'workspace', 'port']) if (decoded.containsKey(key)) key];
    if (kinds.length != 1) return null;
    switch (kinds.single) {
      case 'html':
        final html = decoded['html'];
        return html is String && html.trim().isNotEmpty ? HtmlSource(html, title: title) : null;
      case 'svg':
        final svg = decoded['svg'];
        return svg is String && svg.trim().isNotEmpty ? SvgSource(svg, title: title) : null;
      case 'workspace':
        final path = cleanWorkspacePath(decoded['workspace']);
        return path == null ? null : WorkspaceSource(path, title: title);
      default:
        final port = decoded['port'];
        final rawPath = decoded['path'];
        if (port is! int || (rawPath != null && rawPath is! String)) return null;
        return portSource(port, rawPath as String? ?? '/', title: title);
    }
  }

  /// The page on [port] at [rawPath], or null when the port is not one the user may serve on or the path is not a plain
  /// path of an address.
  static PortSource? portSource(int port, String rawPath, {String title = ''}) {
    if (port < minPort || port > maxPort) return null;
    final path = _urlPath(rawPath);
    return path == null ? null : PortSource(port, path: path, title: title);
  }

  /// [raw] as a path below the workspace (`site/index.html`), or null when it is not one: empty, not text, with a `..`
  /// or a drive letter or a line break in it, or outside `/workspace` when it is written in full.
  static String? cleanWorkspacePath(Object? raw) {
    if (raw is! String) return null;
    var text = raw.trim().replaceAll('\\', '/');
    if (text.isEmpty || RegExp(r'[\u0000-\u001f]').hasMatch(text)) return null;
    if (text == '/workspace') {
      text = '';
    } else if (text.startsWith('/workspace/')) {
      text = text.substring('/workspace/'.length);
    } else if (text.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(text)) {
      return null;
    }
    final parts = [for (final part in text.split('/')) if (part.isNotEmpty && part != '.') part];
    if (parts.contains('..')) return null;
    return parts.join('/');
  }

  /// A path for an address: it starts with `/`, and has no host, scheme, space or control character.
  static String? _urlPath(String raw) {
    final text = raw.trim().isEmpty ? '/' : raw.trim();
    if (!text.startsWith('/') || text.startsWith('//')) return null;
    if (RegExp(r'[\s\u0000-\u001f\\]').hasMatch(text) || text.contains('@')) return null;
    return text;
  }

  /// The address of a [PortSource] on this device.
  static Uri addressOf(PortSource source) {
    final parsed = Uri.parse('http://127.0.0.1:${source.port}${source.path}');
    return parsed;
  }

  /// An SVG picture in a plain page, to show it like any other page.
  static String pageOfSvg(String svg) =>
      '<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
      '<body style="margin:0;background:#fff;display:flex;justify-content:center">$svg</body>';
}
