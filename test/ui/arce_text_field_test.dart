import 'dart:io';

import 'package:arce_ai/ui/arce_text_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('a text field takes suggestions, autocorrect and the keyboard learning, as the chat box does', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ArceTextField(controller: TextEditingController()))));
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.enableSuggestions, isTrue, reason: 'Japanese conversion candidates');
    expect(field.autocorrect, isTrue);
    expect(field.enableIMEPersonalizedLearning, isTrue);
  });

  testWidgets('a secret is the one exception: hidden text is never offered to the keyboard dictionary', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ArceTextField(controller: TextEditingController(), obscure: true, maxLines: 5))));
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.obscureText, isTrue);
    expect(field.enableSuggestions, isFalse);
    expect(field.autocorrect, isFalse);
    expect(field.enableIMEPersonalizedLearning, isFalse);
    expect(field.maxLines, 1, reason: 'a hidden field is one line');
  });

  test('no screen builds a TextField of its own or turns suggestions off: they all use ArceTextField', () {
    final offenders = <String>[];
    for (final file in Directory('lib/ui').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      if (file.path.endsWith('arce_text_field.dart')) continue;
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (RegExp(r'\bTextField\(|\bTextFormField\(').hasMatch(line) && !line.contains('ArceTextField(')) offenders.add('${file.path}:${i + 1}: $line'.trim());
        if (RegExp(r'enableSuggestions:\s*false|autocorrect:\s*false').hasMatch(line)) offenders.add('${file.path}:${i + 1}: $line'.trim());
      }
    }
    expect(offenders, isEmpty, reason: 'use ArceTextField (lib/ui/arce_text_field.dart): one input behaviour for the whole app');
  });
}
