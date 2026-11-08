import 'package:arce_ai/core/markdown_lite.dart';
import 'package:arce_ai/core/page_blocks.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// The text of a reply holding [source] as a block, read back by the chat's own reader of Markdown.
  PageSource? roundTrip(PageSource source) {
    final blocks = MarkdownLite.parse('前置き\n\n${PageBlocks.encode(source)}\n\n後ろ');
    final code = blocks.whereType<CodeBlock>().toList();
    expect(code, hasLength(1), reason: 'the whole block is one code block, whatever the page holds');
    expect(code.single.language, PageBlocks.language);
    expect(code.single.closed, isTrue);
    return PageBlocks.decode(code.single.code);
  }

  group('a page in a reply', () {
    test('each kind comes back as it went in, with its title', () {
      final html = roundTrip(const HtmlSource('<h1>こんにちは</h1>', title: '見出し')) as HtmlSource;
      expect((html.html, html.title), ('<h1>こんにちは</h1>', '見出し'));
      expect((roundTrip(const SvgSource('<svg/>')) as SvgSource).svg, '<svg/>');
      expect((roundTrip(const WorkspaceSource('site/index.html')) as WorkspaceSource).path, 'site/index.html');
      final port = roundTrip(const PortSource(8080, path: '/app?x=1', title: 'viewer')) as PortSource;
      expect((port.port, port.path, port.title), (8080, '/app?x=1', 'viewer'));
    });

    test('nothing inside a page can close the fence: a code fence, backticks, line breaks and quotes in it', () {
      const nasty = '<pre>\n```js\nconsole.log(`a ${"b"}`)\n```\n</pre>\n<script>var s = "```";</script>';
      final back = roundTrip(const HtmlSource(nasty)) as HtmlSource;
      expect(back.html, nasty);
      expect(PageBlocks.encode(const HtmlSource(nasty)).split('```'), hasLength(3), reason: 'the opening and the closing fence only');
    });
  });

  group('what a block may describe (a model, or anything that wrote text, made it)', () {
    test('exactly one source', () {
      expect(PageBlocks.decode('{}'), isNull);
      expect(PageBlocks.decode('{"html":"<p/>","svg":"<svg/>"}'), isNull);
      expect(PageBlocks.decode('{"html":"<p/>","port":8080}'), isNull);
      expect(PageBlocks.decode('{"html":"   "}'), isNull);
      expect(PageBlocks.decode('not json'), isNull);
      expect(PageBlocks.decode('[1]'), isNull);
    });

    test('a port is one the user may serve on, and its path is a plain path of this device', () {
      expect(PageBlocks.decode('{"port":80}'), isNull);
      expect(PageBlocks.decode('{"port":1023}'), isNull);
      expect(PageBlocks.decode('{"port":65536}'), isNull);
      expect(PageBlocks.decode('{"port":"8080"}'), isNull);
      expect(PageBlocks.decode('{"port":1024}'), isA<PortSource>());
      expect(PageBlocks.decode('{"port":65535}'), isA<PortSource>());
      // an address of another host cannot be written into the path
      for (final bad in ['//evil.example/x', 'http://evil.example/', '@evil.example', '/a b', '/a\\\\b', 'x', '/a\\u0000b', '/ok@evil.example']) {
        expect(PageBlocks.decode('{"port":8080,"path":"$bad"}'), isNull, reason: bad);
      }
      final address = PageBlocks.addressOf(PageBlocks.decode('{"port":8080,"path":"/a/b?c=1"}') as PortSource);
      expect((address.scheme, address.host, address.port, address.path, address.query), ('http', '127.0.0.1', 8080, '/a/b', 'c=1'));
    });

    test('a workspace path stays below the workspace', () {
      String? clean(Object? raw) => PageBlocks.cleanWorkspacePath(raw);
      expect(clean('site/index.html'), 'site/index.html');
      expect(clean('/workspace/site/index.html'), 'site/index.html');
      expect(clean('./site//a.html'), 'site/a.html');
      expect(clean('/workspace'), '');
      expect(clean('site\\a.html'), 'site/a.html', reason: 'a backslash is a separator, not a way past the check');
      for (final bad in ['../x', 'a/../../x', '/etc/passwd', '/workspace/../etc', 'C:\\x', 'c:/x', '', '  ', 'a\nb', null, 3]) {
        expect(clean(bad), isNull, reason: '$bad');
      }
      expect(PageBlocks.decode('{"workspace":"../x"}'), isNull);
      expect(PageBlocks.decode('{"workspace":"/etc"}'), isNull);
    });
  });
}
