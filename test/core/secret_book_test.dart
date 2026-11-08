import 'package:arce_ai/core/secret_book.dart';
import 'package:arce_ai/core/shell_secrets.dart';
import 'package:flutter_test/flutter_test.dart';

SecretSource source(SecretKind kind, String name, {String key = 'k-value', List<String> hosts = const ['api.example.com'], String? id}) =>
    SecretSource(kind: kind, name: name, source: id ?? name, hosts: hosts, value: key);

void main() {
  test('every item that holds a key gets an id from its name: kinds side by side, repeated names numbered, a name with nothing to make an id of gets the kind', () {
    final book = SecretRegistry([
      source(SecretKind.own, 'NPM_TOKEN'),
      source(SecretKind.provider, 'Gemini', id: 'gem'),
      source(SecretKind.provider, 'Gemini (無料枠)', id: 'gem2'),
      source(SecretKind.provider, '無料枠', id: 'free'),
      source(SecretKind.mcp, 'GitHub', id: 'github'),
      source(SecretKind.search, 'Brave Search', id: 'brave'),
      source(SecretKind.github, 'GitHub token', id: 'token'),
    ]);
    expect(book.entries.map((e) => e.id).toList(), ['npm-token', 'gemini', 'gemini-2', 'provider', 'github', 'brave-search', 'github-token']);
    expect(book.entries.map((e) => e.stableKey).toList(), ['own:NPM_TOKEN', 'provider:gem', 'provider:gem2', 'provider:free', 'mcp:github', 'search:brave', 'github:token']);
    expect(book.byId('GEMINI')!.label, 'Gemini', reason: 'an id is found whatever its case');
    expect(book.byId('nope'), isNull);
  });

  test('a value is handed out only for an item that has one, somewhere to go, and is not shut off for the model', () {
    final book = SecretRegistry([
      source(SecretKind.provider, 'Gemini', key: 'AIza-key', hosts: const ['generativelanguage.googleapis.com'], id: 'gem'),
      source(SecretKind.provider, 'Empty', key: '', id: 'e'),
      source(SecretKind.own, 'NOWHERE', hosts: const []),
      source(SecretKind.mcp, 'Shut', key: 'tok', id: 's'),
    ], off: {'mcp:s'});
    expect(book.valueOf('gemini'), 'AIza-key');
    expect(book.valueOf('GEMINI'), 'AIza-key');
    expect(book.valueOf('empty'), isNull);
    expect(book.valueOf('nowhere'), isNull);
    expect(book.valueOf('shut'), isNull);
    expect(book.byId('empty')!.unusableReason, contains('値が入っていません'));
    expect(book.byId('nowhere')!.unusableReason, contains('ホスト'));
    expect(book.byId('shut')!.unusableReason, contains('使わせない'));
    expect(book.byId('gemini')!.unusableReason, isNull);
    expect(book.byId('gemini')!.modelMayUse, isTrue);
  });

  test('the name a command sees, and blank hosts are dropped', () {
    final book = SecretRegistry([source(SecretKind.provider, 'Open AI', hosts: const ['api.openai.com', '  ', ''], id: 'o')]);
    expect(book.byId('open-ai')!.envName, 'ARCE_SECRET_OPEN_AI');
    expect(book.byId('open-ai')!.hosts, ['api.openai.com']);
  });

  test('the host of an address, for the list of a provider or a server', () {
    expect(SecretRegistry.hostOfUrl('https://generativelanguage.googleapis.com/v1beta/openai'), 'generativelanguage.googleapis.com');
    expect(SecretRegistry.hostOfUrl(' https://API.example.com:8443/x '), 'api.example.com');
    expect(SecretRegistry.hostOfUrl('not a url'), isNull);
    expect(SecretRegistry.hostOfUrl(''), isNull);
  });

  test('the empty book has nothing', () {
    const book = EmptySecretBook();
    expect(book.entries, isEmpty);
    expect(book.valueOf('x'), isNull);
    expect(book.byId('x'), isNull);
  });

  test('a typed secret keeps its hosts through the settings JSON; an old save without them still loads, and an empty list is not written', () {
    const own = ShellSecret(name: 'NPM_TOKEN', hosts: ['registry.npmjs.org', '*.example.com']);
    expect(ShellSecret.fromJson(own.toJson())!.hosts, ['registry.npmjs.org', '*.example.com']);
    expect(ShellSecret.fromJson({'name': 'OLD'})!.hosts, isEmpty);
    expect(const ShellSecret(name: 'X').toJson().containsKey('hosts'), isFalse);
    expect(ShellSecret.fromJson({'name': 'X', 'hosts': ['a.example', 5, '  ', 'b.example']})!.hosts, ['a.example', 'b.example']);
  });
}
