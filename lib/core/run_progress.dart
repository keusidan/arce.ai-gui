/// What one reply has done so far, so the screen can say that it is going on and what it is doing:
/// the step, how many requests went out, how many tools ran, how long it has taken.
class RunProgress {
  const RunProgress({
    required this.startedAtMs,
    this.finishedAtMs = 0,
    this.stage = '',
    this.detail = '',
    this.modelRequests = 0,
    this.developerRequests = 0,
    this.toolRuns = 0,
    this.round = 1,
    this.inputTokens = 0,
    this.cachedTokens = 0,
    this.outputTokens = 0,
  });

  /// Milliseconds since the epoch.
  final int startedAtMs;

  /// 0 while the reply goes on.
  final int finishedAtMs;

  /// What it is doing now ("plan が考えています").
  final String stage;

  /// A line more about the step: what the model is thinking about, the search word, the file.
  final String detail;

  /// Requests to the model that answers (the planner, in the coding mode), retries included.
  final int modelRequests;

  /// Requests to the developer model of the coding mode, one for each job.
  final int developerRequests;
  final int toolRuns;

  /// How many times the model answered in this reply (each tool it called starts another).
  final int round;

  /// What the provider reported for the requests of this reply, added up: the prompt tokens it read,
  /// how many of them came from its cache, and what it wrote. 0 when it reports nothing (the device
  /// model, a provider without usage).
  final int inputTokens;
  final int cachedTokens;
  final int outputTokens;

  bool get running => finishedAtMs == 0;

  /// All the requests that went out to a model.
  int get requests => modelRequests + developerRequests;

  int elapsedMs(int nowMs) => (running ? nowMs : finishedAtMs) - startedAtMs;

  /// "通信 5 回（plan 3・coding 2）· ツール 1 回"
  String get counts {
    final parts = <String>[
      developerRequests > 0 ? '通信 $requests 回（plan $modelRequests・coding $developerRequests）' : '通信 $modelRequests 回',
      if (toolRuns > 0) 'ツール $toolRuns 回',
      if (inputTokens > 0) '入力 ${_n(inputTokens)} トークン${cachedTokens > 0 ? '（キャッシュ ${_n(cachedTokens)}）' : ''}',
    ];
    return parts.join(' · ');
  }

  static String _n(int value) {
    final digits = value.toString();
    final out = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
      out.write(digits[i]);
    }
    return out.toString();
  }

  /// "0:42", "12:05", "1:02:03"
  static String clock(int ms) {
    final total = ms < 0 ? 0 : ms ~/ 1000;
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
  }

  RunProgress copyWith({
    int? finishedAtMs,
    String? stage,
    String? detail,
    int? modelRequests,
    int? developerRequests,
    int? toolRuns,
    int? round,
    int? inputTokens,
    int? cachedTokens,
    int? outputTokens,
  }) => RunProgress(
    startedAtMs: startedAtMs,
    finishedAtMs: finishedAtMs ?? this.finishedAtMs,
    stage: stage ?? this.stage,
    detail: detail ?? this.detail,
    modelRequests: modelRequests ?? this.modelRequests,
    developerRequests: developerRequests ?? this.developerRequests,
    toolRuns: toolRuns ?? this.toolRuns,
    round: round ?? this.round,
    inputTokens: inputTokens ?? this.inputTokens,
    cachedTokens: cachedTokens ?? this.cachedTokens,
    outputTokens: outputTokens ?? this.outputTokens,
  );
}

/// Counts what a reply does. The chat controller, and the tools that work for a long time (the
/// developer model of the coding mode), tell it; [onChange] hands the new [RunProgress] to the screen.
/// It tells only when something changed, because the chat reports every piece of a stream.
class RunMeter {
  RunMeter({int Function()? now}) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final int Function() _now;
  RunProgress? _progress;

  void Function(RunProgress? progress)? onChange;

  RunProgress? get progress => _progress;

  /// A new reply: everything counts from zero.
  void begin() {
    _progress = RunProgress(startedAtMs: _now());
    onChange?.call(_progress);
  }

  /// The reply is over; the numbers stay for the screen to show.
  void end() {
    final p = _progress;
    if (p == null || !p.running) return;
    _set(p.copyWith(finishedAtMs: _now(), stage: '', detail: ''));
  }

  void clear() {
    if (_progress == null) return;
    _progress = null;
    onChange?.call(null);
  }

  /// What it is doing now. [detail] is cleared unless given.
  void stage(String stage, {String detail = ''}) {
    final p = _progress;
    if (p == null || !p.running) return;
    if (p.stage == stage && p.detail == detail) return;
    _set(p.copyWith(stage: stage, detail: detail));
  }

  void detail(String detail) {
    final p = _progress;
    if (p == null || !p.running || p.detail == detail) return;
    _set(p.copyWith(detail: detail));
  }

  /// A request went to the model that answers.
  void modelRequest() {
    final p = _progress;
    if (p == null || !p.running) return;
    _set(p.copyWith(modelRequests: p.modelRequests + 1));
  }

  /// A request went to the developer model.
  void developerRequest() {
    final p = _progress;
    if (p == null || !p.running) return;
    _set(p.copyWith(developerRequests: p.developerRequests + 1));
  }

  void toolRun() {
    final p = _progress;
    if (p == null || !p.running) return;
    _set(p.copyWith(toolRuns: p.toolRuns + 1));
  }

  /// What a provider said about the request that just ended; added to the totals of this reply.
  void usage({int? promptTokens, int? completionTokens, int? cachedTokens}) {
    final p = _progress;
    if (p == null || !p.running) return;
    _set(p.copyWith(
      inputTokens: p.inputTokens + (promptTokens ?? 0),
      cachedTokens: p.cachedTokens + (cachedTokens ?? 0),
      outputTokens: p.outputTokens + (completionTokens ?? 0),
    ));
  }

  void round(int n) {
    final p = _progress;
    if (p == null || !p.running || p.round == n) return;
    _set(p.copyWith(round: n));
  }

  void _set(RunProgress next) {
    _progress = next;
    onChange?.call(next);
  }
}

/// A few words about what a model's thinking is on now: the last heading it wrote (Gemini and others
/// write `**Analyzing the problem**` before each step), or else its last line.
abstract final class ThinkingHeadline {
  static const maxChars = 70;
  static const _tail = 3000;

  static String of(String thinking) {
    if (thinking.trim().isEmpty) return '';
    final tail = thinking.length > _tail ? thinking.substring(thinking.length - _tail) : thinking;
    final lines = tail.split('\n');
    String? lastLine;
    for (var i = lines.length - 1; i >= 0; i--) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;
      lastLine ??= line;
      final heading = RegExp(r'^(?:\*\*(.+?)\*\*|#{1,6}\s+(.+))$').firstMatch(line);
      if (heading != null) return _clean(heading.group(1) ?? heading.group(2)!);
    }
    return _clean(lastLine ?? '');
  }

  static String _clean(String line) {
    var text = line
        .replaceAll(RegExp(r'[*_`#>]+'), '')
        .replaceFirst(RegExp(r'^\s*(?:[-+]|\d+[.)])\s+'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (text.length > maxChars) text = '${text.substring(0, maxChars)}…';
    return text;
  }
}
