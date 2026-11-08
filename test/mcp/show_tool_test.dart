import 'dart:io';

import 'package:arce_ai/core/markdown_lite.dart';
import 'package:arce_ai/core/page_blocks.dart';
import 'package:arce_ai/core/protocol.dart';
import 'package:arce_ai/core/tool_runtime.dart' show ToolOutcome;
import 'package:arce_ai/mcp/mcp_tools.dart';
import 'package:arce_ai/mcp/show_tool.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory workspace;
  late Directory outside;

  setUp(() async {
    final base = await Directory.systemTemp.createTemp('arce_show_test');
    workspace = Directory('${base.path}/workspace')..createSync();
    outside = Directory('${base.path}/outside')..createSync();
    File('${outside.path}/secret.html').writeAsStringSync('<p>secret</p>');
    File('${workspace.path}/page.html').writeAsStringSync('<h1>page</h1>');
    Directory('${workspace.path}/site').createSync();
    File('${workspace.path}/site/index.html').writeAsStringSync('<link rel=stylesheet href=a.css>');
    File('${workspace.path}/site/notes.txt').writeAsStringSync('not a page');
    Directory('${workspace.path}/empty').createSync();
    Directory('${workspace.path}/.hidden').createSync();
    File('${workspace.path}/.hidden/index.html').writeAsStringSync('<p>hidden</p>');
    addTearDown(() => base.delete(recursive: true)); // Dart deletes a link as a link, it does not follow it
  });

  /// What the model writes, read by the app's own parser: the call that reaches the tool.
  McpCall callOf(String arguments) {
    final result = ToolCallParser.parse('{"name":"show","arguments":$arguments}', [Protocol.show]);
    expect(result, isA<ParseOk>(), reason: arguments);
    return (result as ParseOk).call as McpCall;
  }

  ShowTool tool({bool enabled = true, int maxChars = 200000, Directory? ws, Future<bool> Function(int)? probe}) =>
      ShowTool(settings: ShowSettings(enabled: enabled, maxChars: maxChars), workspace: ws ?? workspace, probe: probe ?? (_) async => true);

  Future<ToolOutcome> run(ShowTool t, String arguments) => t.run(callOf(arguments).arguments);

  PageSource? shownPage(ToolOutcome o) {
    final blocks = MarkdownLite.parse(o.shown ?? '').whereType<CodeBlock>().toList();
    return blocks.length == 1 ? PageBlocks.decode(blocks.single.code) : null;
  }

  group('from what the model writes to the card in its reply', () {
    test('html and svg are put into the reply as the page, with the title, and the model is told what happened', () async {
      final out = await run(tool(), r'{"html":"<h1>hi</h1>","title":"挨拶"}');
      expect(out.activity.failed, isFalse);
      final page = shownPage(out) as HtmlSource;
      expect((page.html, page.title), ('<h1>hi</h1>', '挨拶'));
      expect(out.response, allOf(contains('Put on the user'), contains('button')));
      final svg = shownPage(await run(tool(), r'{"svg":"<svg xmlns=\"http://www.w3.org/2000/svg\"/>"}')) as SvgSource;
      expect(svg.svg, contains('<svg'));
    });

    test('exactly one thing to show, and the model is told when it is not', () {
      for (final bad in [r'{}', r'{"html":"<p/>","svg":"<svg/>"}', r'{"html":"<p/>","port":8080}', r'{"html":"  "}', r'{"port":"x"}', r'{"port":8080.5}', r'{"html":3}']) {
        final result = ToolCallParser.parse('{"name":"show","arguments":$bad}', [Protocol.show]);
        expect(result, isA<ParseInvalid>(), reason: bad);
      }
    });

    test('a page that is too long is refused with the way out; so is turned off, and a text that is not an SVG', () async {
      final long = await run(tool(maxChars: 1000), '{"html":"${'a' * 1001}"}');
      expect(long.activity.failed, isTrue);
      expect(long.response, allOf(contains('1001'), contains('1000'), contains('path')));
      expect((await run(tool(enabled: false), r'{"html":"<p/>"}')).activity.failed, isTrue);
      expect(tool(enabled: false).definition(), isNull);
      expect(tool().definition(), same(Protocol.show));
      expect((await run(tool(), r'{"svg":"<p>not a picture</p>"}')).activity.failed, isTrue);
    });
  });

  group('a file or folder of the workspace', () {
    test('a page, a folder with an index.html, and the workspace itself are shown by their path below it', () async {
      expect((shownPage(await run(tool(), r'{"path":"page.html"}')) as WorkspaceSource).path, 'page.html');
      expect((shownPage(await run(tool(), r'{"path":"/workspace/site"}')) as WorkspaceSource).path, 'site');
      expect((shownPage(await run(tool(), r'{"path":"site/index.html","title":"サイト"}')) as WorkspaceSource).title, 'サイト');
    });

    test('what is not a page, is not there, or is not below the workspace is refused, each with its reason', () async {
      Future<String> refused(String path) async {
        final out = await run(tool(), '{"path":"$path"}');
        expect(out.activity.failed, isTrue, reason: path);
        expect(out.shown, isNull, reason: path);
        return out.response;
      }

      expect(await refused('site/notes.txt'), contains('.txt'));
      expect(await refused('nothing.html'), contains('does not exist'));
      expect(await refused('empty'), contains('index.html'));
      expect(await refused('../outside/secret.html'), contains('not a path below'));
      expect(await refused('/etc/passwd'), contains('not a path below'));
      expect(await refused('.hidden'), contains('hidden'));
      expect(await refused('.hidden/index.html'), contains('hidden'));
    });

    test('a link that leads out of the workspace is refused', () async {
      Link('${workspace.path}/out.html').createSync('${outside.path}/secret.html');
      Link('${workspace.path}/outdir').createSync(outside.path);
      File('${outside.path}/index.html').writeAsStringSync('<p>x</p>');
      for (final path in ['out.html', 'outdir', 'outdir/secret.html']) {
        final out = await run(tool(), '{"path":"$path"}');
        expect(out.activity.failed, isTrue, reason: path);
        expect(out.response, contains('outside'), reason: path);
      }
    });

    test('where there is no workspace (not Android) a path is not possible, and html still is', () async {
      final none = ShowTool(settings: const ShowSettings());
      expect((await run(none, r'{"path":"page.html"}')).response, contains('no workspace'));
      expect(shownPage(await run(none, r'{"html":"<p/>"}')), isA<HtmlSource>());
    });
  });

  group('a program on a port of this device', () {
    test('a port that answers is shown; one that does not is refused with what to do about it', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      // the real check: a connection to a real listener
      final real = ShowTool(settings: const ShowSettings(), workspace: workspace);
      final port = server.port;
      expect(port, greaterThanOrEqualTo(PageBlocks.minPort));
      final shown = shownPage(await run(real, '{"port":$port,"url_path":"/app","title":"viewer"}')) as PortSource;
      expect((shown.port, shown.path, shown.title), (port, '/app', 'viewer'));
      await server.close();
      final gone = await run(real, '{"port":$port}');
      expect(gone.activity.failed, isTrue);
      expect(gone.response, allOf(contains('Nothing answers'), contains('shell_session')));
    });

    test('the ports below 1024 and an address that is not a path are refused before anything is tried', () async {
      var tried = 0;
      final t = tool(probe: (_) async {
        tried++;
        return true;
      });
      expect((await run(t, r'{"port":22}')).activity.failed, isTrue);
      expect((await run(t, r'{"port":8080,"url_path":"//evil.example/"}')).activity.failed, isTrue);
      expect((await run(t, r'{"port":8080,"url_path":"http://evil.example/"}')).activity.failed, isTrue);
      expect(tried, 0, reason: 'nothing was connected to');
    });
  });

  group('inside McpTools', () {
    test('it is offered when it is on, never asks for approval, and is run through the same door as the others', () async {
      final tools = McpTools(const [], show: const ShowSettings(), workspaceDirectory: workspace, showProbe: (_) async => true);
      final names = [for (final d in await tools.definitions()) d.name];
      expect(names, contains('show'));
      expect(tools.approvalRequired('show', const {'html': '<p/>'}), isFalse);
      final out = await tools.run(callOf(r'{"html":"<p>x</p>"}'));
      expect(shownPage(out), isA<HtmlSource>());
      final off = McpTools(const [], show: const ShowSettings(enabled: false));
      expect([for (final d in await off.definitions()) d.name], isNot(contains('show')));
    });
  });
}
