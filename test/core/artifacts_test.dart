import 'package:arce_ai/core/artifacts.dart';
import 'package:arce_ai/core/chat_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('lists only finished code blocks of assistant replies', () {
    const messages = [
      UiMessage(id: 0, role: Role.user, text: '```python\nprint(1)\n```'),
      UiMessage(
        id: 1,
        role: Role.assistant,
        text: '作りました。\n```html\n<html><head><title>ToDo</title></head></html>\n```\n```python\nprint("hi")\n```\n```kotlin\nfun main() {',
      ),
    ];
    final items = Artifacts.extract(messages);
    expect(items.map((i) => i.fileName), ['index.html', 'main.py']);
    expect(items.first.title, 'ToDo');
    expect(items.first.isHtml, isTrue);
    expect(items.last.title, 'python · print("hi")');
    expect(items.map((i) => i.key).toSet(), hasLength(2));
  });
}
