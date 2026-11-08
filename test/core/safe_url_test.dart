import 'package:arce_ai/core/safe_url.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  secretsInTheClear();
  test('a web address is opened', () {
    expect(safeWebUri('https://github.com/keusidan/arce.ai/releases')!.host, 'github.com');
    expect(safeWebUri('http://192.168.0.10:8080/search?q=a b')!.port, 8080);
    expect(safeWebUri('  HTTPS://Example.com/x\n')!.host, 'example.com', reason: 'spaces and line breaks around it are dropped');
  });

  test('anything that would start another app, read a file or run a script is not opened', () {
    for (final bad in [
      'intent://scan/#Intent;scheme=zxing;end',
      'tel:+819012345678',
      'sms:0901234567?body=hi',
      'file:///data/data/ai.arce.app/databases/x.db',
      'content://com.android.contacts/contacts',
      'javascript:alert(1)',
      'market://details?id=x',
      'ftp://example.com/x',
      '//example.com/no-scheme',
      'example.com/no-scheme',
      'https:///no-host',
      'https://good.example@evil.example/login',
      'ja\tvascript:alert(1)',
      '',
      '   ',
    ]) {
      expect(safeWebUri(bad), isNull, reason: bad);
    }
    expect(safeWebUri(null), isNull);
    expect(safeWebUri('https://example.com/${'a' * 5000}'), isNull, reason: 'an absurdly long address');
  });
}

void secretsInTheClear() {
  test('http to a host outside the house is a warning; https and the home network are not', () {
    for (final risky in ['http://api.example.com/v1', 'http://8.8.8.8:8080', 'http://172.32.0.1/', 'http://[2001:db8::1]/mcp', 'HTTP://Example.org']) {
      expect(sendsSecretsInTheClear(risky), isTrue, reason: risky);
    }
    for (final fine in [
      'https://api.openai.com/v1',
      'http://localhost:11434/v1',
      'http://127.0.0.1:8080',
      'http://192.168.0.10:8080',
      'http://10.1.2.3/mcp',
      'http://172.20.1.1',
      'http://raspberrypi.local:3000',
      'http://myserver:3000',
      'http://[::1]:8080',
      'ftp://example.com',
      'not a url',
      '',
    ]) {
      expect(sendsSecretsInTheClear(fine), isFalse, reason: fine);
    }
  });
}
