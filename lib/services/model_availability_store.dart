import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ai/model_availability.dart';

/// What the app found out about which models of each provider this key can use.
///
/// Only the verdict, its short reason and when it was found are kept, per `(provider, model)`: no key, no
/// request and no answer. A result is believed for a number of days only (plans change: a free tier gains
/// a model, a key gets billing), so the caller says how many days when it asks. Results that are old
/// enough are dropped when the store is written.
///
/// One JSON document in shared preferences, apart from the providers: a provider's own settings never
/// carry a note about its models' state.
class ModelAvailabilityStore extends ChangeNotifier {
  ModelAvailabilityStore(this._prefs, {int Function()? now}) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch) {
    _records.addAll(decode(_prefs.getString(_key)));
  }

  static const _key = 'models.availability.v1';

  final SharedPreferences _prefs;
  final int Function() _now;
  final _records = <String, AvailabilityRecord>{};

  static Future<ModelAvailabilityStore> load({int Function()? now}) async =>
      ModelAvailabilityStore(await SharedPreferences.getInstance(), now: now);

  static String refOf(String providerId, String modelId) => '$providerId|$modelId';

  /// The result for the model, when there is one and it is not older than [trustDays].
  AvailabilityRecord? recordOf(String providerId, String modelId, {required int trustDays}) {
    final found = _records[refOf(providerId, modelId)];
    if (found == null || !found.isFresh(_now(), trustDays)) return null;
    return found;
  }

  /// How many models have a result (of any age); for the tests and the settings screen.
  int get length => _records.length;

  /// Keeps [verdict] for the model. Only a verdict that stays true for a while is kept (usable or
  /// blocked); a failure that passes, or says nothing, changes nothing. Results older than [trustDays] go.
  Future<void> record(String providerId, String modelId, AvailabilityVerdict verdict, {required int trustDays}) async {
    if (providerId.isEmpty || modelId.isEmpty || !verdict.isRemembered) return;
    _records[refOf(providerId, modelId)] = AvailabilityRecord(verdict.availability, verdict.reason, _now());
    _dropOld(trustDays);
    notifyListeners();
    await _persist();
  }

  /// Several results at once (the end of a probe): one write.
  Future<void> recordAll(String providerId, Map<String, AvailabilityVerdict> verdicts, {required int trustDays}) async {
    var changed = false;
    for (final entry in verdicts.entries) {
      if (providerId.isEmpty || entry.key.isEmpty || !entry.value.isRemembered) continue;
      _records[refOf(providerId, entry.key)] = AvailabilityRecord(entry.value.availability, entry.value.reason, _now());
      changed = true;
    }
    if (!changed) return;
    _dropOld(trustDays);
    notifyListeners();
    await _persist();
  }

  /// A request was answered by the model: a mark that said it was unusable is no longer true. Nothing is
  /// written for a model that was not marked, so answering costs nothing.
  Future<void> noteAnswered(String providerId, String modelId) async {
    final ref = refOf(providerId, modelId);
    final found = _records[ref];
    if (found == null || !found.isBlocked) return;
    _records[ref] = AvailabilityRecord(ModelAvailability.usable, '', _now());
    notifyListeners();
    await _persist();
  }

  /// Forgets what is known about the model.
  Future<void> forget(String providerId, String modelId) async {
    if (_records.remove(refOf(providerId, modelId)) == null) return;
    notifyListeners();
    await _persist();
  }

  /// Forgets everything about the providers that are not in [keep] (a provider was removed).
  Future<void> keepOnly(Set<String> keep) async {
    final before = _records.length;
    _records.removeWhere((ref, _) => !keep.contains(ref.substring(0, ref.indexOf('|'))));
    if (_records.length == before) return;
    notifyListeners();
    await _persist();
  }

  /// Forgets everything (the settings screen's button).
  Future<void> clear() async {
    if (_records.isEmpty) return;
    _records.clear();
    notifyListeners();
    await _prefs.remove(_key);
  }

  void _dropOld(int trustDays) => _records.removeWhere((_, r) => !r.isFresh(_now(), trustDays));

  Future<void> _persist() => _prefs.setString(_key, encode(_records));

  static String encode(Map<String, AvailabilityRecord> records) => jsonEncode({
        for (final entry in records.entries)
          entry.key: {'a': entry.value.availability.name, 'r': entry.value.reason, 't': entry.value.at},
      });

  /// A damaged or older document gives what can be read, never an error.
  static Map<String, AvailabilityRecord> decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final out = <String, AvailabilityRecord>{};
      for (final entry in decoded.entries) {
        final value = entry.value;
        if (entry.key is! String || !(entry.key as String).contains('|') || value is! Map) continue;
        final availability = ModelAvailability.values.asNameMap()[value['a']];
        final at = value['t'];
        if (availability == null || at is! int) continue;
        // only what stays true for a while is ever written; anything else in a file is ignored
        if (availability != ModelAvailability.usable && availability != ModelAvailability.blocked) continue;
        out[entry.key as String] = AvailabilityRecord(availability, value['r'] is String ? value['r'] as String : '', at);
      }
      return out;
    } catch (_) {
      return {};
    }
  }
}
