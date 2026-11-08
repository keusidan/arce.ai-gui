import 'dart:convert';

import 'package:arce_ai/mcp/mcp_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  String describe(Map<String, Object?> result, {int max = 30000}) => McpClient.describeResult(result, maxChars: max);

  test('テキストはそのまま。複数あれば改行でつなぐ', () {
    expect(describe({'content': [{'type': 'text', 'text': 'a'}, {'type': 'text', 'text': 'b'}]}), 'a\nb');
  });

  test('画像・音声は、種類と大きさだけを渡す。base64 の中身はモデルに渡さない', () {
    final bytes = base64Encode(List.filled(300 * 1024, 1));
    final text = describe({'content': [{'type': 'image', 'mimeType': 'image/png', 'data': bytes}, {'type': 'audio', 'mimeType': 'audio/wav', 'data': 'AAAA'}]});
    expect(text, contains('image: image/png, 300 KB'));
    expect(text, contains('audio: audio/wav'));
    expect(text, isNot(contains(bytes.substring(0, 50))), reason: 'hundreds of thousands of characters of base64 are not sent');
    expect(text.length, lessThan(300));
  });

  test('ファイル（resource）は、テキストなら中身を、バイナリなら説明だけを渡す', () {
    final text = describe({
      'content': [
        {'type': 'resource', 'resource': {'uri': 'file:///repo/README.md', 'mimeType': 'text/markdown', 'text': '# Title'}},
        {'type': 'resource', 'resource': {'uri': 'file:///repo/a.zip', 'mimeType': 'application/zip', 'blob': base64Encode(List.filled(4096, 7))}},
      ],
    });
    expect(text, contains('[file: file:///repo/README.md (text/markdown)]\n# Title'));
    expect(text, contains('file:///repo/a.zip (application/zip), 4 KB'));
    expect(text, contains('バイナリのため中身は送りません'));
  });

  test('resource_link は、名前とアドレスを渡す', () {
    final text = describe({'content': [{'type': 'resource_link', 'name': 'report.pdf', 'uri': 'https://x.example/report.pdf', 'mimeType': 'application/pdf'}]});
    expect(text, '[link: report.pdf https://x.example/report.pdf (application/pdf)]');
  });

  test('content が無く structuredContent だけなら、それを JSON で渡す。全体の JSON は渡さない', () {
    expect(describe({'structuredContent': {'n': 3}, 'isError': false}), '{"n":3}');
    expect(describe({'isError': false}), isEmpty);
  });

  test('上限を超えた分は省き、何文字省いたかを書く', () {
    final text = describe({'content': [{'type': 'text', 'text': 'あ' * 1000}]}, max: 600);
    expect(text, startsWith('あ' * 600));
    expect(text, contains('400 文字を省略しました'));
  });
}
