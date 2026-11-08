import 'package:arce_ai/core/run_progress.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ThinkingHeadline', () {
    test('the last heading the model wrote', () {
      const text = '**Analyzing the problem**\n\nI will look at the graph.\n\n**Choosing an algorithm**\n\nLink-cut trees fit.';
      expect(ThinkingHeadline.of(text), 'Choosing an algorithm');
    });

    test('a markdown heading counts too', () {
      expect(ThinkingHeadline.of('## 方針\n本文'), '方針');
    });

    test('without a heading, the last line, cleaned and cut', () {
      expect(ThinkingHeadline.of('最初の行\n- 最後の行は `code` を含む'), '最後の行は code を含む');
      final long = 'あ' * 200;
      final line = ThinkingHeadline.of(long);
      expect(line.length, ThinkingHeadline.maxChars + 1);
      expect(line, endsWith('…'));
    });

    test('nothing to say for an empty thinking, and a huge one is read from its end only', () {
      expect(ThinkingHeadline.of('  \n '), '');
      final huge = '${'x\n' * 50000}**最後の見出し**\n本文';
      expect(ThinkingHeadline.of(huge), '最後の見出し');
    });
  });

  group('RunProgress', () {
    test('the numbers read as one line', () {
      const p = RunProgress(startedAtMs: 0, modelRequests: 3, developerRequests: 2, toolRuns: 1);
      expect(p.counts, '通信 5 回（plan 3・coding 2） · ツール 1 回');
      expect(const RunProgress(startedAtMs: 0, modelRequests: 1).counts, '通信 1 回');
    });

    test('what the provider reports is added up, with the cached part', () {
      const p = RunProgress(startedAtMs: 0, modelRequests: 2, inputTokens: 12340, cachedTokens: 9800);
      expect(p.counts, '通信 2 回 · 入力 12,340 トークン（キャッシュ 9,800）');
      expect(const RunProgress(startedAtMs: 0, modelRequests: 1, inputTokens: 500).counts, '通信 1 回 · 入力 500 トークン');

      final meter = RunMeter(now: () => 0)..begin();
      meter.usage(promptTokens: 1000, completionTokens: 20, cachedTokens: 0);
      meter.usage(promptTokens: 1100, completionTokens: 30, cachedTokens: 900);
      meter.usage(); // a request that reported nothing
      expect((meter.progress!.inputTokens, meter.progress!.cachedTokens, meter.progress!.outputTokens), (2100, 900, 50));
    });

    test('the clock', () {
      expect(RunProgress.clock(0), '0:00');
      expect(RunProgress.clock(42000), '0:42');
      expect(RunProgress.clock(725000), '12:05');
      expect(RunProgress.clock(3723000), '1:02:03');
      expect(RunProgress.clock(-5), '0:00');
    });

    test('the time stops when the reply ends', () {
      const p = RunProgress(startedAtMs: 1000, finishedAtMs: 4000);
      expect(p.running, isFalse);
      expect(p.elapsedMs(99999), 3000);
      expect(const RunProgress(startedAtMs: 1000).elapsedMs(2500), 1500);
    });
  });

  group('RunMeter', () {
    test('tells only when something changed', () {
      var now = 0;
      final meter = RunMeter(now: () => now);
      var told = 0;
      meter.onChange = (_) => told++;
      meter.stage('x'); // before begin: nothing to report on
      expect(told, 0);
      meter.begin();
      expect(told, 1);
      meter.stage('考えています', detail: 'a');
      meter.stage('考えています', detail: 'a');
      meter.detail('a');
      expect(told, 2, reason: 'the same step and line are not told again');
      meter.modelRequest();
      meter.developerRequest();
      meter.toolRun();
      meter.round(2);
      meter.round(2);
      expect(told, 6);
      now = 5000;
      meter.end();
      final end = meter.progress!;
      expect(end.running, isFalse);
      expect(end.elapsedMs(0), 5000);
      expect((end.modelRequests, end.developerRequests, end.toolRuns, end.round), (1, 1, 1, 2));
      meter.modelRequest(); // a reply that is over is not counted any more
      expect(meter.progress!.modelRequests, 1);
      meter.clear();
      expect(meter.progress, isNull);
    });
  });
}
