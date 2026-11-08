/// The split of a job as a graph: what has to be done (nodes) and what has to come first (arrows).
///
/// The planner writes it as a Mermaid flowchart because that is a form a model writes well, a person
/// reads at a glance, and other tools take as they are (a CLI agent such as opencode can be given the
/// same text). Only the part of Mermaid that says "this, then that" is read: `flowchart`/`graph`, nodes
/// (`a["title"]`, `a[title]`, `a(title)`, `a{title}`, `a`) and arrows (`-->`, `---`, `==>`, `-.->`, with or
/// without a label, `a --> b & c`, `a --> b --> c`). Styling, subgraphs and the rest are skipped.
///
/// An arrow `a --> b` means b starts after a. A task with no arrow into it starts at once, so the
/// more independent the tasks, the more run at the same time.
class PlanGraph {
  PlanGraph(this.labels, this.edges);

  /// Node id -> the text written for it ('' when it has none).
  final Map<String, String> labels;

  /// `(from, to)`: [to] starts after [from].
  final List<(String, String)> edges;

  static final _arrow = RegExp(r'(?:-{2,}>|={2,}>|-\.+->|-{3,}|--[xo]|~~~)');
  static final _id = RegExp(r'^[A-Za-z0-9_]+$');

  /// Reads [text]; null when no node is found in it.
  static PlanGraph? parse(String text) {
    final labels = <String, String>{};
    final edges = <(String, String)>[];
    final seen = <String>{};
    var inSubgraph = 0;

    void node(String raw) {
      final parsed = _node(raw);
      if (parsed == null) return;
      final (id, label) = parsed;
      if (label.isNotEmpty || !labels.containsKey(id)) labels[id] = label.isNotEmpty ? label : (labels[id] ?? '');
    }

    for (var line in text.split(RegExp(r'[\n;]'))) {
      line = line.trim();
      if (line.isEmpty || line.startsWith('%%') || line.startsWith('```')) continue;
      final lower = line.toLowerCase();
      if (lower.startsWith('flowchart') || lower.startsWith('graph ') || lower == 'graph') continue;
      if (lower.startsWith('subgraph')) {
        inSubgraph++;
        continue;
      }
      if (lower == 'end') {
        if (inSubgraph > 0) inSubgraph--;
        continue;
      }
      if (RegExp(r'^(classdef|class|style|linkstyle|click|direction)\b', caseSensitive: false).hasMatch(line)) continue;
      // `a -- text --> b` and `a -->|text| b`: the label is not a node
      line = line.replaceAllMapped(RegExp(r'--\s+[^>\-][^>]*?\s+-->'), (_) => '-->');
      line = line.replaceAll(RegExp(r'\|[^|]*\|'), ' ');
      final parts = line.split(_arrow);
      List<String>? previous;
      for (final part in parts) {
        final group = [for (final piece in _splitAnd(part)) if (piece.trim().isNotEmpty) piece.trim()];
        final ids = <String>[];
        for (final piece in group) {
          final parsed = _node(piece);
          if (parsed == null) continue;
          node(piece);
          ids.add(parsed.$1);
        }
        if (previous != null) {
          for (final from in previous) {
            for (final to in ids) {
              if (from != to && seen.add('$from>$to')) edges.add((from, to));
            }
          }
        }
        if (ids.isNotEmpty) previous = ids;
      }
    }
    if (labels.isEmpty) return null;
    return PlanGraph(labels, edges);
  }

  /// `b & c` -> `b`, `c`, without splitting inside quotes or brackets.
  static List<String> _splitAnd(String text) {
    final out = <String>[];
    var depth = 0;
    var quote = false;
    var start = 0;
    for (var i = 0; i < text.length; i++) {
      final ch = text[i];
      if (ch == '"') quote = !quote;
      if (quote) continue;
      if ('[({'.contains(ch)) depth++;
      if ('])}'.contains(ch) && depth > 0) depth--;
      if (ch == '&' && depth == 0) {
        out.add(text.substring(start, i));
        start = i + 1;
      }
    }
    out.add(text.substring(start));
    return out;
  }

  /// `a["title"]`, `a(title)`, `a{title}`, `a((title))`, `a>title]`, `a` -> (id, label).
  static (String, String)? _node(String raw) {
    final text = raw.trim();
    final shape = text.indexOf(RegExp(r'[\[({>]'));
    final id = (shape < 0 ? text : text.substring(0, shape)).trim();
    if (!_id.hasMatch(id)) return null;
    if (shape < 0) return (id, '');
    var label = text.substring(shape).trim();
    label = label.replaceAll(RegExp(r'^[\[({>]+'), '').replaceAll(RegExp(r'[\])}]+$'), '').trim();
    if (label.length >= 2 && label.startsWith('"') && label.endsWith('"')) label = label.substring(1, label.length - 1);
    label = label.replaceAll('<br/>', ' ').replaceAll('<br>', ' ').trim();
    return (id, label);
  }

  /// id -> the ids that must be done before it (only ids in [labels]).
  Map<String, Set<String>> get dependencies {
    final out = {for (final id in labels.keys) id: <String>{}};
    for (final (from, to) in edges) {
      out[to]?.add(from);
    }
    return out;
  }

  /// A cycle in the arrows (the ids along it), or null. A plan with a cycle can never finish.
  List<String>? cycle() {
    final deps = dependencies;
    final state = <String, int>{}; // 1 = on the way, 2 = done
    final stack = <String>[];
    List<String>? found;
    void visit(String id) {
      if (found != null || state[id] == 2) return;
      if (state[id] == 1) {
        found = [...stack.sublist(stack.indexOf(id)), id];
        return;
      }
      state[id] = 1;
      stack.add(id);
      for (final d in deps[id] ?? const <String>{}) {
        visit(d);
        if (found != null) return;
      }
      stack.removeLast();
      state[id] = 2;
    }

    for (final id in labels.keys) {
      visit(id);
      if (found != null) break;
    }
    return found;
  }

  /// The ids in rounds: everything in a round can run at the same time, and needs only earlier rounds.
  /// Empty for a graph with a cycle.
  List<List<String>> waves() {
    if (cycle() != null) return const [];
    final deps = dependencies;
    final done = <String>{};
    final out = <List<String>>[];
    while (done.length < labels.length) {
      final ready = [
        for (final id in labels.keys)
          if (!done.contains(id) && deps[id]!.every(done.contains)) id,
      ];
      if (ready.isEmpty) return const [];
      out.add(ready);
      done.addAll(ready);
    }
    return out;
  }

  /// The flowchart for [nodes] (`id`, title) and [dependencies] (id -> what it waits for), in the form
  /// the planner is asked to write, so a plan that was given as a list is shown the same way.
  static String build(List<(String, String)> nodes, Map<String, Iterable<String>> dependencies) {
    String clean(String s) => s.replaceAll('"', "'").replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
    final b = StringBuffer('flowchart TD\n');
    for (final (id, title) in nodes) {
      b.writeln('  $id["${clean(title)}"]');
    }
    for (final (id, _) in nodes) {
      for (final dep in dependencies[id] ?? const <String>[]) {
        b.writeln('  $dep --> $id');
      }
    }
    return b.toString().trimRight();
  }
}
