import '../data/llm_db.dart';
import 'conversation_database.dart';

/// One conversation in the search results, with the text that matched.
class ConversationHit {
  const ConversationHit(this.meta, {this.snippet});

  final ConversationMeta meta;

  /// A line of the message that matched, with the matched part between `[` and `]`.
  /// Null when only the title matched (or when nothing was searched for).
  final String? snippet;
}

/// Turns what the database finds (messages) into what the history list shows (conversations).
///
/// The title is searched here, case-insensitively, because the full-text index only holds message
/// text; a message hit is added for the conversations the title did not already bring in.
abstract final class ConversationSearch {
  /// How many messages the database is asked for; they are then grouped by conversation.
  static const messageLimit = 200;

  /// [run] with the hits taken from [database].
  static List<ConversationHit> find(
    ConversationDatabase database,
    List<ConversationMeta> all,
    String query,
  ) {
    final q = query.trim();
    final hits = q.isEmpty ? const <SearchHit>[] : database.search(q, limit: messageLimit);
    return run(q, all, hits);
  }

  /// [all] is every conversation, newest first. [messageHits] are the database's hits for
  /// [query], best first. An empty [query] gives all conversations, newest first.
  static List<ConversationHit> run(
    String query,
    List<ConversationMeta> all,
    List<SearchHit> messageHits,
  ) {
    final q = query.trim();
    if (q.isEmpty) return [for (final meta in all) ConversationHit(meta)];

    final byId = {for (final meta in all) meta.id: meta};
    // the first (best) snippet of each conversation
    final snippets = <String, String>{};
    for (final hit in messageHits) {
      snippets.putIfAbsent(hit.conversationId, () => hit.snippet);
    }

    final lower = q.toLowerCase();
    final out = <ConversationHit>[];
    final seen = <String>{};
    for (final meta in all) {
      if (meta.title.toLowerCase().contains(lower)) {
        out.add(ConversationHit(meta, snippet: snippets[meta.id]));
        seen.add(meta.id);
      }
    }
    for (final entry in snippets.entries) {
      final meta = byId[entry.key];
      if (meta == null || !seen.add(meta.id)) continue;
      out.add(ConversationHit(meta, snippet: entry.value));
    }
    return out;
  }
}
