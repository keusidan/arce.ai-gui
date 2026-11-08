import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'provider.dart';

/// "When this model cannot be used, use these instead."
///
/// A free model of a router is the cheapest to ask and the first to answer with 403 or 429; the
/// user keeps another provider's model for those moments. A rule names the model (or all the
/// models of a provider, or every model) and the models to try, in order.
class FallbackRule {
  const FallbackRule({required this.from, required this.targets, this.statuses = const {}});

  /// `provider|model`, `provider|*` (any model of the provider) or `*` (any model).
  final String from;

  /// `provider|model` references, tried in order.
  final List<String> targets;

  /// The HTTP statuses that start the fallback; empty means [FallbackPolicy.defaultStatuses].
  final Set<int> statuses;

  /// How closely the rule names a model: an exact one wins over a provider's, which wins over `*`.
  int get specificity => from == '*' ? 0 : (from.endsWith('|*') ? 1 : 2);

  bool covers(String providerId, String modelId) {
    if (from == '*') return true;
    final parsed = parseRef(from);
    if (parsed == null) return false;
    final (provider, model) = parsed;
    return provider == providerId && (model == '*' || model == modelId);
  }

  Map<String, Object?> toJson() => {
        'from': from,
        'targets': targets,
        if (statuses.isNotEmpty) 'statuses': (statuses.toList()..sort()),
      };

  static FallbackRule? fromJson(Object? json) {
    if (json is! Map || json['from'] is! String) return null;
    final targets = [
      if (json['targets'] is List)
        for (final t in json['targets']! as List)
          if (t is String && parseRef(t) != null) t,
    ];
    if (targets.isEmpty) return null;
    return FallbackRule(
      from: json['from']! as String,
      targets: targets,
      statuses: {
        if (json['statuses'] is List)
          for (final s in json['statuses']! as List)
            if (s is int && s >= 100 && s < 600) s,
      },
    );
  }

  /// `provider|model` → its two parts; null when it is not one. The model may be empty (the
  /// provider's own first model) or `*`.
  static (String, String)? parseRef(String ref) {
    final bar = ref.indexOf('|');
    if (bar <= 0) return null;
    return (ref.substring(0, bar), ref.substring(bar + 1));
  }

  static List<FallbackRule> decodeList(Object? json) => [
        if (json is List)
          for (final entry in json) ...[?fromJson(entry)],
      ];
}

/// Which failures start the fallback, and which rule applies to a model.
abstract final class FallbackPolicy {
  /// A refused key, a missing model, a request that took too long, too many requests. Every 5xx
  /// and every failure to connect counts as well. A 400 (the request itself is wrong) does not:
  /// the next model would refuse it as well.
  static const defaultStatuses = {401, 403, 404, 408, 429};

  /// Whether [error] is the kind that another model may not share.
  static bool accepts(Object error, Set<int> statuses) {
    if (error is AiProviderException) {
      final code = error.statusCode;
      if (code == null) return false;
      return code >= 500 || statuses.contains(code);
    }
    return error is SocketException || error is TimeoutException || error is http.ClientException;
  }

  /// The most specific rule that covers the model; the earlier one when two are as specific.
  static FallbackRule? ruleFor(List<FallbackRule> rules, String providerId, String modelId) {
    FallbackRule? best;
    for (final rule in rules) {
      if (!rule.covers(providerId, modelId)) continue;
      if (best == null || rule.specificity > best.specificity) best = rule;
    }
    return best;
  }

  /// A short reason for the notice shown when the fallback happens.
  static String reason(Object error) {
    if (error is AiProviderException) {
      final code = error.statusCode;
      return code == null ? error.message : 'HTTP $code';
    }
    if (error is TimeoutException) return '時間切れ';
    return '接続できません';
  }
}

/// The models to try after the one in use fails, and which failures count.
class FallbackPlan {
  const FallbackPlan({required this.targets, required this.statuses});

  final List<AiProvider> targets;
  final Set<int> statuses;

  bool accepts(Object error) => FallbackPolicy.accepts(error, statuses);
}

/// Streams the answer of [primary]; when it fails before sending anything and [plan] says the
/// failure is one to step over, the next model of the plan answers instead. A failure after the
/// first piece went out is not hidden: the reply is already half written by that model.
///
/// [build] makes the request for one provider (each model has its own limits and thinking
/// settings). [onSwitch] is told which model took over, and why.
///
/// [onFailure] is told of every model that failed, and returns the error to go on with (the same one, or
/// one that says more: which model this key cannot use). [onSuccess] is told of the model that answered.
Stream<Delta> streamWithFallback({
  required AiProvider primary,
  required FallbackPlan? plan,
  required AiRequest Function(AiProvider provider) build,
  void Function(AiProvider from, AiProvider to, String reason)? onSwitch,
  Object Function(AiProvider provider, Object error)? onFailure,
  void Function(AiProvider provider)? onSuccess,
}) async* {
  final chain = [primary, ...?plan?.targets];
  for (var i = 0; i < chain.length; i++) {
    final provider = chain[i];
    var sent = false;
    try {
      await for (final delta in provider.stream(build(provider))) {
        sent = true;
        yield delta;
      }
      onSuccess?.call(provider);
      return;
    } catch (error, stack) {
      final noted = onFailure?.call(provider, error) ?? error;
      final hasNext = i < chain.length - 1;
      if (sent || !hasNext || plan == null || !plan.accepts(error)) Error.throwWithStackTrace(noted, stack);
      onSwitch?.call(provider, chain[i + 1], FallbackPolicy.reason(error));
    }
  }
}
