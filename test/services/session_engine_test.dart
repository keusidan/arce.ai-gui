import 'dart:async';

import 'package:arce_ai/ai/cloud_engine.dart';
import 'package:arce_ai/ai/provider.dart';
import 'package:arce_ai/ai/provider_config.dart';
import 'package:arce_ai/ai/routing_engine.dart';
import 'package:arce_ai/core/engine.dart';
import 'package:arce_ai/core/generation.dart';
import 'package:arce_ai/core/prompt.dart';
import 'package:arce_ai/core/chat_controller.dart';
import 'package:arce_ai/services/chat_handle.dart';
import 'package:arce_ai/services/session_engine.dart';
import 'package:flutter_test/flutter_test.dart';

/// An online provider whose answers the test writes by hand, one stream per request.
class HandProvider implements AiProvider {
  final streams = <StreamController<Delta>>[];

  @override
  String get id => 'hand';
  @override
  String get label => '手書き';
  @override
  String get modelId => 'm';
  @override
  ModelConfig? get modelConfig => null;
  @override
  ProviderCapabilities get capabilities => const ProviderCapabilities();
  @override
  Future<void> verify() async {}

  /// How many requests were dropped by the user's stop (a real provider closes its connection).
  int aborted = 0;

  @override
  Stream<Delta> stream(AiRequest request) {
    final controller = StreamController<Delta>();
    streams.add(controller);
    request.abort?.then((_) {
      aborted++;
      controller.close();
    });
    return controller.stream;
  }
}

/// The device model: answers when the test says so.
class HandLocal implements InferenceEngine {
  final runs = <StreamController<GenerationEvent>>[];
  int cancels = 0;

  @override
  bool get isLoaded => true;
  @override
  Future<void> load(LoadParams params) async {}
  @override
  Future<void> unload() async {}
  @override
  void cancel() => cancels++;

  @override
  Stream<GenerationEvent> generate(GenerateRequest request) {
    final controller = StreamController<GenerationEvent>();
    runs.add(controller);
    return controller.stream;
  }
}

GenerateRequest request(String text) => GenerateRequest(
      prompt: ChatMlPromptBuilder.build([UserTurn(text)], const [], null, false),
      toolCallSchema: null,
      thinking: false,
      maxTokens: 64,
      sampling: const SamplingParams(temperature: 0.5, topP: 1, topK: 20, minP: 0, dryMultiplier: 0),
    );

Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  test('online: stopping one chat ends only that chat; the other one carries on', () async {
    final provider = HandProvider();
    final cloud = CloudEngine(provider);
    final router = RoutingEngine(local: HandLocal(), cloud: cloud)..target = provider;
    final lease = ExclusiveLease();
    final a = SessionEngine(router, lease);
    final b = SessionEngine(router, lease);

    final textA = <String>[];
    final textB = <String>[];
    final endA = <FinishReason>[];
    final endB = <FinishReason>[];
    a.generate(request('a')).listen((e) {
      if (e is Piece) textA.add(e.text);
      if (e is Finished) endA.add(e.reason);
    });
    b.generate(request('b')).listen((e) {
      if (e is Piece) textB.add(e.text);
      if (e is Finished) endB.add(e.reason);
    });
    await settle();
    expect(provider.streams, hasLength(2), reason: 'two requests at once');

    provider.streams[0].add(const TextDelta('A1'));
    provider.streams[1].add(const TextDelta('B1'));
    await settle();
    a.cancel();
    provider.streams[0].add(const TextDelta('A2'));
    provider.streams[1].add(const TextDelta('B2'));
    await settle();
    provider.streams[1].add(const StopDelta(FinishReason.eog));
    await provider.streams[1].close();
    await settle();

    expect(textA, ['A1'], reason: 'nothing after stop');
    expect(endA, [FinishReason.cancelled]);
    expect(textB, ['B1', 'B2'], reason: 'the other chat is not stopped');
    expect(endB, [FinishReason.eog]);
    expect(lease.isHeld, isFalse, reason: 'online answers do not take the device model');
  });

  test('online: stop ends the reply at once even when the model is silent (it is thinking), and drops the request', () async {
    final provider = HandProvider();
    final router = RoutingEngine(local: HandLocal(), cloud: CloudEngine(provider))..target = provider;
    final a = SessionEngine(router, ExclusiveLease());
    final events = <GenerationEvent>[];
    var closed = false;
    a.generate(request('a')).listen(events.add, onDone: () => closed = true);
    await settle();
    expect(provider.streams, hasLength(1));
    a.cancel(); // nothing has been sent by the model: no event to wake the loop
    await settle();
    await settle();
    expect(closed, isTrue, reason: 'it does not wait for the next word');
    expect(events.whereType<Finished>().single.reason, FinishReason.cancelled);
    expect(provider.aborted, 1, reason: 'the request is told to drop its connection');
  });

  test('device model: a second chat is told it is in use, and can use it once the first is done', () async {
    final local = HandLocal();
    final router = RoutingEngine(local: local, cloud: CloudEngine(HandProvider())); // no target: the device model answers
    final lease = ExclusiveLease();
    final a = SessionEngine(router, lease);
    final b = SessionEngine(router, lease);

    final first = <GenerationEvent>[];
    a.generate(request('a')).listen(first.add);
    await settle();
    expect(lease.isHeld, isTrue);

    await expectLater(b.generate(request('b')).toList(), throwsA(isA<EngineException>().having((e) => e.message, 'message', contains('ほかのチャット'))));

    local.runs.single.add(const Piece('done'));
    local.runs.single.add(const Finished(FinishReason.eog));
    await local.runs.single.close();
    await settle();
    expect(first.whereType<Finished>(), hasLength(1));
    expect(lease.isHeld, isFalse);

    final second = <GenerationEvent>[];
    b.generate(request('b')).listen(second.add);
    await settle();
    expect(local.runs, hasLength(2), reason: 'now it may use the model');
  });

  test('device model: stop reaches the device engine, and only for the chat that uses it', () async {
    final local = HandLocal();
    final router = RoutingEngine(local: local, cloud: CloudEngine(HandProvider()));
    final lease = ExclusiveLease();
    final a = SessionEngine(router, lease);
    final b = SessionEngine(router, lease);
    a.generate(request('a')).listen((_) {});
    await settle();
    b.cancel(); // b is not generating: it must not stop a
    expect(local.cancels, 0);
    a.cancel();
    expect(local.cancels, 1);
  });

  test('ChatHandle shows one chat at a time and tells its listeners when it changes', () async {
    ChatController make() => ChatController(HandLocal());
    final first = make();
    final second = make();
    final handle = ChatHandle(first);
    var heard = 0;
    handle.addListener(() => heard++);

    first.clear();
    expect(heard, greaterThan(0), reason: 'what the shown chat does reaches the listeners');
    final before = heard;
    handle.show(second);
    expect(handle.current, same(second));
    expect(heard, before + 1);

    final now = heard;
    first.clear(); // not shown any more
    expect(heard, now);
    second.clear();
    expect(heard, greaterThan(now));
  });
}
