import 'dart:convert';

import 'llm_db.dart';

/// The finish reasons a message can carry, as stored. Anything else is read back as null.
const _finishReasons = {'eog', 'length', 'cancelled', 'error'};

/// One row of the history list, as the screen needs it.
class StoredConversation {
  const StoredConversation({
    required this.id,
    required this.title,
    required this.updatedAt,
    required this.messageCount,
    required this.generating,
  });

  final String id;
  final String title;
  final DateTime updatedAt;
  final int messageCount;

  /// A reply was still running when the app last stopped.
  final bool generating;
}

/// Reads and writes a conversation in the shape the chat screen keeps it in: the messages the
/// screen shows, the model-facing history, and the next message id.
///
/// Working on decoded JSON rather than on the app's classes keeps this layer free of Flutter,
/// which is what lets the database be exercised without a device.
class ConversationSnapshotStore {
  const ConversationSnapshotStore(this.db);

  final LlmDatabase db;

  /// Writes [snapshot] under [conversationId], or starts a conversation when it is null;
  /// returns the id used.
  ///
  /// [generating] marks the reply that is still running, so a restart can offer to resume it.
  String save(
    String? conversationId,
    Map<String, Object?> snapshot, {
    required bool generating,
    String agentId = '',
    String providerId = 'local',
    String modelId = '',
  }) {
    final messages = _maps(snapshot['messages']);
    if (messages.isEmpty) throw ArgumentError('the snapshot has no messages');

    String id;
    if (conversationId == null) {
      id = _start(messages, agentId: agentId, providerId: providerId, modelId: modelId);
    } else {
      id = conversationId;
      // The row was removed while the chat was open; write it back rather than losing the reply.
      if (db.conversation(id) == null) {
        _start(messages, id: id, agentId: agentId, providerId: providerId, modelId: modelId);
      }
    }

    final lastReply = messages.lastIndexWhere((m) => m['role'] == 'assistant');
    db.replaceMessages(id, [
      for (var i = 0; i < messages.length; i++)
        _message(messages[i], interrupted: generating && i == lastReply),
    ]);
    db.saveTurns(id, [for (final turn in _maps(snapshot['history'])) _turn(turn)]);
    return id;
  }

  /// Gives the conversation a title of its own (the history list shows it). [save] never touches it.
  void rename(String conversationId, String title) => db.renameConversation(conversationId, title);

  /// The conversation in the shape [save] took, or null when nothing is stored under
  /// [conversationId].
  Map<String, Object?>? read(String conversationId) {
    final transcript = db.loadTranscript(conversationId);
    if (transcript == null) return null;

    final messages = <Map<String, Object?>>[];
    for (final entry in transcript.messages) {
      final parts = entry.parts;
      messages.add({
        // Ids only need to be unique within the conversation: the chat controller uses them as
        // update keys and numbers new messages after the restored count.
        'id': messages.length,
        'role': entry.message.role == MessageRole.assistant ? 'assistant' : 'user',
        'text': _textOf(parts),
        'thinking': _bodyOf(parts, PartKind.reasoning) ?? '',
        'thinkingMs': _thinkingMsOf(parts),
        'question': _jsonOf(_payloadOf(parts, PartKind.question)),
        'finish': _finishOf(entry.message.finishReason),
        'activities': _jsonsOf(parts, PartKind.toolResult),
        'agent': entry.message.agentId,
        'attachments': _bodiesOf(parts, PartKind.attachment),
        'time': entry.message.createdAt,
      });
    }

    return {
      'messages': messages,
      'history': [for (final turn in db.turnsOf(conversationId)) _turnJson(turn)],
      'nextId': messages.length,
    };
  }

  /// Newest first. A conversation whose last reply is still marked as running comes back with
  /// [StoredConversation.generating] set.
  List<StoredConversation> list({int limit = 200}) {
    final counts = db.messageCounts();
    final finishes = db.lastFinishReasons();
    return [
      for (final c in db.listConversations(limit: limit))
        StoredConversation(
          id: c.id,
          title: c.title,
          updatedAt: DateTime.fromMillisecondsSinceEpoch(c.updatedAt),
          messageCount: counts[c.id] ?? 0,
          generating: finishes[c.id] == interruptedFinishReason,
        ),
    ];
  }

  /// Deletes a conversation and returns the asset paths that are no longer referenced.
  List<String> delete(String conversationId) => db.deleteConversation(conversationId);

  /// Marks the unfinished reply as stopped, so a restart no longer offers to resume it.
  void clearGenerating(String conversationId) => db.setLastFinishReason(conversationId, 'cancelled');

  /// Message text across every conversation; a hit carries its conversation and message ids.
  List<SearchHit> search(String query, {int limit = 50}) => db.search(query, limit: limit);

  String _start(
    List<Map<String, Object?>> messages, {
    String? id,
    required String agentId,
    required String providerId,
    required String modelId,
  }) =>
      db.startConversation(
        id: id,
        title: titleOf(messages),
        agentId: agentId,
        providerId: providerId,
        modelId: modelId,
        now: _timeOf(messages.first),
      );

  static NewMessage _message(Map<String, Object?> message, {required bool interrupted}) {
    final parts = <NewPart>[];

    final thinking = (message['thinking'] as String?) ?? '';
    final thinkingMs = message['thinkingMs'];
    if (thinking.trim().isNotEmpty) {
      parts.add(NewPart(PartKind.reasoning, text: thinking, payload: thinkingMs is num && thinkingMs > 0 ? jsonEncode({'ms': thinkingMs.toInt()}) : null));
    }

    final text = (message['text'] as String?) ?? '';
    if (text.isNotEmpty) parts.add(NewPart(PartKind.text, text: text));

    for (final name in (message['attachments'] as List? ?? const [])) {
      if (name is String && name.isNotEmpty) parts.add(NewPart(PartKind.attachment, text: name));
    }

    for (final activity in (message['activities'] as List? ?? const [])) {
      if (activity is! Map) continue;
      parts.add(NewPart(
        PartKind.toolResult,
        text: activity['summary'] as String?,
        toolName: activity['tool'] as String?,
        payload: jsonEncode(activity),
      ));
    }

    final question = message['question'];
    if (question is Map) parts.add(NewPart(PartKind.question, payload: jsonEncode(question)));

    return NewMessage(
      message['role'] == 'assistant' ? MessageRole.assistant : MessageRole.user,
      parts,
      agentId: message['agent'] as String?,
      createdAt: _timeOf(message),
      finishReason: interrupted ? interruptedFinishReason : message['finish'] as String?,
    );
  }

  static NewTurn _turn(Map<String, Object?> turn) {
    final type = turn['type'] as String?;
    return NewTurn(
      type == 'assistant'
          ? MessageRole.assistant
          : type == 'tool'
              ? MessageRole.tool
              : MessageRole.user,
      text: turn['text'] as String?,
      toolCallJson: turn['toolCallJson'] as String?,
      reasoning: turn['reasoning'] as String?,
    );
  }

  static Map<String, Object?> _turnJson(TurnRow turn) => {
        'type': turn.kind,
        'text': turn.text ?? '',
        'toolCallJson': turn.toolCallJson,
        if (turn.reasoning != null) 'reasoning': turn.reasoning,
      };

  /// The title the history list shows: the first thing the user typed, shortened.
  static String titleOf(List<Map<String, Object?>> messages) {
    final first = messages.firstWhere(
      (m) => m['role'] != 'assistant',
      orElse: () => const {},
    );
    final text = ((first['text'] as String?) ?? '').trim();
    if (text.isEmpty) return '新しい会話';
    return text.length > 40 ? text.substring(0, 40) : text;
  }

  static String? _finishOf(String? stored) {
    if (stored == interruptedFinishReason) return 'cancelled';
    return _finishReasons.contains(stored) ? stored : null;
  }

  /// The reply's text. One message holds one text part in this version; several are joined in
  /// the order the model wrote them.
  static String _textOf(List<PartRow> parts) => [
        for (final p in parts)
          if (p.kind == PartKind.text && (p.body?.isNotEmpty ?? false)) p.body!,
      ].join('\n');

  static String? _bodyOf(List<PartRow> parts, String kind) {
    for (final p in parts) {
      if (p.kind == kind && p.body != null) return p.body;
    }
    return null;
  }

  /// How long the model thought, kept in the payload of the reasoning part (0 when it was not noted).
  static int _thinkingMsOf(List<PartRow> parts) {
    final payload = _payloadOf(parts, PartKind.reasoning);
    if (payload == null) return 0;
    try {
      final decoded = jsonDecode(payload);
      return decoded is Map && decoded['ms'] is num ? (decoded['ms'] as num).toInt() : 0;
    } on FormatException {
      return 0;
    }
  }

  static String? _payloadOf(List<PartRow> parts, String kind) {
    for (final p in parts) {
      if (p.kind == kind && p.payload != null) return p.payload;
    }
    return null;
  }

  static List<String> _bodiesOf(List<PartRow> parts, String kind) => [
        for (final p in parts)
          if (p.kind == kind && p.body != null) p.body!,
      ];

  static List<Map<String, Object?>> _jsonsOf(List<PartRow> parts, String kind) {
    final out = <Map<String, Object?>>[];
    for (final p in parts) {
      if (p.kind != kind) continue;
      final decoded = _jsonOf(p.payload);
      if (decoded != null) out.add(decoded);
    }
    return out;
  }

  static Map<String, Object?>? _jsonOf(String? payload) {
    if (payload == null) return null;
    try {
      final decoded = jsonDecode(payload);
      return decoded is Map ? decoded.cast<String, Object?>() : null;
    } catch (_) {
      return null;
    }
  }

  static DateTime _timeOf(Map<String, Object?> message) {
    final millis = message['time'];
    return millis is int ? DateTime.fromMillisecondsSinceEpoch(millis) : DateTime.now();
  }

  static List<Map<String, Object?>> _maps(Object? value) => [
        for (final entry in (value as List? ?? const []))
          if (entry is Map) entry.cast<String, Object?>(),
      ];
}
