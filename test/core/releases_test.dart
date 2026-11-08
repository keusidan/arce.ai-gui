import 'package:arce_ai/core/releases.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('versions compare numerically and pre-releases sort first', () {
    expect(Version.parse('v0.1.10')! > Version.parse('0.1.9')!, isTrue);
    expect(Version.parse('1.0.0')! > Version.parse('1.0.0-beta')!, isTrue);
    expect(Version.parse('0.1.0-dev'), const Version(0, 1, 0, 'dev'));
    expect(Version.parse('latest'), isNull);
  });

  test('release json yields one asset and checksum per platform', () {
    final release = ReleaseParser.parse('''{"tag_name":"v0.4.1","body":"notes","html_url":"https://github.com/x/y/releases/tag/v0.4.1","assets":[
      {"id":1,"name":"ARCE.AI-v0.4.1-android.apk","size":10117153},
      {"id":2,"name":"ARCE.AI-v0.4.1-android.apk.sha256","size":85},
      {"id":3,"name":"ARCE.AI-v0.4.1-windows-x64.zip","size":99},
      {"id":4,"name":"ARCE.AI-v0.4.1-linux-x64.tar.gz","size":98}]}''')!;
    expect(release.version, const Version(0, 4, 1));
    final apk = release.assetFor(UpdateTarget.android)!;
    expect(apk.id, 1);
    expect(release.checksumFor(apk)!.id, 2);
    expect(release.assetFor(UpdateTarget.windows)!.id, 3);
    expect(release.assetFor(UpdateTarget.linux)!.id, 4);
    expect(release.assetFor(UpdateTarget.macos), isNull);
    expect(ReleaseParser.parseChecksum('${'ab' * 32}  ARCE.AI-v0.4.1-android.apk\n'), 'ab' * 32);
    expect(ReleaseParser.parseChecksum('nope'), isNull);
  });

  test('each platform has its own tags and the newest one of its own is picked', () {
    const list = '''[
      {"tag_name":"ios-v0.5.0","assets":[{"id":1,"name":"ARCE.AI-v0.5.0-ios-unsigned.ipa","size":1}]},
      {"tag_name":"v0.4.0","assets":[{"id":2,"name":"ARCE.AI-v0.4.0-android.apk","size":1}]},
      {"tag_name":"v0.3.1","assets":[{"id":3,"name":"ARCE.AI-v0.3.1.apk","size":1}]},
      {"tag_name":"windows-v0.4.5","assets":[{"id":4,"name":"ARCE.AI-v0.4.5-windows-x64.zip","size":1}]},
      {"tag_name":"windows-v0.4.9","draft":true,"assets":[{"id":5,"name":"ARCE.AI-v0.4.9-windows-x64.zip","size":1}]},
      {"tag_name":"v0.6.0","assets":[]}
    ]''';
    expect(ReleaseParser.latestFor(list, UpdateTarget.android)!.tag, 'v0.4.0',
        reason: 'the plain tag is Android; v0.6.0 has no APK; ios- and windows- tags are other platforms');
    expect(ReleaseParser.latestFor(list, UpdateTarget.ios)!.version, const Version(0, 5, 0));
    expect(ReleaseParser.latestFor(list, UpdateTarget.windows)!.tag, 'windows-v0.4.5', reason: 'a draft is ignored');
    expect(ReleaseParser.latestFor(list, UpdateTarget.linux), isNull);
  });
}
