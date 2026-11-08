/// A piece of text with one style. Adjacent pieces differ in at least one field.
class Span {
  const Span(this.text, {this.bold = false, this.italic = false, this.code = false, this.strike = false, this.link});

  final String text;
  final bool bold;
  final bool italic;

  /// `inline code`
  final bool code;
  final bool strike;

  /// The address a link opens (`[text](url)` or a bare http(s) address); null for plain text.
  final String? link;

  @override
  bool operator ==(Object other) =>
      other is Span &&
      other.text == text &&
      other.bold == bold &&
      other.italic == italic &&
      other.code == code &&
      other.strike == strike &&
      other.link == link;

  @override
  int get hashCode => Object.hash(text, bold, italic, code, strike, link);

  @override
  String toString() => 'Span($text${bold ? ', bold' : ''}${italic ? ', italic' : ''}${code ? ', code' : ''}${strike ? ', strike' : ''}${link == null ? '' : ', $link'})';
}

sealed class Block {
  const Block();
}

class Paragraph extends Block {
  const Paragraph(this.spans);
  final List<Span> spans;
}

/// `# text` to `###### text`.
class Heading extends Block {
  const Heading(this.level, this.spans);
  final int level;
  final List<Span> spans;
}

/// `---`
class Rule extends Block {
  const Rule();
}

class CodeBlock extends Block {
  const CodeBlock(this.language, this.code, {required this.closed});
  final String language;
  final String code;

  /// False while the fence is still being streamed; an Artifact can wait for it.
  final bool closed;
}

/// One line of a list: `- item`, `1. item`, nested by its indent.
class ListItem {
  const ListItem({required this.depth, required this.spans, this.number, this.checked});

  /// 0 for the outermost list.
  final int depth;

  /// The number of an ordered item (`3.`); null for a bullet.
  final int? number;

  /// `[x]` / `[ ]` at the start of the item (a task list); null when there is none.
  final bool? checked;
  final List<Span> spans;
}

class ListBlock extends Block {
  const ListBlock(this.items);
  final List<ListItem> items;
}

/// `> quoted text`; what is inside is read as blocks again.
class Quote extends Block {
  const Quote(this.blocks, {this.raw = ''});
  final List<Block> blocks;

  /// The quoted text as written, without the `>` marks: what a copy button copies (a prompt that
  /// was put in a quote to be handed to another AI).
  final String raw;
}

enum ColumnAlign { left, center, right }

/// A table of pipes (`| a | b |`, then `|---|---|`, then rows).
class TableBlock extends Block {
  const TableBlock({required this.header, required this.aligns, required this.rows});
  final List<List<Span>> header;
  final List<ColumnAlign> aligns;

  /// Every row has as many cells as the header (missing ones are empty, extra ones are cut).
  final List<List<List<Span>>> rows;
}

/// The Markdown a model writes in a reply: headings, bold / italic / strike / `code`, links, lists,
/// quotes, rules, tables and fenced code blocks. It is not a full CommonMark reader: what it does not
/// know (HTML, footnotes, images, LaTeX) stays as the text it is.
///
/// Tolerates half-streamed input: an unclosed fence becomes an open code block, an unmatched `**`
/// or `` ` `` is shown as it is, and a table is a table from the moment its `|---|` line is there.
abstract final class MarkdownLite {
  static const _fence = '```';

  static List<Block> parse(String text) {
    final blocks = <Block>[];
    var rest = text;
    while (rest.isNotEmpty) {
      final open = _fenceStart(rest);
      if (open < 0) {
        _addText(rest, blocks);
        break;
      }
      _addText(rest.substring(0, open), blocks);
      final afterFence = rest.substring(open + _fence.length);
      final headerEnd = afterFence.indexOf('\n');
      if (headerEnd < 0) {
        // only "```lang" so far
        blocks.add(CodeBlock(afterFence.trim(), '', closed: false));
        break;
      }
      final language = afterFence.substring(0, headerEnd).trim();
      final body = afterFence.substring(headerEnd + 1);
      final close = body.indexOf(_fence);
      if (close < 0) {
        blocks.add(CodeBlock(language, body, closed: false));
        break;
      }
      var code = body.substring(0, close);
      if (code.endsWith('\n')) code = code.substring(0, code.length - 1);
      blocks.add(CodeBlock(language, code, closed: true));
      rest = body.substring(close + _fence.length);
      if (rest.startsWith('\n')) rest = rest.substring(1);
    }
    return blocks;
  }

  /// Where a fence opens: the first ``` in [text] (a fence can also follow a line of text directly).
  static int _fenceStart(String text) => text.indexOf(_fence);

  // ---- blocks (the text between code fences) ----

  static final _heading = RegExp(r'^ {0,3}(#{1,6})[ \t]+(.*?)[ \t]*#*[ \t]*$');
  static final _rule = RegExp(r'^ {0,3}([-*_])([ \t]*\1){2,}[ \t]*$');
  static final _bullet = RegExp(r'^([ \t]*)([-*+]|\d{1,9}[.)])[ \t]+(.*)$');
  static final _quote = RegExp(r'^ {0,3}>[ \t]?(.*)$');
  static final _tableSeparator = RegExp(r'^[ \t]*\|?[ \t]*:?-+:?[ \t]*(\|[ \t]*:?-+:?[ \t]*)*\|?[ \t]*$');

  static void _addText(String text, List<Block> blocks) {
    final lines = text.split('\n');
    var i = 0;
    while (i < lines.length) {
      final line = lines[i];
      if (line.trim().isEmpty) {
        i++;
        continue;
      }
      final heading = _heading.firstMatch(line);
      if (heading != null) {
        blocks.add(Heading(heading.group(1)!.length, spans(heading.group(2)!)));
        i++;
        continue;
      }
      if (_rule.hasMatch(line)) {
        blocks.add(const Rule());
        i++;
        continue;
      }
      if (_isTableStart(lines, i)) {
        i = _readTable(lines, i, blocks);
        continue;
      }
      if (_quote.hasMatch(line)) {
        final inner = <String>[];
        while (i < lines.length) {
          final m = _quote.firstMatch(lines[i]);
          if (m == null) break;
          inner.add(m.group(1)!);
          i++;
        }
        final nested = <Block>[];
        _addText(inner.join('\n'), nested);
        blocks.add(Quote(nested, raw: inner.join('\n').trim()));
        continue;
      }
      if (_bullet.hasMatch(line)) {
        i = _readList(lines, i, blocks);
        continue;
      }
      // a paragraph: lines up to a blank line or the start of another block
      final para = <String>[];
      while (i < lines.length && lines[i].trim().isNotEmpty && (para.isEmpty || !_startsBlock(lines, i))) {
        para.add(lines[i]);
        i++;
      }
      blocks.add(Paragraph(spans(para.join('\n'))));
    }
  }

  static bool _startsBlock(List<String> lines, int i) {
    final line = lines[i];
    return _heading.hasMatch(line) || _rule.hasMatch(line) || _quote.hasMatch(line) || _bullet.hasMatch(line) || _isTableStart(lines, i);
  }

  static bool _isTableStart(List<String> lines, int i) {
    if (i + 1 >= lines.length) return false;
    final header = lines[i];
    final separator = lines[i + 1];
    if (!header.contains('|') || !separator.contains('-')) return false;
    if (!_tableSeparator.hasMatch(separator)) return false;
    // a separator with fewer cells than the header is still being written (or is no table at all)
    return _cells(separator).length == _cells(header).length;
  }

  static int _readTable(List<String> lines, int start, List<Block> blocks) {
    final header = _cells(lines[start]);
    final aligns = [
      for (final cell in _cells(lines[start + 1]))
        cell.startsWith(':') && cell.endsWith(':') && cell.length > 1
            ? ColumnAlign.center
            : cell.endsWith(':')
                ? ColumnAlign.right
                : ColumnAlign.left,
    ];
    final count = header.length;
    final rows = <List<List<Span>>>[];
    var i = start + 2;
    while (i < lines.length && lines[i].trim().isNotEmpty && lines[i].contains('|')) {
      final cells = _cells(lines[i]);
      rows.add([for (var c = 0; c < count; c++) spans(c < cells.length ? cells[c] : '')]);
      i++;
    }
    blocks.add(TableBlock(
      header: [for (final cell in header) spans(cell)],
      aligns: [for (var c = 0; c < count; c++) c < aligns.length ? aligns[c] : ColumnAlign.left],
      rows: rows,
    ));
    return i;
  }

  /// The cells of a table line: split at the pipes that are not escaped (`\|`) or inside `code`.
  static List<String> _cells(String line) {
    var text = line.trim();
    if (text.startsWith('|')) text = text.substring(1);
    if (text.endsWith('|') && !text.endsWith(r'\|')) text = text.substring(0, text.length - 1);
    final cells = <String>[];
    final cell = StringBuffer();
    var inCode = false;
    for (var i = 0; i < text.length; i++) {
      final ch = text[i];
      if (ch == r'\' && i + 1 < text.length && text[i + 1] == '|') {
        cell.write('|');
        i++;
      } else if (ch == '`') {
        inCode = !inCode;
        cell.write(ch);
      } else if (ch == '|' && !inCode) {
        cells.add(cell.toString().trim());
        cell.clear();
      } else {
        cell.write(ch);
      }
    }
    cells.add(cell.toString().trim());
    return cells;
  }

  static int _readList(List<String> lines, int start, List<Block> blocks) {
    final items = <ListItem>[];
    // the indent of each open level, outermost first
    final indents = <int>[];
    var i = start;
    while (i < lines.length) {
      final m = _bullet.firstMatch(lines[i]);
      if (m == null) {
        // text under an item, indented: it goes on in that item
        if (items.isNotEmpty && lines[i].trim().isNotEmpty && lines[i].startsWith(RegExp(r'[ \t]+')) && !_startsBlock(lines, i)) {
          final last = items.removeLast();
          items.add(ListItem(
            depth: last.depth,
            number: last.number,
            checked: last.checked,
            spans: [...last.spans, ...spans('\n${lines[i].trim()}')],
          ));
          i++;
          continue;
        }
        // one blank line does not end a list that goes on
        if (lines[i].trim().isEmpty && i + 1 < lines.length && _bullet.hasMatch(lines[i + 1])) {
          i++;
          continue;
        }
        break;
      }
      if (_rule.hasMatch(lines[i])) break;
      // a bullet list does not go on as a numbered one (and the other way round): that is a new list
      if (items.isNotEmpty && !m.group(1)!.contains(RegExp(r'[ \t]')) && items.first.depth == 0 && (items.first.number != null) != RegExp(r'^\d').hasMatch(m.group(2)!) && m.group(1)!.isEmpty) break;
      final indent = m.group(1)!.replaceAll('\t', '    ').length;
      while (indents.isNotEmpty && indent < indents.last) {
        indents.removeLast();
      }
      if (indents.isEmpty || indent > indents.last) indents.add(indent);
      final marker = m.group(2)!;
      var content = m.group(3)!;
      bool? checked;
      final task = RegExp(r'^\[([ xX])\][ \t]+(.*)$').firstMatch(content);
      if (task != null) {
        checked = task.group(1) != ' ';
        content = task.group(2)!;
      }
      items.add(ListItem(
        depth: indents.length - 1,
        number: RegExp(r'^\d').hasMatch(marker) ? int.parse(marker.substring(0, marker.length - 1)) : null,
        checked: checked,
        spans: spans(content),
      ));
      i++;
    }
    blocks.add(ListBlock(items));
    return i;
  }

  // ---- inline ----

  /// The styled pieces of one run of text. Adjacent pieces of the same style are one piece.
  static List<Span> spans(String text) {
    final out = <Span>[];
    _inline(text, const Span(''), out);
    return out;
  }

  static final _wordChar = RegExp(r'[A-Za-z0-9_]');
  static final _urlChars = RegExp(r"[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]");

  static bool _isWord(String text, int i) => i >= 0 && i < text.length && _wordChar.hasMatch(text[i]);

  static void _inline(String text, Span style, List<Span> out) {
    final plain = StringBuffer();
    void flush() {
      if (plain.isEmpty) return;
      _emit(out, Span(plain.toString(), bold: style.bold, italic: style.italic, code: style.code, strike: style.strike, link: style.link));
      plain.clear();
    }

    Span derive({bool? bold, bool? italic, bool? strike, String? link}) => Span('',
        bold: bold ?? style.bold, italic: italic ?? style.italic, code: style.code, strike: strike ?? style.strike, link: link ?? style.link);

    var i = 0;
    while (i < text.length) {
      final ch = text[i];
      // a backslash before a mark: the mark as it is
      if (ch == r'\' && i + 1 < text.length && r'\`*_{}[]()#+-.!|~>'.contains(text[i + 1])) {
        plain.write(text[i + 1]);
        i += 2;
        continue;
      }
      if (ch == '`') {
        final end = text.indexOf('`', i + 1);
        if (end > i + 1) {
          flush();
          _emit(out, Span(text.substring(i + 1, end), bold: style.bold, italic: style.italic, code: true, strike: style.strike, link: style.link));
          i = end + 1;
          continue;
        }
      }
      if ((text.startsWith('**', i) || text.startsWith('__', i)) && !style.bold) {
        final mark = text.substring(i, i + 2);
        final end = text.indexOf(mark, i + 2);
        if (end > i + 2 && (mark == '**' || (!_isWord(text, i - 1) && !_isWord(text, end + 2)))) {
          flush();
          _inline(text.substring(i + 2, end), derive(bold: true), out);
          i = end + 2;
          continue;
        }
      }
      if (text.startsWith('~~', i) && !style.strike) {
        final end = text.indexOf('~~', i + 2);
        if (end > i + 2) {
          flush();
          _inline(text.substring(i + 2, end), derive(strike: true), out);
          i = end + 2;
          continue;
        }
      }
      if ((ch == '*' || ch == '_') && !style.italic && !text.startsWith(ch * 2, i)) {
        final end = _closeItalic(text, i, ch);
        if (end > 0) {
          flush();
          _inline(text.substring(i + 1, end), derive(italic: true), out);
          i = end + 1;
          continue;
        }
      }
      if (ch == '[' && style.link == null) {
        final link = _link(text, i);
        if (link != null) {
          flush();
          _inline(link.label, derive(link: link.url), out);
          i = link.end;
          continue;
        }
      }
      if ((ch == 'h' || ch == 'H') && style.link == null && !_isWord(text, i - 1) && _startsUrl(text, i)) {
        var end = i;
        while (end < text.length && _urlChars.hasMatch(text[end])) {
          end++;
        }
        while (end > i && '.,;:!?)\'*'.contains(text[end - 1])) {
          end--;
        }
        final url = text.substring(i, end);
        if (url.length > 'https://'.length) {
          flush();
          _emit(out, Span(url, bold: style.bold, italic: style.italic, strike: style.strike, link: url));
          i = end;
          continue;
        }
      }
      if (ch == '<' && RegExp(r'^<br\s*/?>', caseSensitive: false).hasMatch(text.substring(i))) {
        plain.write('\n');
        i += RegExp(r'^<br\s*/?>', caseSensitive: false).firstMatch(text.substring(i))!.end;
        continue;
      }
      plain.write(ch);
      i++;
    }
    flush();
  }

  static bool _startsUrl(String text, int i) {
    final rest = text.substring(i, i + 8 > text.length ? text.length : i + 8).toLowerCase();
    return rest.startsWith('http://') || rest.startsWith('https://');
  }

  /// The index of the mark that closes an italic run opened at [open] with [mark] (`*` or `_`), or -1.
  /// The run may not start or end with a space; an underscore inside a word (`snake_case`) is not a mark.
  static int _closeItalic(String text, int open, String mark) {
    if (open + 1 >= text.length || text[open + 1] == ' ' || text[open + 1] == '\n') return -1;
    if (mark == '_' && _isWord(text, open - 1)) return -1;
    var j = open + 1;
    while (j < text.length) {
      final at = text.indexOf(mark, j);
      if (at < 0) return -1;
      if (text.startsWith(mark * 2, at)) {
        // a bold mark inside: step over it
        j = at + 2;
        continue;
      }
      if (text[at - 1] == ' ' || text[at - 1] == '\n') {
        j = at + 1;
        continue;
      }
      if (mark == '_' && _isWord(text, at + 1)) {
        j = at + 1;
        continue;
      }
      return at;
    }
    return -1;
  }

  static ({String label, String url, int end})? _link(String text, int open) {
    final close = text.indexOf(']', open + 1);
    if (close < 0 || close + 1 >= text.length || text[close + 1] != '(') return null;
    final end = text.indexOf(')', close + 2);
    if (end < 0) return null;
    final url = text.substring(close + 2, end).trim();
    if (!RegExp(r'^(https?://|mailto:)', caseSensitive: false).hasMatch(url) || url.contains(' ')) return null;
    final label = text.substring(open + 1, close);
    if (label.isEmpty) return null;
    return (label: label, url: url, end: end + 1);
  }

  static void _emit(List<Span> out, Span span) {
    if (span.text.isEmpty) return;
    if (out.isNotEmpty) {
      final last = out.last;
      if (last.bold == span.bold && last.italic == span.italic && last.code == span.code && last.strike == span.strike && last.link == span.link) {
        out[out.length - 1] = Span(last.text + span.text, bold: span.bold, italic: span.italic, code: span.code, strike: span.strike, link: span.link);
        return;
      }
    }
    out.add(span);
  }
}
