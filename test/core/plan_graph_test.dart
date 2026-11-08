import 'package:arce_ai/core/plan_graph.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('nodes with their text, and arrows meaning "this first, then that"', () {
    final g = PlanGraph.parse('''
flowchart TD
  a["モデル（User）"] --> c["画面"]
  b[API クライアント] --> c
  c --> d(テスト)
''')!;
    expect(g.labels, {'a': 'モデル（User）', 'b': 'API クライアント', 'c': '画面', 'd': 'テスト'});
    expect(g.edges, [('a', 'c'), ('b', 'c'), ('c', 'd')]);
    expect(g.dependencies, {'a': <String>{}, 'b': <String>{}, 'c': {'a', 'b'}, 'd': {'c'}});
    expect(g.cycle(), isNull);
    expect(g.waves(), [
      ['a', 'b'],
      ['c'],
      ['d'],
    ], reason: 'a and b run at the same time, then c, then d');
  });

  test('chains, several targets with &, labelled arrows, other arrow styles and shapes', () {
    final g = PlanGraph.parse('graph LR; a --> b --> c; a ==> d & e; b -.->|ラベル| f; c -- 文章 --> g; h{判断} --- i((丸))')!;
    expect(g.edges, containsAll([('a', 'b'), ('b', 'c'), ('a', 'd'), ('a', 'e'), ('b', 'f'), ('c', 'g'), ('h', 'i')]));
    expect(g.labels.keys, containsAll(['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i']));
    expect(g.labels['h'], '判断');
    expect(g.labels['i'], '丸');
    expect(g.labels.containsKey('ラベル'), isFalse, reason: 'an arrow label is not a node');
    expect(g.labels.containsKey('文章'), isFalse);
  });

  test('styling, comments, subgraph lines and a code fence are skipped', () {
    final g = PlanGraph.parse('''
```mermaid
%% a comment
flowchart TD
  subgraph s1[グループ]
    a --> b
  end
  classDef ok fill:#cfc
  class a ok
  style b fill:#fcc
```
''')!;
    expect(g.labels.keys.toSet(), {'a', 'b'});
    expect(g.edges, [('a', 'b')]);
  });

  test('an arrow written twice counts once; an arrow to itself is dropped', () {
    final g = PlanGraph.parse('a --> b\na --> b\nc --> c')!;
    expect(g.edges, [('a', 'b')]);
    expect(g.labels.containsKey('c'), isTrue);
  });

  test('a cycle is found, and a graph with one has no waves', () {
    final g = PlanGraph.parse('a --> b\nb --> c\nc --> a')!;
    final cycle = g.cycle()!;
    expect(cycle.first, cycle.last);
    expect(cycle.toSet(), {'a', 'b', 'c'});
    expect(g.waves(), isEmpty);
  });

  test('text without a node is null; a lone node is a plan of one', () {
    expect(PlanGraph.parse(''), isNull);
    expect(PlanGraph.parse('flowchart TD\n%% nothing'), isNull);
    expect(PlanGraph.parse('x["だけ"]')!.waves(), [
      ['x'],
    ]);
  });

  test('build writes the form the planner is asked for, and it reads back as the same graph', () {
    final text = PlanGraph.build(
      [('a', 'モデル'), ('b', '"画面" を作る'), ('c', 'まとめ')],
      {
        'b': ['a'],
        'c': ['a', 'b'],
      },
    );
    expect(text, startsWith('flowchart TD'));
    final g = PlanGraph.parse(text)!;
    expect(g.edges.toSet(), {('a', 'b'), ('a', 'c'), ('b', 'c')});
    expect(g.labels['b'], "'画面' を作る", reason: 'a quote inside a title is softened so the text stays valid');
  });
}
