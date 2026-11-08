import 'package:arce_ai/ai/provider_config.dart';
import 'package:arce_ai/core/shell_secrets.dart';
import 'package:arce_ai/services/app_controller.dart';
import 'package:arce_ai/ui/secrets_widgets.dart';
import 'package:arce_ai/ui/theme.dart';
import 'package:arce_ai/ui/widgets.dart' show ArceSwitch;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app_test.dart' show makeApp, setSize;

/// The secrets card and the http_request card on their own (the Linux group that holds them is Android only).
Future<AppController> pumpScreen(WidgetTester tester) async {
  setSize(tester, const Size(411, 2400));
  final app = await makeApp(tester);
  await tester.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: Scaffold(
      body: SingleChildScrollView(
        child: Column(children: [ShellSecretsCard(app: app), HttpRequestCard(app: app)]),
      ),
    ),
  ));
  await tester.pump();
  return app;
}

Finder field(String label) => find.byWidgetPredicate((w) => w is TextField && w.decoration?.labelText == label);

/// Lets what waits for the secure storage (a platform channel: the real event loop) end.
Future<void> settle(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
  await tester.pumpAndSettle();
}

void main() {
  group('SecretHostsInput', () {
    test('parse: one per line, or separated by commas and spaces, trimmed, each once', () {
      expect(SecretHostsInput.parse(' api.example.com\n*.example.org, api.example.com ;x.test\n\n'), ['api.example.com', '*.example.org', 'x.test']);
      expect(SecretHostsInput.parse(''), isEmpty);
    });

    test('firstInvalid: hosts, a wildcard name, *, and a URL are fine; the rest is named', () {
      expect(SecretHostsInput.firstInvalid(['api.example.com', '*.example.com', '*', 'https://api.example.com/v1']), isNull);
      expect(SecretHostsInput.firstInvalid(['ok.example.com', 'bad host']), 'bad host');
      expect(SecretHostsInput.firstInvalid(['exa*mple.com']), 'exa*mple.com');
      expect(SecretHostsInput.firstInvalid(['https://']), 'https://');
      expect(SecretHostsInput.firstInvalid(['*.']), '*.');
    });
  });

  testWidgets('every item that holds a key is listed with its placeholder, its hosts and a switch; a typed one can be edited and deleted', (tester) async {
    final app = await pumpScreen(tester);
    await tester.runAsync(() async {
      await app.providers.save(const ProviderConfig(id: 'gem', label: 'Gemini', baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai', models: [ModelConfig(id: 'm', name: 'm')]));
      await app.providers.setKey('gem', 'AIza-secret-value');
      await app.settings.setShellSecret(const ShellSecret(name: 'GITHUB_TOKEN', hosts: ['api.github.com']), 'ghp_value_1234');
    });
    await tester.pump();

    expect(find.text('秘密（モデルが {{secret:ID}} で使う）'), findsOneWidget);
    expect(find.text('{{secret:gemini}}'), findsOneWidget, reason: 'the id is made from the name of the provider');
    expect(find.text('{{secret:github-token}}'), findsWidgets, reason: 'the typed secret and the GitHub token of the app both make this one: one is numbered');
    expect(find.textContaining('generativelanguage.googleapis.com'), findsWidgets);
    expect(find.textContaining('AIza-secret-value'), findsNothing, reason: 'a value is never shown');
    expect(find.textContaining('ghp_value_1234'), findsNothing);

    // the switch of the provider's key: off puts its stable key in the list, on takes it out
    final gemini = find.byKey(const ValueKey('secret-entry-gemini'));
    expect(gemini, findsOneWidget);
    final toggle = find.descendant(of: gemini, matching: find.byType(ArceSwitch));
    expect(tester.widget<ArceSwitch>(toggle).value, isTrue);
    await tester.tap(toggle);
    await settle(tester);
    expect(app.settings.value.secretsOffForModel, ['provider:gem']);
    expect(app.secretBook().byId('gemini')!.modelMayUse, isFalse);
    expect(tester.widget<ArceSwitch>(find.descendant(of: gemini, matching: find.byType(ArceSwitch))).value, isFalse);
    await tester.tap(find.descendant(of: gemini, matching: find.byType(ArceSwitch)));
    await settle(tester);
    expect(app.settings.value.secretsOffForModel, isEmpty);

    // a typed secret: its hosts are changed without typing the value again, and the value is kept
    await tester.tap(find.byKey(const ValueKey('secret-edit-github-token')));
    await tester.pumpAndSettle();
    expect(find.text('秘密を編集'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('secret-hosts')), 'api.github.com\nuploads.github.com');
    await tester.pump();
    expect(find.byKey(const ValueKey('hosts-ok')), findsOneWidget);
    await tester.ensureVisible(find.text('保存'));
    await tester.tap(find.text('保存'));
    await settle(tester);
    expect(app.settings.value.shellSecrets.single.hosts, ['api.github.com', 'uploads.github.com']);
    expect(app.settings.shellSecretValue(app.settings.value.shellSecrets.single), 'ghp_value_1234');
    await tester.pump(const Duration(seconds: 30));

    // and deleted
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('secret-entry-github-token')), matching: find.byTooltip('削除')));
    await settle(tester);
    expect(app.settings.value.shellSecrets, isEmpty);
    await tester.pump(const Duration(seconds: 30));
  });

  testWidgets('an item that has no value or no host says why a model cannot use it', (tester) async {
    final app = await pumpScreen(tester);
    await tester.runAsync(() async {
      await app.providers.save(const ProviderConfig(id: 'p', label: 'Plain', baseUrl: 'https://api.plain.example/v1', models: [ModelConfig(id: 'm', name: 'm')]));
      await app.settings.setShellSecret(const ShellSecret(name: 'NO_HOST'), 'value-1234');
    });
    await tester.pump();
    expect(find.textContaining('値が入っていません'), findsWidgets, reason: 'the provider has no key');
    expect(find.textContaining('送ってよいホストが決まっていません'), findsOneWidget, reason: 'the typed secret has no host');
    await tester.pump(const Duration(seconds: 30));
  });

  testWidgets('the editor: a name that cannot be used and a host that cannot be read are refused, * is warned about, and nothing is saved', (tester) async {
    final app = await pumpScreen(tester);
    await tester.ensureVisible(find.text('秘密を追加'));
    await tester.tap(find.text('秘密を追加'));
    await tester.pumpAndSettle();
    expect(find.text('秘密を追加'), findsWidgets);
    expect(find.byKey(const ValueKey('hosts-empty')), findsOneWidget, reason: 'no host: said what it means');

    await tester.enterText(find.byKey(const ValueKey('secret-name')), 'PATH');
    await tester.enterText(find.byKey(const ValueKey('secret-value')), 'abcd1234');
    await tester.ensureVisible(find.text('保存'));
    await tester.tap(find.text('保存'));
    await settle(tester);
    expect(app.settings.value.shellSecrets, isEmpty, reason: 'PATH is reserved');
    await tester.pump(const Duration(seconds: 30));

    await tester.enterText(find.byKey(const ValueKey('secret-name')), 'MY_KEY');
    await tester.enterText(find.byKey(const ValueKey('secret-hosts')), 'bad_host.example.com');
    await tester.pump();
    expect(find.byKey(const ValueKey('hosts-bad')), findsOneWidget);
    await tester.tap(find.text('保存'));
    await settle(tester);
    expect(app.settings.value.shellSecrets, isEmpty, reason: 'the host cannot be read');
    await tester.pump(const Duration(seconds: 30));

    await tester.enterText(find.byKey(const ValueKey('secret-hosts')), '*');
    await tester.pump();
    expect(find.byKey(const ValueKey('hosts-any')), findsOneWidget, reason: 'anywhere: a warning');
    await tester.tap(find.text('保存'));
    await settle(tester);
    expect(app.settings.value.shellSecrets.single.hosts, ['*'], reason: 'it is allowed, after the warning');
    expect(app.settings.shellSecretValue(app.settings.value.shellSecrets.single), 'abcd1234');
    await tester.pump(const Duration(seconds: 30));
  });

  testWidgets('http_request: the switch, the confirmation, the insecure switch and the two numbers are saved; the risky ones warn', (tester) async {
    final app = await pumpScreen(tester);
    expect(app.settings.value.httpRequestEnabled, isTrue);
    expect(find.byKey(const ValueKey('http-confirm-warning')), findsNothing);
    expect(find.byKey(const ValueKey('http-insecure-warning')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('http-confirm-never')));
    await settle(tester);
    expect(app.settings.value.httpRequestConfirm, 'never');
    expect(find.byKey(const ValueKey('http-confirm-warning')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('http-confirm-all')));
    await settle(tester);
    expect(app.settings.value.httpRequestConfirm, 'all');
    expect(find.byKey(const ValueKey('http-confirm-warning')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('http-max-50000')));
    await settle(tester);
    expect(app.settings.value.httpRequestMaxResponseChars, 50000);
    await tester.tap(find.byKey(const ValueKey('http-timeout-120')));
    await settle(tester);
    expect(app.settings.value.httpRequestTimeoutSeconds, 120);

    final switches = find.descendant(of: find.byType(HttpRequestCard), matching: find.byType(ArceSwitch));
    final insecure = switches.at(1);
    await tester.ensureVisible(insecure);
    await tester.tap(insecure);
    await settle(tester);
    expect(app.settings.value.httpRequestAllowInsecure, isTrue);
    expect(find.byKey(const ValueKey('http-insecure-warning')), findsOneWidget);

    final enabled = switches.at(0);
    await tester.ensureVisible(enabled);
    await tester.tap(enabled);
    await settle(tester);
    expect(app.settings.value.httpRequestEnabled, isFalse);
    await tester.pump(const Duration(seconds: 30));
  });

  testWidgets('a large text scale and a narrow screen do not overflow', (tester) async {
    setSize(tester, const Size(320, 2400));
    final app = await makeApp(tester);
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.6)), child: child!),
      home: Scaffold(body: SingleChildScrollView(child: Column(children: [ShellSecretsCard(app: app), HttpRequestCard(app: app)]))),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
