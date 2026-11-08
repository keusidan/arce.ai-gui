import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// One name for each thing on the screen. A name that is not used any more must not come back in a new text
/// (`コーディングモード` is 分担モード, `端末のモデル` is ローカルモデル, `プランナー` is plan ...). The terms list the names
/// with what each means; this test keeps the code to it.
void main() {
  /// Not used, with the name that is.
  const replaced = {
    'コーディングモード': '分担モード',
    'プロバイダー': 'プロバイダ',
    '端末のモデル': 'ローカルモデル',
    'オンラインのモデル': 'オンラインモデル',
    'Thinking 表示': '思考の表示',
    'Thinking アイコン': '思考中のアイコン',
    'Searchを': '検索を',
    '速度と精度': '速度⇔精度',
    '確認カード': '承認カード',
    '設定画面': '詳細設定',
    'アーティファクト': '生成物',
    'シークレット': '秘密',
    'プランナー': 'plan',
    '開発モデル': 'coding',
    '開発の役': 'coding',
  };

  /// The one file that may hold an old name: the words a person may type to choose the Artifact agent.
  bool exempt(String path, String name) => name == 'アーティファクト' && path.replaceAll('\\', '/').endsWith('lib/core/agents.dart');

  List<File> filesUnder(String dir, String extension) => [
        for (final e in Directory(dir).listSync(recursive: true))
          if (e is File && e.path.endsWith(extension)) e,
      ];

  test('the code (what the screen says) uses the names of the terms only', () {
    final problems = <String>[];
    for (final file in [...filesUnder('lib', '.dart'), File('README.md')]) {
      final text = file.readAsStringSync();
      replaced.forEach((old, now) {
        if (!exempt(file.path, old) && text.contains(old)) problems.add('${file.path}: 「$old」→「$now」');
      });
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

}
