import 'dart:async';

import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'protocol.dart';
import 'settings_spec.dart';
import 'search.dart';
import 'weather.dart';

class Link {
  const Link(this.title, this.url);
  final String title;
  final String url;

  Map<String, Object?> toJson() => {'title': title, 'url': url};
  factory Link.fromJson(Map<String, Object?> json) =>
      Link(json['title'] as String, json['url'] as String);
}

/// What the chat shows about a tool run (e.g. the collapsible Search list).
class ToolActivity {
  const ToolActivity(
    this.tool,
    this.summary, {
    this.links = const [],
    this.failed = false,
  });

  final String tool;
  final String summary;
  final List<Link> links;
  final bool failed;

  Map<String, Object?> toJson() => {
    'tool': tool,
    'summary': summary,
    'links': [for (final l in links) l.toJson()],
    'failed': failed,
  };

  factory ToolActivity.fromJson(Map<String, Object?> json) => ToolActivity(
    json['tool'] as String,
    json['summary'] as String,
    links: [
      for (final l in (json['links'] as List? ?? const []))
        Link.fromJson((l as Map).cast()),
    ],
    failed: json['failed'] as bool? ?? false,
  );
}

/// [response] goes back to the model inside `<tool_response>`; [activity] goes to the UI.
class ToolOutcome {
  const ToolOutcome(this.response, this.activity, {this.shown});
  final String response;
  final ToolActivity activity;

  /// Text the chat adds to the reply the user reads, besides what the model says (the files the
  /// developer model wrote, in the coding mode). The model gets [response], not this, so a long
  /// result does not have to be copied into its answer.
  final String? shown;
}

/// Fired when the user presses stop. A tool that takes long (the developer model working) listens to
/// it, because nothing else tells it. [reset] clears it when a new reply starts.
class StopSignal {
  Completer<void> _completer = Completer<void>();

  Future<void> get future => _completer.future;
  bool get isStopped => _completer.isCompleted;

  void fire() {
    if (!_completer.isCompleted) _completer.complete();
  }

  void reset() {
    if (_completer.isCompleted) _completer = Completer<void>();
  }
}

/// Runs every tool except ask_user, which needs the user and is handled by the chat itself.
abstract interface class ToolRuntime {
  Future<ToolOutcome> run(ToolCall call);
}

class NoToolRuntime implements ToolRuntime {
  const NoToolRuntime();

  @override
  Future<ToolOutcome> run(ToolCall call) async => ToolOutcome(
    'This tool is not available.',
    ToolActivity(call.runtimeType.toString(), '利用できません', failed: true),
  );
}

typedef Clock = DateTime Function();

class DefaultToolRuntime implements ToolRuntime {
  DefaultToolRuntime({
    this.search,
    this.weather,
    this.settingsValues,
    this.extraSettings,
    this.searchHint,
    Clock? clock,
  }) : _clock = clock ?? DateTime.now;

  final SearchService? search;
  final OpenMeteoWeather? weather;

  /// Current values of the app settings (`AppSettings.toJson`), read for get_settings. Null where
  /// there is no settings store, which makes the tool answer that it is not available.
  final Map<String, Object?> Function()? settingsValues;

  /// Providers and MCP servers, appended to `get_settings`; never contains a key or a token.
  final String Function()? extraSettings;

  /// Added to the failure of a search, when something the user can set would have made it work.
  final String? searchHint;
  final Clock _clock;

  static bool _zonesReady = false;

  @override
  Future<ToolOutcome> run(ToolCall call) async => switch (call) {
    WebSearch() => _search(call.query),
    GetWeather() => _weather(call.location),
    GetTime() => _time(call.timezone),
    AskUser() => throw StateError(
      'ask_user is answered by the user, not run as a tool',
    ),
    GetSettings() => _settings(),
    UpdateSettings() => throw StateError(
      'update_settings is answered by the user, not run as a tool',
    ),
    AddProvider() => throw StateError(
      'add_provider is answered by the user, not run as a tool',
    ),
    McpCall() => throw StateError('MCP tools are run by the MCP runtime'),
    Delegate() => throw StateError('delegate is run by the coding mode, which holds the developer model'),
  };

  ToolOutcome _settings() {
    final values = settingsValues?.call();
    if (values == null) {
      return const ToolOutcome(
        'The app settings are not available here.',
        ToolActivity('Settings', '設定を読み取れません', failed: true),
      );
    }
    final extra = extraSettings?.call() ?? '';
    return ToolOutcome(
      'Current settings of this app (key = value # label):\n${AgentSettings.describe(values)}'
      '${extra.trim().isEmpty ? '' : '\n$extra'}',
      ToolActivity('Settings', '設定 ${AgentSettings.specs.length} 項目を読み取り'),
    );
  }

  Future<ToolOutcome> _search(String query) async {
    final service = search;
    if (service == null) {
      return const ToolOutcome(
        'Web search is turned off. Answer from your own knowledge and say so.',
        ToolActivity('Search', '検索はOFFです', failed: true),
      );
    }
    switch (await service.search(query)) {
      case SearchFound(:final provider, :final hits):
        final b = StringBuffer('Results for "$query" from $provider:\n');
        for (var i = 0; i < hits.length; i++) {
          final hit = hits[i];
          b
            ..write('${i + 1}. ${hit.title}\n')
            ..write('   ${hit.url}\n');
          if (hit.snippet.trim().isNotEmpty) {
            b.write(
              '   ${hit.snippet.length > 300 ? hit.snippet.substring(0, 300) : hit.snippet}\n',
            );
          }
        }
        b.write('Cite the URLs you use.');
        return ToolOutcome(
          b.toString(),
          ToolActivity(
            'Search',
            '「$query」 ${hits.length}件（$provider）',
            links: [for (final h in hits) Link(h.title, h.url)],
          ),
        );
      // spec §10.1: every provider failed -> continue with the local model only
      case SearchFailed(:final errors):
        return ToolOutcome(
          'Web search failed. Answer from your own knowledge and tell the user the answer was not checked online.'
          '${searchHint == null ? '' : ' Also tell the user: $searchHint'}',
          ToolActivity(
            'Search',
            '検索に失敗（ローカルAIのみで回答）: ${errors.isEmpty ? '' : errors.last}'
            '${searchHint == null ? '' : '\n$searchHint'}',
            failed: true,
          ),
        );
    }
  }

  Future<ToolOutcome> _weather(String location) async {
    final service = weather;
    if (service == null) {
      return const ToolOutcome(
        'Weather is unavailable.',
        ToolActivity('Weather', '天気は利用できません', failed: true),
      );
    }
    try {
      final r = await service.report(location);
      final text = [
        '${r.place}: ${r.description} ${r.temperatureC}°C',
        if (r.todayMaxC != null) 'max ${r.todayMaxC}°C',
        if (r.todayMinC != null) 'min ${r.todayMinC}°C',
        if (r.windKmh != null) 'wind ${r.windKmh} km/h',
      ].join(', ');
      return ToolOutcome(
        'Current weather: $text (Open-Meteo)',
        ToolActivity(
          'Weather',
          text,
          links: const [Link('Open-Meteo', 'https://open-meteo.com/')],
        ),
      );
    } catch (e) {
      return ToolOutcome(
        'Weather lookup failed: $e',
        ToolActivity('Weather', '天気の取得に失敗: $e', failed: true),
      );
    }
  }

  ToolOutcome _time(String? timezone) {
    const weekdays = ['月', '火', '水', '木', '金', '土', '日'];
    String two(int n) => n.toString().padLeft(2, '0');

    DateTime now;
    var zoneName = _clock().timeZoneName;
    if (timezone != null) {
      if (!_zonesReady) {
        tzdata.initializeTimeZones();
        _zonesReady = true;
      }
      try {
        final location = tz.getLocation(timezone);
        final t = tz.TZDateTime.from(_clock(), location);
        now = t;
        zoneName = timezone;
      } on tz.LocationNotFoundException {
        now = _clock();
      }
    } else {
      now = _clock();
    }
    final text =
        '${now.year}-${two(now.month)}-${two(now.day)} (${weekdays[now.weekday - 1]}) '
        '${two(now.hour)}:${two(now.minute)}:${two(now.second)} $zoneName';
    return ToolOutcome('Current time: $text', ToolActivity('Time', text));
  }
}
