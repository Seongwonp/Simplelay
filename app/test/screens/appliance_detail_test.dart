// 가전 상세(사진 패널)와 루틴 녹화(2026-09-30).
//
// 사진 속 버튼을 눌러도 곧바로 누르지 않는다 -- 확인을 한 번 거친 뒤에만
// /execute-buttons로 간다. 녹화는 아무것도 보내지 않고 순서만 돌려준다.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/appliance.dart';
import 'package:simplelay/models/display_status.dart' show kGantryAbsentReason, purposeActionName;
import 'package:simplelay/models/hub.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/providers/server_appliance_provider.dart';
import 'package:simplelay/screens/appliance_detail_screen.dart';
import 'package:simplelay/screens/routine_record_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';

import '../helpers/test_helpers.dart';

/// 사진 매핑이 있는 전자레인지. 좌표는 형식 예시다(실물 값 아님).
final _mapped = ApplianceMap(
  id: 'custom_1',
  name: '전자레인지',
  location: '주방',
  category: ApplianceCategory.microwave,
  rows: 1,
  cols: 3,
  buttons: const [
    ApplianceButton(id: 'B01', label: '해동', x: 0, y: 0),
    ApplianceButton(id: 'B02', label: '시작', x: 1, y: 0),
    ApplianceButton(id: 'B03', label: '취소', x: 2, y: 0),
  ],
  isCustom: true,
  stopButton: 'B03',
  panelMapping: const PanelMapping(
    photoWidth: 1000,
    photoHeight: 800,
    buttons: {
      'B01': PhotoPoint(200, 400),
      'B02': PhotoPoint(500, 400),
      'B03': PhotoPoint(800, 400),
    },
    parkPoint: PhotoPoint(950, 750),
  ),
);

class _Server {
  final requests = <String>[];
  Map<String, dynamic>? executeBody;
  int historyStatus = 200;
  List<Object> history = const [];
  Completer<http.Response>? pendingHistory;

  http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
        utf8.encode(jsonEncode(body)),
        status,
        headers: {'content-type': 'application/json'},
      );

  RpiApiService api() => RpiApiService(
        'http://rpi5.local:8000',
        client: MockClient((req) async {
          requests.add('${req.method} ${req.url.path}');
          if (req.url.path == '/execute-buttons') {
            executeBody = jsonDecode(utf8.decode(req.bodyBytes)) as Map<String, dynamic>;
            return _json({'job_id': 'job-1'});
          }
          if (req.url.path == '/routines') return _json(<dynamic>[]);
          if (req.url.path == '/history') {
            if (pendingHistory != null) return pendingHistory!.future;
            return _json(historyStatus == 200 ? history : {'detail': 'unavailable'}, historyStatus);
          }
          return _json({'detail': 'not found'}, 404);
        }),
      );
}

Widget _build(_Server server, {String initial = '/detail', ServerApplianceCatalog? catalog}) {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (_, __) => const Scaffold(body: Text('홈')),
        routes: [
          GoRoute(
            path: 'detail',
            builder: (_, __) => const ApplianceDetailScreen(applianceId: 'custom_1'),
          ),
          GoRoute(
            path: 'record',
            builder: (_, __) => const RoutineRecordScreen(applianceId: 'custom_1'),
          ),
        ],
      ),
      GoRoute(path: '/status', builder: (_, __) => const Scaffold(body: Text('상태 화면'))),
    ],
  );
  router.push(initial);
  return buildWithProviderState(
    overrides: [
      ...connectedOverrides(),
      ...installedOverrides([_mapped]),
      rpiApiServiceProvider.overrideWithValue(server.api()),
      if (catalog != null)
        serverApplianceCatalogProvider
            .overrideWith((ref) => ServerApplianceNotifier.seeded(ref, catalog)),
    ],
    child: MaterialApp.router(theme: ThemeData.dark(), routerConfig: router),
  );
}

/// 본체 목록 한 항목(준비 판정 포함).
ApplianceMap _hubItem(String id, String name,
        {required bool custom, String readiness = 'operable', List<String> reasons = const []}) =>
    ApplianceMap.fromJson({
      'id': id,
      'name': name,
      'rows': 1,
      'cols': 1,
      'buttons': const [],
      'is_custom': custom,
      'can_execute': readiness == 'operable',
      'readiness': readiness,
      'readiness_reasons': reasons,
    });

void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(500, 1800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('촬영 전 기록 표시', () {
    testWidgets('조회 중에는 실제 미사용으로 단정하지 않는다', (tester) async {
      final server = _Server()..pendingHistory = Completer<http.Response>();
      _tall(tester);
      await tester.pumpWidget(_build(server));
      await _settle(tester);
      expect(find.text('기록을 불러오고 있어요'), findsOneWidget);
      expect(find.text('오늘은 아직 사용하지 않았어요'), findsNothing);
      server.pendingHistory!.complete(server._json(<dynamic>[]));
      await _settle(tester);
      expect(find.text('오늘 SimpleLay에 남은 기록이 없어요'), findsOneWidget);
    });

    testWidgets('조회 실패 뒤 새로 보기는 기록 조회만 다시 하고 실행하지 않는다', (tester) async {
      final server = _Server()..historyStatus = 503;
      _tall(tester);
      await tester.pumpWidget(_build(server));
      await _settle(tester);
      expect(find.text('기록을 불러오지 못했어요'), findsOneWidget);
      expect(find.text('오늘은 아직 사용하지 않았어요'), findsNothing);
      server.historyStatus = 200;
      await tester.ensureVisible(find.byKey(const Key('today-history-retry')));
      await tester.tap(find.byKey(const Key('today-history-retry')));
      await _settle(tester);
      expect(find.text('오늘 SimpleLay에 남은 기록이 없어요'), findsOneWidget);
      expect(server.requests.where((s) => s == 'GET /history').length, 2);
      expect(server.executeBody, isNull);
    });
  });

  // 첫 사용 평가(10/24): 오늘 사용 줄이 제안의 질문을 그대로 적었다 — '공기청정기 바람을 세게 할까요?, 완료'.
  // 기록은 한 일의 이름으로 적는다(홈 알림 줄·기록 탭과 같은 [purposeActionName]).
  testWidgets('오늘 사용 줄은 제안의 질문이 아니라 한 일의 이름으로 적는다', (tester) async {
    const at = '2026-09-09T08:30:00'; // 테스트 시계(2026-09-09 09:00)의 오늘
    final server = _Server()
      ..history = [
        {
          'job_id': 'j-air',
          'finished_at': at,
          'status': 'succeeded',
          'outcome': 'success',
          'retry_count': 0,
          'buttons': const [],
          'execution_mode': 'real',
          'route': 'thinq',
          'receipt': 'accepted',
          'confirmation': 'state_confirmed',
          'termination': 'unknown',
          'purpose': '공기청정기 바람을 세게 할까요?',
          'detail': '',
          'abort_reason': null,
          'appliance_id': 'custom_1',
        },
      ];
    _tall(tester);
    await tester.pumpWidget(_build(server));
    await _settle(tester);
    expect(find.textContaining('할까요?'), findsNothing);
    expect(find.textContaining('${purposeActionName('공기청정기 바람을 세게 할까요?')}, 완료'), findsOneWidget);
  });

  testWidgets('사진 위에 버튼·정지(빨강)·쉬는 자리를 그리고, 누르기는 확인 뒤에만 보낸다',
      (tester) async {
    final server = _Server();
    _tall(tester);
    await tester.pumpWidget(_build(server));
    await _settle(tester);

    expect(find.bySemanticsLabel('해동'), findsOneWidget);
    expect(find.bySemanticsLabel('정지 버튼 취소'), findsOneWidget);
    expect(find.bySemanticsLabel('기다리는 자리'), findsOneWidget);

    // 누르면 먼저 묻는다 -- 취소하면 아무것도 보내지 않는다.
    await tester.tap(find.byKey(const Key('mark-B02')));
    await _settle(tester);
    expect(find.text("'시작' 버튼을 누를까요?"), findsOneWidget);
    await tester.tap(find.text('취소').last);
    await _settle(tester);
    expect(server.executeBody, isNull);

    await tester.tap(find.byKey(const Key('mark-B02')));
    await _settle(tester);
    await tester.tap(find.text('누르기'));
    await _settle(tester);
    expect(server.executeBody, {
      'buttons': ['시작'],
      'appliance_id': 'custom_1',
      'client_request_id': matches(RegExp(r'^[A-Za-z0-9_-]{1,64}$')), // 요청 번호(검토 10/19)
    });
    expect(find.text('상태 화면'), findsOneWidget);
  });

  testWidgets('루틴 녹화는 짚은 순서만 쌓고 아무것도 보내지 않는다', (tester) async {
    final server = _Server();
    _tall(tester);
    await tester.pumpWidget(_build(server, initial: '/record'));
    await _settle(tester);

    await tester.tap(find.byKey(const Key('mark-B01')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('mark-B02')));
    await tester.pump();
    expect(find.byKey(const Key('order-0')), findsOneWidget);
    expect(find.byKey(const Key('order-1')), findsOneWidget);
    // 사진 위 번호 핀(읽기 전용)도 순서대로 찍힌다.
    expect(find.byKey(const Key('mark-pin-1')), findsOneWidget);

    await tester.tap(find.text('하나 지우기'));
    await tester.pump();
    expect(find.byKey(const Key('order-1')), findsNothing);

    expect(server.requests.where((r) => r.contains('/execute')), isEmpty);
  });

  // 검토 10/19: 폰에서 추가한 가전은 본체가 누를 장치가 없다고 판정해도 이 폰 저장분에 판정이 없어 '누를까요?'를
  // 물은 뒤에야 거절됐다. 본체 목록의 판정으로 미리 말하고, 누르기 전에 막는다.
  testWidgets('본체가 누를 장치가 없다고 하면 상세 맨 위에 쉬운 말과 할 일을 보이고, 누르기를 묻지 않는다', (tester) async {
    final server = _Server();
    _tall(tester);
    await tester.pumpWidget(_build(server,
        catalog: ServerApplianceCatalog(
          status: ServerCatalogStatus.loaded,
          appliances: [
            _hubItem('microwave', '전자레인지', custom: false),
            _hubItem('induction', '인덕션',
                custom: false, readiness: 'needs_setup', reasons: const [kGantryAbsentReason]),
          ],
          customAppliances: [_hubItem('custom_1', '전자레인지', custom: true, readiness: 'disconnected')],
        )));
    await _settle(tester);

    const notice = '이 가전에는 아직 누름 장치가 연결되지 않아 지금은 누를 수 없어요. '
        '설치하는 분께 이 가전의 누름 장치 연결을 부탁해 주세요.';
    expect(find.text(notice), findsOneWidget);

    await tester.tap(find.byKey(const Key('mark-B02')));
    await _settle(tester);
    expect(find.text("'시작' 버튼을 누를까요?"), findsNothing);
    expect(find.text(notice), findsNWidgets(2), reason: '누르면 같은 말을 한 번 더(알림 줄)');
    expect(server.executeBody, isNull);
  });

  // 첫 사용 평가(10/24): 누름 장치(RPi4)가 끊겨 본체가 실행을 거절하는데 버튼판은 눌리는 판과 똑같이 보였다 —
  // 눌러 본 뒤에야 알림 줄로 알았다. 화면 자체에 이유 한 줄을 두고, 판은 흐리게·낭독은 '지금은 쓸 수 없어요'.
  testWidgets('누름 장치 연결이 끊기면 버튼판을 흐리게 하고 이유를 화면에 적는다', (tester) async {
    const reason = '누름 장치와 연결되지 않았어요. 누름 장치 전원과 연결을 확인해 주세요.';
    final server = _Server();
    _tall(tester);
    await tester.pumpWidget(_build(server,
        catalog: ServerApplianceCatalog(
          status: ServerCatalogStatus.loaded,
          customAppliances: [
            _hubItem('custom_1', '전자레인지', custom: true, readiness: 'disconnected', reasons: const [reason]),
          ],
        )));
    await _settle(tester);

    expect(find.text(reason), findsOneWidget, reason: '누르기 전에 화면에서 이유를 본다');
    final dim = tester.widget<Opacity>(
        find.ancestor(of: find.byKey(const Key('mark-B02')), matching: find.byType(Opacity)).first);
    expect(dim.opacity, lessThan(1), reason: '눌리는 판처럼 보이지 않게');
    expect(find.bySemanticsLabel(RegExp(r'^시작.*지금은 쓸 수 없어요')), findsOneWidget);

    await tester.tap(find.byKey(const Key('mark-B02')), warnIfMissed: false);
    await _settle(tester);
    expect(find.text("'시작' 버튼을 누를까요?"), findsNothing);
    expect(server.executeBody, isNull);
  });

  testWidgets('본체가 실행할 수 있다고 하면 안내 없이 종전대로 묻는다', (tester) async {
    final server = _Server();
    _tall(tester);
    await tester.pumpWidget(_build(server,
        catalog: ServerApplianceCatalog(
          status: ServerCatalogStatus.loaded,
          customAppliances: [_hubItem('custom_1', '전자레인지', custom: true)],
        )));
    await _settle(tester);
    expect(find.textContaining('누름 장치가 연결되지 않아'), findsNothing);
    await tester.tap(find.byKey(const Key('mark-B02')));
    await _settle(tester);
    expect(find.text("'시작' 버튼을 누를까요?"), findsOneWidget);
  });
}
