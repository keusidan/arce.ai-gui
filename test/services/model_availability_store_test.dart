import 'package:arce_ai/ai/model_availability.dart';
import 'package:arce_ai/services/model_availability_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

AvailabilityVerdict blocked([String reason = '理由']) => AvailabilityVerdict(ModelAvailability.blocked, reason);

void main() {
  const day = Duration.millisecondsPerDay;
  late int now;

  Future<ModelAvailabilityStore> open([Map<String, Object> initial = const {}]) async {
    SharedPreferences.setMockInitialValues(initial);
    return ModelAvailabilityStore.load(now: () => now);
  }

  setUp(() => now = 1000 * day);

  test('remembers what was found, per provider and model', () async {
    final store = await open();
    await store.record('gemini', 'gemini-2.5-pro', blocked('無料枠では 0'), trustDays: 7);
    await store.record('gemini', 'gemini-2.5-flash', AvailabilityVerdict.usable, trustDays: 7);
    expect(store.recordOf('gemini', 'gemini-2.5-pro', trustDays: 7)!.isBlocked, isTrue);
    expect(store.recordOf('gemini', 'gemini-2.5-pro', trustDays: 7)!.reason, '無料枠では 0');
    expect(store.recordOf('gemini', 'gemini-2.5-flash', trustDays: 7)!.isUsable, isTrue);
    expect(store.recordOf('gemini', 'other', trustDays: 7), isNull);
    expect(store.recordOf('openai', 'gemini-2.5-pro', trustDays: 7), isNull, reason: 'another provider is another key');
  });

  test('a failure that passes, or says nothing, or is about the key, is not remembered', () async {
    final store = await open();
    for (final verdict in [
      const AvailabilityVerdict(ModelAvailability.temporary, 't'),
      const AvailabilityVerdict(ModelAvailability.unknown, 'u'),
      const AvailabilityVerdict(ModelAvailability.keyRejected, 'k'),
    ]) {
      await store.record('p', 'm', verdict, trustDays: 7);
    }
    expect(store.length, 0);
    // and it never wipes what was known
    await store.record('p', 'm', blocked(), trustDays: 7);
    await store.record('p', 'm', const AvailabilityVerdict(ModelAvailability.temporary, 't'), trustDays: 7);
    expect(store.recordOf('p', 'm', trustDays: 7)!.isBlocked, isTrue);
  });

  test('a result is believed for the number of days asked, and no longer', () async {
    final store = await open();
    await store.record('p', 'm', blocked(), trustDays: 30);
    now += 6 * day;
    expect(store.recordOf('p', 'm', trustDays: 7), isNotNull);
    now += 2 * day;
    expect(store.recordOf('p', 'm', trustDays: 7), isNull, reason: 'eight days: too old for a week');
    expect(store.recordOf('p', 'm', trustDays: 30), isNotNull, reason: 'the setting decides, the file does not');
  });

  test('old results are dropped when something is written', () async {
    final store = await open();
    await store.record('p', 'old', blocked(), trustDays: 7);
    now += 10 * day;
    await store.record('p', 'new', blocked(), trustDays: 7);
    expect(store.length, 1);
    expect(store.recordOf('p', 'new', trustDays: 7), isNotNull);
  });

  test('survives a restart, with the time it was found', () async {
    final first = await open();
    await first.record('p', 'm', blocked('なし'), trustDays: 7);
    now += 2 * day;
    final prefs = await SharedPreferences.getInstance();
    final second = ModelAvailabilityStore(prefs, now: () => now);
    final found = second.recordOf('p', 'm', trustDays: 7)!;
    expect(found.reason, 'なし');
    expect(found.at, 1000 * day);
    expect(found.isBlocked, isTrue);
  });

  test('a model id with a bar in it is kept apart from its provider', () async {
    final store = await open();
    await store.record('p', 'a|b', blocked(), trustDays: 7);
    final prefs = await SharedPreferences.getInstance();
    final again = ModelAvailabilityStore(prefs, now: () => now);
    expect(again.recordOf('p', 'a|b', trustDays: 7), isNotNull);
  });

  test('one write for the end of a probe, and only what stays true', () async {
    final store = await open();
    var told = 0;
    store.addListener(() => told++);
    await store.recordAll(
      'p',
      {
        'ok': AvailabilityVerdict.usable,
        'no': blocked(),
        'busy': const AvailabilityVerdict(ModelAvailability.temporary, 't'),
        'huh': const AvailabilityVerdict(ModelAvailability.unknown, 'u'),
      },
      trustDays: 7,
    );
    expect(store.length, 2);
    expect(told, 1);
    await store.recordAll('p', {'busy': const AvailabilityVerdict(ModelAvailability.temporary, 't')}, trustDays: 7);
    expect(told, 1, reason: 'nothing changed: nobody is told');
  });

  test('a model that answers loses its "unusable" note; one that was not marked costs nothing', () async {
    final store = await open();
    await store.record('p', 'm', blocked(), trustDays: 7);
    await store.noteAnswered('p', 'm');
    expect(store.recordOf('p', 'm', trustDays: 7)!.isUsable, isTrue);
    var told = 0;
    store.addListener(() => told++);
    await store.noteAnswered('p', 'never-marked');
    await store.noteAnswered('p', 'm');
    expect(told, 0, reason: 'a usable model answering again changes nothing');
    expect(store.length, 1);
  });

  test('forgetting one model, the models of removed providers, and everything', () async {
    final store = await open();
    for (final (p, m) in [('a', '1'), ('a', '2'), ('b', '1'), ('c', '1')]) {
      await store.record(p, m, blocked(), trustDays: 7);
    }
    await store.forget('a', '1');
    expect(store.recordOf('a', '1', trustDays: 7), isNull);
    expect(store.length, 3);
    await store.keepOnly({'a', 'b'});
    expect(store.recordOf('c', '1', trustDays: 7), isNull);
    expect(store.length, 2);
    await store.clear();
    expect(store.length, 0);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('models.availability.v1'), isNull);
  });

  test('tells its listeners when something changed', () async {
    final store = await open();
    var told = 0;
    store.addListener(() => told++);
    await store.record('p', 'm', blocked(), trustDays: 7);
    await store.forget('p', 'm');
    await store.forget('p', 'm');
    expect(told, 2);
  });

  test('a damaged or foreign document gives what can be read, never an error', () async {
    for (final raw in ['', 'not json', '[]', '{"a":1}', '{"p|m":{"a":"nonsense","t":1}}', '{"nobar":{"a":"blocked","t":1}}', '{"p|m":{"a":"temporary","t":1}}', '{"p|m":{"a":"blocked"}}']) {
      expect(ModelAvailabilityStore.decode(raw), isEmpty, reason: raw);
    }
    final ok = ModelAvailabilityStore.decode('{"p|m":{"a":"blocked","r":"x","t":5},"p|bad":{"a":"nonsense","t":1}}');
    expect(ok.keys, ['p|m']);
    expect(ok['p|m']!.reason, 'x');
    // a reason that is not text is dropped, the verdict is kept
    expect(ModelAvailabilityStore.decode('{"p|m":{"a":"usable","r":5,"t":5}}')['p|m']!.reason, '');
  });

  test('what is written holds a verdict, a reason and a time, and nothing else', () async {
    final store = await open();
    await store.record('gemini', 'gemini-2.5-pro', blocked('理由'), trustDays: 7);
    final prefs = await SharedPreferences.getInstance();
    final text = prefs.getString('models.availability.v1')!;
    expect(text, '{"gemini|gemini-2.5-pro":{"a":"blocked","r":"理由","t":${1000 * day}}}');
  });
}
