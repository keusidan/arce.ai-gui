import 'dart:convert';

import 'package:arce_ai/core/secret_placeholders.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ids from names', () {
    test('a name becomes a plain id; full-width letters and symbols are folded; a name of ours-less letters has none', () {
      expect(SecretIds.slug('Gemini'), 'gemini');
      expect(SecretIds.slug('Gemini (無料枠)'), 'gemini');
      expect(SecretIds.slug('ＯｐｅｎＡＩ　互換'), 'openai');
      expect(SecretIds.slug('GitHub Token'), 'github-token');
      expect(SecretIds.slug('--a__b--'), 'a-b');
      expect(SecretIds.slug('無料枠'), '');
      expect(SecretIds.slug(''), '');
    });

    test('ids are unique: a second one gets a number; a nameless one gets the fallback', () {
      expect(SecretIds.unique('gemini', const []), 'gemini');
      expect(SecretIds.unique('gemini', ['gemini']), 'gemini-2');
      expect(SecretIds.unique('gemini', ['gemini', 'gemini-2']), 'gemini-3');
      expect(SecretIds.fromName('無料枠', fallback: 'provider', taken: const []), 'provider');
      expect(SecretIds.fromName('無料枠', fallback: 'provider', taken: ['provider']), 'provider-2');
      expect(SecretIds.fromName('Gemini', fallback: 'provider', taken: ['gemini']), 'gemini-2');
    });

    test('what may appear in a placeholder', () {
      for (final ok in ['gemini', 'a', 'github-token', 'a.b_c', 'x1']) {
        expect(SecretIds.valid.hasMatch(ok), isTrue, reason: ok);
      }
      for (final bad in ['', '-a', 'A', 'a b', 'a/b', 'a' * 65, '日本']) {
        expect(SecretIds.valid.hasMatch(bad), isFalse, reason: bad);
      }
    });
  });

  group('placeholders', () {
    test('found in a text, lower-case, once each, in order; spaces inside the braces are allowed', () {
      expect(SecretPlaceholders.idsIn('curl -H "Authorization: Bearer {{secret:Gemini}}" {{ secret : github-token }} {{secret:gemini}}'), ['gemini', 'github-token']);
      expect(SecretPlaceholders.hasAny('no placeholder'), isFalse);
      expect(SecretPlaceholders.hasAny('{{secret:a}}'), isTrue);
    });

    test('not placeholders: other braces, a missing name, a name with a slash or a space', () {
      for (final text in ['{{key:a}}', '{{secret:}}', '{{secret:a/b}}', '{{secret:a b}}', '{secret:a}', '{{ secret }}', r'${secret:a}', '{{secret:-a}}']) {
        expect(SecretPlaceholders.idsIn(text), isEmpty, reason: text);
      }
    });

    test('substituted from what the caller knows; one it does not know stays as written', () {
      final text = SecretPlaceholders.substitute('a {{secret:k1}} b {{secret:nope}} c {{secret:K1}}', (id) => id == 'k1' ? 'VALUE' : null);
      expect(text, 'a VALUE b {{secret:nope}} c VALUE');
    });

    test('a value that itself looks like a placeholder is not substituted again', () {
      expect(SecretPlaceholders.substitute('{{secret:a}}', (id) => id == 'a' ? '{{secret:b}}' : 'B'), '{{secret:b}}');
    });
  });

  group('where a secret may be sent', () {
    String? p(String url, List<String> allowed, {bool insecure = false}) => SecretHosts.problem(url, allowed, allowInsecure: insecure);
    const gem = ['generativelanguage.googleapis.com'];

    test('the host that was chosen, with a path, a query and a port', () {
      expect(p('https://generativelanguage.googleapis.com/v1beta/models?pageSize=1', gem), isNull);
      expect(p('https://GenerativeLanguage.GoogleAPIs.com./v1beta/models', gem), isNull, reason: 'case and the dot of a full name do not matter');
      expect(p('https://generativelanguage.googleapis.com:443/x', gem), isNull);
      expect(p('https://generativelanguage.googleapis.com:8443/x', gem), isNull);
    });

    test('a host that only looks like it: user name, suffix, prefix, look-alike, extra label', () {
      for (final url in [
        'https://generativelanguage.googleapis.com@evil.example/x',
        'https://generativelanguage.googleapis.com:pass@evil.example/x',
        'https://generativelanguage.googleapis.com.evil.example/x',
        'https://evilgenerativelanguage.googleapis.com/x',
        'https://evil-generativelanguage.googleapis.com/x',
        'https://generativelanguage.googleapis.com-evil.example/x',
        'https://googleapis.com/x',
        'https://evil.example/generativelanguage.googleapis.com',
        'https://evil.example/?h=generativelanguage.googleapis.com',
        'https://evil.example#generativelanguage.googleapis.com',
      ]) {
        expect(p(url, gem), isNotNull, reason: url);
      }
    });

    test('written in a way that tricks a reader: backslash, space, control characters, encoded or non-ASCII host', () {
      for (final url in [
        r'https://generativelanguage.googleapis.com\@evil.example/x',
        r'https://evil.example\.generativelanguage.googleapis.com/x',
        'https://generativelanguage.googleapis.com /x',
        'https://generativelanguage.googleapis.com\n.evil.example/x',
        'https://generativelanguage.googleapis.com\t/x',
        'https://generativelanguage.googleapis.com\u0000.evil.example/x',
        'https://generativelanguage%2egoogleapis.com/x',
        'https://generativelanguage.googleapis.com%40evil.example/x',
        'https://ｇenerativelanguage.googleapis.com/x',
        'https://generativelanguage.googleapis.com。evil.example/x',
        'https://gеnerativelanguage.googleapis.com/x', // a Cyrillic е
      ]) {
        expect(p(url, gem), isNotNull, reason: url.replaceAll('\u0000', r'\0').replaceAll('\n', r'\n').replaceAll('\t', r'\t'));
      }
    });

    test('only https; http only when the user allowed it; other schemes never', () {
      expect(p('http://generativelanguage.googleapis.com/x', gem), contains('http'));
      expect(p('http://generativelanguage.googleapis.com/x', gem, insecure: true), isNull);
      for (final url in ['ftp://generativelanguage.googleapis.com/x', 'file:///etc/passwd', 'javascript:alert(1)', 'gopher://generativelanguage.googleapis.com/', 'ws://generativelanguage.googleapis.com/', '//generativelanguage.googleapis.com/x', 'generativelanguage.googleapis.com/x', '', '   ']) {
        expect(p(url, gem, insecure: true), isNotNull, reason: url);
      }
    });

    test('the inside of the device and the local network is never reached, whatever the user allowed', () {
      const any = ['*'];
      for (final host in [
        'localhost', 'LOCALHOST', 'app.localhost', 'intranet', 'printer.local', 'db.internal', 'nas.lan', 'router.home',
        '127.0.0.1', '127.1', '127.0.0.2', '0.0.0.0', '10.0.0.5', '172.16.0.1', '172.31.255.255', '192.168.1.1', '169.254.169.254',
        '100.64.0.1', '192.0.0.1', '198.18.0.1', '224.0.0.1', '255.255.255.255',
        '2130706433', '0x7f000001', '0x7f.0.0.1', '017700000001', '0177.0.0.1', '1.2.3', '1.2.3.4.5', '256.1.1.1', '01.2.3.4', '3232235777',
        '[::1]', '[::]', '[fe80::1]', '[fc00::1]', '[fd12:3456::1]', '[ff02::1]', '[::ffff:127.0.0.1]', '[::ffff:10.0.0.1]', '[::127.0.0.1]', '[::ffff:7f00:1]',
      ]) {
        expect(p('https://$host/x', any, insecure: true), isNotNull, reason: host);
      }
    });

    test('a public address is fine only when it is the host that was chosen', () {
      expect(p('https://8.8.8.8/x', gem), contains('may not be sent'));
      expect(p('https://8.8.8.8/x', ['8.8.8.8']), isNull);
      expect(p('https://[2001:4860:4860::8888]/x', ['2001:4860:4860::8888']), isNull);
      expect(p('https://[2001:4860:4860::8888]/x', gem), isNotNull);
    });

    test('allowed hosts: one name, a wildcard under a domain (not the domain itself), any; written as a URL too; empty means none', () {
      expect(p('https://api.example.com/x', ['*.example.com']), isNull);
      expect(p('https://a.b.example.com/x', ['*.example.com']), isNull);
      expect(p('https://example.com/x', ['*.example.com']), isNotNull);
      expect(p('https://badexample.com/x', ['*.example.com']), isNotNull);
      expect(p('https://example.com.evil.example/x', ['*.example.com']), isNotNull);
      expect(p('https://anything.example/x', ['*']), isNull);
      expect(p('https://api.example.com/x', ['https://api.example.com/v1']), isNull, reason: 'an entry written as a URL means its host');
      expect(p('https://api.example.com/x', const []), contains('none'));
      expect(p('https://api.example.com/x', ['', '  ']), isNotNull);
      expect(p('https://api.example.com/x', [' API.Example.com ']), isNull);
    });

    test('hosts written in a text: urls with other schemes too, once each; what cannot be read is returned as written', () {
      expect(SecretHosts.hostsInText('curl -s https://A.example.com/x?y=1 -d "u=https://b.example/q" && wget http://c.example:8080/z'), ['a.example.com', 'b.example', 'c.example']);
      expect(SecretHosts.hostsInText('git clone ssh://git@evil.example/repo; ftp://f.example/x'), ['git@evil.example'.isEmpty ? '' : 'evil.example', 'f.example']);
      expect(SecretHosts.hostsInText('echo hello'), isEmpty);
      expect(SecretHosts.hostsInText('curl https://a.example/x https://a.example/y'), ['a.example']);
      expect(SecretHosts.hostsInText(r'curl https://a.example\@evil.example/x'), isNotEmpty);
    });
  });

  group('taking values out of a text', () {
    const token = 'AIzaSyExample-Token_123=';

    test('the value as it is, URL-encoded, escaped for JSON, and in base64 (with and without padding, url-safe)', () {
      final forms = SecretRedaction.variants(token);
      for (final form in [token, Uri.encodeComponent(token), base64.encode(utf8.encode(token)), base64Url.encode(utf8.encode(token)).replaceAll('=', '')]) {
        expect(forms, contains(form));
      }
      // a value whose base64 has + and / (and padding) has its url-safe form too
      const odd = 'ab>?cd>?ef';
      expect(SecretRedaction.variants(odd), containsAll([base64.encode(utf8.encode(odd)), base64Url.encode(utf8.encode(odd)), base64Url.encode(utf8.encode(odd)).replaceAll('=', '')]));
      for (final form in forms) {
        final out = SecretRedaction.redact('before $form after', {'gemini': token});
        expect(out, 'before [secret:gemini] after', reason: form);
      }
    });

    test('JSON escaping: a value with a quote or a backslash is found inside a JSON text', () {
      const odd = r'ab"c\d';
      expect(SecretRedaction.redact(jsonEncode({'k': odd}), {'x': odd}), '{"k":"[secret:x]"}');
    });

    test('the longest form first, several secrets at once, and a short value is left alone', () {
      final out = SecretRedaction.redact('a=SECRETVALUE1 b=OTHER-VAL ab', {'one': 'SECRETVALUE1', 'two': 'OTHER-VAL', 'tiny': 'ab'});
      expect(out, 'a=[secret:one] b=[secret:two] ab');
      expect(SecretRedaction.variants('abc'), isEmpty);
      expect(SecretRedaction.redact('nothing', {'x': 'something-else'}), 'nothing');
    });

    test('the forms an attacker would pick: hex, \\u escapes, escaped slashes, HTML entities', () {
      const token = 'sk-Ab/12+xyZ';
      final forms = [
        [for (final b in utf8.encode(token)) b.toRadixString(16).padLeft(2, '0')].join(),
        [for (final u in token.codeUnits) '\\u${u.toRadixString(16).padLeft(4, '0')}'].join(),
        jsonEncode(token).substring(1, jsonEncode(token).length - 1).replaceAll('/', r'\/'),
        [for (final r in token.runes) '&#$r;'].join(),
      ];
      for (final form in forms) {
        expect(SecretRedaction.redact('x $form y', {'k': token}), 'x [secret:k] y', reason: form);
      }
    });

    test('a value in the middle of a longer base64 text is found at all three alignments', () {
      const token = 'AIzaSyExample-Token_123';
      for (final before in ['', 'a', 'ab', 'abc', 'abcd']) {
        for (final after in ['', 'z', 'zy', 'zyx']) {
          for (final codec in [base64, base64Url]) {
            final blob = codec.encode(utf8.encode('$before$token$after'));
            final out = SecretRedaction.redact('blob=$blob', {'k': token});
            expect(out, contains('[secret:k]'), reason: '$before|$after|$blob');
            expect(out, isNot(contains(token)));
          }
        }
      }
    });

    test('a value cut off at the end is taken out with trimTail (the other half may come next)', () {
      const token = 'AIzaSyExample-Token_123';
      final cut = 'text ${token.substring(0, 12)}';
      expect(SecretRedaction.redact(cut, {'k': token}), cut);
      expect(SecretRedaction.redact(cut, {'k': token}, trimTail: true), 'text ');
      // a whole value is replaced, and an ordinary end is left alone
      expect(SecretRedaction.redact('a $token', {'k': token}, trimTail: true), 'a [secret:k]');
      expect(SecretRedaction.redact('all done', {'k': token}, trimTail: true), 'all done');
    });

    test('a value that contains another secret is replaced whole', () {
      expect(SecretRedaction.redact('t=AAAA-BBBB-CCCC', {'long': 'AAAA-BBBB-CCCC', 'part': 'BBBB'}), 't=[secret:long]');
    });
  });
}
