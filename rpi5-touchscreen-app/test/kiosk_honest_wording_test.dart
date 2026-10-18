// 화면이 실제 확인 수준보다 앞서 말하지 않는다(심사위원 시각 평가 10/18 §3-5 — 정직성 예외).
//
// 확인 수준별 결과 문구 표(작은 팔 실행 성공):
// | 실행 환경 | 근거                                  | 제목                     |
// |-----------|---------------------------------------|--------------------------|
// | real      | 전력 변화(L3, 출처 real)               | '<가전 이름>이/가 켜졌어요' |
// | real      | 전력 판정이 연습 값(출처 mock)          | '버튼은 다 눌렀어요'       |
// | real      | 작은 팔 보고(reported)·L1(press_confirmed) | '버튼은 다 눌렀어요'   |
// | real      | 확인 근거 없음(none)                   | '눌렸는지 몰라요'          |
// | mock      | (무엇이든)                            | '연습을 마쳤어요'          |
// | 모름      | (무엇이든)                            | '버튼은 다 눌렀어요'       |
// '켜졌어요'는 L3 실측(출처 real)일 때만 나온다 — 누름 확인(L1)·엔코더·작은 팔 보고로는 가전이 켜졌다고 말하지 않는다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/models/command_result.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/appliance_strip.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/done_view.dart';

Future<void> _pump(WidgetTester tester, Widget view) async {
  tester.view.physicalSize = const Size(800, 480);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: view)));
}

ApplianceMap _appliance(String id, String name, {String readiness = 'unknown', bool canExecute = true}) => ApplianceMap(
      id: id,
      name: name,
      category: 'microwave',
      rows: 1,
      cols: 1,
      buttons: const [],
      readiness: readiness,
      canExecute: canExecute,
    );

void main() {
  group('작은 팔 성공 제목은 확인 수준만큼', () {
    final cases = <(String, String, String?, bool?, String?, String)>[
      // (설명, 실행 환경, 확인 수준, 전력 판정, 판정 출처, 기대 제목)
      ('L3 실측', 'real', 'operation_confirmed', true, 'real', '전자레인지가 켜졌어요'),
      ('L3 연습 값', 'real', 'reported', true, 'mock', '버튼은 다 눌렀어요'),
      ('작은 팔 보고만', 'real', 'reported', null, null, '버튼은 다 눌렀어요'),
      ('누름 센서(L1)', 'real', 'press_confirmed', null, null, '버튼은 다 눌렀어요'),
      ('근거 없음', 'real', 'none', null, null, '눌렸는지 몰라요'),
      ('연습', 'mock', 'operation_confirmed', true, 'real', '연습을 마쳤어요'),
      ('실행 환경 모름', 'unknown', 'reported', true, 'real', '버튼은 다 눌렀어요'),
    ];
    for (final (what, mode, confirmation, op, source, headline) in cases) {
      testWidgets('$what → $headline', (tester) async {
        await _pump(
          tester,
          KioskDoneView(
            success: true,
            label: '즉석밥 데워줘',
            target: kMicrowaveAppliance,
            executionMode: mode,
            resultConfirmation: confirmation,
            operationConfirmed: op,
            operationSource: source,
            onDismiss: () {},
          ),
        );
        expect(find.text(headline), findsOneWidget);
        if (headline != '전자레인지가 켜졌어요') {
          // L3 실측이 아니면 어디에도 가전이 켜졌다고 쓰지 않는다.
          expect(find.textContaining('켜졌어요'), findsNothing);
        }
      });
    }

    testWidgets('가전 이름을 모르면 가전이 켜졌어요', (tester) async {
      await _pump(
        tester,
        KioskDoneView(
          success: true,
          label: '즉석밥 데워줘',
          executionMode: 'real',
          resultConfirmation: 'operation_confirmed',
          operationConfirmed: true,
          operationSource: 'real',
          onDismiss: () {},
        ),
      );
      expect(find.text('가전이 켜졌어요'), findsOneWidget);
    });

    testWidgets('받침 있는 이름은 이(밥솥이 켜졌어요)', (tester) async {
      await _pump(
        tester,
        KioskDoneView(
          success: true,
          label: '밥 짓기',
          target: _appliance('rice', '밥솥'),
          executionMode: 'real',
          resultConfirmation: 'operation_confirmed',
          operationConfirmed: true,
          operationSource: 'real',
          onDismiss: () {},
        ),
      );
      expect(find.text('밥솥이 켜졌어요'), findsOneWidget);
    });
  });

  group('확인 근거 칩·음성 문장도 같은 표', () {
    test('전력 변화(L3)는 전기를 쓰기 시작했다까지 — 폰과 같은 말', () {
      expect(confirmationLabel(confirmation: 'operation_confirmed', executionMode: 'real'),
          '가전이 전기를 쓰기 시작했어요');
      expect(confirmationLabel(confirmation: 'press_confirmed', executionMode: 'real'), '버튼을 눌렀어요');
      expect(confirmationLabel(confirmation: 'reported', executionMode: 'real'), '작은 팔이 눌렀어요');
      expect(confirmationLabel(confirmation: 'none', executionMode: 'real'), '눌렸는지 몰라요');
    });

    test('음성·상태 문장: L3 실측만 전기를 쓰기 시작했다고, 아니면 버튼까지만', () {
      expect(finishedMessage(kind: ResultKind.success, executionMode: 'real', operationVerified: true),
          '버튼은 다 눌렀어요. 가전이 전기를 쓰기 시작했어요. 원하는 대로 됐는지 봐 주세요.');
      final pressOnly = finishedMessage(kind: ResultKind.success, executionMode: 'real', confirmation: 'reported');
      expect(pressOnly, '버튼은 다 눌렀어요. 가전이 움직이는지 봐 주세요.');
      expect(pressOnly.contains('켜졌'), isFalse);
    });
  });

  group("가전 타일 '준비됐어요'는 서버가 실행을 받아 준다고 말한 때만", () {
    test('서버 판정 operable + 실행 가능 → 준비됐어요', () {
      expect(kioskTileBand(_appliance('mw', '전자레인지', readiness: 'operable')).text, '준비됐어요');
    });
    test('판정이 없거나(옛 서버·하드코딩) 실행 불가면 준비됐다고 하지 않는다', () {
      expect(kioskTileBand(_appliance('mw', '전자레인지')).text, '확인 전이에요');
      expect(kioskTileBand(_appliance('mw', '전자레인지', readiness: 'operable', canExecute: false)).text,
          '확인 전이에요');
      expect(kioskTileBand(_appliance('mw', '전자레인지', readiness: 'disconnected')).text, '연결이 안 돼요');
      expect(kioskTileBand(_appliance('mw', '전자레인지', readiness: 'needs_setup')).text, '설정이 필요해요');
    });
  });
}
