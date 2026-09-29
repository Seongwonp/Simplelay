// 완료 화면 — 끝낸 것은 버튼 조작이다. 무엇을·어느 가전에·어떻게 확인했는지
// 말하고, 자동으로 돌아간다는 사실을 글자로도 알린다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/models/scenario_run.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/done_view.dart';

Future<void> _pump(
  WidgetTester tester,
  Widget view, {
  double textScale = 1.0,
}) async {
  tester.view.physicalSize = const Size(800, 480);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
      child: Scaffold(body: view),
    ),
  ));
}

void main() {
  testWidgets('연결 유실은 정지나 실패 확정으로 표시하지 않는다', (tester) async {
    await _pump(tester, const KioskDoneView(
      success: false, label: '실행 확인 불가',
      reason: KioskFailureReason.serverLost,
    ));
    expect(find.text('실행 상태를 확인할 수 없어요'), findsOneWidget);
    expect(find.text('실행을 멈췄어요'), findsNothing);
    expect(find.textContaining('직접 확인'), findsOneWidget);
  });

  testWidgets('성공: 버튼 조작을 마쳤어요·대상·한 일·확인 방법·자동 복귀·처음으로',
      (tester) async {
    var dismissed = 0;
    await _pump(
      tester,
      KioskDoneView(
        success: true,
        label: '즉석밥 데워줘',
        // 실행 환경을 아는 실행만 '버튼 조작을 마쳤어요'라고 말한다.
        executionMode: 'real',
        target: kMicrowaveAppliance,
        onDismiss: () => dismissed++,
      ),
    );

    expect(find.text('버튼 조작을 마쳤어요'), findsOneWidget);
    expect(find.text('전자레인지'), findsOneWidget);
    expect(find.text('즉석밥 데워줘'), findsOneWidget);
    expect(find.text('실행기가 버튼 조작 완료를 보고했어요'), findsOneWidget);
    expect(find.text('잠시 후 처음 화면으로 돌아가요'), findsOneWidget);
    // 가전이 조리·세탁을 끝냈다고 말하지 않는다.
    expect(find.textContaining('완료되었'), findsNothing);

    await tester.tap(find.text('처음으로'));
    expect(dismissed, 1);
  });

  testWidgets('실행 환경을 모르면 버튼 조작을 마쳤다고 단정하지 않는다', (tester) async {
    await _pump(
      tester,
      KioskDoneView(
        success: true,
        label: '즉석밥 데워줘',
        // executionMode 미지정 = unknown(옛 노드·UART가 보고하지 않음).
        target: kMicrowaveAppliance,
        onDismiss: () {},
      ),
    );

    expect(find.text('버튼 조작을 마쳤어요'), findsNothing);
    expect(find.text('실행기가 완료를 보고했어요'), findsOneWidget);
    expect(find.text('실제 조작 여부는 확인하지 못했어요'), findsOneWidget);
  });

  testWidgets('L3 판정은 있을 때만 말하고, 모의 판정이면 그 사실을 밝힌다',
      (tester) async {
    await _pump(
      tester,
      KioskDoneView(
        success: true,
        label: '즉석밥 데워줘',
        executionMode: 'real',
        target: kMicrowaveAppliance,
        operationConfirmed: true,
        operationSource: 'mock',
        operationDetail: '전력 파형에서 가열 시작을 확인했어요',
        onDismiss: () {},
      ),
    );

    expect(find.text('가전 동작도 확인했어요'), findsOneWidget);
    expect(find.textContaining('모의 판정'), findsOneWidget);
  });

  testWidgets('실패는 자동으로 돌아간다고 말하지 않고 다음 행동을 준다', (tester) async {
    await _pump(
      tester,
      KioskDoneView(
        success: false,
        label: '즉석밥 데워줘',
        onRetry: () {},
        onManual: () {},
        onDismiss: () {},
      ),
    );

    expect(find.text('버튼 조작을 확인하지 못했어요'), findsOneWidget);
    expect(find.text('다시 시도'), findsOneWidget);
    expect(find.text('버튼으로 조작'), findsOneWidget);
    expect(find.text('잠시 후 처음 화면으로 돌아가요'), findsNothing);
  });

  testWidgets('긴급 정지 뒤에도 장치가 멈췄다고 단정하지 않는다', (tester) async {
    // 서버가 확인하는 것은 실행 루프가 끝났다는 것까지다. 모터가 물리적으로
    // 멈췄는지는 아직 아무 센서도 확인하지 않는다(정지 지연 ③은 실측 대기).
    await _pump(
      tester,
      KioskDoneView(
        success: false,
        label: '즉석밥 데워줘',
        reason: KioskFailureReason.stopped,
        onRetry: () {},
        onManual: () {},
        onDismiss: () {},
      ),
    );

    expect(find.textContaining('안전하게 멈췄어요'), findsNothing);
    expect(find.textContaining('멈췄는지 확인'), findsOneWidget);
  });

  testWidgets('큰 글씨에서도 넘치지 않는다', (tester) async {
    await _pump(
      tester,
      KioskDoneView(
        success: true,
        label: '냉동 만두 데워서 라면이랑 같이 먹을 준비',
        target: kMicrowaveAppliance,
        onDismiss: () {},
      ),
      textScale: 1.22,
    );

    expect(tester.takeException(), isNull);
    expect(find.text('처음으로'), findsOneWidget);
  });

  testWidgets('단계별 결과: 확인 못 한 ThinQ 단계를 확인됨으로 올리지 않는다',
      (tester) async {
    await _pump(
      tester,
      KioskDoneView(
        success: false,
        label: '저녁 쉬기',
        reason: KioskFailureReason.receiptUnknown,
        route: 'thinq',
        runSteps: const [
          ScenarioRunStep(
            targetId: 'air_purifier',
            route: 'thinq',
            summary: '공기청정기 풍량 약하게',
            status: 'unconfirmed',
            receipt: 'unknown',
            confirmation: 'none',
            executionMode: 'mock',
          ),
          ScenarioRunStep(
            targetId: 'microwave',
            route: 'physical',
            summary: '전자레인지 즉석밥',
            status: 'failed',
            receipt: 'not_dispatched',
            confirmation: 'none',
            executionMode: 'mock',
          ),
        ],
        onDismiss: () {},
      ),
    );

    expect(find.text('ThinQ · 모의 실행 · 접수 불명 · 확인 못 함'), findsOneWidget);
    expect(find.text('물리 버튼 · 모의 실행 · 확인 근거 없음 · 실패'),
        findsOneWidget);
    expect(find.textContaining('상태 확인됨'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('단계가 하나뿐이면 단계 목록을 새로 그리지 않는다', (tester) async {
    await _pump(
      tester,
      KioskDoneView(
        success: true,
        label: '즉석밥 데워줘',
        executionMode: 'mock',
        runSteps: const [
          ScenarioRunStep(
            targetId: 'microwave',
            route: 'physical',
            summary: '전자레인지 즉석밥',
            status: 'succeeded',
            confirmation: 'reported',
            executionMode: 'mock',
          ),
        ],
        onDismiss: () {},
      ),
    );
    expect(find.text('1. 전자레인지 즉석밥'), findsNothing);
  });
}
