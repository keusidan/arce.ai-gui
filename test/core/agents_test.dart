import 'package:arce_ai/core/agents.dart';
import 'package:arce_ai/core/attachments.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const unclearRequest = '週末に家族で楽しめる過ごし方を一緒に考えてほしいです';

  group('AgentSelector', () {
    test('keywords pick the most specific agent', () {
      expect(AgentSelector.select('HTMLでゲームを作って', false, null), Agents.artifact);
      expect(AgentSelector.select('Pythonで関数を実装して', false, null), Agents.coding);
      expect(AgentSelector.select('最新のニュースを調べて', false, null), Agents.research);
      expect(AgentSelector.select('こんにちは', false, null), Agents.general);
    });

    test('attachments and manual override', () {
      expect(AgentSelector.select('これは何？', true, null), Agents.fileAnalysis);
      expect(AgentSelector.select('こんにちは', false, 'coding'), Agents.coding);
    });

    test('attachments are capped per file and in total', () {
      final big = Attachment('a.txt', 'x' * 20000);
      final composed = AttachmentPolicy.compose('要約して', [big, big, big]);
      expect(composed, contains('<file name="a.txt">'));
      expect(composed, contains('characters omitted'));
      expect(composed.length, lessThan(AttachmentPolicy.maxTotalChars + 1000));
      expect(composed, endsWith('要約して'));
    });
  });

  group('AgentRouter', () {
    test('clear keyword hits never ask the model', () async {
      var asked = false;
      final router = AgentRouter((_, _) async {
        asked = true;
        return '{"agent":"research"}';
      });
      expect(await router.select('Pythonでスクリプトを作って', false, null, useModel: true), Agents.coding);
      expect(asked, isFalse);
    });

    test('ambiguous request is settled by the model', () async {
      expect(AgentSelector.isAmbiguous(unclearRequest, false), isTrue);
      final router = AgentRouter((prompt, schema) async {
        expect(schema, allOf(contains('research'), contains('file-analysis')));
        expect(prompt, endsWith('</think>\n\n'));
        return '{"agent": "research"}';
      });
      expect(await router.select(unclearRequest, false, null, useModel: true), Agents.research);
    });

    test('bad answers, failures and disabled selection fall back to the rules', () async {
      Future<AgentDefinition> pick(AgentClassifier c, {bool useModel = true}) =>
          AgentRouter(c).select(unclearRequest, false, null, useModel: useModel);
      expect(await pick((_, _) async => '{"agent":"hacker"}'), Agents.general);
      expect(await pick((_, _) async => null), Agents.general);
      expect(await pick((_, _) async => throw StateError('boom')), Agents.general);
      expect(await pick((_, _) async => '{"agent":"coding"}', useModel: false), Agents.general);
    });

    test('user override wins and greetings are not ambiguous', () async {
      final router = AgentRouter((_, _) async => '{"agent":"coding"}');
      expect(await router.select(unclearRequest, false, 'artifact', useModel: true), Agents.artifact);
      expect(AgentSelector.isAmbiguous('こんにちは', false), isFalse);
    });
  });
}
