// 홈 타일의 판정이 **지금의 것**인가(외부 검토 2026-10-13, M3·M1).
// 연결·서버 상태가 바뀐 뒤 예전 조회 결과를 계속 보이지 않는지 실제 홈 배선으로 본다.
import 'dart:convert';

import 'package:flutter/material.dart';
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

const _estopReason = '비상정지가 걸려 있어요';

/// 응답을 시험 도중 바꿀 수 있는 가짜 허브.
class _Server {
  http.Response verify = _json({'state': 'done', 'execution_mode': 'real'});
  int verifyCalls = 0;
  Duration verifyDelay = Duration.zero;

  /// `/status.estop_latched` — 로컬 갠트리 걸림.
  bool estop = false;

  /// 서버 구성 모의 실행기 가전(걸림과 무관하게 실행 가능)을 목록에 넣는다.
  bool withMock = false;
  Duration appliancesDelay = Duration.zero;

  RpiApiService api() => RpiApiService(
        'http://rpi5.local:8000',
        client: MockClient((req) async {
          final path = req.url.path;
          if (path.startsWith('/execute') || path.endsWith('/approve')) {
            fail('홈이 실행 경로를 불렀어요: ${req.method} $path');
          }
          if (req.method == 'GET' && path == '/status') {
            return _json({
              'running': false,
              'estop_latched': estop,
              if (estop) 'estop_detail': _estopReason,
            });
          }
          if (req.method == 'GET' && path == '/appliances') {
            // 서버 판정(readiness_view)을 흉내 낸다: 걸림은 로컬 대상(a)만 막는다.
            final blocked = estop;
            final reply = _json([
              {
                'id': 'a',
                'name': '전자레인지',
                'category': 'microwave',
                'rows': 1,
                'cols': 1,
                'is_custom': true,
                'revision': 1,
                'can_execute': !blocked,
                'readiness': blocked ? 'needs_setup' : 'operable',
                'readiness_reasons': blocked ? [_estopReason] : <String>[],
                'buttons': [
                  {'id': 'a-1', 'label': '시작', 'x': 0, 'y': 0},
                ],
                'panel_mapping': {
                  'photo': {'width': 100, 'height': 100},
                },
              },
              if (withMock)
                {
                  'id': 'm',
                  'name': '모의 세탁기',
                  'category': 'washer',
                  'rows': 1,
                  'cols': 1,
                  'is_custom': false,
                  'revision': 1,
                  'can_execute': true,
                  'readiness': 'operable',
                  'readiness_reasons': <String>[],
                  'buttons': [
                    {'id': 'm-1', 'label': '시작', 'x': 0, 'y': 0},
                  ],
                },
            ]);
            if (appliancesDelay > Duration.zero) {
              await Future<void>.delayed(appliancesDelay);
            }
            return reply;
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

Finder _inTile(String text, [String id = 'a']) => find.descendant(
    // 타일 상태 줄은 낱말 중간 줄바꿈을 막는 결합 문자(U+2060)를 넣어 그린다(2026-10-14) — 빼고 비교한다.
    of: find.byKey(Key('appliance-card-$id')),
    matching: find.byWidgetPredicate(
        (w) => w is Text && (w.data ?? '').replaceAll('\u2060', '') == text));

/// 타일 상태 줄이 **무언가를 말하는가**. 평소(실행 가능)에는 할 일 '준비됐어요'만 적는다(평가 3차 10/18 —
/// 그 전에는 줄이 없었다). 그 말이면 긍정 상태로 보고 찾지 않는다 — 없으면 긍정, 있으면 무언가를 말한다.
Finder _statusLine([String id = 'a']) => find.descendant(
    of: find.byKey(Key('appliance-status-$id')),
    matching: find.byWidgetPredicate(
        (w) => w is Text && (w.data ?? '').replaceAll('⁠', '') != '준비됐어요'));

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
  expect(_inTile('본체 연결을 봐 주세요'), findsOneWidget);
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
      expect(_statusLine(), findsNothing);
      expect(find.byType(ApplianceSetupCard), findsNothing, reason: '실제 완료면 설정 카드 없음');
      for (final t in ['아직 시험 이동을 안 했어요', '시험 이동을 했는지 몰라요']) {
        expect(_inTile(t), findsNothing);
      }

      server.verify = _json({'detail': '확인 주행 기록이 없어요'}, 404);
      await _reconnect(tester, conn);

      expect(_inTile('아직 시험 이동을 안 했어요'), findsOneWidget,
          reason: '예전 done/real로 보조 줄을 계속 숨기지 않는다');
      expect(find.byType(ApplianceSetupCard), findsOneWidget);
    });

    testWidgets('첫 조회 오류 → 재연결 → 성공이면 "확인하지 못했어요"를 지운다', (tester) async {
      final server = _Server()..verify = _json({'detail': 'boom'}, 500);
      final conn = await _pumpHome(tester, server);
      expect(_inTile('시험 이동을 했는지 몰라요'), findsOneWidget);

      server.verify = _json({'state': 'done', 'execution_mode': 'real'});
      await _reconnect(tester, conn);

      expect(_inTile('시험 이동을 했는지 몰라요'), findsNothing);
      expect(find.byType(ApplianceSetupCard), findsNothing);
    });

    testWidgets('다시 묻는 동안(응답 전)에는 예전 결과 대신 모름', (tester) async {
      final server = _Server();
      final conn = await _pumpHome(tester, server);
      expect(_inTile('시험 이동을 했는지 몰라요'), findsNothing);
      final before = server.verifyCalls;

      server.verifyDelay = const Duration(seconds: 2);
      conn.set(RpiConnectionState.unreachable);
      await _settle(tester);
      conn.set(RpiConnectionState.connected);
      // 목록은 왔지만 확인 주행 응답은 아직 — 예전 done/real(보조 줄 없음)을 쓰지 않는다.
      await _settle(tester);
      expect(server.verifyCalls, greaterThan(before), reason: '재연결 뒤 다시 물었다');
      expect(_inTile('시험 이동을 했는지 몰라요'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      await _settle(tester);
      expect(_inTile('시험 이동을 했는지 몰라요'), findsNothing);
    });
  });

  group('M1 — 연결을 유지한 채 걸림이 바뀌면 준비 판정을 다시 받는다', () {
    testWidgets('실행 가능 → 비상정지 걸림 → 타일이 예전 긍정을 버리고 서버 사유로, 풀리면 다시',
        (tester) async {
      final server = _Server()..withMock = true;
      await _pumpHome(tester, server);
      expect(_statusLine(), findsNothing);
      expect(_statusLine('m'), findsNothing);

      // 허브 연결은 그대로, 로컬 갠트리만 걸린다. 목록 응답은 늦게 온다.
      server
        ..estop = true
        ..appliancesDelay = const Duration(seconds: 2);
      await tester.pump(const Duration(seconds: 5)); // 걸림 조회 주기
      await _settle(tester);
      // 다시 받는 동안 예전 긍정(빈 상태 줄)을 쓰지 않는다 — 타일이 없거나, 있으면 무언가를 말한다.
      expect(
          find.byKey(const Key('appliance-card-a')).evaluate().isEmpty ||
              _statusLine().evaluate().isNotEmpty,
          isTrue,
          reason: '다시 받는 동안 예전 긍정을 쓰지 않는다');
      await tester.pump(const Duration(seconds: 3));
      await _settle(tester);
      expect(_inTile('준비가 필요해요'), findsOneWidget);
      expect(_inTile(_estopReason), findsOneWidget, reason: '서버가 준 사유 그대로');
      expect(_statusLine(), findsOneWidget);
      // 걸림의 범위는 서버가 정한다 — 모의 실행기 가전까지 폰이 일괄로 막지 않는다.
      expect(_statusLine('m'), findsNothing);

      server
        ..estop = false
        ..appliancesDelay = Duration.zero;
      await tester.pump(const Duration(seconds: 5));
      await _settle(tester);
      expect(_statusLine(), findsNothing);
      expect(_inTile('준비가 필요해요'), findsNothing);
    });
  });
}
