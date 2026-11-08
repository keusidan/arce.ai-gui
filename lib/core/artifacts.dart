import 'chat_controller.dart';
import 'markdown_lite.dart';

/// A finished code block of a reply, listed on the Artifacts page.
class ArtifactItem {
  const ArtifactItem({
    required this.messageId,
    required this.index,
    required this.language,
    required this.code,
    required this.title,
    required this.fileName,
  });

  final int messageId;
  final int index;
  final String language;
  final String code;
  final String title;
  final String fileName;

  bool get isHtml => language == 'html';
  String get key => '$messageId:$index';
}

abstract final class Artifacts {
  static const _extensions = {
    'html': 'html',
    'css': 'css',
    'javascript': 'js',
    'js': 'js',
    'typescript': 'ts',
    'ts': 'ts',
    'python': 'py',
    'py': 'py',
    'kotlin': 'kt',
    'java': 'java',
    'c': 'c',
    'cpp': 'cpp',
    'c++': 'cpp',
    'rust': 'rs',
    'go': 'go',
    'dart': 'dart',
    'json': 'json',
    'yaml': 'yaml',
    'bash': 'sh',
    'sh': 'sh',
    'sql': 'sql',
    'markdown': 'md',
    'md': 'md',
  };

  /// Closed code blocks of the assistant's replies, oldest first. A block still being streamed
  /// is left out, so a preview never shows half a page.
  static List<ArtifactItem> extract(List<UiMessage> messages) {
    final items = <ArtifactItem>[];
    for (final message in messages) {
      if (message.role != Role.assistant) continue;
      var index = 0;
      for (final block in MarkdownLite.parse(message.text)) {
        if (block is! CodeBlock || !block.closed || block.code.trim().isEmpty) continue;
        final language = block.language.toLowerCase();
        final extension = _extensions[language] ?? (language.isEmpty ? 'txt' : language);
        items.add(ArtifactItem(
          messageId: message.id,
          index: index++,
          language: language.isEmpty ? 'text' : language,
          code: block.code,
          title: titleOf(language, block.code),
          fileName: language == 'html' ? 'index.html' : 'main.$extension',
        ));
      }
    }
    return items;
  }

  static String titleOf(String language, String code) {
    if (language == 'html') {
      final title = RegExp(r'<title>\s*(.*?)\s*</title>', caseSensitive: false, dotAll: true).firstMatch(code)?.group(1);
      if (title != null && title.isNotEmpty) return title;
      final h1 = RegExp(r'<h1[^>]*>\s*(.*?)\s*</h1>', caseSensitive: false, dotAll: true).firstMatch(code)?.group(1);
      if (h1 != null && h1.isNotEmpty) return h1.replaceAll(RegExp(r'<[^>]+>'), '');
      return 'HTML ページ';
    }
    final firstLine = code.split('\n').firstWhere((l) => l.trim().isNotEmpty, orElse: () => '').trim();
    final label = language.isEmpty ? 'コード' : language;
    return firstLine.isEmpty ? label : '$label · ${firstLine.length > 40 ? firstLine.substring(0, 40) : firstLine}';
  }
}
