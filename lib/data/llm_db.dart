import 'dart:math';

import 'package:sqlite3/sqlite3.dart';

/// The kinds a [PartRow] can have. Everything a message is made of is a part, so one message can
/// hold text, thinking, an attachment and the tool round trips without extra tables.
abstract final class PartKind {
  static const text = 'text';
  static const reasoning = 'reasoning';
  static const image = 'image';
  static const document = 'document';
  static const attachment = 'attachment';
  static const toolCall = 'tool_call';
  static const toolResult = 'tool_result';
  static const question = 'question';
  static const artifact = 'artifact';
}

abstract final class MessageRole {
  static const user = 'user';
  static const assistant = 'assistant';
  static const system = 'system';
  static const tool = 'tool';
}

/// The finish reason stored while a reply is still being generated.
///
/// A value of its own rather than `cancelled`, so the history list can tell "the app stopped in the
/// middle of a reply" (offer to resume) from "the user pressed stop".
const interruptedFinishReason = 'interrupted';

class ConversationRow {
  const ConversationRow({
    required this.id,
    required this.title,
    required this.agentId,
    required this.providerId,
    required this.modelId,
    required this.createdAt,
    required this.updatedAt,
    required this.archived,
    required this.pinned,
  });

  final String id;
  final String title;
  final String agentId;

  /// `local` or the id of a provider the user added.
  final String providerId;
  final String modelId;
  final int createdAt;
  final int updatedAt;
  final bool archived;
  final bool pinned;
}

class MessageRow {
  const MessageRow({
    required this.id,
    required this.conversationId,
    required this.seq,
    required this.role,
    this.agentId,
    this.providerId,
    this.modelId,
    required this.createdAt,
    this.finishReason,
    this.errorText,
    this.promptTokens,
    this.completionTokens,
    this.costMicros,
  });

  final String id;
  final String conversationId;
  final int seq;
  final String role;

  /// The agent that produced this message, kept so an old reply can still say who wrote it.
  final String? agentId;
  final String? providerId;
  final String? modelId;
  final int createdAt;
  final String? finishReason;
  final String? errorText;
  final int? promptTokens;
  final int? completionTokens;
  final int? costMicros;
}

class PartRow {
  const PartRow({
    required this.id,
    required this.messageId,
    required this.seq,
    required this.kind,
    this.body,
    this.assetId,
    this.toolCallId,
    this.toolName,
    this.payload,
  });

  final String id;
  final String messageId;
  final int seq;
  final String kind;

  /// The body of a text or reasoning part, or a summary of a tool result.
  final String? body;
  final String? assetId;
  final String? toolCallId;
  final String? toolName;

  /// JSON for anything richer than a string (tool arguments, a question tile, ...).
  final String? payload;
}

/// Attachments and generated media. The bytes live in the files area; only metadata is here,
/// so the database stays small.
class AssetRow {
  const AssetRow({
    required this.id,
    required this.relPath,
    required this.mime,
    required this.byteSize,
    required this.sha256,
    required this.createdAt,
    this.conversationId,
  });

  final String id;
  final String? conversationId;
  final String relPath;
  final String mime;
  final int byteSize;
  final String sha256;
  final int createdAt;
}

/// One turn of the conversation as the model sees it. Kept apart from [MessageRow] because the
/// model history also holds tool responses and the raw tool-call JSON, which the screen never shows.
class TurnRow {
  const TurnRow({required this.seq, required this.kind, this.text, this.toolCallJson, this.reasoning});

  final int seq;

  /// `user`, `assistant` or `tool`.
  final String kind;
  final String? text;
  final String? toolCallJson;

  /// What the model thought before it answered (an assistant turn of a model that thinks).
  final String? reasoning;
}

/// A turn about to be written.
class NewTurn {
  const NewTurn(this.kind, {this.text, this.toolCallJson, this.reasoning});

  final String kind;
  final String? text;
  final String? toolCallJson;
  final String? reasoning;
}

/// One message with its parts, as the chat screen needs them.
class MessageWithParts {
  const MessageWithParts(this.message, this.parts);

  final MessageRow message;
  final List<PartRow> parts;

  String get text => [
        for (final p in parts)
          if (p.kind == PartKind.text && (p.body?.isNotEmpty ?? false)) p.body!,
      ].join('\n');
}

/// A conversation and everything in it.
class Transcript {
  const Transcript(this.conversation, this.messages);

  final ConversationRow conversation;
  final List<MessageWithParts> messages;

  /// The flat text of the conversation, for export or a prompt preview.
  String get plainText =>
      [for (final m in messages) '${m.message.role}: ${m.text}'].join('\n\n');
}

/// One search hit: which message matched, and the surrounding text.
class SearchHit {
  const SearchHit({required this.messageId, required this.conversationId, required this.snippet});

  final String messageId;
  final String conversationId;
  final String snippet;
}

/// A message about to be written; the id and `seq` are assigned by [LlmDatabase.addMessage].
class NewMessage {
  const NewMessage(
    this.role,
    this.parts, {
    this.agentId,
    this.providerId,
    this.modelId,
    this.createdAt,
    this.finishReason,
  });

  final String role;
  final List<NewPart> parts;
  final String? agentId;
  final String? providerId;
  final String? modelId;
  final DateTime? createdAt;
  final String? finishReason;
}

class NewPart {
  const NewPart(
    this.kind, {
    this.text,
    this.assetId,
    this.toolCallId,
    this.toolName,
    this.payload,
  });

  final String kind;
  final String? text;
  final String? assetId;
  final String? toolCallId;
  final String? toolName;
  final String? payload;
}

/// The chat history database: conversations, messages, their parts, attachment metadata and a
/// full-text index. Settings, provider definitions and API keys do not belong here.
///
/// Search uses FTS5 with the trigram tokenizer, which matches inside Japanese words where the
/// default tokenizer finds nothing; queries shorter than three characters fall back to LIKE.
///
/// SQL is written by hand rather than generated, so the app needs no code generation step.
class LlmDatabase {
  LlmDatabase(this._db) {
    _initialise();
  }

  /// Opens a database at [path] (creating it), or `:memory:` for tests.
  factory LlmDatabase.open(String path) => LlmDatabase(sqlite3.open(path));

  /// A database that lives only as long as the object, for tests.
  factory LlmDatabase.memory() => LlmDatabase(sqlite3.openInMemory());

  final Database _db;

  static const _schemaVersion = 3;

  int get schemaVersion => _db.userVersion;

  void close() => _db.close();

  void _initialise() {
    _db.execute('PRAGMA foreign_keys = ON');
    _db.execute('PRAGMA journal_mode = WAL');
    if (_db.userVersion < _schemaVersion) {
      _db.execute('''
        CREATE TABLE IF NOT EXISTS conversations (
          id          TEXT PRIMARY KEY,
          title       TEXT NOT NULL,
          agent_id    TEXT NOT NULL,
          provider_id TEXT NOT NULL,
          model_id    TEXT NOT NULL,
          created_at  INTEGER NOT NULL,
          updated_at  INTEGER NOT NULL,
          archived    INTEGER NOT NULL DEFAULT 0,
          pinned      INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS messages (
          id                TEXT PRIMARY KEY,
          conversation_id   TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
          seq               INTEGER NOT NULL,
          role              TEXT NOT NULL,
          agent_id          TEXT,
          provider_id       TEXT,
          model_id          TEXT,
          created_at        INTEGER NOT NULL,
          finish_reason     TEXT,
          error_text        TEXT,
          prompt_tokens     INTEGER,
          completion_tokens INTEGER,
          cost_micros       INTEGER,
          UNIQUE(conversation_id, seq)
        );
        CREATE TABLE IF NOT EXISTS assets (
          id              TEXT PRIMARY KEY,
          conversation_id TEXT REFERENCES conversations(id) ON DELETE SET NULL,
          rel_path        TEXT NOT NULL,
          mime            TEXT NOT NULL,
          byte_size       INTEGER NOT NULL,
          sha256          TEXT NOT NULL,
          created_at      INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS parts (
          id           TEXT PRIMARY KEY,
          message_id   TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
          seq          INTEGER NOT NULL,
          kind         TEXT NOT NULL,
          text         TEXT,
          asset_id     TEXT REFERENCES assets(id),
          tool_call_id TEXT,
          tool_name    TEXT,
          payload      TEXT,
          UNIQUE(message_id, seq)
        );
        CREATE TABLE IF NOT EXISTS turns (
          conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
          seq             INTEGER NOT NULL,
          kind            TEXT NOT NULL,
          text            TEXT,
          tool_call_json  TEXT,
          reasoning       TEXT,
          PRIMARY KEY (conversation_id, seq)
        );
        CREATE INDEX IF NOT EXISTS idx_messages_conv ON messages(conversation_id, seq);
        CREATE INDEX IF NOT EXISTS idx_parts_msg     ON parts(message_id, seq);
        CREATE INDEX IF NOT EXISTS idx_conv_updated ON conversations(updated_at DESC);
      ''');
      // Contentless-enough FTS table: the columns we never search are UNINDEXED, so a hit can be
      // traced back to its message without a second table.
      _db.execute('''
        CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
          message_id UNINDEXED, conversation_id UNINDEXED, body, tokenize='trigram'
        );
      ''');
      // version 3: a turn keeps the model's reasoning (a database made before has the table without it)
      final hasReasoning = _db.select('PRAGMA table_info(turns)').any((c) => c['name'] == 'reasoning');
      if (!hasReasoning) _db.execute('ALTER TABLE turns ADD COLUMN reasoning TEXT');
      _db.userVersion = _schemaVersion;
    }
  }

  // ---------------------------------------------------------------- conversations

  /// Starts a conversation and returns its id.
  String startConversation({
    required String title,
    required String agentId,
    required String providerId,
    required String modelId,
    DateTime? now,
    String? id,
  }) {
    final at = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final conversationId = id ?? newId(now);
    _db.execute(
      'INSERT INTO conversations (id, title, agent_id, provider_id, model_id, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?)',
      [conversationId, title, agentId, providerId, modelId, at, at],
    );
    return conversationId;
  }

  /// Newest first. Archived conversations are hidden unless [includeArchived].
  List<ConversationRow> listConversations({bool includeArchived = false, int limit = 200}) {
    final rows = _db.select(
      'SELECT * FROM conversations ${includeArchived ? '' : 'WHERE archived = 0'} '
      'ORDER BY pinned DESC, updated_at DESC LIMIT ?',
      [limit],
    );
    return [for (final r in rows) _conversation(r)];
  }

  ConversationRow? conversation(String id) {
    final rows = _db.select('SELECT * FROM conversations WHERE id = ?', [id]);
    return rows.isEmpty ? null : _conversation(rows.first);
  }

  void renameConversation(String id, String title) => _db.execute(
        'UPDATE conversations SET title = ?, updated_at = ? WHERE id = ?',
        [title, _now(), id],
      );

  void archiveConversation(String id, {bool archived = true}) => _db.execute(
        'UPDATE conversations SET archived = ? WHERE id = ?',
        [archived ? 1 : 0, id],
      );

  void setPinned(String id, {required bool pinned}) => _db.execute(
        'UPDATE conversations SET pinned = ? WHERE id = ?',
        [pinned ? 1 : 0, id],
      );

  /// Sets the sort time explicitly; used when importing history that already has one.
  void setUpdatedAt(String id, DateTime at) => _db.execute(
        'UPDATE conversations SET updated_at = ? WHERE id = ?',
        [at.millisecondsSinceEpoch, id],
      );

  /// Deletes the conversation, its messages, its parts and the search entries.
  /// Returns the asset paths that are no longer referenced, so the caller can delete the files.
  List<String> deleteConversation(String id) {
    final assets = _db.select('SELECT rel_path FROM assets WHERE conversation_id = ?', [id]);
    final paths = [for (final a in assets) a['rel_path'] as String];
    // a saved KV cache means nothing without its conversation: its row goes too (the caller
    // deletes the file with the others)
    _db.execute('DELETE FROM assets WHERE conversation_id = ? AND mime = ?', [id, kvMime]);
    _db.execute('DELETE FROM messages_fts WHERE conversation_id = ?', [id]);
    // Parts and messages go with the conversation through ON DELETE CASCADE.
    _db.execute('DELETE FROM conversations WHERE id = ?', [id]);
    return paths;
  }

  // ---------------------------------------------------------------- messages

  /// Appends a message, assigns its `seq` and indexes its text. The conversation's `updated_at`
  /// moves to the newest message.
  String addMessage(String conversationId, NewMessage message) {
    final id = newId(message.createdAt);
    final at = (message.createdAt ?? DateTime.now()).millisecondsSinceEpoch;

    _transaction(() {
      final seq = _nextSeq(conversationId);
      _db.execute(
        'INSERT INTO messages (id, conversation_id, seq, role, agent_id, provider_id, model_id, '
        'created_at, finish_reason) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          id,
          conversationId,
          seq,
          message.role,
          message.agentId,
          message.providerId,
          message.modelId,
          at,
          message.finishReason,
        ],
      );

      var partSeq = 0;
      for (final p in message.parts) {
        _db.execute(
          'INSERT INTO parts (id, message_id, seq, kind, text, asset_id, tool_call_id, tool_name, payload) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
          [newId(), id, partSeq++, p.kind, p.text, p.assetId, p.toolCallId, p.toolName, p.payload],
        );
      }

      _index(id, conversationId, message.parts);
      _db.execute(
        'UPDATE conversations SET updated_at = ? WHERE id = ?',
        [at, conversationId],
      );
    });
    return id;
  }

  /// Writes every message of [conversationId] again, replacing what was stored.
  ///
  /// The chat screen hands the whole conversation over at the points where a crash would lose
  /// work, so appending would store the reply that is still streaming twice. Ids come from the
  /// position, which keeps the rows stable when the same conversation is saved again.
  void replaceMessages(String conversationId, List<NewMessage> messages) {
    _transaction(() {
      _db.execute('DELETE FROM messages_fts WHERE conversation_id = ?', [conversationId]);
      // parts go with the messages through ON DELETE CASCADE
      _db.execute('DELETE FROM messages WHERE conversation_id = ?', [conversationId]);

      var seq = 0;
      var newest = 0;
      for (final message in messages) {
        final id = '$conversationId@$seq';
        final at = (message.createdAt ?? DateTime.now()).millisecondsSinceEpoch;
        if (at > newest) newest = at;
        _db.execute(
          'INSERT INTO messages (id, conversation_id, seq, role, agent_id, provider_id, model_id, '
          'created_at, finish_reason) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
          [
            id,
            conversationId,
            seq,
            message.role,
            message.agentId,
            message.providerId,
            message.modelId,
            at,
            message.finishReason,
          ],
        );

        var partSeq = 0;
        for (final p in message.parts) {
          _db.execute(
            'INSERT INTO parts (id, message_id, seq, kind, text, asset_id, tool_call_id, tool_name, payload) '
            'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
            ['$id@$partSeq', id, partSeq++, p.kind, p.text, p.assetId, p.toolCallId, p.toolName, p.payload],
          );
        }

        _index(id, conversationId, message.parts);
        seq++;
      }

      if (newest > 0) {
        _db.execute('UPDATE conversations SET updated_at = ? WHERE id = ?', [newest, conversationId]);
      }
    });
  }

  /// Records how a reply ended, and what it cost.
  void finishMessage(
    String messageId, {
    String? finishReason,
    String? errorText,
    int? promptTokens,
    int? completionTokens,
    int? costMicros,
  }) =>
      _db.execute(
        'UPDATE messages SET finish_reason = COALESCE(?, finish_reason), '
        'error_text = COALESCE(?, error_text), '
        'prompt_tokens = COALESCE(?, prompt_tokens), '
        'completion_tokens = COALESCE(?, completion_tokens), '
        'cost_micros = COALESCE(?, cost_micros) WHERE id = ?',
        [finishReason, errorText, promptTokens, completionTokens, costMicros, messageId],
      );

  /// The newest message's finish reason per conversation, so the history list can tell a reply
  /// that the app stopped in the middle of from one the user ended.
  Map<String, String?> lastFinishReasons() {
    final rows = _db.select(
      'SELECT m.conversation_id AS conversation_id, m.finish_reason AS finish_reason '
      'FROM messages m WHERE m.seq = '
      '(SELECT MAX(seq) FROM messages WHERE conversation_id = m.conversation_id)',
    );
    return {for (final r in rows) r['conversation_id'] as String: r['finish_reason'] as String?};
  }

  /// Replaces the newest message's finish reason; used once an interrupted reply is resolved.
  void setLastFinishReason(String conversationId, String? reason) => _db.execute(
        'UPDATE messages SET finish_reason = ? WHERE conversation_id = ? AND seq = '
        '(SELECT MAX(seq) FROM messages WHERE conversation_id = ?)',
        [reason, conversationId, conversationId],
      );

  /// Replaces the text of a reply that is still streaming, so a crash keeps the latest text.
  void updateStreamingText(String messageId, String text) {
    _transaction(() {
      final message = _db.select('SELECT conversation_id FROM messages WHERE id = ?', [messageId]);
      if (message.isEmpty) return;
      final conversationId = message.first['conversation_id'] as String;

      final existing = _db.select(
        'SELECT id FROM parts WHERE message_id = ? AND kind = ? ORDER BY seq LIMIT 1',
        [messageId, PartKind.text],
      );
      if (existing.isEmpty) {
        _db.execute(
          'INSERT INTO parts (id, message_id, seq, kind, text) VALUES (?, ?, ?, ?, ?)',
          [newId(), messageId, 0, PartKind.text, text],
        );
      } else {
        _db.execute('UPDATE parts SET text = ? WHERE id = ?', [text, existing.first['id']]);
      }

      _db.execute('DELETE FROM messages_fts WHERE message_id = ?', [messageId]);
      _db.execute(
        'INSERT INTO messages_fts (message_id, conversation_id, body) VALUES (?, ?, ?)',
        [messageId, conversationId, text],
      );
    });
  }

  int _nextSeq(String conversationId) {
    final rows = _db.select(
      'SELECT COALESCE(MAX(seq), -1) + 1 AS next FROM messages WHERE conversation_id = ?',
      [conversationId],
    );
    return rows.first['next'] as int;
  }

  void _index(String messageId, String conversationId, List<NewPart> parts) {
    final body = [
      for (final p in parts)
        if (p.text != null && p.text!.trim().isNotEmpty) p.text!,
    ].join('\n');
    if (body.isEmpty) return;
    _db.execute(
      'INSERT INTO messages_fts (message_id, conversation_id, body) VALUES (?, ?, ?)',
      [messageId, conversationId, body],
    );
  }

  // ---------------------------------------------------------------- reading

  /// The whole conversation, oldest message first.
  Transcript? loadTranscript(String conversationId) {
    final head = conversation(conversationId);
    if (head == null) return null;

    final messages = messagesOf(conversationId);
    final byMessage = <String, List<PartRow>>{};
    if (messages.isNotEmpty) {
      final marks = List.filled(messages.length, '?').join(', ');
      final rows = _db.select(
        'SELECT * FROM parts WHERE message_id IN ($marks) ORDER BY seq',
        [for (final m in messages) m.id],
      );
      for (final r in rows) {
        final part = _part(r);
        byMessage.putIfAbsent(part.messageId, () => []).add(part);
      }
    }
    return Transcript(head, [
      for (final m in messages) MessageWithParts(m, byMessage[m.id] ?? const []),
    ]);
  }

  List<MessageRow> messagesOf(String conversationId) {
    final rows = _db.select(
      'SELECT * FROM messages WHERE conversation_id = ? ORDER BY seq',
      [conversationId],
    );
    return [for (final r in rows) _message(r)];
  }

  List<PartRow> partsOf(String messageId) {
    final rows = _db.select(
      'SELECT * FROM parts WHERE message_id = ? ORDER BY seq',
      [messageId],
    );
    return [for (final r in rows) _part(r)];
  }

  // ---------------------------------------------------------------- model history

  /// Replaces the model-facing history of [conversationId]. The chat controller rebuilds it as
  /// it runs (tool round trips included), so the whole list is written instead of appending.
  void saveTurns(String conversationId, List<NewTurn> turns) {
    _transaction(() {
      _db.execute('DELETE FROM turns WHERE conversation_id = ?', [conversationId]);
      var seq = 0;
      for (final t in turns) {
        _db.execute(
          'INSERT INTO turns (conversation_id, seq, kind, text, tool_call_json, reasoning) VALUES (?, ?, ?, ?, ?, ?)',
          [conversationId, seq++, t.kind, t.text, t.toolCallJson, t.reasoning],
        );
      }
    });
  }

  List<TurnRow> turnsOf(String conversationId) {
    final rows = _db.select(
      'SELECT seq, kind, text, tool_call_json, reasoning FROM turns WHERE conversation_id = ? ORDER BY seq',
      [conversationId],
    );
    return [
      for (final r in rows)
        TurnRow(
          seq: r['seq'] as int,
          kind: r['kind'] as String,
          text: r['text'] as String?,
          toolCallJson: r['tool_call_json'] as String?,
          reasoning: r['reasoning'] as String?,
        ),
    ];
  }

  // ---------------------------------------------------------------- search

  /// Searches message text across every conversation.
  ///
  /// The trigram tokenizer cannot index fewer than three characters, so short queries scan
  /// with instr(), which treats every character literally.
  List<SearchHit> search(String query, {int limit = 50}) {
    final q = query.trim();
    if (q.isEmpty) return const [];

    if (q.runes.length < 3) {
      final rows = _db.select(
        'SELECT m.id AS message_id, m.conversation_id AS conversation_id, p.text AS body '
        'FROM parts p JOIN messages m ON m.id = p.message_id '
        'WHERE instr(p.text, ?) > 0 ORDER BY m.created_at DESC LIMIT ?',
        [q, limit],
      );
      return [
        for (final r in rows)
          SearchHit(
            messageId: r['message_id'] as String,
            conversationId: r['conversation_id'] as String,
            snippet: _snippet(r['body'] as String? ?? '', q),
          ),
      ];
    }

    final rows = _db.select(
      '''SELECT message_id, conversation_id,
         snippet(messages_fts, 2, '[', ']', '…', 12) AS snippet
         FROM messages_fts WHERE body MATCH ? ORDER BY rank LIMIT ?''',
      [_ftsQuery(q), limit],
    );
    return [
      for (final r in rows)
        SearchHit(
          messageId: r['message_id'] as String,
          conversationId: r['conversation_id'] as String,
          snippet: r['snippet'] as String,
        ),
    ];
  }

  /// Counts messages per conversation, for the history list.
  Map<String, int> messageCounts() {
    final rows = _db.select(
      'SELECT conversation_id, COUNT(*) AS n FROM messages GROUP BY conversation_id',
    );
    return {for (final r in rows) r['conversation_id'] as String: r['n'] as int};
  }

  // ---------------------------------------------------------------- assets

  String addAsset({
    required String relPath,
    required String mime,
    required int byteSize,
    required String sha256,
    String? conversationId,
    DateTime? now,
  }) {
    final id = newId(now);
    _db.execute(
      'INSERT INTO assets (id, conversation_id, rel_path, mime, byte_size, sha256, created_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?)',
      [id, conversationId, relPath, mime, byteSize, sha256, (now ?? DateTime.now()).millisecondsSinceEpoch],
    );
    return id;
  }

  /// The `mime` of a saved KV cache (see `KvSnapshotService`). These files are an index of
  /// something only the engine can read, not message attachments: no message points at them.
  static const kvMime = 'application/x-llama-kv-state';

  /// Assets nothing points at any more, so the caller can delete the files. A saved KV cache is
  /// never listed: it is managed by its own service, which keeps its own limit.
  List<AssetRow> unreferencedAssets() {
    final rows = _db.select(
      'SELECT a.* FROM assets a WHERE a.mime <> ? AND NOT EXISTS '
      '(SELECT 1 FROM parts p WHERE p.asset_id = a.id)',
      [kvMime],
    );
    return [for (final r in rows) _asset(r)];
  }

  /// Every asset of [mime], oldest first (the one used longest ago comes first).
  List<AssetRow> assetsByMime(String mime) {
    final rows = _db.select('SELECT * FROM assets WHERE mime = ? ORDER BY created_at, id', [mime]);
    return [for (final r in rows) _asset(r)];
  }

  void deleteAsset(String id) => _db.execute('DELETE FROM assets WHERE id = ?', [id]);

  /// Marks an asset as just used: `created_at` doubles as "last used" for the ones kept by size.
  void touchAsset(String id, {DateTime? now}) => _db.execute(
        'UPDATE assets SET created_at = ? WHERE id = ?',
        [(now ?? DateTime.now()).millisecondsSinceEpoch, id],
      );

  // ---------------------------------------------------------------- internals

  void _transaction(void Function() body) {
    _db.execute('BEGIN');
    try {
      body();
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  static int _now() => DateTime.now().millisecondsSinceEpoch;

  static ConversationRow _conversation(Row r) => ConversationRow(
        id: r['id'] as String,
        title: r['title'] as String,
        agentId: r['agent_id'] as String,
        providerId: r['provider_id'] as String,
        modelId: r['model_id'] as String,
        createdAt: r['created_at'] as int,
        updatedAt: r['updated_at'] as int,
        archived: (r['archived'] as int) != 0,
        pinned: (r['pinned'] as int) != 0,
      );

  static MessageRow _message(Row r) => MessageRow(
        id: r['id'] as String,
        conversationId: r['conversation_id'] as String,
        seq: r['seq'] as int,
        role: r['role'] as String,
        agentId: r['agent_id'] as String?,
        providerId: r['provider_id'] as String?,
        modelId: r['model_id'] as String?,
        createdAt: r['created_at'] as int,
        finishReason: r['finish_reason'] as String?,
        errorText: r['error_text'] as String?,
        promptTokens: r['prompt_tokens'] as int?,
        completionTokens: r['completion_tokens'] as int?,
        costMicros: r['cost_micros'] as int?,
      );

  static PartRow _part(Row r) => PartRow(
        id: r['id'] as String,
        messageId: r['message_id'] as String,
        seq: r['seq'] as int,
        kind: r['kind'] as String,
        body: r['text'] as String?,
        assetId: r['asset_id'] as String?,
        toolCallId: r['tool_call_id'] as String?,
        toolName: r['tool_name'] as String?,
        payload: r['payload'] as String?,
      );

  static AssetRow _asset(Row r) => AssetRow(
        id: r['id'] as String,
        conversationId: r['conversation_id'] as String?,
        relPath: r['rel_path'] as String,
        mime: r['mime'] as String,
        byteSize: r['byte_size'] as int,
        sha256: r['sha256'] as String,
        createdAt: r['created_at'] as int,
      );

  /// FTS5 treats characters such as -, *, ( and the quote mark as syntax, so the
  /// query is passed as a quoted phrase to keep them literal.
  static String _ftsQuery(String q) {
    final quote = String.fromCharCode(0x22);
    return '$quote${q.replaceAll(quote, quote + quote)}$quote';
  }

  static String _snippet(String body, String query) {
    final at = body.indexOf(query);
    if (at < 0) return body.length > 80 ? '${body.substring(0, 80)}…' : body;
    final start = at - 30 < 0 ? 0 : at - 30;
    final end = at + query.length + 30 > body.length ? body.length : at + query.length + 30;
    return '${start > 0 ? '…' : ''}${body.substring(start, end)}${end < body.length ? '…' : ''}';
  }
}

/// A time-ordered unique id. Only the ordering part and the shape matter here, so the version
/// and variant bits of RFC 9562 are not set.
String newId([DateTime? now]) {
  final ms = (now ?? DateTime.now()).millisecondsSinceEpoch & 0xFFFFFFFFFFFF;
  final random = Random.secure();
  final bytes = <int>[
    (ms >> 40) & 0xFF,
    (ms >> 32) & 0xFF,
    (ms >> 24) & 0xFF,
    (ms >> 16) & 0xFF,
    (ms >> 8) & 0xFF,
    ms & 0xFF,
    for (var i = 0; i < 10; i++) random.nextInt(256),
  ];
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}'
      '-${hex.substring(16, 20)}-${hex.substring(20)}';
}
