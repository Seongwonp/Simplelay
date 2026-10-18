// 연습용 LG 세탁기(2026-10-18, 사용자 요청) — 실제 공기청정기 옆에 서버가 세우는 모의 세탁기.
//
// - 세탁기 상태를 사람 말 줄로(폰과 같은 칸·말), 조작은 '빨래 시작·잠시 멈춤'(set_operation).
// - 서버가 그 가전 상태를 execution_mode mock으로 주면 상세에 연습 표시가 보인다.
// 전부 모의(가짜 읽기·보내기)다 — 실가전 검증이 아니다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/models/thinq.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/manual_view.dart';

const _washer = <String, dynamic>{
  'runState': {'currentState': 'RUNNING'},
  'remoteControlEnable': {'remoteControlEnabled': true},
  'timer': {'remainHour': 0, 'remainMinute': 45},
};

final _practiceWasher = applianceFromServerJson({
  'id': 'thinq_washer',
  'name': 'LG 세탁기(연습)',
  'category': 'washing_machine',
  'rows': 0,
  'cols': 0,
  'buttons': <dynamic>[],
  'control_path': 'thinq',
  'can_execute': true,
  'readiness': 'operable',
});

void main() {
  test('세탁기 상태 줄과 조작(폰과 같은 말)', () {
    expect(thinqStateRows(_washer).map((r) => (r.label, r.value)).toList(), [
      ('빨래', '빨래하는 중'),
      ('남은 시간', '45분'),
      // 2차 독립 평가 F(10/18): 이어 읽으면 '휴대폰으로 시작할 수 있어요'.
      ('휴대폰으로', '시작할 수 있어요'),
    ]);
    final control = thinqControlsFor(_washer).single;
    expect(control.action, 'set_operation');
    expect(control.current, 'START');
    expect(control.choices, [('START', '시작'), ('STOP', '잠시 멈춤')]);
    expect(control.question('LG 세탁기', 'START', '시작'), 'LG 세탁기 빨래를 시작할까요?');
    expect(control.question('LG 세탁기', 'STOP', '잠시 멈춤'), 'LG 세탁기 빨래를 잠시 멈출까요?');
    expect(control.doneLabel('LG 세탁기', '시작'), 'LG 세탁기 빨래 시작');
    expect(thinqControlsFor({'runState': {'currentState': 'PAUSE'}}).single.current, 'STOP');
  });

  test('세탁기 그림은 세탁기 종류에서 나온다', () {
    expect(_practiceWasher.icon, Icons.local_laundry_service);
    expect(_practiceWasher.name, contains('연습'));
  });

  test('타일 이름은 연습 표기를 빼고(배지가 말한다), 실제 가전 이름은 그대로', () {
    expect(_practiceWasher.isPractice, isTrue);
    expect(_practiceWasher.tileName, 'LG 세탁기');
    final real = applianceFromServerJson({
      'id': 'air_purifier',
      'name': '공기청정기',
      'category': 'air_purifier',
      'rows': 0,
      'cols': 0,
      'buttons': <dynamic>[],
      'control_path': 'thinq',
    });
    expect(real.isPractice, isFalse);
    expect(real.tileName, '공기청정기');
    // 모의 모드 이름('(모의)')은 종전 그대로 — 타일 배지는 'LG 가전'.
    final mock = applianceFromServerJson({
      'id': 'air_purifier',
      'name': '공기청정기(모의)',
      'category': 'air_purifier',
      'rows': 0,
      'cols': 0,
      'buttons': <dynamic>[],
      'control_path': 'thinq',
    });
    expect(mock.isPractice, isFalse);
    expect(mock.tileName, '공기청정기(모의)');
  });

  testWidgets('상세: 연습 세탁기 — 연습 표시·빨래 줄·시작 단추, 확인 뒤 set_operation을 보낸다', (tester) async {
    tester.view.physicalSize = const Size(800, 480);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final sent = <(String, Map<String, Object>)>[];
    final accepted = <(String, String)>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: KioskManualView(
          appliance: _practiceWasher,
          onExecute: (_) => fail('ThinQ 가전에는 누를 버튼판이 없다'),
          onCancel: () {},
          thinqRead: () async => KioskThinqStatus(
              executionMode: 'mock', readAt: DateTime(2026, 10, 18, 9, 7), state: _washer),
          thinqSend: (action, args) {
            sent.add((action, args));
            return Future.value(const KioskJobAccepted(jobId: 'job-9'));
          },
          onThinqAccepted: (jobId, label) => accepted.add((jobId, label)),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('thinq-practice')), findsOneWidget);
    expect(find.text('빨래하는 중'), findsOneWidget);
    expect(find.text('45분'), findsOneWidget);
    expect(find.byKey(const ValueKey('thinq-controls-phone')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('thinq-set-set_operation-STOP')));
    await tester.pump();
    expect(find.text('LG 세탁기(연습) 빨래를 잠시 멈출까요?'), findsOneWidget);
    expect(sent, isEmpty);
    await tester.tap(find.byKey(const ValueKey('thinq-confirm-ok')));
    await tester.pump();
    await tester.pump();
    expect(sent.single.$1, 'set_operation');
    expect(sent.single.$2, {'operation': 'STOP'});
    expect(accepted.single.$1, 'job-9');
    expect(tester.takeException(), isNull);
  });
}
