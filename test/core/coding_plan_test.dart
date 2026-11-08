import 'package:arce_ai/core/coding_plan.dart';
import 'package:arce_ai/core/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('設定と参照', () {
    test('provider|model の形を読む', () {
      expect(CodingSettings.parseRef('openai|gpt-4o'), ('openai', 'gpt-4o'));
      expect(CodingSettings.parseRef('local|'), ('local', ''));
      expect(CodingSettings.parseRef('deepinfra|deepseek-ai/DeepSeek|x'), ('deepinfra', 'deepseek-ai/DeepSeek|x'));
      expect(CodingSettings.parseRef(''), isNull);
      expect(CodingSettings.parseRef('|x'), isNull);
    });

    test('両方の役にモデルがあって、オンのときだけ使える', () {
      expect(const CodingSettings(enabled: true, planner: 'a|b', developer: 'c|d').isReady, isTrue);
      expect(const CodingSettings(enabled: false, planner: 'a|b', developer: 'c|d').isReady, isFalse);
      expect(const CodingSettings(enabled: true, planner: 'a|b').isReady, isFalse);
    });
  });

  group('分担の設定', () {
    test('plan は使用中のモデルに合わせるのが既定。選んだモデルに固定するときだけ、plan の欄が要る', () {
      const follows = CodingSettings(enabled: true, developer: 'd|m');
      expect(follows.plannerFollowsModel, isTrue);
      expect(follows.isReady, isTrue, reason: 'no planner chosen, and none needed');
      const fixed = CodingSettings(enabled: true, developer: 'd|m', plannerFollowsModel: false);
      expect(fixed.isReady, isFalse);
      expect(const CodingSettings(enabled: true, developer: 'd|m', plannerFollowsModel: false, planner: 'p|m').isReady, isTrue);
    });

    test('coding は複数（最初のものから順に。空と重なりは除く）。1 つも無ければ始まらない', () {
      const s = CodingSettings(enabled: true, developer: 'a|1', moreDevelopers: ['b|2', ' ', 'a|1', 'c|3']);
      expect(s.developers, ['a|1', 'b|2', 'c|3']);
      expect(const CodingSettings(enabled: true, moreDevelopers: ['b|2']).developers, ['b|2'], reason: 'the first may be empty');
      expect(const CodingSettings(enabled: true).isReady, isFalse);
    });
  });

  group('plan に伝えること', () {
    test('分け方も、直させるかも、plan が決める。アプリは上限と使い方だけを伝える', () {
      final text = CodingPrompts.plannerInstructions(maxTasks: 3, reviewRounds: 2);
      expect(text, contains('delegate'));
      expect(text, contains('at most 3 per call'));
      expect(text, contains('Mermaid flowchart'), reason: 'the split is drawn as a diagram');
      expect(text, contains('SMALL goals'));
      expect(text, contains('revise'));
      expect(text, contains('at most 2 times'));
      expect(text, contains('do not copy their files into your answer'), reason: 'the user already sees the developers\' files');
      expect(text, contains('do not ask you'), reason: 'the developers decide on their own');
      expect(text, contains('answer yourself'), reason: 'a small job is not delegated');
      expect(text, contains('/workspace/PLAN.md'), reason: 'the same plan can be handed to a command-line agent');
      expect(text, contains('shell_session'));
    });

    test('直しの回数が 0 なら、直させないと伝える', () {
      final text = CodingPrompts.plannerInstructions(maxTasks: 4, reviewRounds: 0);
      expect(text, contains('Do not send work back'));
      expect(text, isNot(contains('revise set to')));
    });
  });

  group('coding に渡すこと', () {
    test('計画の要約と、そのタスクだけ。ほかのタスクは見せない', () {
      const first = DelegateTask(title: 'A', instructions: 'Aを作る', files: ['a.py']);
      final text = CodingPrompts.developerTask('共有の決めごと', first);
      expect(text, contains('共有の決めごと'));
      expect(text, contains('Aを作る'));
      expect(text, contains('a.py'));
      expect(text, isNot(contains('Bを作る')));
    });

    test('要約が空なら、その見出しは出さない', () {
      final text = CodingPrompts.developerTask('  ', const DelegateTask(title: 'A', instructions: 'Aを作る'));
      expect(text, isNot(contains('The plan')));
    });

    test('前の仕事の結果を待っていた仕事には、その結果が渡る（id と題つき）', () {
      final text = CodingPrompts.developerTask(
        '決めごと',
        const DelegateTask(title: '画面', instructions: '画面を作る'),
        given: const [('d1', 'モデル', 'class User {}')],
      );
      expect(text, contains('# Result of the job you waited for: d1 — モデル'));
      expect(text, contains('class User {}'));
      expect(text.indexOf('class User {}'), lessThan(text.indexOf('# Your task')), reason: 'the results come before the task');
    });

    test('coding は聞かずに自分で決める。どうしても進めないときだけ QUESTION: で答える', () {
      expect(CodingPrompts.developer, contains('decide every detail yourself'));
      expect(CodingPrompts.developer, contains('"QUESTION:"'));
      expect(CodingPrompts.questionIn('QUESTION: どの言語？'), 'どの言語？');
      expect(CodingPrompts.questionIn('  question：全角でも'), '全角でも');
      expect(CodingPrompts.questionIn('QUESTION:'), isNull);
      expect(CodingPrompts.questionIn('コードです\nQUESTION: 途中の行'), isNull, reason: 'a question is the whole answer');
    });

    test('答えの「File: パス」の行から、書いたファイルが分かる', () {
      expect(CodingPrompts.filesIn('File: a.py\n```python\n```\nFile: `b/c.dart`\nfile: ignored.txt\nFile: a.py'), ['a.py', 'b/c.dart']);
      expect(CodingPrompts.filesIn('コードだけ'), isEmpty);
    });

    test('直しの依頼は、直す内容と「完全なファイルで」を伝える', () {
      final text = CodingPrompts.correction('  関数名を add に  ');
      expect(text, contains('関数名を add に'));
      expect(text, contains('complete corrected files'));
    });
  });
}
