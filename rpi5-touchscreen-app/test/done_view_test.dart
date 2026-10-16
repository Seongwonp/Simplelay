// 완료 화면 — 끝낸 것은 버튼 조작이다. 무엇을·어느 가전에·어떻게 확인했는지
// 말하고, 자동으로 돌아간다는 사실을 글자로도 알린다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/models/scenario_run.dart';
import 'package:simplelay_touchscreen/theme/kiosk_colors.dart';
import 'package:simplelay_touchscreen/theme/kiosk_tokens.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/done_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/hold_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/practice_band.dart';

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

  // 2026-10-15 문구 개선: 끝낸 것은 버튼 누르기 — 가전이 움직이는지는 사람이 본다(제목 바로 아래 한 줄).
  testWidgets('성공: 버튼을 다 눌렀어요·가전은 직접·대상·한 일·자동 복귀·처음 화면으로',
      (tester) async {
    var dismissed = 0;
    await _pump(
      tester,
      KioskDoneView(
        success: true,
        label: '즉석밥 데워줘',
        // 실행 환경을 아는 실행만 '버튼을 다 눌렀어요'라고 말한다.
        executionMode: 'real',
        target: kMicrowaveAppliance,
        onDismiss: () => dismissed++,
      ),
    );

    expect(find.text('버튼 누름 완료'), findsOneWidget);
    expect(find.text('가전 반응은 직접 확인해 주세요'), findsOneWidget);
    expect(find.text('전자레인지'), findsOneWidget);
    expect(find.text('즉석밥 데워줘'), findsOneWidget);
    expect(find.textContaining('누름 장치'), findsNothing);
    expect(find.text('10초 뒤 처음 화면으로 돌아가요'), findsOneWidget);
    // 가전이 조리·세탁을 끝냈다고 말하지 않는다.
    expect(find.textContaining('완료되었'), findsNothing);

    await tester.pump(const Duration(seconds: 4));
    expect(find.text('6초 뒤 처음 화면으로 돌아가요'), findsOneWidget);
    await tester.tap(find.text('처음 화면으로'));
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

    expect(find.text('버튼 누름 완료'), findsNothing);
    expect(find.text('작은 팔이 다 눌렀다고 알려 왔어요'), findsOneWidget);
    expect(find.text('가전이 실제로 움직이는지는 직접 봐 주세요'), findsOneWidget);
  });

  testWidgets('모의 실행은 가장 큰 글자부터 연습이라고 말한다', (tester) async {
    await _pump(
      tester,
      KioskDoneView(
        success: true,
        label: '즉석밥 데워줘',
        executionMode: 'mock',
        target: kMicrowaveAppliance,
        onDismiss: () {},
      ),
    );

    // 맨 위 고정 띠 + 제목 + 제목 바로 아래 한 줄(2026-10-15).
    expect(find.text(kPracticeBandText), findsOneWidget);
    expect(find.text('연습을 마쳤어요'), findsOneWidget);
    expect(find.text('버튼 누름 완료'), findsNothing);
    expect(find.text('실제 가전은 누르지 않았어요'), findsOneWidget);
  });

  testWidgets('L3 판정은 있을 때만 말하고, 모의 판정이면(실물 모션이어도) 그 사실을 밝힌다',
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

    // 외부 평가 2026-10-13 M5: 실물 모션 + 모의 L3는 실제 동작 확인이 아니다.
    expect(find.text('가전 동작도 확인했어요'), findsNothing);
    expect(find.text('가전이 켜졌는지는 직접 봐 주세요'), findsOneWidget);
    expect(find.text('연습용 판정 값이에요 · 전력 파형에서 가열 시작을 확인했어요'), findsOneWidget);
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

    expect(find.text('가전을 먼저 봐 주세요'), findsOneWidget);
    expect(find.textContaining('이미 움직이고 있으면 다시 시도하지 마세요'), findsOneWidget);
    expect(find.text('처음 화면으로'), findsOneWidget);
    expect(find.text('다시 시도'), findsOneWidget);
    expect(find.text('화면으로 조작하기'), findsOneWidget);
    expect(find.text('10초 뒤 처음 화면으로 돌아가요'), findsNothing);
    // 눌렸는지 모르는 것은 '실패'가 아니다 — 앰버 '확인 필요'와 물음표(외부 평가 10/16 4차).
    expect(find.text('확인 필요'), findsOneWidget);
    expect(find.text('실패'), findsNothing);
    expect(find.byIcon(Icons.question_mark), findsOneWidget);
    expect(find.byIcon(Icons.close), findsNothing);
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
    expect(find.text('작은 팔과 가전이 멈췄는지 직접 봐 주세요'), findsOneWidget);
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
    expect(find.text('처음 화면으로'), findsOneWidget);
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

    expect(find.text('ThinQ · 연습 모드 · 받았는지 확인이 필요해요 · 확인 못 함'),
        findsOneWidget);
    // 보내지 않은 단계는 '확인 못 함'이 아니라 '누르지 않음'. 물리 경로 배지는 달지 않는다(2026-10-14).
    expect(find.text('연습 모드 · 누르지 않음 · 실패'),
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

  testWidgets('real 실행에는 머리 표시를 달지 않고 센서·기계 검증을 암시하지 않는다',
      (tester) async {
    await _pump(
      tester,
      KioskDoneView(
        success: true,
        label: '즉석밥 데워줘',
        executionMode: 'real',
        target: kMicrowaveAppliance,
        onDismiss: () {},
      ),
    );

    // execution_mode=real은 실행 경로가 실제 장치였다는 뜻일 뿐이다 —
    // 눌림·동작 확인은 확인 수준(L3 판정 등)이 따로 말한다. 실제 실행은 평소라 머리 표시가 없다(2026-10-14).
    expect(find.text('실제 장치로 실행'), findsNothing);
    expect(find.text('연습 모드'), findsNothing);
    expect(find.textContaining('실기기'), findsNothing);
    expect(find.textContaining('검증'), findsNothing);
    expect(find.text('가전 동작도 확인했어요'), findsNothing);
  });

  // 10/6 Copilot 리뷰(66990be): 모의 실행에서 L3 true가 "가전 동작도
  // 확인했어요"로 나와 실제 가전 확인으로 읽혔다. 실행 환경을 먼저 본다.
  testWidgets('모의 실행의 L3 확인은 모의 판정이라고 말하고 가전 확인으로 말하지 않는다',
      (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      KioskDoneView(
        success: true,
        label: '즉석밥 데워줘',
        executionMode: 'mock',
        target: kMicrowaveAppliance,
        operationConfirmed: true,
        operationSource: 'mock',
        onDismiss: () {},
      ),
    );

    expect(find.text('가전 동작도 확인했어요'), findsNothing);
    expect(find.text('연습이라 가전 동작은 보지 않았어요'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('가전 동작도 확인했어요')), findsNothing);
    handle.dispose();
  });

  testWidgets('모의 ThinQ 성공의 큰 글자는 가전 상태를 확인했다고 말하지 않는다',
      (tester) async {
    await _pump(
      tester,
      KioskDoneView(
        success: true,
        label: '에어컨 켜줘',
        executionMode: 'mock',
        route: 'thinq',
        confirmation: '연습 상태 확인',
        onDismiss: () {},
      ),
    );

    expect(find.text('가전 상태를 확인했어요'), findsNothing);
    expect(find.text('연습으로 상태를 확인했어요'), findsOneWidget);
  });

  group('L3 판정 출처 × 모션 실행 모드 (평가 M5)', () {
    // 확인한 것은 전력 변화다 — 물리 성공은 제목 바로 아래 한 줄이 말한다(2026-10-15).
    const realSentence = '전자레인지의 전력 사용이 늘었어요. 원하는 동작인지는 직접 봐 주세요';
    const mockMotion = '연습이라 가전 동작은 보지 않았어요';
    // 모의 L3와 출처 모름은 같은 말(직접 봐 달라) — 모의 출처는 아래 작은 글씨가 밝힌다.
    const mockL3 = '가전이 켜졌는지는 직접 봐 주세요';
    const unknownL3 = '가전이 켜졌는지는 직접 봐 주세요';
    final cases = <(String, String?, String)>[
      ('real', 'real', realSentence),
      ('real', 'mock', mockL3),
      ('real', null, unknownL3),
      ('unknown', 'real', realSentence),
      ('unknown', 'mock', mockL3),
      ('unknown', null, unknownL3),
      ('mock', 'real', mockMotion),
      ('mock', 'mock', mockMotion),
      ('mock', null, mockMotion),
    ];
    for (final (mode, source, expected) in cases) {
      testWidgets('모션 $mode · L3 출처 ${source ?? '모름'} → $expected', (tester) async {
        await _pump(
          tester,
          KioskDoneView(
            success: true,
            label: '즉석밥 데워줘',
            executionMode: mode,
            target: kMicrowaveAppliance,
            operationConfirmed: true,
            operationSource: source,
            onDismiss: () {},
          ),
        );
        expect(find.text(expected), findsOneWidget);
        // 실물 모션 + 모의 L3만 '연습용 판정 값'이라고 밝힌다(모의 모션은 큰 줄이 이미 연습이라고 말한다).
        expect(find.text('연습용 판정 값이에요'),
            mode != 'mock' && source == 'mock' ? findsOneWidget : findsNothing);
        if (expected != realSentence) {
          expect(find.text(realSentence), findsNothing);
          expect(find.byIcon(Icons.verified_outlined), findsNothing);
        }
      });
    }
  });

  group('동작 중 화면의 전력 판정 줄도 출처가 real일 때만 확인이라고 말한다 (평가 M5)', () {
    for (final (mode, source, expected) in <(String, String?, String)>[
      ('real', 'real', '전력으로 가전 동작을 확인했어요'),
      ('real', 'mock', '연습이라 실제 전력은 재지 않아요'),
      ('real', null, '가전이 켜졌는지는 직접 봐 주세요'),
      ('mock', 'real', '연습이라 실제 전력은 재지 않아요'),
    ]) {
      testWidgets('모션 $mode · 출처 ${source ?? '모름'} → $expected', (tester) async {
        await _pump(
          tester,
          KioskHoldView(
            appliance: kMicrowaveAppliance,
            holdState: 'hovering_stop',
            stopButton: '취소',
            executionMode: mode,
            elapsed: const Duration(minutes: 1),
            buttonsPressed: 3,
            operationConfirmed: true,
            operationSource: source,
            onStop: () {},
          ),
        );
        expect(find.text(expected), findsOneWidget);
      });
    }
  });

  // 2026-10-14 UI 정리: 누름 완료는 파랑 체크, 가전 상태 확인은 초록 체크. 연습·근거 미상은 중립이다.
  group('성공 화면의 큰 아이콘·색은 확인 수준만큼', () {
    final cases = <(String, KioskDoneView, bool)>[
      ('물리 · 실행 환경 모름(미확인)',
          const KioskDoneView(success: true, label: '즉석밥 데워줘', executionMode: 'unknown'), false),
      ('물리 · 실제(누름 장치 보고만)',
          const KioskDoneView(success: true, label: '즉석밥 데워줘', executionMode: 'real'), false),
      ('물리 · 연습',
          const KioskDoneView(success: true, label: '즉석밥 데워줘', executionMode: 'mock'), false),
      ('물리 · 실제 + 모의 L3',
          const KioskDoneView(
              success: true, label: '즉석밥 데워줘', executionMode: 'real',
              operationConfirmed: true, operationSource: 'mock'), false),
      ('ThinQ · 연습',
          const KioskDoneView(success: true, label: '에어컨 켜줘', executionMode: 'mock', route: 'thinq'),
          false),
      ('물리 · 실제 + 실측 L3 동작 확인',
          const KioskDoneView(
              success: true, label: '즉석밥 데워줘', executionMode: 'real',
              operationConfirmed: true, operationSource: 'real'), true),
      ('ThinQ · 실제 상태 재조회(바꿈)',
          const KioskDoneView(
              success: true, label: '공기청정기 강풍', executionMode: 'real', route: 'thinq',
              resultConfirmation: 'state_confirmed'), true),
      ('ThinQ · 실제 상태 재조회(이미 목표값)',
          const KioskDoneView(
              success: true, label: '공기청정기 강풍', executionMode: 'real', route: 'thinq',
              resultConfirmation: 'already_at_target'), true),
    ];
    for (final (name, view, strong) in cases) {
      testWidgets('$name → ${strong ? '가전 확인 초록' : '누름 완료 또는 미확인 구분'}', (tester) async {
        await _pump(tester, view);
        final press = view.executionMode == 'real' && view.route != 'thinq';
        expect(find.byIcon(Icons.check), strong || press ? findsWidgets : findsNothing);
        expect(find.byIcon(Icons.info_outline), strong || press ? findsNothing : findsOneWidget);
        // 가장 큰 글자(핵심 단계, 2026-10-16 디자인 규격)의 색도 같은 규칙 — 체크 없이 초록 글자로 성공을 암시하지 않는다.
        final headline = tester
            .widgetList<Text>(find.byType(Text))
            .firstWhere((t) => t.style?.fontSize == KioskType.key);
        expect(headline.style!.color, strong ? KioskColors.confirmed : press ? KioskColors.running : view.executionMode == 'mock' ? Colors.white : KioskColors.warning);
      });
    }
  });

  // 외부 평가 10/16 2차 k04: 연습 실패 화면에 왜 실패했는지가 없었다('실제 가전은 누르지 않았어요'만).
  testWidgets('연습 실패도 이유 한 줄을 말한다 — 실제 가전은 누르지 않았다는 말과 함께', (tester) async {
    for (final (reason, why) in [
      (KioskFailureReason.safetyStop, '연습에서 눌림을 확인하지 못해 멈췄어요'),
      (KioskFailureReason.execution, '연습에서 눌림을 확인하지 못했어요'),
      (KioskFailureReason.serverLost, '연습 결과를 받지 못했어요'),
    ]) {
      await _pump(
        tester,
        KioskDoneView(
          success: false,
          label: '즉석밥 데워줘',
          executionMode: 'mock',
          reason: reason,
          target: kMicrowaveAppliance,
        ),
      );
      expect(find.textContaining(why), findsOneWidget, reason: '$reason');
      expect(find.textContaining('실제 가전은 누르지 않았어요'), findsOneWidget, reason: '$reason');
    }
  });

  // 외부 평가 10/16 4차: 위 줄은 '취소' 버튼을 직접 누르라는데 아래 줄은 '정지 버튼'이라 했다 — 같은 이름으로.
  testWidgets('정지 확인 못 함: 작은 팔이 대신 누른 버튼을 실제 이름으로 말한다', (tester) async {
    await _pump(
      tester,
      KioskHoldView(
        appliance: kMicrowaveAppliance,
        holdState: 'hovering_stop',
        stopButton: '취소',
        stopOutcome: 'requested_unconfirmed',
        executionMode: 'real',
        elapsed: const Duration(minutes: 1),
        buttonsPressed: 1,
        onStop: () {},
      ),
    );
    expect(find.text("작은 팔이 '취소' 버튼을 대신 눌렀어요"), findsOneWidget);
    expect(find.text('작은 팔이 정지 버튼을 대신 눌렀어요'), findsNothing);
  });
}
