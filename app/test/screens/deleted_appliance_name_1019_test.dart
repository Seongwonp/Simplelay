// 결선 모의 평가(2026-10-19, 폰): 본체에서 지운 가전을 가리키는 루틴이 'washer · 누를 버튼 3개'처럼
// 내부 ID를 그대로 보였다. 루틴 목록·홈·루틴 편집·'끝나면' 조건 어디서도 ID를 내지 않는다 —
// 가전 이름, 없으면 '지운 가전'(버튼 ID도 '버튼 N개').
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/appliance.dart';
import 'package:simplelay/models/routine.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/home_screen.dart';
import 'package:simplelay/screens/routine_editor_screen.dart';
import 'package:simplelay/screens/routines_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';

import '../helpers/test_helpers.dart';

final _mw = ApplianceMap.fromJson({
  'id': 'mw',
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
    {'id': 'mw-1', 'label': '시작', 'x': 0, 'y': 0},
  ],
  'panel_mapping': {
    'photo': {'width': 100, 'height': 100},
  },
});

const _washRoutine = Routine(
  id: 'r-wash',
  name: '빨래 시작',
  steps: [RoutineStep.press('washer', ['power', 'course', 'start'])],
  trigger: RoutineTrigger.manual(),
);

final _rawRoutines = [
  {
    'id': 'r-wash',
    'name': '빨래 시작',
    'steps': [
      {'kind': 'press_sequence', 'appliance_id': 'washer', 'buttons': ['power', 'course', 'start']},
    ],
    'trigger': {'kind': 'manual'},
    'when': '직접 실행할 때',
    'mode': 'approve',
    'enabled': true,
  },
];

http.Response _json(Object body) => http.Response.bytes(utf8.encode(jsonEncode(body)), 200,
    headers: {'content-type': 'application/json'});

RpiApiService _api() => RpiApiService(
      'http://rpi5.local:8000',
      client: MockClient((req) async {
        final path = req.url.path;
        if (path == '/appliances') return _json([_mw.toJson()]);
        if (path == '/routines') return _json(_rawRoutines);
        if (path == '/routines/next' || path == '/routines/auto-rules') return _json(const []);
        if (path == '/history' || path == '/suggestions') return _json(const []);
        return http.Response('{"detail":"not found"}', 404);
      }),
    );

Future<void> _pump(WidgetTester tester, Widget screen) async {
  tester.view.physicalSize = const Size(390, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final router = GoRouter(routes: [GoRoute(path: '/', builder: (_, __) => screen)]);
  await tester.pumpWidget(buildWithProviderState(
    overrides: [
      ...connectedOverrides(),
      ...installedOverrides([_mw]),
      rpiServerOverride(RpiConnectionState.connected),
      rpiApiServiceProvider.overrideWithValue(_api()),
    ],
    child: MaterialApp.router(routerConfig: router),
  ));
  for (var i = 0; i < 16; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void _expectNoIds() {
  for (final id in ['washer', 'power', 'course', 'start']) {
    expect(findPlainText(id, contains: true), findsNothing, reason: id);
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test("목록 줄·부제는 지운 가전을 '지운 가전'으로", () {
    const names = {'mw': '전자레인지'};
    expect(routineListLine(_washRoutine, names), '지운 가전 · 누를 버튼 3개');
    expect(routineSubtitle(_washRoutine, names), '지운 가전 · 누를 버튼 3개');
    const thinq = Routine(
      name: '저녁',
      steps: [RoutineStep.thinq('air', 'set_power', {'power': 'POWER_ON'})],
      trigger: RoutineTrigger.manual(),
    );
    expect(routineListLine(thinq, names), '지운 가전 켜기');
  });

  test("'끝나면' 조건도 ID를 내지 않는다", () {
    expect(const RoutineTrigger(kind: RoutineTriggerKind.afterDone, applianceId: 'washer').describe(applianceNames: const {}),
        '지운 가전 동작이 끝나면');
    expect(const RoutineTrigger(kind: RoutineTriggerKind.afterDone, routineId: 'r-gone').describe(), '앞 루틴이 끝나면');
  });

  testWidgets('루틴 목록에 내부 ID가 보이지 않는다', (tester) async {
    await _pump(tester, const RoutinesScreen());
    expect(findPlainText('빨래 시작'), findsOneWidget);
    expect(findPlainText('지운 가전', contains: true), findsOneWidget);
    _expectNoIds();
  });

  testWidgets('홈 루틴 칸에 내부 ID가 보이지 않는다', (tester) async {
    await _pump(tester, const HomeScreen());
    expect(findPlainText('빨래 시작', contains: true), findsWidgets);
    _expectNoIds();
  });

  testWidgets("루틴 편집은 '지운 가전'에서 '버튼 3개'", (tester) async {
    await _pump(tester, const RoutineEditorScreen(initial: _washRoutine));
    expect(findPlainText('지운 가전'), findsOneWidget);
    expect(findPlainText('버튼 3개'), findsOneWidget);
    _expectNoIds();
  });
}
