// 개발자 도구 화면 (Phase 2, 모의 제어 전용).
//
// 못 박는 것: 모의 배너가 항상 보인다 · 세션 중 heartbeat를 비밀값과 함께
// 보낸다 · 화면을 떠나거나 앱이 숨겨지면 세션을 끝내고 heartbeat를 멈춘다 ·
// 정지 미확인을 완료처럼 말하지 않는다 · 세션 만료를 알리고 명령을 잠근다 ·
// 모의가 아닌 서버는 조작하지 않는다 · 토큰이 없으면 토큰 입력만 있다.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/providers/dev_api_provider.dart';
import 'package:simplelay/screens/developer_console_screen.dart';
import 'package:simplelay/services/dev_api_service.dart';

import '../helpers/test_helpers.dart';

class _FakeDevServer {
  String phase = 'idle';
  bool mock = true;
  bool stopConfirmed = true;
  bool expired = false;
  final requests = <http.Request>[];

  Map<String, dynamic> _state(String phase, {bool session = false}) => {
        'phase': phase,
        'mock': mock,
        'shutting_down': false,
        'session': session
            ? {
                'session_id': 's1',
                'appliance_id': kTestAppliance.id,
                'node_id': 'phone-console',
                'started_at': '2026-09-24T10:00:00Z',
                'expires_at': '2026-09-24T10:00:02Z',
              }
            : null,
        'fault_reason':
            phase == 'fault' ? 'stop_unconfirmed:emergency_stop' : null,
        'heartbeat_ttl_s': 2.0,
        'max_jog_mm': 5.0,
        'max_command_len': 64,
        'allowed_commands': ['status'],
      };

  http.Response _json(Object body, [int status = 200]) => http.Response(
        jsonEncode(body),
        status,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );

  late final client = MockClient((request) async {
    requests.add(request);
    switch (request.url.path) {
      case '/dev/state':
        return _json(_state(phase, session: phase == 'active'));
      case '/dev/sessions':
        phase = 'active';
        return _json({
          'session_id': 's1',
          'session_secret': 'sec-123',
          'state': _state('active', session: true),
        }, 201);
      case '/dev/sessions/s1/heartbeat':
        if (expired) {
          phase = 'idle';
          return _json({
            'detail': {'code': 'session_expired', 'message': '끝남'},
          }, 410);
        }
        return _json(_state('active', session: true));
      case '/dev/sessions/s1/commands':
        return _json({
          'accepted': true,
          'request_id': 'r',
          'normalized': 'home',
          'sensor': null,
          'state': _state('active', session: true),
        });
      case '/dev/sessions/s1/end':
        phase = 'idle';
        return _json({'confirmed': true, 'message': '', 'state': _state('idle')});
      case '/dev/stop':
        phase = stopConfirmed ? 'idle' : 'fault';
        return _json({
          'confirmed': stopConfirmed,
          'message': '',
          'state': _state(phase),
        });
      case '/dev/log':
        return _json([]);
    }
    return _json({
      'detail': {'code': 'not_found', 'message': '?'},
    }, 404);
  });

  int count(String path) => requests.where((r) => r.url.path == path).length;
}

Widget _build(_FakeDevServer server, {bool withToken = true}) => buildScreen(
      const DeveloperConsoleScreen(),
      overrides: [
        ...installedOverrides([kTestAppliance]),
        devTokenProvider.overrideWith(
          (ref) => DevTokenNotifier.seeded(withToken ? 'dev-tok' : null),
        ),
        devApiServiceProvider.overrideWithValue(
          withToken
              ? DevApiService('http://rpi.test:8000',
                  devToken: 'dev-tok', client: server.client)
              : null,
        ),
      ],
    );

void _tallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(420, 3200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _open(WidgetTester tester, _FakeDevServer server,
    {bool withToken = true}) async {
  _tallViewport(tester);
  await tester.pumpWidget(_build(server, withToken: withToken));
  await tester.pump(); // 첫 프레임 뒤 상태 조회
  await tester.pump();
}

Future<void> _startSession(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(FilledButton, '세션 시작'));
  await tester.pump();
  await tester.pump();
}

/// 화면을 내리고 남은 비동기를 흘려보낸다 -- heartbeat 타이머가 테스트 밖에
/// 남아 있으면 flutter_test가 실패로 잡는다.
Future<void> _close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('모의 제어 배너와 서버 상태를 보여준다', (tester) async {
    final server = _FakeDevServer();
    await _open(tester, server);

    expect(find.text('모의 제어 — 실제로 움직이지 않음'), findsOneWidget);
    expect(find.text('대기 — 세션 없음'), findsOneWidget);
    await _close(tester);
  });

  testWidgets('세션 중에는 heartbeat를 비밀값과 함께 보낸다', (tester) async {
    final server = _FakeDevServer();
    await _open(tester, server);
    await _startSession(tester);
    expect(find.text('세션 진행 중'), findsOneWidget);

    await tester.pump(const Duration(seconds: 2));

    final beats = server.requests
        .where((r) => r.url.path == '/dev/sessions/s1/heartbeat')
        .toList();
    expect(beats.length, greaterThanOrEqualTo(2));
    for (final beat in beats) {
      expect(beat.headers['X-Dev-Session-Secret'], 'sec-123');
      expect(beat.headers['X-Dev-Token'], 'dev-tok');
    }
    await _close(tester);
  });

  testWidgets('화면을 떠나면 세션을 끝내고 heartbeat를 멈춘다', (tester) async {
    final server = _FakeDevServer();
    await _open(tester, server);
    await _startSession(tester);

    await _close(tester);
    final beatsAtClose = server.count('/dev/sessions/s1/heartbeat');
    await tester.pump(const Duration(seconds: 3));

    expect(server.count('/dev/sessions/s1/end'), 1);
    expect(server.count('/dev/sessions/s1/heartbeat'), beatsAtClose);
  });

  testWidgets('앱이 화면에서 사라지면 세션을 끝내고 heartbeat를 멈춘다', (tester) async {
    final server = _FakeDevServer();
    await _open(tester, server);
    await _startSession(tester);
    addTearDown(() => tester.binding
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(server.count('/dev/sessions/s1/end'), 0); // 알림창 정도로는 안 끊는다

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    await tester.pump();

    expect(server.count('/dev/sessions/s1/end'), 1);
    expect(find.text('앱이 화면에서 사라져 세션을 끝냈어요'), findsOneWidget);
    final beats = server.count('/dev/sessions/s1/heartbeat');
    await tester.pump(const Duration(seconds: 3));
    expect(server.count('/dev/sessions/s1/heartbeat'), beats);
    await _close(tester);
  });

  testWidgets('정지를 확인하지 못하면 완료처럼 말하지 않고 잠김을 보여준다', (tester) async {
    final server = _FakeDevServer()..stopConfirmed = false;
    await _open(tester, server);
    await _startSession(tester);

    await tester.tap(find.widgetWithText(FilledButton, '정지'));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('정지를 확인하지 못했어요'), findsOneWidget);
    expect(find.text('정지를 확인했어요'), findsNothing);
    expect(find.text('정지 미확인 — 기기 잠김'), findsOneWidget);
    final start = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '세션 시작'));
    expect(start.onPressed, isNull);
    await _close(tester);
  });

  testWidgets('정지가 확인되면 그렇게 말한다', (tester) async {
    final server = _FakeDevServer();
    await _open(tester, server);

    await tester.tap(find.widgetWithText(FilledButton, '정지'));
    await tester.pump();
    await tester.pump();

    expect(server.count('/dev/stop'), 1); // 세션이 없어도 정지는 나간다
    expect(find.text('정지를 확인했어요'), findsOneWidget);
    await _close(tester);
  });

  testWidgets('heartbeat가 세션 만료로 거절되면 알리고 명령을 잠근다', (tester) async {
    final server = _FakeDevServer();
    await _open(tester, server);
    await _startSession(tester);

    server.expired = true;
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();

    expect(find.textContaining('세션이 끝났어요'), findsOneWidget);
    final home =
        tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '홈'));
    expect(home.onPressed, isNull);
    await _close(tester);
  });

  testWidgets('명령은 세션의 대상 가전과 request_id를 싣는다', (tester) async {
    final server = _FakeDevServer();
    await _open(tester, server);
    await _startSession(tester);

    await tester.tap(find.widgetWithText(OutlinedButton, '홈'));
    await tester.pump();
    await tester.pump();

    final sent = server.requests
        .lastWhere((r) => r.url.path == '/dev/sessions/s1/commands');
    final body = jsonDecode(sent.body) as Map<String, dynamic>;
    expect(body['appliance_id'], kTestAppliance.id);
    expect(body['text'], 'home');
    expect(body['request_id'], matches(RegExp(r'^[A-Za-z0-9_-]{1,32}$')));
    expect(find.textContaining('모의 어댑터가 받았어요'), findsOneWidget);
    await _close(tester);
  });

  testWidgets('모의가 아닌 서버면 조작을 잠근다', (tester) async {
    final server = _FakeDevServer()..mock = false;
    await _open(tester, server);

    expect(find.text('모의 제어 서버가 아니에요'), findsOneWidget);
    final start = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '세션 시작'));
    expect(start.onPressed, isNull);
    await _close(tester);
  });

  testWidgets('개발자 토큰이 없으면 토큰 입력만 보인다', (tester) async {
    final server = _FakeDevServer();
    await _open(tester, server, withToken: false);
    await tester.pump();

    expect(find.text('모의 제어 — 실제로 움직이지 않음'), findsOneWidget);
    expect(find.text('개발자 토큰'), findsOneWidget);
    expect(find.text('세션 시작'), findsNothing);
    expect(server.requests, isEmpty);
    await _close(tester);
  });
}
