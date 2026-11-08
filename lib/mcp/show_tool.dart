import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/page_blocks.dart';
import '../core/protocol.dart';
import '../core/tool_runtime.dart';
import '../services/preview_server.dart' show WorkspacePages;

/// What `show` reads from the settings.
class ShowSettings {
  const ShowSettings({this.enabled = true, this.maxChars = 200000});

  /// Whether the tool is offered at all.
  final bool enabled;

  /// The longest page (html or svg text) a call may carry; a longer one is written to a file and shown by its path.
  final int maxChars;
}

/// Puts a page on the user's screen, inside the chat: the page itself, a file or folder of the
/// workspace, or a program of this device that serves a page on a port. The answer is a card in the reply that the user
/// opens with a button (or by itself, when they have said so in the settings); this tool shows nothing by itself, and
/// everything it hands over is checked here, because it is what a model wrote.
class ShowTool {
  ShowTool({required this.settings, this.workspace, Future<bool> Function(int port)? probe}) : _probe = probe ?? _listening;

  final ShowSettings settings;

  /// The folder the Linux environment sees as `/workspace`; null where there is none (only Android has one).
  final Directory? workspace;

  final Future<bool> Function(int port) _probe;

  static const shownExtensions = WorkspacePages.shownExtensions;

  ToolDefinition? definition() => settings.enabled ? Protocol.show : null;

  static Future<bool> _listening(int port) async {
    try {
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, port, timeout: const Duration(milliseconds: 1500));
      socket.destroy();
      return true;
    } on Object {
      return false;
    }
  }

  Future<ToolOutcome> run(Map<String, Object?> arguments) async {
    if (!settings.enabled) return _refuse('show is turned off in the settings.', '設定でオフです');
    final title = '${arguments['title'] ?? ''}';
    final html = arguments['html'];
    final svg = arguments['svg'];
    final path = arguments['path'];
    final port = arguments['port'];
    if (html is String) {
      if (html.length > settings.maxChars) return _tooLong(html.length);
      return _shown(HtmlSource(html, title: title), '${html.length} 文字のページ');
    }
    if (svg is String) {
      if (svg.length > settings.maxChars) return _tooLong(svg.length);
      if (!svg.contains('<svg')) return _refuse('That is not an SVG: it has no <svg> element.', 'SVG ではありません');
      return _shown(SvgSource(svg, title: title), '${svg.length} 文字の SVG');
    }
    if (path is String) return _showPath(path, title);
    if (port is int) return _showPort(port, '${arguments['url_path'] ?? '/'}', title);
    return _refuse('Give exactly one of html, svg, path or port.', '内容がありません');
  }

  Future<ToolOutcome> _showPath(String raw, String title) async {
    final root = workspace;
    if (root == null) {
      return _refuse('There is no workspace on this device (the Linux environment is on Android only): give html or svg instead.', 'ワークスペースがありません');
    }
    final clean = PageBlocks.cleanWorkspacePath(raw);
    if (clean == null) {
      return _refuse('"$raw" is not a path below /workspace (no "..", nothing outside it).', 'パスが読めません');
    }
    final parts = clean.split('/');
    if (parts.any((part) => part.startsWith('.'))) {
      return _refuse('A hidden file or folder (a name that starts with a dot) is not shown.', '隠しファイルは表示しません');
    }
    try {
      final rootReal = root.resolveSymbolicLinksSync();
      final target = clean.isEmpty ? rootReal : p.joinAll([rootReal, ...parts]);
      final isDirectory = FileSystemEntity.isDirectorySync(target);
      final page = isDirectory ? p.join(target, 'index.html') : target;
      if (!File(page).existsSync()) {
        return _refuse(
          isDirectory ? '/workspace/$clean has no index.html.' : '/workspace/$clean does not exist.',
          isDirectory ? 'index.html がありません' : 'ファイルがありません',
        );
      }
      final real = File(page).resolveSymbolicLinksSync();
      if (!p.isWithin(rootReal, real)) return _refuse('That file is outside /workspace (a link leads out of it).', 'ワークスペースの外です');
      final extension = p.extension(real).replaceFirst('.', '').toLowerCase();
      if (!shownExtensions.contains(extension)) {
        return _refuse('Only pages and pictures are shown (${shownExtensions.join(', ')}); this is .$extension.', '表示できない種類です');
      }
      return _shown(WorkspaceSource(clean, title: title), '/workspace${clean.isEmpty ? '' : '/$clean'}');
    } on FileSystemException catch (e) {
      return _refuse('The file could not be read: ${e.message}.', '読めませんでした');
    }
  }

  Future<ToolOutcome> _showPort(int port, String urlPath, String title) async {
    if (port < PageBlocks.minPort || port > PageBlocks.maxPort) {
      return _refuse('Ports ${PageBlocks.minPort}-${PageBlocks.maxPort} only.', 'ポートは ${PageBlocks.minPort}〜${PageBlocks.maxPort}');
    }
    final source = PageBlocks.portSource(port, urlPath);
    if (source == null) return _refuse('url_path must start with / and hold no host or space.', 'アドレスが読めません');
    if (!await _probe(port)) {
      return _refuse(
        'Nothing answers on 127.0.0.1:$port. Start the program first, and keep it running: a command of run_command '
        'ends when it returns, so start a server with shell_session (and listen on 127.0.0.1 or 0.0.0.0). Then call show again.',
        'ポート $port に何も出ていません',
      );
    }
    return _shown(PortSource(source.port, path: source.path, title: title), '127.0.0.1:$port${source.path}');
  }

  ToolOutcome _shown(PageSource source, String what) => ToolOutcome(
        'Put on the user\'s screen: $what. It is a card in your reply with a button the user presses to open it there '
        '(it opens by itself when they have turned that on). You do not need to repeat its content.',
        ToolActivity('Show', what),
        shown: PageBlocks.encode(source),
      );

  ToolOutcome _tooLong(int length) => _refuse(
        'The page is $length characters; the most is ${settings.maxChars}. Write it to a file in /workspace and show it by path.',
        '長すぎます（$length 文字）',
      );

  ToolOutcome _refuse(String response, String summary) => ToolOutcome(response, ToolActivity('Show', summary, failed: true));
}
