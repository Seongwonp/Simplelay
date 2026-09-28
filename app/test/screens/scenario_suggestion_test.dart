// 시나리오 카드(2026-09-30): 서버가 고정한 명령(대상·경로·동작)·근거·준비 상태를
// 보여 주고, 승인 재검사 실패(409)면 실행하지 않고 다시 확인하게 한다.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/suggestion_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';

import '../helpers/test_helpers.dart';

const _card = {
  'id': 'sug-1',
  'purpose': '저녁 휴식 — 공기청정기를 켜고 선풍기를 약풍으로 켤까요?',
  'time_band': '시나리오',
  'occurrences': 0,
  'steps': <String>[],
  'reason': '시연: 합성 이력 — 실제 사용 기록이 아니에요',
  'appliance_id': 'air_purifier',
  'is_demo': true,
  'scenario_id': 'evening_rest',
  'commands': [
    {
      'target_id': 'air_purifier',
      'route': 'thinq',
      'action': 'set_power',
      'args': {'power': 'POWER_ON'},
      'buttons': <String>[],
      'summary': '공기청정기 전원 켜기',
    },
    {
      'target_id': 'fan',
      'route': 'physical',
      'action': null,
      'args': <String, dynamic>{},
      'buttons': ['전원', '약풍'],
      'summary': '선풍기 전원 → 약풍',
    },
  ],
};

class _Server {
  _Server({this.purifierReady = true, this.approveDetail = _mismatch});

  static const _mismatch = '승인한 내용과 지금 실행할 내용이 달라졌어요 — '
      '다시 확인하고 승인해 주세요 (승인한 명령과 실행할 명령의 지문이 달라요)';

  final bool purifierReady;
  final String approveDetail;
  int approveCalls = 0;
  bool retired = false;

  http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
        utf8.encode(jsonEncode(body)),
        status,
        headers: {'content-type': 'application/json'},
      );

  RpiApiService api() => RpiApiService(
        'http://rpi5.local:8000',
        client: MockClient((req) async {
          final path = req.url.path;
          if (path == '/suggestions') return _json(retired ? [] : [_card]);
          if (path == '/scenarios') {
            return _json([
              {'scenario_id': 'evening_rest', 'name': '저녁 휴식'},
            ]);
          }
          if (path == '/readiness/air_purifier') {
            return _json({
              'appliance_id': 'air_purifier',
              'route': 'thinq',
              'state': purifierReady ? 'operable' : 'disconnected',
              'can_execute': purifierReady,
              'reasons': purifierReady ? [] : ['가전이 오프라인이에요'],
            });
          }
          if (path == '/readiness/fan') {
            return _json({
              'appliance_id': 'fan',
              'route': 'physical',
              'state': 'disconnected',
              'can_execute': true,
              'reasons': [],
            });
          }
          if (path == '/suggestions/sug-1/approve') {
            approveCalls++;
            // 승인 오류면 서버가 카드를 내린다(_fail_approval retire).
            retired = approveDetail.contains('승인');
            return _json({'detail': approveDetail}, 409);
          }
          return _json({'detail': 'not found'}, 404);
        }),
      );
}

Widget _build(_Server server) {
  final router = GoRouter(
    initialLocation: '/suggestion/sug-1',
    routes: [
      GoRoute(path: '/', builder: (_, __) => const Scaffold(body: Text('홈'))),
      GoRoute(
        path: '/suggestion/:id',
        builder: (context, state) =>
            SuggestionScreen(sequenceId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/status',
        builder: (_, __) => const Scaffold(body: Text('상태 화면')),
      ),
    ],
  );
  return buildWithProviderState(
    overrides: [
      ...connectedOverrides(),
      rpiApiServiceProvider.overrideWithValue(server.api()),
    ],
    child: MaterialApp.router(theme: ThemeData.dark(), routerConfig: router),
  );
}

void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(900, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('시나리오 이름·근거·고정 명령(가전·경로·동작)을 보여 준다', (tester) async {
    _tall(tester);
    await tester.pumpWidget(_build(_Server()));
    await _settle(tester);

    expect(find.text('시나리오 · 저녁 휴식'), findsOneWidget);
    expect(find.textContaining('근거: 시연'), findsOneWidget);
    expect(find.text('공기청정기 전원 켜기'), findsOneWidget);
    expect(find.text('선풍기 전원 → 약풍'), findsOneWidget);
    expect(find.text('ThinQ'), findsOneWidget);
    expect(find.text('물리 버튼'), findsOneWidget);
    // ThinQ 가전은 폰 가전 목록에 없어도 '대상을 찾지 못함'이 아니다.
    expect(find.text('대상 가전 정보를 확인해 주세요.'), findsNothing);
    final run = tester.widget<FilledButton>(
        find.ancestor(of: find.text('지금 실행'), matching: find.byWidgetPredicate((w) => w is FilledButton)));
    expect(run.onPressed, isNotNull);
  });

  testWidgets('409(승인 내용 변경)면 실행하지 않고 다시 확인하라고 한 뒤 카드를 새로 받는다',
      (tester) async {
    _tall(tester);
    final server = _Server();
    await tester.pumpWidget(_build(server));
    await _settle(tester);

    await tester.tap(find.text('지금 실행'));
    await _settle(tester);

    expect(server.approveCalls, 1);
    expect(find.text('제안 내용이 바뀌어 다시 확인이 필요해요'), findsOneWidget);
    expect(find.text('상태 화면'), findsNothing);
    // 서버가 내린 카드는 목록에서도 사라졌다(재조회).
    expect(find.text('제안을 찾을 수 없어요.'), findsOneWidget);
  });

  testWidgets('다른 작업 실행 중(409, 승인 문장 아님)은 종전 안내', (tester) async {
    _tall(tester);
    final server =
        _Server(approveDetail: 'an execution is already in progress');
    await tester.pumpWidget(_build(server));
    await _settle(tester);

    await tester.tap(find.text('지금 실행'));
    await _settle(tester);

    expect(find.textContaining('다른 작업이 실행 중이에요'), findsOneWidget);
    expect(find.text('제안 내용이 바뀌어 다시 확인이 필요해요'), findsNothing);
  });

  testWidgets('ThinQ 대상이 준비 안 됐으면 실행을 막고 이유(412 사유)를 말한다',
      (tester) async {
    _tall(tester);
    await tester.pumpWidget(_build(_Server(purifierReady: false)));
    await _settle(tester);

    expect(find.textContaining('가전이 오프라인이에요'), findsWidgets);
    final run = tester.widget<FilledButton>(
        find.ancestor(of: find.text('지금 실행'), matching: find.byWidgetPredicate((w) => w is FilledButton)));
    expect(run.onPressed, isNull);
  });
}
