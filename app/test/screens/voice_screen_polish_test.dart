import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/main.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/providers/voice_provider.dart';
import 'package:simplelay/screens/voice_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';
import 'package:simplelay/services/voice_service.dart';
import 'package:simplelay/theme/app_theme.dart';
import '../helpers/test_helpers.dart';

// 실기기 점검(10/26) 뒤 음성 화면 다듬기: 탭 이동·생각 중 한 가지 상태·나란한 확인 버튼·홈에서 열면 가전에 묶지 않음.

class _FakeVoice extends VoiceService {
  bool listening = false;
  int cancels = 0;
  @override
  bool get isListening => listening;
  @override
  Future<bool> initialize() async => true;
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
    onText('듣는 중 문장');
  }

  @override
  Future<void> stop() async => listening = false;
  @override
  Future<void> cancel() async {
    cancels++;
    listening = false;
  }
}

http.Response _json(Object body, [int code = 200]) =>
    http.Response(jsonEncode(body), code,
        headers: {'content-type': 'application/json; charset=utf-8'});

const _proposal = {
  'understood': true,
  'source': 'llm',
  'label': '공기청정기를 켜요',
  'question': '서버가 만든 질문 그대로인가요?',
  'action': {
    'kind': 'thinq',
    'appliance_id': 'air',
    'action': 'power',
    'args': {'power': 'ON'}
  },
};

Finder _tab(String label) => find.descendant(
    of: find.byKey(const Key('task-navigation')), matching: find.text(label));

Future<(GoRouter, _FakeVoice)> _mountApp(WidgetTester tester,
    {List<Override> extra = const []}) async {
  SharedPreferences.setMockInitialValues({});
  final voice = _FakeVoice();
  final router = buildAppRouter(initialLocation: '/voice');
  addTearDown(router.dispose);
  await tester.pumpWidget(buildWithProviderState(
    overrides: [
      ...disconnectedOverrides(),
      ...installedOverrides([kTestAppliance]),
      voiceServiceProvider.overrideWithValue(voice),
      ...extra,
    ],
    child: MaterialApp.router(theme: AppTheme.light, routerConfig: router),
  ));
  await tester.pumpAndSettle();
  return (router, voice);
}

Future<ProviderContainer> _mountFallback(WidgetTester tester,
    Future<http.Response> Function(http.Request) handler) async {
  SharedPreferences.setMockInitialValues({});
  final api = RpiApiService('http://hub',
      apiKey: 'test-key', client: MockClient(handler));
  final container = ProviderContainer(overrides: [
    ...installedOverrides([kTestAppliance]),
    rpiApiServiceProvider.overrideWithValue(api),
  ]);
  addTearDown(container.dispose);
  final router = GoRouter(routes: [
    GoRoute(path: '/', builder: (_, __) => const VoiceScreen()),
    GoRoute(
        path: '/status',
        builder: (_, __) => const Scaffold(body: Text('tracked-job'))),
  ]);
  addTearDown(router.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(
      container: container, child: MaterialApp.router(routerConfig: router)));
  container.read(voiceTextProvider.notifier).state = '공기가 텁텁하네';
  await tester.pump();
  await tester.ensureVisible(find.text('이대로 하기'));
  await tester.tap(find.text('이대로 하기'));
  await tester.pump();
  return container;
}

void main() {
  for (final (label, path) in [
    ('가전', '/appliances'),
    ('자동 실행', '/automation'),
    ('기록', '/history'),
    ('홈', '/'),
  ]) {
    testWidgets('말로 하기에서 $label 탭을 누르면 듣기를 멈추고 그 탭으로 간다', (tester) async {
      final (router, voice) = await _mountApp(tester);
      expect(router.routeInformationProvider.value.uri.path, '/voice');
      await tester.tap(find.bySemanticsLabel('말하기 시작'));
      await tester.pumpAndSettle();
      expect(voice.listening, isTrue);
      await tester.tap(_tab(label));
      await tester.pumpAndSettle();
      expect(router.routeInformationProvider.value.uri.path, path);
      expect(voice.listening, isFalse);
    });
  }

  testWidgets('홈에서 연 말로 하기는 가전에 묶지 않고 중립 머리말, 본체에 가전 번호 없이 보낸다',
      (tester) async {
    http.Request? sent;
    final api = RpiApiService('http://hub',
        apiKey: 'test-key',
        client: MockClient((r) async {
          if (r.url.path == '/execute') {
            sent = r;
            return _json({'job_id': 'j1'});
          }
          return _json({'running': false});
        }));
    await _mountApp(tester,
        extra: [rpiApiServiceProvider.overrideWithValue(api)]);
    expect(find.text('${kTestAppliance.displayName}에게'), findsNothing);
    expect(find.byKey(const Key('voice-neutral-target')), findsOneWidget);
    final scope =
        ProviderScope.containerOf(tester.element(find.byType(VoiceScreen)));
    scope.read(voiceTextProvider.notifier).state = '공기청정기 켜 줘';
    await tester.pump();
    await tester.ensureVisible(find.text('이대로 하기'));
    await tester.tap(find.text('이대로 하기'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(sent, isNotNull);
    final body = jsonDecode(sent!.body) as Map<String, dynamic>;
    expect(body.containsKey('appliance_id'), isFalse);
    expect(body['purpose'] ?? body['text'], '공기청정기 켜 줘');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('생각 중에는 가운데 한 상태만: 원·문구·인식 문장·취소 하나', (tester) async {
    final reply = Completer<http.Response>();
    await _mountFallback(tester, (r) async {
      if (r.url.path == '/execute') return _json({'detail': '모름'}, 422);
      if (r.url.path == '/intent/understand') return reply.future;
      return _json({});
    });
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('생각하고 있어요…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('공기가 텁텁하네'), findsOneWidget);
    expect(find.text('취소'), findsOneWidget);
    expect(find.text('이대로 할까요?'), findsNothing);
    expect(find.text('보내는 중…'), findsNothing);
    expect(find.text('이대로 하기'), findsNothing);
    expect(find.text('다시 말하기'), findsNothing);
    reply.complete(_json({'understood': false, 'source': 'off'}));
    await tester.pumpAndSettle();
  });

  testWidgets('확인 창: 아니요(왼쪽 테두리)·네(오른쪽 채움) 같은 높이, 서버 질문 그대로', (tester) async {
    await _mountFallback(tester, (r) async {
      if (r.url.path == '/execute') return _json({'detail': '모름'}, 422);
      if (r.url.path == '/intent/understand') return _json(_proposal);
      return _json({});
    });
    await tester.pumpAndSettle();
    expect(find.text('서버가 만든 질문 그대로인가요?'), findsOneWidget);
    final no = find.widgetWithText(OutlinedButton, '아니요');
    final yes = find.widgetWithText(FilledButton, '네');
    expect(no, findsOneWidget);
    expect(yes, findsOneWidget);
    final noRect = tester.getRect(no);
    final yesRect = tester.getRect(yes);
    expect(noRect.right, lessThan(yesRect.left));
    expect(noRect.top, yesRect.top);
    expect(noRect.height, yesRect.height);
    expect(noRect.width, yesRect.width);
    expect(find.bySemanticsLabel('네. 공기청정기를 켜요'), findsOneWidget);
    await tester.tap(no);
    await tester.pumpAndSettle();
  });
}
