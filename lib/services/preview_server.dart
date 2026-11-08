import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

/// Serves generated HTML on 127.0.0.1 so it can be opened in the system browser on every
/// platform. The page runs in a sandboxed origin, so it cannot reach other local pages or
/// the app itself.
///
/// Any other app on the device can connect to a port on 127.0.0.1, so a page is reachable only by its
/// address, and the address holds 128 random bits (it used to be a counter: `/p/0`, `/p/1` ...,
/// which another app could simply walk through to read the code and text of every page). Requests
/// that name another host (a web page that makes its own name point at 127.0.0.1) are refused, and
/// only the newest [maxPages] pages are kept.
class PreviewServer {
  PreviewServer({this.maxPages = 50, this.maxFileBytes = 20 * 1024 * 1024});

  /// How many pages are kept; the oldest goes when there are more.
  int maxPages;

  /// The largest file of a folder that is served (see [publishFolder]); a bigger one is refused.
  int maxFileBytes;

  HttpServer? _server;
  final _pages = <String, String>{}; // keeps the order they were published in
  final _folders = <String, Directory>{}; // the folders served by [publishFolder], in the order they were published
  final _random = Random.secure();

  Future<Uri> publish(String html) async {
    final server = _server ??= await _start();
    final id = _newId();
    _pages[id] = html;
    while (_pages.length > (maxPages < 1 ? 1 : maxPages)) {
      _pages.remove(_pages.keys.first);
    }
    return Uri(scheme: 'http', host: '127.0.0.1', port: server.port, path: '/p/$id');
  }

  /// Serves the folder [root] (a folder of the workspace) read only, and returns the address of [entry], a file in it.
  /// What the page of it asks for next (its style, its script, its pictures) is answered from the same folder, but
  /// only from inside it: a path that leaves it (`..`, a link that points out of it), a hidden file or folder (a name
  /// that starts with a dot: the settings and keys of a program live there) and a file larger than [maxFileBytes] are
  /// refused. Like a page, the address holds 128 random bits and is kept while the newest [maxPages] are.
  Future<Uri> publishFolder(Directory root, String entry) async {
    final server = _server ??= await _start();
    final id = _newId();
    _folders[id] = root;
    while (_folders.length > (maxPages < 1 ? 1 : maxPages)) {
      _folders.remove(_folders.keys.first);
    }
    return Uri(scheme: 'http', host: '127.0.0.1', port: server.port, pathSegments: ['w', id, ...p.posix.split(entry)]);
  }

  /// The file [segments] name below [root], or null when the request may not have it (see [publishFolder]).
  File? _fileIn(Directory root, List<String> segments) {
    if (segments.any((s) => s.isEmpty || s == '.' || s == '..' || s.startsWith('.') || s.contains('\\') || s.contains('\u0000'))) return null;
    try {
      final rootReal = root.resolveSymbolicLinksSync();
      var path = p.joinAll([rootReal, ...segments]);
      if (FileSystemEntity.isDirectorySync(path)) path = p.join(path, 'index.html');
      final file = File(path);
      if (!file.existsSync()) return null;
      final real = file.resolveSymbolicLinksSync(); // a link that leads out of the folder is refused here
      if (!p.isWithin(rootReal, real)) return null;
      if (File(real).lengthSync() > maxFileBytes) return null;
      return File(real);
    } on FileSystemException {
      return null;
    }
  }

  static const _types = {
    'html': 'text/html; charset=utf-8',
    'htm': 'text/html; charset=utf-8',
    'css': 'text/css; charset=utf-8',
    'js': 'text/javascript; charset=utf-8',
    'mjs': 'text/javascript; charset=utf-8',
    'json': 'application/json; charset=utf-8',
    'txt': 'text/plain; charset=utf-8',
    'md': 'text/plain; charset=utf-8',
    'svg': 'image/svg+xml',
    'png': 'image/png',
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'gif': 'image/gif',
    'webp': 'image/webp',
    'ico': 'image/x-icon',
    'woff': 'font/woff',
    'woff2': 'font/woff2',
    'wasm': 'application/wasm',
  };

  String _newId() => [for (var i = 0; i < 16; i++) _random.nextInt(256).toRadixString(16).padLeft(2, '0')].join();

  Future<HttpServer> _start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final segments = request.uri.pathSegments;
      final response = request.response;
      if ((request.method != 'GET' && request.method != 'HEAD') || request.headers.host != '127.0.0.1') {
        response
          ..statusCode = HttpStatus.notFound
          ..close();
        return;
      }
      response
        ..headers.set('X-Content-Type-Options', 'nosniff')
        ..headers.set('Cache-Control', 'no-store')
        ..headers.set('Referrer-Policy', 'no-referrer')
        // no allow-same-origin: the page gets an opaque origin of its own
        ..headers.set('Content-Security-Policy', 'sandbox allow-scripts allow-forms allow-modals allow-popups');
      if (segments.length == 2 && segments.first == 'p' && _pages[segments[1]] != null) {
        response
          ..headers.contentType = ContentType('text', 'html', charset: 'utf-8')
          ..add(utf8.encode(_pages[segments[1]]!))
          ..close();
        return;
      }
      if (segments.length >= 3 && segments.first == 'w' && _folders[segments[1]] != null) {
        // `/w/<token>/` is the folder itself: its index.html
        final names = segments.last.isEmpty ? segments.sublist(2, segments.length - 1) : segments.sublist(2);
        final file = _fileIn(_folders[segments[1]]!, names);
        if (file != null) {
          final extension = p.extension(file.path).replaceFirst('.', '').toLowerCase();
          response.headers.set('Content-Type', _types[extension] ?? 'application/octet-stream');
          try {
            if (request.method == 'GET') await response.addStream(file.openRead());
          } on FileSystemException {
            // gone while it was read: the answer ends where it is
          }
          await response.close();
          return;
        }
      }
      response
        ..statusCode = HttpStatus.notFound
        ..close();
    });
    return server;
  }

  Future<void> dispose() async {
    await _server?.close(force: true);
    _server = null;
    _pages.clear();
    _folders.clear();
  }
}

/// The files of the workspace that `show` may put on the screen, and where to serve them from.
abstract final class WorkspacePages {
  /// What may be shown: pages and pictures. Any other file is not a page.
  static const shownExtensions = {'html', 'htm', 'svg', 'png', 'jpg', 'jpeg', 'gif', 'webp'};

  /// The folder to serve and the file in it to open for [clean] (a path below [workspace], see
  /// `PageBlocks.cleanWorkspacePath`): the file itself, or the `index.html` of a folder. Null when there is no such page,
  /// when it is not a kind that is shown, when a name on the way is hidden (starts with a dot), or when a link leads out
  /// of the workspace. A page is served from the folder it is in, so its style, script and pictures beside it come with it.
  static ({Directory root, String entry})? resolve(Directory workspace, String clean) {
    try {
      final parts = clean.isEmpty ? <String>[] : clean.split('/');
      if (parts.any((part) => part.startsWith('.'))) return null;
      final rootReal = workspace.resolveSymbolicLinksSync();
      final target = p.joinAll([rootReal, ...parts]);
      final page = FileSystemEntity.isDirectorySync(target) ? p.join(target, 'index.html') : target;
      if (!File(page).existsSync()) return null;
      final real = File(page).resolveSymbolicLinksSync();
      if (!p.isWithin(rootReal, real)) return null;
      if (!shownExtensions.contains(p.extension(real).replaceFirst('.', '').toLowerCase())) return null;
      return (root: Directory(p.dirname(real)), entry: p.basename(real));
    } on FileSystemException {
      return null;
    }
  }
}
