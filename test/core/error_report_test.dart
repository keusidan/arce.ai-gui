import 'package:arce_ai/core/error_report.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('伏せ字（送る前に、出してはいけないものを消す）', () {
    String r(String s) => ErrorRedactor.redact(s);

    test('キーとトークン：ヘッダー・項目・クエリの値、よくある形のキー', () {
      expect(r('Authorization: Bearer abcdef1234567890xyz'), isNot(contains('abcdef1234567890xyz')));
      expect(r('{"api_key": "sk-proj-AAAABBBBCCCCDDDD1111"}'), isNot(contains('AAAABBBB')));
      expect(r('GET /v1?key=AIzaSyA1234567890abcdefghijk&x=1'), allOf(isNot(contains('AIzaSy')), isNot(contains('key=AIza'))));
      expect(r('token=ghp_abcdefghijklmnopqrstuvwxyz0123456789'), isNot(contains('ghp_abc')));
      expect(r('failed with github_pat_11ABCDEFG0abcdefghijklmnop_qrstuvwxyz0123'), contains('[key]'));
      expect(r('sk-abcdefgh12345678'), '[key]');
      expect(r('password: hunter2'), isNot(contains('hunter2')));
    });

    test('長い英数字の並びは、何かの鍵かもしれないので消す', () {
      expect(r('id=abcdefghijklmnopqrstuvwxyz0123456789ABCD'), contains('[long-token]'));
      expect(r('x abcdefghijklmnopqrstuvwxyz0123456789ABCD y'), 'x [long-token] y');
    });

    test('アドレスは、ホストだけ残す（ログイン・パス・クエリは消す）', () {
      expect(r('failed https://user:pass@api.example.com/v1/chat?session=abc123&k=1 now'), 'failed https://api.example.com/… now');
      expect(r('see http://localhost:8080/x'), 'see http://localhost:8080/…');
    });

    test('メールアドレスと、端末の中の場所（ユーザー名が入る）', () {
      expect(r('mail me@example.com'), 'mail [email]');
      expect(r('/home/ponzu/.cache/x'), '/home/[user]/.cache/x');
      expect(r('/Users/ponzu/Library'), '/Users/[user]/Library');
      expect(r(r'C:\Users\ponzu\AppData'), r'C:\Users\[user]\AppData');
      expect(r('/data/user/0/ai.arce.app/files/db'), '/data/[app]/files/db');
      expect(r('/storage/emulated/0/Download/a.gguf'), '/storage/[user]/Download/a.gguf');
    });

    test('ふつうの文章は変えない', () {
      const plain = 'プロバイダが失敗しました（HTTP 400）: Unknown parameter reasoning_content';
      expect(r(plain), plain);
    });

    test('スタックは、アプリの中のフレームだけ（行番号つき）。件数の上限と、場所の伏せ字', () {
      final stack = [
        '#0      Foo.bar (package:arce_ai/ai/titles.dart:42:7)',
        '#1      _rootRun (dart:async/zone.dart:1399:13)',
        '#2      State.setState (package:flutter/src/widgets/framework.dart:1200:5)',
        '#3      Baz.run (package:arce_ai/core/chat_controller.dart:900:3)',
        '#4      main (file:///home/ponzu/app/lib/main.dart:3:1)',
      ].join('\n');
      final frames = ErrorRedactor.appFrames(stack.replaceAll('\\\n', '\n'), maxFrames: 10);
      expect(frames.split('\n'), ['Foo.bar (package:arce_ai/ai/titles.dart:42:7)', 'Baz.run (package:arce_ai/core/chat_controller.dart:900:3)']);
      final many = [for (var i = 0; i < 30; i++) '#$i  F$i (package:arce_ai/x.dart:$i:1)'].join('\n');
      expect(ErrorRedactor.appFrames(many.replaceAll('\\\n', '\n'), maxFrames: 10).split('\n'), hasLength(10));
    });
  });

  group('報告の中身', () {
    test('of: メッセージも事実も伏せ字にして、長さを切る。キーは本文のどこにも残らない', () {
      final report = ErrorReport.of(
        kind: 'chat',
        message: 'プロバイダが失敗しました（HTTP 400）: bad key sk-secretsecretsecret1 ${'あ' * 1000}',
        error: const FormatException('x'),
        facts: {'app': '0.11.0', 'provider host': 'api.example.com', 'note': 'token=ghp_abcdefghijklmnopqrstuvwxyz0123456789'},
        at: DateTime.utc(2026, 10, 27, 12),
      );
      expect(report.message.length, lessThanOrEqualTo(ErrorReport.maxMessageChars + 1));
      expect(report.errorType, 'FormatException');
      final all = '${report.title}\n${report.body}';
      expect(all, isNot(contains('sk-secret')));
      expect(all, isNot(contains('ghp_')));
      expect(all, allOf(contains('0.11.0'), contains('api.example.com'), contains('2026-10-27T12:00:00.000Z')));
    });

    test('本文は「会話は入っていない」と書き、質問や答えを入れる場所を持たない', () {
      final report = ErrorReport.of(kind: 'chat', message: 'HTTP 400', at: DateTime.utc(2026));
      expect(report.body, contains('contains no conversation'));
    });

    test('署名：数字や id が違うだけの同じ問題は、同じ署名。種類やメッセージが違えば別', () {
      ErrorReport make(String msg, {String kind = 'chat'}) => ErrorReport.of(kind: kind, message: msg, at: DateTime.utc(2026));
      expect(make('HTTP 400 at 12:03 id=abc12345').signature, make('HTTP 400 at 14:55 id=ffee9988').signature);
      expect(make('HTTP 400').signature, isNot(make('HTTP 422').signature));
      expect(make('HTTP 400').signature, isNot(make('HTTP 400', kind: 'crash').signature));
    });

    test('題名は 1 行目を 80 文字まで。JSON に書いて読み戻せる', () {
      final report = ErrorReport.of(kind: 'crash', message: '${'あ' * 200}\n2 行目', error: StateError('x'), at: DateTime.utc(2026));
      expect(report.title, startsWith('[auto/crash] '));
      expect(report.title.contains('\n'), isFalse);
      expect(report.title.length, lessThan(100));
      final back = ErrorReport.fromJson(report.toJson());
      expect((back.kind, back.message, back.errorType, back.signature), (report.kind, report.message, report.errorType, report.signature));
    });
  });

  group('送る価値のあるエラー', () {
    bool should(String kind, String text) => ErrorPolicy.shouldReport(kind, text);

    test('あなたの側で直せるものは送らない：キー・回数制限・提供元の障害・通信・文脈', () {
      for (final text in [
        'APIキーが受け付けられませんでした（HTTP 401）',
        '回数制限に達しました（HTTP 429）',
        'プロバイダが失敗しました（HTTP 503）',
        'プロバイダとの通信に失敗しました（SocketException: Failed host lookup）',
        '接続先が見つかりません（HTTP 404）。URL とモデル名を確認してください',
        '会話が長すぎます',
        'ローカルモデル（または分担）を、ほかのチャットが使っています',
      ]) {
        expect(should('chat', text), isFalse, reason: text);
      }
    });

    test('アプリが直すもの：不正な要求（400・422）、読めない応答、プログラムの例外', () {
      for (final text in [
        'プロバイダが失敗しました（HTTP 400）: Unknown parameter',
        'プロバイダが失敗しました（HTTP 422）',
        'not JSON: Unexpected character (at character 28)',
        "type 'Null' is not a subtype of type 'String'",
        'Bad state: No element',
        'FormatException: Unfinished UTF-8 octet sequence',
        'plan の返信が空でした（思考のあとで何も書かれませんでした）。もう一度試すか、別のモデルを選んでください。',
      ]) {
        expect(should('chat', text), isTrue, reason: text);
      }
    });

    test('捕まえ損ねたエラーは、通信の失敗でなければ送る。テストは常に送る', () {
      expect(should('crash', 'RangeError (index): Invalid value'), isTrue);
      expect(should('crash', 'SocketException: Connection reset by peer'), isFalse);
      expect(should('crash', 'ClientException: Connection closed before full header was received'), isFalse);
      expect(should('test', 'x'), isTrue);
    });
  });
}
