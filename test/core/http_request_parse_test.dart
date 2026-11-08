import 'package:arce_ai/core/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  ParseResult parse(String arguments) => ToolCallParser.parse('{"name":"http_request","arguments":$arguments}', [Protocol.httpRequest]);

  McpCall ok(ParseResult r) => (r as ParseOk).call as McpCall;

  group('http_request as the model writes it', () {
    test('the method defaults to GET, is upper-cased, and the address is kept as written (placeholders and all)', () {
      final call = ok(parse(r'{"url":" https://api.example.com/v1/models?key={{secret:gemini}} "}'));
      expect(call.name, 'http_request');
      expect(call.arguments['method'], 'GET');
      expect(call.arguments['url'], 'https://api.example.com/v1/models?key={{secret:gemini}}');
      expect(call.arguments.containsKey('headers'), isFalse);
      expect(ok(parse(r'{"method":" post ","url":"https://a.example/x"}')).arguments['method'], 'POST');
    });

    test('headers: text, numbers and booleans become text; the body is kept as it is', () {
      final call = ok(parse(r'{"method":"POST","url":"https://a.example/x","headers":{"x-n":1,"x-b":true,"Authorization":"Bearer {{secret:gh}}"},"body":"  a=1\n"}'));
      expect(call.arguments['headers'], {'x-n': '1', 'x-b': 'true', 'Authorization': 'Bearer {{secret:gh}}'});
      expect(call.arguments['body'], '  a=1\n');
    });

    test('a json body is kept as an object, and the timeout as a whole number', () {
      final call = ok(parse(r'{"method":"POST","url":"https://a.example/x","json":{"k":"{{secret:a}}","n":[1,2]},"timeout_seconds":12.0}'));
      expect(call.arguments['json'], {'k': '{{secret:a}}', 'n': [1, 2]});
      expect(call.arguments['timeout_seconds'], 12);
    });

    test('what cannot be sent is the model\'s to fix, with the reason', () {
      expect(parse(r'{"url":"https://a.example/x","method":"TRACE"}'), isA<ParseInvalid>());
      expect((parse(r'{"url":"https://a.example/x","method":"TRACE"}') as ParseInvalid).reason, contains('GET, HEAD, POST'));
      expect(parse(r'{}'), isA<ParseInvalid>());
      expect(parse(r'{"url":"  "}'), isA<ParseInvalid>());
      expect((parse(r'{"url":"https://a.example/x","body":"a","json":{"b":1}}') as ParseInvalid).reason, contains('either body or json'));
      expect(parse(r'{"url":{"a":1}}'), isA<ParseInvalid>());
      expect(parse(r'{"url":"https://a.example/x","headers":"x"}'), isA<ParseInvalid>());
      expect(parse(r'{"url":"https://a.example/x","headers":{"a":{"b":1}}}'), isA<ParseInvalid>());
      expect(parse(r'{"url":"https://a.example/x","body":5}'), isA<ParseInvalid>());
      expect(parse(r'{"url":"https://a.example/x","json":"text"}'), isA<ParseInvalid>());
      expect(parse(r'{"url":"https://a.example/x","timeout_seconds":"9"}'), isA<ParseInvalid>());
    });

    test('it is not parsed when the turn does not offer it', () {
      expect(ToolCallParser.parse('{"name":"http_request","arguments":{"url":"https://a.example/x"}}', [Protocol.askUser]), isA<ParseInvalid>());
    });

    test('it is an MCP-like call: the approval policy and the runner see it as one', () {
      expect(Protocol.isMcpLike('http_request'), isTrue);
      expect(Protocol.toolCallSchema([Protocol.httpRequest]), isNotEmpty);
    });
  });

  group('the card the user approves', () {
    String card(String arguments) => ToolApproval.tile(ok(parse(arguments))).title;

    test('shows the method, the address with the placeholder (never a value), the real host and the ids', () {
      final text = card(r'{"method":"POST","url":"https://generativelanguage.googleapis.com/v1beta/x?key={{secret:gemini}}","headers":{"Authorization":"Bearer {{secret:github}}"},"body":"hello"}');
      expect(text, contains('POST https://generativelanguage.googleapis.com/v1beta/x?key={{secret:gemini}}'));
      expect(text, contains('送り先のホスト: generativelanguage.googleapis.com'));
      expect(text, contains('使う秘密: gemini、github'));
      expect(text, contains('値は見えません'));
      expect(text, contains('本文（5 文字）: hello'));
    });

    test('a request without a secret says none, and a plain GET has no body line', () {
      final text = card(r'{"url":"https://example.org/"}');
      expect(text, contains('GET https://example.org/'));
      expect(text, isNot(contains('使う秘密')));
      expect(text, isNot(contains('本文')));
    });

    test('the host shown is the real one: user@host and a placeholder in the host cannot hide it', () {
      expect(card(r'{"url":"https://generativelanguage.googleapis.com@evil.example/x"}'), contains('送り先のホスト: evil.example'));
      expect(card(r'{"url":"https://api.{{secret:a}}.evil.example/x"}'), contains('使う秘密: a'));
    });

    test('a long body is cut, with its size; a json body is shown as JSON', () {
      final long = card('{"method":"PUT","url":"https://a.example/x","body":"${'x' * 500}"}');
      expect(long, contains('本文（500 文字）'));
      expect(long, contains('…'));
      expect(long.length, lessThan(600));
      expect(card(r'{"method":"POST","url":"https://a.example/x","json":{"k":"{{secret:a}}"}}'), contains('{"k":"{{secret:a}}"}'));
    });

    test('a secret in a header name or the body is listed too', () {
      expect(card(r'{"method":"POST","url":"https://a.example/x","body":"k={{secret:b}}"}'), contains('使う秘密: b'));
      expect(card(r'{"url":"https://a.example/x","headers":{"{{secret:c}}":"v"}}'), contains('使う秘密: c'));
    });

    test('it cannot be remembered: what it does depends on the request', () {
      expect(ToolApproval.canRemember('http_request'), isFalse);
      expect(ToolApproval.tile(ok(parse(r'{"url":"https://a.example/x"}')), rememberable: true).options, [ToolApproval.approve, ToolApproval.reject]);
    });
  });
}
