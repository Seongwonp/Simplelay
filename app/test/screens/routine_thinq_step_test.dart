// 루틴에 'ThinQ 가전 조작' 단계 넣기 (2026-10-15).
//
// - '단계 추가'에 ThinQ 가전이 한 대라도 있을 때만 'ThinQ 가전 조작'이 보인다.
// - 가전 → 무엇을·어떤 값으로를 고르면 서버 `thinq_command` 모양의 단계가 생긴다
//   (`appliance_id` · `action` · `args`). 고르기만 하고 보내지 않는다 — 저장도 루틴 저장
//   (POST /routines)뿐이고 실행 경로(/execute·/thinq/command·/approve)는 부르지 않는다.
// - 편집기는 동작 이름(set_wind_strength)이 아니라 사람 말로 적는다.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/appliance.dart';
import 'package:simplelay/models/routine.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/routine_editor_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';
import 'package:simplelay/widgets/thinq_state_card.dart';

import '../helpers/test_helpers.dart';

const _purifier = ApplianceMap(
  id: 'air_purifier',
  name: '공기청정기',
  category: ApplianceCategory.other,
  rows: 0,
  cols: 0,
  buttons: [],
  controlPath: 'thinq',
  readiness: 'operable',
  readinessKnown: true,
);

/// 언제는 이미 정한 새 초안 — 저장이 POST /routines로 간다.
const _draft = Routine(
  name: '아침 공기',
  steps: [],
  trigger: RoutineTrigger(kind: RoutineTriggerKind.time, days: [0], time: '07:30'),
);

class _Hub {
  final requests = <String>[];
  Map<String, dynamic>? saved;

  http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
      utf8.encode(jsonEncode(body)), status,
      headers: {'content-type': 'application/json'});

  RpiApiService api() => RpiApiService(
        'http://rpi5.local:8000',
        client: MockClient((req) async {
          final path = req.url.path;
          requests.add('${req.method} $path');
          if (req.method == 'POST' && path == '/routines') {
            saved = jsonDecode(utf8.decode(req.bodyBytes)) as Map<String, dynamic>;
            return _json({...saved!, 'id': 'rt-9', 'when': '월 07:30'}, 201);
          }
          return _json({'detail': 'not found'}, 404);
        }),
      );
}

Widget _host(_Hub hub, List<ApplianceMap> installed) => buildWithProviderState(
      overrides: [
        ...connectedOverrides(),
        ...installedOverrides(installed),
        rpiApiServiceProvider.overrideWithValue(hub.api()),
      ],
      child: MaterialApp(
        theme: ThemeData.dark(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => const RoutineEditorScreen(initial: _draft))),
                child: const Text('편집기 열기'),
              ),
            ),
          ),
        ),
      ),
    );

Future<void> _open(WidgetTester tester, _Hub hub, List<ApplianceMap> installed) async {
  tester.view.physicalSize = const Size(600, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_host(hub, installed));
  await tester.pumpAndSettle();
  await tester.tap(find.text('편집기 열기'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets("ThinQ 가전이 있으면 '풍량 강풍'을 골라 thinq_command 단계로 저장한다",
      (tester) async {
    final hub = _Hub();
    await _open(tester, hub, [kTestAppliance, _purifier]);

    await tester.tap(find.byKey(const Key('routine-add-step')));
    await tester.pumpAndSettle();
    expect(find.text('ThinQ 가전 조작'), findsOneWidget);
    expect(find.text('공기청정기 전원·풍량·운전 모드를 바꿔요'), findsOneWidget);
    await tester.tap(find.byKey(const Key('routine-add-thinq')));
    await tester.pumpAndSettle();

    // ThinQ 가전이 한 대면 가전 고르기를 건너뛰고 바로 무엇을 바꿀지 묻는다.
    expect(find.text('공기청정기에서 무엇을 바꿀까요?'), findsOneWidget);
    for (final phrase in [
      '전원 켜기', '전원 끄기',
      '풍량 약풍으로 바꾸기', '풍량 중풍으로 바꾸기', '풍량 강풍으로 바꾸기', '풍량 자동으로 바꾸기',
      '운전 모드 청정으로 바꾸기', '운전 모드 수면으로 바꾸기', '운전 모드 자동으로 바꾸기',
    ]) {
      expect(find.text(phrase), findsOneWidget, reason: phrase);
    }
    await tester.tap(find.byKey(const Key('routine-thinq-set_wind_strength-HIGH')));
    await tester.pumpAndSettle();

    // 편집기 문장: [공기청정기] 풍량 강풍으로 바꾸기 — 동작 이름은 보이지 않는다.
    expect(find.text('공기청정기'), findsOneWidget);
    expect(find.text('풍량 강풍으로 바꾸기'), findsOneWidget);
    expect(find.textContaining('set_wind_strength'), findsNothing);
    expect(find.textContaining('ThinQ 명령'), findsNothing);
    // 고르기만 했다 — 아무것도 보내지 않았다.
    expect(hub.requests.where((r) => r.startsWith('POST')), isEmpty);

    await tester.tap(find.byKey(const Key('routine-save')));
    await tester.pumpAndSettle();
    expect(hub.saved?['steps'], [
      {
        'kind': 'thinq_command',
        'appliance_id': 'air_purifier',
        'action': 'set_wind_strength',
        'args': {'wind_strength': 'HIGH'},
      },
    ]);
    // 저장만 했다 — 실행 경로는 부르지 않는다.
    expect(hub.requests.where((r) => r.startsWith('POST')), ['POST /routines']);
  });

  testWidgets('ThinQ 가전이 여러 대면 먼저 가전을 고르고, 고른 가전 ID로 단계를 만든다',
      (tester) async {
    final hub = _Hub();
    const other = ApplianceMap(
      id: 'bedroom_purifier',
      name: '공기청정기',
      location: '안방',
      category: ApplianceCategory.other,
      rows: 0,
      cols: 0,
      buttons: [],
      controlPath: 'thinq',
    );
    await _open(tester, hub, [kTestAppliance, _purifier, other]);

    await tester.tap(find.byKey(const Key('routine-add-step')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('routine-add-thinq')));
    await tester.pumpAndSettle();
    // 버튼 가전(전자레인지)은 고를 수 없다.
    expect(find.text(kTestAppliance.displayName), findsNothing);
    await tester.tap(find.text('안방 공기청정기'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('routine-thinq-set_power-POWER_ON')));
    await tester.pumpAndSettle();
    expect(find.text('전원 켜기'), findsOneWidget);

    await tester.tap(find.byKey(const Key('routine-save')));
    await tester.pumpAndSettle();
    expect(hub.saved?['steps'], [
      {
        'kind': 'thinq_command',
        'appliance_id': 'bedroom_purifier',
        'action': 'set_power',
        'args': {'power': 'POWER_ON'},
      },
    ]);
  });

  testWidgets("ThinQ 가전이 없으면 'ThinQ 가전 조작'을 내걸지 않는다", (tester) async {
    await _open(tester, _Hub(), [kTestAppliance]);
    await tester.tap(find.byKey(const Key('routine-add-step')));
    await tester.pumpAndSettle();
    expect(find.text('버튼 누르기'), findsOneWidget);
    expect(find.text('ThinQ 가전 조작'), findsNothing);
    expect(find.byKey(const Key('routine-add-thinq')), findsNothing);
  });

  testWidgets('저장된 ThinQ 단계도 사람 말로 보인다(동작 이름을 내지 않는다)', (tester) async {
    tester.view.physicalSize = const Size(600, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const routine = Routine(
      id: 'rt-1',
      name: '저녁 공기',
      steps: [
        RoutineStep.thinq('air_purifier', 'set_job_mode', {'job_mode': 'SLEEP'}),
        RoutineStep.thinq('air_purifier', 'set_power', {'power': 'POWER_OFF'}),
      ],
    );
    await tester.pumpWidget(buildScreen(const RoutineEditorScreen(initial: routine),
        overrides: installedOverrides([_purifier])));
    await tester.pumpAndSettle();
    expect(find.text('운전 모드 수면으로 바꾸기'), findsOneWidget);
    expect(find.text('전원 끄기'), findsOneWidget);
    expect(find.textContaining('set_'), findsNothing);
  });

  test('ThinQ 단계 문장 — 표에 있는 값·없는 값·모르는 동작', () {
    expect(thinqStepPhrase('set_power', {'power': 'POWER_ON'}), '전원 켜기');
    expect(thinqStepPhrase('set_power', {'power': 'POWER_OFF'}), '전원 끄기');
    expect(thinqStepPhrase('set_wind_strength', {'wind_strength': 'LOW'}),
        '풍량 약풍으로 바꾸기');
    expect(thinqStepPhrase('set_wind_strength', {'wind_strength': 'MID'}),
        '풍량 중풍으로 바꾸기');
    expect(thinqStepPhrase('set_wind_strength', {'wind_strength': 'AUTO'}),
        '풍량 자동으로 바꾸기');
    expect(thinqStepPhrase('set_job_mode', {'job_mode': 'CLEAN'}),
        '운전 모드 청정으로 바꾸기');
    expect(thinqStepPhrase('set_job_mode', {'job_mode': 'AUTO'}),
        '운전 모드 자동으로 바꾸기');
    // 고르는 표에는 없지만 상태 표에 있는 값은 그 말로.
    // 받침 없는 말은 '로'.
    expect(thinqStepPhrase('set_wind_strength', {'wind_strength': 'POWER'}),
        '풍량 파워로 바꾸기');
    expect(thinqStepPhrase('set_job_mode', {'job_mode': 'SILENT'}),
        '운전 모드 조용으로 바꾸기');
    // 아무 표에도 없는 값은 지어내지 않고 그대로.
    expect(thinqStepPhrase('set_job_mode', {'job_mode': 'TURBO'}),
        '운전 모드 TURBO(으)로 바꾸기');
    // 모르는 동작은 동작 이름을 내지 않는다.
    final unknown = thinqStepPhrase('set_operation', {'operation': 'START'});
    expect(unknown, isNot(contains('set_operation')));
    expect(unknown, contains('ThinQ'));
  });

  test('공기청정기 조작 표는 지금 값 없이도 고를 수 있고, 상태 카드와 같은 표다', () {
    expect([
      for (final c in kAirPurifierControls)
        (c.action, c.arg, [for (final (v, _) in c.choices) v].join(','), c.current),
    ], [
      ('set_power', 'power', 'POWER_ON,POWER_OFF', null),
      ('set_wind_strength', 'wind_strength', 'LOW,MID,HIGH,AUTO', null),
      ('set_job_mode', 'job_mode', 'CLEAN,SLEEP,AUTO', null),
    ]);
    final fromState = thinqControlsFor({
      'operation': {'airPurifierOperationMode': 'POWER_ON'},
      'airFlow': {'windStrength': 'LOW'},
      'airPurifierJobMode': {'currentJobMode': 'SLEEP'},
    });
    expect([for (final c in fromState) (c.action, c.current)], [
      ('set_power', 'POWER_ON'),
      ('set_wind_strength', 'LOW'),
      ('set_job_mode', 'SLEEP'),
    ]);
  });

  test('ThinQ 단계 JSON 왕복 — 서버 thinq_command 모양 그대로', () {
    const step = RoutineStep.thinq(
        'air_purifier', 'set_wind_strength', {'wind_strength': 'HIGH'});
    final json = step.toJson();
    expect(json, {
      'kind': 'thinq_command',
      'appliance_id': 'air_purifier',
      'action': 'set_wind_strength',
      'args': {'wind_strength': 'HIGH'},
    });
    final back = RoutineStep.fromJson(
        jsonDecode(jsonEncode(json)) as Map<String, dynamic>)!;
    expect(back.kind, RoutineStepKind.thinqCommand);
    expect(back.applianceId, 'air_purifier');
    expect(back.action, 'set_wind_strength');
    expect(back.args, {'wind_strength': 'HIGH'});
    expect(back.toJson(), json);

    final routine = const Routine(name: '아침 공기', steps: [step]);
    expect(routine.toRequestJson()['steps'], [json]);
    expect(routine.operatesAppliance, isTrue);
  });
}
