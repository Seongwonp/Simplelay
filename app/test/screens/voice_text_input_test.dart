import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/providers/voice_provider.dart';
import 'package:simplelay/screens/voice_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';
import 'package:simplelay/services/voice_service.dart';

import '../helpers/test_helpers.dart';

const _fieldKey = Key('voice-text-field');
const _sendKey = Key('voice-text-send');

class _FakeVoice extends VoiceService {
  _FakeVoice({this.available = true});

  final bool available;
  bool listening = false;
  int stops = 0;

  @override
  bool get isListening => listening;

  @override
  Future<bool> initialize() async => available;

  @override
  Future<void> listen({
    required void Function(String text) onText,
    required void Function(String finalText) onSilence,
    void Function(String errorId)? onError,
    void Function(double level)? onSoundLevel,
    void Function()? onInterrupted,
    void Function(String text)? onFinal,
    void Function()? onDone,
  }) async {
    listening = true;
    onText('듣던 문장');
  }

  @override
  Future<void> stop() async {
    stops++;
    listening = false;
  }

  @override
  Future<void> cancel() async => listening = false;
}

http.Response _json(Object body, [int code = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), code,
        headers: {'content-type': 'application/json; charset=utf-8'});

Future<ProviderContainer> _mount(
  WidgetTester tester,
  _FakeVoice voice,
  Future<http.Response> Function(http.Request) hub, {
  bool withAppliance = true,
}) async {
  final api = RpiApiService('http://hub', client: MockClient(hub));
  final container = ProviderContainer(overrides: [
    ...installedOverrides(withAppliance ? [kTestAppliance] : []),
    voiceServiceProvider.overrideWithValue(voice),
    rpiApiServiceProvider.overrideWithValue(api),
  ]);
  addTearDown(container.dispose);
  final router = GoRouter(routes: [
    GoRoute(path: '/', builder: (_, __) => const VoiceScreen()),
    GoRoute(
        path: '/status',
        builder: (_, __) => const Scaffold(body: Text('status-screen-stub'))),
  ]);
  addTearDown(router.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(
      container: container, child: MaterialApp.router(routerConfig: router)));
  await tester.pump();
  return container;
}

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(_fieldKey), text);
  await tester.pump();
}

bool _sendEnabled(WidgetTester tester) =>
    tester.widget<IconButton>(find.byKey(_sendKey)).onPressed != null;

String _fieldText(WidgetTester tester) =>
    tester.widget<TextField>(find.byKey(_fieldKey)).controller!.text;

void main() {
  testWidgets('적어서 보내면 음성의 최종 문장처럼 확인을 묻고, 확인 전에는 본체에 보내지 않는다',
      (tester) async {
    final bodies = <Map<String, dynamic>>[];
    final writes = <String>[];
    final container = await _mount(tester, _FakeVoice(), (r) async {
      if (r.method == 'POST') writes.add(r.url.path);
      if (r.url.path == '/execute') {
        bodies.add(jsonDecode(r.body) as Map<String, dynamic>);
        return _json({'detail': 'busy'}, 409);
      }
      return _json({});
    });

    await _type(tester, '  즉석밥 데워줘  ');
    await tester.tap(find.byKey(_sendKey));
    await tester.pump();

    expect(find.text('이대로 할까요?'), findsOneWidget);
    expect(container.read(voiceTextProvider), '즉석밥 데워줘');
    expect(_fieldText(tester), isEmpty);
    expect(writes, isEmpty);

    await tester.ensureVisible(find.text('이대로 하기'));
    await tester.tap(find.text('이대로 하기'));
    await tester.pump();
    await tester.pump();

    expect(bodies, hasLength(1));
    expect(bodies.single['text'], '즉석밥 데워줘');
    expect(bodies.single['source'], 'voice');
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('글자도 언어 모델 제안을 거치면 네를 누르기 전에는 실행하지 않고 대기를 보인다',
      (tester) async {
    final understand = Completer<http.Response>();
    final writes = <String>[];
    await _mount(tester, _FakeVoice(), (r) async {
      if (r.url.path == '/execute') return _json({'detail': '몰라요'}, 422);
      if (r.url.path == '/intent/understand') return understand.future;
      if (r.method == 'POST') writes.add(r.url.path);
      return _json({'job_id': 'job1', 'running': false});
    });

    await _type(tester, '공기가 텁텁하네');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();
    await tester.ensureVisible(find.text('이대로 하기'));
    await tester.tap(find.text('이대로 하기'));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.text('생각하고 있어요…'), findsOneWidget);
    expect(find.byKey(_fieldKey), findsNothing);

    understand.complete(_json({
      'understood': true,
      'source': 'llm',
      'label': '공기청정기 켜기',
      'question': '공기청정기를 켤까요?',
      'action': {
        'kind': 'buttons',
        'appliance_id': kTestAppliance.id,
        'buttons': ['시작']
      },
    }));
    await tester.pumpAndSettle();

    expect(find.text('공기청정기를 켤까요?'), findsOneWidget);
    expect(writes, isEmpty);

    await tester.tap(find.text('아니요'));
    await tester.pumpAndSettle();
    expect(writes.where((p) => p.startsWith('/execute')), isEmpty);
  });

  testWidgets('빈 입력과 공백은 보내지 않는다', (tester) async {
    final container = await _mount(tester, _FakeVoice(), (r) async => _json({}));

    expect(_sendEnabled(tester), isFalse);
    await _type(tester, '   ');
    expect(_sendEnabled(tester), isFalse);
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();

    expect(container.read(voiceTextProvider), isEmpty);
    expect(find.text('이대로 할까요?'), findsNothing);
  });

  testWidgets('보내는 동안에는 글자 전송이 잠긴다', (tester) async {
    final execute = Completer<http.Response>();
    var calls = 0;
    final container = await _mount(tester, _FakeVoice(), (r) async {
      if (r.url.path == '/execute') {
        calls++;
        return execute.future;
      }
      return _json({});
    });
    container.read(voiceTextProvider.notifier).state = '즉석밥 데워줘';
    await tester.pump();
    await tester.ensureVisible(find.text('이대로 하기'));
    await tester.tap(find.text('이대로 하기'));
    await tester.pump();

    await _type(tester, '멈춰');
    expect(_sendEnabled(tester), isFalse);
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();

    expect(_fieldText(tester), '멈춰');
    expect(calls, 1);

    execute.complete(_json({'detail': 'busy'}, 409));
    await tester.pump();
    await tester.pump();
    expect(_sendEnabled(tester), isTrue);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('적은 "멈춰"는 확인 없이 정지로 보내고 실행으로 보내지 않는다', (tester) async {
    final paths = <String>[];
    final container = await _mount(tester, _FakeVoice(), (r) async {
      paths.add(r.url.path);
      return _json({'ok': true, 'was_running': false});
    });

    await _type(tester, ' 멈춰 ');
    await tester.tap(find.byKey(_sendKey));
    await tester.pump();
    await tester.pump();

    expect(paths.where((p) => p == '/stop'), hasLength(1));
    expect(paths.where((p) => p == '/execute'), isEmpty);
    expect(container.read(voiceTextProvider), isEmpty);
    expect(find.text('status-screen-stub'), findsNothing);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('마이크를 쓸 수 없는 기기에서도 적어서 확인 뒤 보낼 수 있다', (tester) async {
    final executed = <String>[];
    await _mount(tester, _FakeVoice(available: false), (r) async {
      if (r.url.path == '/execute') {
        executed.add(r.url.path);
        return _json({'detail': 'busy'}, 409);
      }
      return _json({});
    });
    await tester.tap(find.byIcon(Icons.mic_rounded));
    await tester.pumpAndSettle();

    expect(find.textContaining('마이크를 쓸 수 없어요'), findsOneWidget);
    await _type(tester, '즉석밥 데워줘');
    await tester.tap(find.byKey(_sendKey));
    await tester.pump();

    expect(find.text('이대로 할까요?'), findsOneWidget);
    expect(find.text('다시 말하기'), findsNothing);
    expect(find.byIcon(Icons.mic_rounded), findsNothing);
    expect(executed, isEmpty);

    await tester.ensureVisible(find.text('이대로 하기'));
    await tester.tap(find.text('이대로 하기'));
    await tester.pump();
    await tester.pump();
    expect(executed, hasLength(1));
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('쓸 수 없는 기기에서 적은 말을 취소하면 안내로 돌아간다', (tester) async {
    await _mount(
        tester, _FakeVoice(available: false), (r) async => _json({}));
    await tester.tap(find.byIcon(Icons.mic_rounded));
    await tester.pumpAndSettle();
    await _type(tester, '즉석밥 데워줘');
    await tester.tap(find.byKey(_sendKey));
    await tester.pump();

    await tester.ensureVisible(find.text('취소'));
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();

    expect(find.textContaining('마이크를 쓸 수 없어요'), findsOneWidget);
  });

  testWidgets('조작할 가전이 없으면 입력칸도 내주지 않는다', (tester) async {
    await _mount(tester, _FakeVoice(), (r) async => _json({}),
        withAppliance: false);

    expect(find.text('사용할 가전을 먼저 추가해 주세요'), findsOneWidget);
    expect(find.byKey(_fieldKey), findsNothing);
  });

  testWidgets('듣는 중에 글자를 보내면 듣기를 멈추고 적은 말만 남긴다', (tester) async {
    final voice = _FakeVoice();
    final container = await _mount(tester, voice, (r) async => _json({}));
    await tester.tap(find.byIcon(Icons.mic_rounded));
    await tester.pump();
    expect(container.read(voiceListeningProvider), isTrue);

    await _type(tester, '즉석밥 데워줘');
    await tester.tap(find.byKey(_sendKey));
    await tester.pump();
    await tester.pump();

    expect(voice.stops, 1);
    expect(container.read(voiceListeningProvider), isFalse);
    expect(container.read(voiceTextProvider), '즉석밥 데워줘');
    expect(find.text('이대로 할까요?'), findsOneWidget);
  });

  testWidgets('키보드가 올라와도 입력칸이 키보드 위에 있다', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    addTearDown(tester.view.reset);
    await _mount(tester, _FakeVoice(), (r) async => _json({}));

    expect(tester.takeException(), isNull);
    expect(tester.getRect(find.byKey(_fieldKey)).bottom, lessThan(360));
    expect(tester.getRect(find.byKey(_sendKey)).bottom, lessThan(360));
  });

  for (final pending in [false, true]) {
    testWidgets('좁은 폰·큰 글씨·키보드에서 넘치지 않는다 (확인 대기 $pending)',
        (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 240);
      addTearDown(tester.view.reset);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      final container =
          await _mount(tester, _FakeVoice(), (r) async => _json({}));
      if (pending) {
        container.read(voiceTextProvider.notifier).state = '즉석밥 데워줘' * 8;
        await tester.pump();
      }
      await _type(tester, '길게 적은 말 ' * 12);
      await tester.pump(const Duration(milliseconds: 300));

      expect(tester.takeException(), isNull);
      expect(tester.getRect(find.byKey(_sendKey)).bottom, lessThan(328));
    });
  }

  testWidgets('입력칸과 보내기 단추에 접근성 이름이 있다', (tester) async {
    final handle = tester.ensureSemantics();
    await _mount(tester, _FakeVoice(), (r) async => _json({}));

    expect(find.byTooltip('보내기'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('글자로 말하기')), findsWidgets);
    handle.dispose();
  });
}
