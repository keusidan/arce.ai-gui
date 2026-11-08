import 'dart:async';

import '../core/engine.dart';
import '../core/generation.dart';

/// Stands in for a model on platforms without an engine, and before a model is loaded, so
/// the whole interface can be tried. It answers with a fixed notice.
class DemoEngine implements InferenceEngine {
  bool _cancelled = false;

  @override
  bool get isLoaded => false;

  @override
  Future<void> load(LoadParams params) async =>
      throw EngineException('このビルドには推論エンジンが入っていません');

  @override
  Future<void> unload() async {}

  @override
  void cancel() => _cancelled = true;

  static String lastUserText(String prompt) {
    final start = prompt.lastIndexOf('<|im_start|>user\n');
    if (start < 0) return '';
    final from = start + '<|im_start|>user\n'.length;
    final end = prompt.indexOf('<|im_end|>', from);
    final text = prompt.substring(from, end < 0 ? prompt.length : end);
    // the latest user turn may be a tool response or carry attached files; show the typed part
    final withoutFiles = text.replaceAll(RegExp(r'<file name=".*?">[\s\S]*?</file>\n?'), '').trim();
    return withoutFiles.length > 80 ? '${withoutFiles.substring(0, 80)}…' : withoutFiles;
  }

  static const _pythonSample = '''```python
todos = []

def add(title):
    todos.append({"title": title, "done": False})

def complete(index):
    todos[index]["done"] = True

add("レポートを書く")
add("買い物に行く")
complete(1)
for i, t in enumerate(todos):
    print(i, "[x]" if t["done"] else "[ ]", t["title"])
```''';

  static const _htmlSample = '''```html
<!doctype html>
<html lang="ja">
<head><meta charset="utf-8"><title>今日のタスク</title></head>
<body style="font-family:sans-serif;padding:24px;background:#f6f7fa">
  <h1>今日のタスクを、すっきり整理。</h1>
  <p>小さく分けて、ひとつずつ進めましょう。</p>
  <button onclick="alert('追加しました')">タスクを追加</button>
</body>
</html>
```''';

  static const _askCall =
      '<tool_call>\n{"name":"ask_user","arguments":{"title":"どの言語で作りますか？","options":["Python","Kotlin","Dart"],"allow_free_input":true}}\n</tool_call>';

  /// What the demo says for a request: a plain notice, or a sample that exercises the code,
  /// preview and question views.
  static String replyFor(String request, {required bool canAsk}) {
    final lower = request.toLowerCase();
    final notice = '※ 推論エンジンに接続されていないため、これは固定のデモ応答です。';
    if (canAsk && (request.contains('質問') || lower.contains('ask'))) {
      return '作る前に、確認させてください。\n$_askCall';
    }
    if (lower.contains('html') || request.contains('ページ') || request.contains('サイト')) {
      return 'シンプルなページを作りました。**プレビュー**で表示を確認できます。\n\n$_htmlSample\n\n$notice';
    }
    if (request.contains('コード') || lower.contains('python') || request.contains('作って')) {
      return 'ToDo リストの例です。**追加**と**完了**だけの小さな実装です。\n\n$_pythonSample\n\n$notice';
    }
    return '「$request」を受け取りました。\n\n'
        '今は推論エンジンに接続されていないため、実際の回答は行っていません。\n\n'
        'Android 版でモデルを読み込むと、同じ画面で端末内AIと会話できます。'
        '履歴・設定・Artifact の表示は、このままお試しいただけます。';
  }

  @override
  Stream<GenerationEvent> generate(GenerateRequest request) async* {
    _cancelled = false;
    final echo = lastUserText(request.prompt);
    final reply = StringBuffer();
    if (request.thinking) reply.write('<think>入力を確認して、デモ応答を準備しています。</think>');
    reply.write(replyFor(echo, canAsk: request.toolCallSchema != null));
    final text = reply.toString();
    for (var i = 0; i < text.length; i += 4) {
      if (_cancelled) {
        yield const Finished(FinishReason.cancelled);
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 18));
      yield Piece(text.substring(i, i + 4 > text.length ? text.length : i + 4));
    }
    yield const Finished(FinishReason.eog);
  }
}
