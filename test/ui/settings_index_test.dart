import 'dart:io';

import 'package:arce_ai/core/settings_search.dart';
import 'package:arce_ai/core/settings_spec.dart';
import 'package:arce_ai/services/app_controller.dart' show SettingsSection;
import 'package:arce_ai/services/settings.dart';
import 'package:arce_ai/ui/settings_index.dart';
import 'package:flutter_test/flutter_test.dart';

/// The text of every file of the UI, as one string: what the screen can say is in it.
String uiSource() => [
      for (final file in Directory('lib/ui').listSync().whereType<File>())
        if (file.path.endsWith('.dart')) file.readAsStringSync(),
    ].join('\n');

void main() {
  final rows = [for (final e in settingsIndex) if (!e.isGroup) e];
  final groups = [for (final e in settingsIndex) if (e.isGroup) e];

  group('the groups', () {
    test('every group of the settings screen has one entry, and there is no other', () {
      expect([for (final g in groups) g.sectionId]..sort(), [for (final s in SettingsSection.values) s.name]..sort());
      expect(groups.map((g) => g.sectionId).toSet(), hasLength(groups.length));
      for (final g in groups) {
        expect(g.title, settingsSectionTitle(SettingsSection.values.byName(g.sectionId)));
        expect(g.settingKey, isNull);
      }
    });

    test('every group has rows of its own', () {
      for (final section in SettingsSection.values) {
        expect(rows.where((e) => e.sectionId == section.name), isNotEmpty, reason: section.name);
      }
    });

    test('every entry says a group that exists', () {
      final names = {for (final s in SettingsSection.values) s.name};
      for (final e in settingsIndex) {
        expect(names, contains(e.sectionId), reason: e.title);
      }
    });

    test('the title of a group finds the group, first', () {
      for (final section in SettingsSection.values) {
        final title = settingsSectionTitle(section);
        final hits = SettingsSearch.search(settingsIndex, title);
        expect(hits, isNotEmpty, reason: title);
        expect(hits.first.entry.isGroup, isTrue, reason: '$title: the group is the first hit');
        expect(hits.first.entry.sectionId, section.name, reason: title);
      }
    });

    test('the titles are the ones the screen has (read from the group list of the settings page, when it is there)', () {
      final source = File('lib/ui/settings_page.dart').readAsStringSync();
      final found = RegExp(r"_Group\(SettingsSection\.(\w+),\s*ArceSvg\.\w+,\s*'([^']*)',\s*'([^']*)'\)").allMatches(source).toList();
      if (found.isEmpty) return; // the list moved: the other tests still guard the index
      expect(found, hasLength(SettingsSection.values.length));
      for (final m in found) {
        final section = SettingsSection.values.byName(m.group(1)!);
        expect(settingsSectionTitle(section), m.group(2), reason: section.name);
        expect(groups.firstWhere((g) => g.sectionId == section.name).subtitle, m.group(3), reason: section.name);
      }
    });
  });

  group('the rows', () {
    test('no row twice in one group', () {
      final seen = <String>{};
      for (final e in rows) {
        expect(seen.add('${e.sectionId}|${e.title}'), isTrue, reason: '${e.sectionId}: ${e.title}');
      }
    });

    test('every row has a title and some keywords', () {
      for (final e in rows) {
        expect(e.title.trim(), isNotEmpty);
        expect(e.title, e.title.trim(), reason: e.title);
        expect(e.keywords, isNotEmpty, reason: '${e.sectionId}: ${e.title} has no synonym');
      }
    });

    test('the key a row names exists in the settings, and no setting has two rows', () {
      final json = const AppSettings().toJson();
      final keys = <String>[];
      for (final e in settingsIndex) {
        final key = e.settingKey;
        if (key == null) continue;
        expect(json.containsKey(key), isTrue, reason: '${e.title}: $key is not an AppSettings key');
        keys.add(key);
      }
      expect(keys.toSet(), hasLength(keys.length), reason: 'a setting is edited in one place');
    });

    // Settings the chat can change that have no row in the settings screen of their own.
    const noRow = {
      // the 「検索」 button under the chat input is its switch; the settings screen has no row for it
      'searchEnabled',
      // the batch size is only for the chat to change; the screen has no row for it
      'batchSize',
    };

    test('every setting the chat can change has a row, or is in the list of those that have none', () {
      final covered = {for (final e in settingsIndex) if (e.settingKey != null) e.settingKey!};
      final missing = [for (final key in AgentSettings.specs.keys) if (!covered.contains(key) && !noRow.contains(key)) key];
      expect(missing, isEmpty, reason: 'rows are missing for: $missing');
    });

    test('the list of settings without a row is kept honest: each is a setting the chat can change, and has really no row', () {
      final covered = {for (final e in settingsIndex) if (e.settingKey != null) e.settingKey!};
      for (final key in noRow) {
        expect(AgentSettings.isEditable(key), isTrue, reason: key);
        expect(covered, isNot(contains(key)), reason: '$key has a row now: take it out of the list');
      }
    });

    test('the blocked settings that have a row of their own are marked: the chat cannot change them, the screen can', () {
      for (final e in rows) {
        final key = e.settingKey;
        if (key != null && AgentSettings.blocked.contains(key)) {
          expect(AgentSettings.isEditable(key), isFalse, reason: key);
        }
      }
      // and the other way: a key that the chat can change is never in the blocked list
      for (final key in AgentSettings.specs.keys) {
        expect(AgentSettings.blocked, isNot(contains(key)));
      }
    });
  });

  group('what the screen says', () {
    final source = uiSource();

    test('every title is a text of the UI (the index is copied from the screen, not made up)', () {
      for (final e in settingsIndex) {
        expect(source.contains(e.title), isTrue, reason: '${e.sectionId}: "${e.title}" is not in lib/ui');
      }
    });

    test('every note starts as a text of the UI does', () {
      for (final e in settingsIndex) {
        if (e.subtitle.isEmpty) continue;
        final head = e.subtitle.length <= 10 ? e.subtitle : e.subtitle.substring(0, 10);
        expect(source.contains(head), isTrue, reason: '${e.sectionId}: the note of "${e.title}" starts with "$head", which is not in lib/ui');
      }
    });
  });

  group('what people type', () {
    List<SettingsHit> find(String query) => SettingsSearch.search(settingsIndex, query);
    Set<String> sections(String query) => {for (final h in find(query)) h.entry.sectionId};
    Set<String?> keys(String query) => {for (final h in find(query)) h.entry.settingKey};

    test('通知 finds the four notification settings, first', () {
      final hits = find('通知');
      expect(hits.take(4).map((h) => h.entry.settingKey).toSet(), {'notifyNeedsYou', 'notifyDone', 'notifyFailed', 'notifyOnlyAway'});
    });

    test('トークン, token and とーくん find the token rows of every group that has one', () {
      for (final query in ['トークン', 'token', 'とーくん', 'ＴＯＫＥＮ']) {
        expect(sections(query), containsAll(['mcp', 'update', 'reports', 'providers', 'shell']), reason: query);
      }
    });

    test('temperature finds the online and the local one, and 温度 too', () {
      expect(keys('temperature'), containsAll(['onlineTemperature', 'localTemperature']));
      expect(keys('温度'), containsAll(['onlineTemperature', 'localTemperature']));
      expect(keys('ｔｅｍｐｅｒａｔｕｒｅ'), containsAll(['onlineTemperature', 'localTemperature']));
    });

    test('top_p, top-p and top p', () {
      expect(keys('top_p'), containsAll(['onlineTopP', 'localTopP']));
      expect(keys('top-p'), containsAll(['onlineTopP', 'localTopP']));
    });

    test('タイムアウト and timeout find the timeouts of the limits, the shell and the MCP servers', () {
      for (final query in ['タイムアウト', 'timeout']) {
        expect(keys(query), containsAll(['httpTimeoutSeconds', 'mcpTimeoutSeconds', 'providerTimeoutSeconds', 'shellTimeoutSeconds']), reason: query);
      }
    });

    test('キャッシュ and cache find the KV cache rows', () {
      for (final query in ['キャッシュ', 'cache']) {
        expect(keys(query), containsAll(['kvCache', 'kvSnapshotEnabled']), reason: query);
      }
    });

    test('要約 and 圧縮 find the compaction settings', () {
      for (final query in ['要約', '圧縮']) {
        expect(keys(query), containsAll(['compactEnabled', 'compactAtPercent', 'compactKeepTurns', 'compactSummaryChars', 'compactToolResultChars']), reason: query);
      }
    });

    test('秘密 and 環境変数 find the secrets for commands', () {
      expect(find('秘密').take(2).map((h) => h.entry.title).toSet(), {'秘密を追加', '秘密（モデルが {{secret:ID}} で使う）'}, reason: 'the two rows with it in the title come first');
      expect(keys('秘密'), contains('shellSecrets'));
      expect(keys('環境変数'), contains('shellSecrets'));
    });

    test('the tools people name find the Linux environment', () {
      for (final query in ['opencode', 'agy', 'antigravity', 'proot', 'ubuntu']) {
        expect(sections(query), contains('shell'), reason: query);
      }
    });

    test('通知 does not find the update settings, and a word nobody wrote finds nothing', () {
      expect(sections('通知'), isNot(contains('update')));
      expect(find('ほげふがぴよ'), isEmpty);
      expect(find(''), isEmpty);
    });

    test('two words narrow the search', () {
      final both = keys('mcp タイムアウト');
      expect(both, contains('mcpTimeoutSeconds'));
      expect(both, isNot(contains('httpTimeoutSeconds')));
    });
  });
}
