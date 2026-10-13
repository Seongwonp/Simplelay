// 홈 타일의 판정이 **지금의 것**인가(외부 검토 2026-10-13, M3·M1).
// 연결·서버 상태가 바뀐 뒤 예전 조회 결과를 계속 보이지 않는지 실제 홈 배선으로 본다.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/home_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';
import 'package:simplelay/widgets/appliance_setup_card.dart';

import '../helpers/test_helpers.dart';

/// 테스트가 연결 상태를 바꿀 수 있는 연결 provider.
class _Conn extends RpiConnectionNotifier {
  _Conn(super.ref, RpiConnectionState initial) {
    state = initial;
  }

  @override
  Future<void> check() async {}

  void set(RpiConnectionState next) => state = next;
}

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      status,
      headers: {'content-type': 'application/json'},
    );

/// 응답을 시험 도중 바꿀 수 있는 가짜 허브.
class _Server {
  http.Response verify = _json({'state': 'done', 'execution_mode': 'real'});
  int verifyCalls = 0;
  Duration verifyDelay = Duration.zero;

  RpiApiService api() => RpiApiService(
        'http://rpi5.local:8000',
        client: MockClient((req) async {
          final path = req.url.path;
          if (path.startsWith('/execute') || path.endsWith('/approve')) {
            fail('홈이 실행 경로를 불렀어요: ${req.method} $path');
          }
          if (req.method == 'GET' && path == '/appliances') {
            return _json([
              {
                'id': 'a',
                'name': '전자레인지',
                'category': 'microwave',
                'rows': 1,
                'cols': 1,
                'is_custom': true,
                'revision': 1,
                'can_execute': true,
                'readiness': 'operable',
                'readiness_reasons': <String>[],
                'buttons': [
                  {'id': 'a-1', 'label': '시작', 'x': 0, 'y': 0},
                ],
                'panel_mapping': {
                  'photo': {'width': 100, 'height': 100},
                },
              },
            ]);
          }
          if (req.method == 'GET' && path == '/routines') return _json(const []);
          if (path == '/suggestions') return _json(const []);
          if (req.method == 'GET' && path.endsWith('/verify-pass')) {
            verifyCalls++;
            final reply = verify;
            if (verifyDelay > Duration.zero) await Future<void>.delayed(verifyDelay);
            return reply;
          }
          return _json({'detail': 'not found'}, 404);
        }),
      );
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 16; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Finder _inTile(String text) => find.descendant(
    of: find.byKey(const Key('appliance-card-a')), matching: find.text(text));

Future<_Conn> _pumpHome(WidgetTester tester, _Server server) async {
  tester.view.physicalSize = const Size(400, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  late _Conn conn;
  await tester.pumpWidget(buildWithProviderState(
    overrides: [
      ...connectedOverrides(),
      ...installedOverrides(const []),
      rpiConnectionProvider.overrideWith(
          (ref) => conn = _Conn(ref, RpiConnectionState.connected)),
      rpiApiServiceProvider.overrideWithValue(server.api()),
    ],
    // 이 노트북 Flutter의 잉크 셰이더 판 불일치를 피한다(동작과 무관).
    child: MaterialApp(
      theme: ThemeData.dark().copyWith(splashFactory: InkRipple.splashFactory),
      home: const HomeScreen(),
    ),
  ));
  await _settle(tester);
  return conn;
}

/// 끊겼다가 다시 붙는다(서버 재시작을 폰이 본 경우).
Future<void> _reconnect(WidgetTester tester, _Conn conn) async {
  conn.set(RpiConnectionState.unreachable);
  await _settle(tester);
  expect(_inTile('연결을 확인해 주세요'), findsOneWidget);
  conn.set(RpiConnectionState.connected);
  await _settle(tester);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('M3 — 재연결 뒤 확인 주행을 다시 묻는다', () {
    testWidgets('실제 완료 → 서버 재시작(기록 사라짐) → 재연결 뒤 "기록이 없어요"',
        (tester) async {
      final server = _Server();
      final conn = await _pumpHome(tester, server);
      expect(_inTile('실행을 요청할 수 있어요'), findsOneWidget);
      expect(find.byType(ApplianceSetupCard), findsNothing, reason: '실제 완료면 설정 카드 없음');
      for (final t in ['확인 주행 기록이 없어요', '확인 주행 여부를 확인하지 못했어요']) {
        expect(_inTile(t), findsNothing);
      }

      server.verify = _json({'detail': '확인 주행 기록이 없어요'}, 404);
      await _reconnect(tester, conn);

      expect(_inTile('확인 주행 기록이 없어요'), findsOneWidget,
          reason: '예전 done/real로 보조 줄을 계속 숨기지 않는다');
      expect(find.byType(ApplianceSetupCard), findsOneWidget);
    });

    testWidgets('첫 조회 오류 → 재연결 → 성공이면 "확인하지 못했어요"를 지운다', (tester) async {
      final server = _Server()..verify = _json({'detail': 'boom'}, 500);
      final conn = await _pumpHome(tester, server);
      expect(_inTile('확인 주행 여부를 확인하지 못했어요'), findsOneWidget);

      server.verify = _json({'state': 'done', 'execution_mode': 'real'});
      await _reconnect(tester, conn);

      expect(_inTile('확인 주행 여부를 확인하지 못했어요'), findsNothing);
      expect(find.byType(ApplianceSetupCard), findsNothing);
    });

    testWidgets('다시 묻는 동안(응답 전)에는 예전 결과 대신 모름', (tester) async {
      final server = _Server();
      final conn = await _pumpHome(tester, server);
      expect(_inTile('확인 주행 여부를 확인하지 못했어요'), findsNothing);
      final before = server.verifyCalls;

      server.verifyDelay = const Duration(seconds: 2);
      conn.set(RpiConnectionState.unreachable);
      await _settle(tester);
      conn.set(RpiConnectionState.connected);
      // 목록은 왔지만 확인 주행 응답은 아직 — 예전 done/real(보조 줄 없음)을 쓰지 않는다.
      await _settle(tester);
      expect(server.verifyCalls, greaterThan(before), reason: '재연결 뒤 다시 물었다');
      expect(_inTile('확인 주행 여부를 확인하지 못했어요'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      await _settle(tester);
      expect(_inTile('확인 주행 여부를 확인하지 못했어요'), findsNothing);
    });
  });
}
