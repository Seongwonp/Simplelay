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
    expect(find.text('어떻게 됐는지 몰라요'), findsOneWidget);
    expect(find.text('실행을 멈췄어요'), findsNothing);
    expect(find.textContaining('가전을 봐 주세요'), findsOneWidget);
  });

  // 2026-10-15 문구 개선: 끝낸 것은 버튼 누르기 — 가전이 움직이는지는 사람이 본다(제목 바로 아래 한 줄).
  // 2차 독립 평가 C(10/18): 누름 보고만은 확인이 필요한 결과라 자동으로 닫지 않는다 — '움직였어요 / 안 움직였어요'로 답한다.
  testWidgets('성공: 버튼을 다 눌렀어요·가전은 직접·대상·한 일·사람 확인(자동 복귀 없음)·처음 화면으로',
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

    expect(find.text('버튼은 다 눌렀어요'), findsOneWidget);
    expect(find.text('가전이 움직이는지 봐 주세요'), findsOneWidget);
    // 무엇이었는지는 위 띠 오른쪽 한 줄(평가 17차 10/18). 제목은 명령문이 아니라 행동 이름(평가 4차 10/18).
    expect(find.text('전자레인지 · 즉석밥 데우기'), findsOneWidget);
    expect(find.textContaining('누름 장치'), findsNothing);
    expect(find.text('잠시 뒤 처음 화면으로 돌아가요'), findsNothing);
    expect(find.byKey(const ValueKey('done-check-yes')), findsOneWidget);
    expect(find.byKey(const ValueKey('done-check-no')), findsOneWidget);
    // 가전이 조리·세탁을 끝냈다고 말하지 않는다.
    expect(find.textContaining('완료되었'), findsNothing);

    await tester.pump(const Duration(seconds: 4));
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

    // 기계 말투('누름 장치가 다 눌렀다고 알려 왔어요') 대신 같은 말 하나로(평가 4차 10/18). 확인 수준은 띠가 지킨다 —
    // 실제 확인이 아니므로 '됐어요'가 아니라 '살펴볼 게 있어요', 할 일은 '가전이 움직이는지 봐 주세요'.
    expect(find.textContaining('알려 왔어요'), findsNothing);
    expect(find.text('버튼은 다 눌렀어요'), findsOneWidget);
    expect(find.text('살펴볼 게 있어요'), findsOneWidget);
    expect(find.text('가전이 움직이는지 봐 주세요'), findsOneWidget);
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
    expect(find.text('다 눌렀어요'), findsNothing);
    // '실제 가전은 누르지 않았어요'는 위 연습 띠가 말한다 — 아래에 또 쓰지 않는다(10/18).
    expect(find.text('실제 가전은 누르지 않았어요'), findsNothing);
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
    expect(find.text('가전이 움직이는지 봐 주세요'), findsOneWidget);
    expect(find.text('연습 값이에요 · 전력 파형에서 가열 시작을 확인했어요'), findsOneWidget);
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

    expect(find.text('눌렸는지 몰라요'), findsOneWidget);
    // 같은 경고는 화면에 한 번 — '다시 시도' 확인 창에만 있다(쉬운 말 10/17).
    expect(find.textContaining('이미 움직이고 있으면 다시 시도하지 마세요'), findsNothing);
    expect(find.text('처음 화면으로'), findsOneWidget);
    // 휴리스틱 평가(10/18): 다음 행동은 '가전을 보고 알려 주세요' — 다시 누르기는 '안 움직였어요'라고 답한 뒤에만(R1).
    expect(find.byKey(const ValueKey('done-check-yes')), findsOneWidget);
    expect(find.byKey(const ValueKey('done-check-no')), findsOneWidget);
    expect(find.text('한 번 더 하기'), findsNothing);
    expect(find.text('누름 장치로 골라 누르기'), findsNothing);
    expect(find.text('잠시 뒤 처음 화면으로 돌아가요'), findsNothing);
    // 눌렸는지 모르는 것은 '실패'가 아니다 — 앰버 띠와 물음표(외부 평가 10/16 4차). 결과 띠 말은 두 가지뿐이라
    // '살펴볼 게 있어요'(평가 3차 10/18), 제목은 본 사실('눌렸는지 몰라요').
    expect(find.text('살펴볼 게 있어요'), findsOneWidget);
    expect(find.text('주의'), findsNothing);
    expect(find.text('실패'), findsNothing);
    // 순서 안내가 있으면 큰 결과 원은 뺀다(사용자 결정 10/18) — 물음표는 위 띠가 말한다.
    expect(find.byIcon(Icons.help_outline), findsWidgets);
    expect(find.byKey(const ValueKey('done-recovery-steps')), findsOneWidget);
    // 가위표는 '안 움직였어요' 답 단추 안에만 — 결과 표시로 쓰지 않는다.
    expect(find.byIcon(Icons.close), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('done-check-no')), matching: find.byIcon(Icons.close)),
        findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('done-check-no')));
    await tester.pump();
    expect(find.text('한 번 더 하기'), findsOneWidget);
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
    expect(find.text('누름 장치가 멈췄는지 몰라요'), findsOneWidget);
    expect(find.byKey(const ValueKey('done-recovery-steps')), findsOneWidget); // 평가 15차: 할 일은 번호 안내가 한 번만
    // 직접 멈춘 사람에게 '다시 시도'를 같은 무게로 두지 않는다 — 다시 누를 위험(UI 평가 5차 10/17).
    // 멈췄는지 모르면 누름 장치를 다시 움직이게 하는 '누름 장치로 골라 누르기'도 두지 않는다(평가 15차 10/18, 안전).
    expect(find.text('한 번 더 하기'), findsNothing);
    expect(find.text('누름 장치로 골라 누르기'), findsNothing);
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

    expect(find.text('LG 가전 · 연습 · 받았는지 몰라요 · 확인 못 함'),
        findsOneWidget);
    // 보내지 않은 단계는 '몰라요'이 아니라 '누르지 않았어요'. 물리 경로 배지는 달지 않는다(2026-10-14).
    expect(find.text('연습 · 누르지 않았어요 · 실패'),
        findsOneWidget);
    expect(find.textContaining('바뀐 것을 봤어요'), findsNothing);
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
    // 연습에는 판정 줄을 두지 않는다 — '연습이라 가전은 보지 않았어요'는 연습 띠와 부딪혔다(평가 4차 10/18).
    expect(find.text('연습이라 가전은 보지 않았어요'), findsNothing);
    expect(find.text(kPracticeBandText), findsOneWidget);
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
        confirmation: '연습 결과',
        onDismiss: () {},
      ),
    );

    expect(find.text('가전 상태를 확인했어요'), findsNothing);
    expect(find.text('연습을 마쳤어요'), findsOneWidget);
  });

  group('L3 판정 출처 × 모션 실행 모드 (평가 M5)', () {
    // 확인한 것은 전력 변화다 — 물리 성공은 제목 바로 아래 한 줄이 말한다(2026-10-15).
    const realSentence = '원하는 대로 됐는지 봐 주세요';
    // 연습(모션 mock)은 판정 줄이 없다(평가 4차 10/18) — 연습 띠 한 줄이 말한다.
    const mockMotion = kPracticeBandText;
    // 모의 L3와 출처 모름은 같은 말(직접 봐 달라) — 모의 출처는 아래 작은 글씨가 밝힌다.
    const mockL3 = '가전이 움직이는지 봐 주세요';
    const unknownL3 = '가전이 움직이는지 봐 주세요';
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
        expect(find.text('연습 값이에요'),
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
      ('real', 'real', '가전이 켜졌어요'),
      ('real', 'mock', '연습이라 가전은 보지 않아요'),
      ('real', null, '가전이 켜졌는지 봐 주세요'),
      // 연습은 판정 줄 대신 위 연습 띠 한 줄(평가 4차 10/18).
      ('mock', 'real', kPracticeBandText),
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
      ('LG 가전 · 연습',
          const KioskDoneView(success: true, label: '에어컨 켜줘', executionMode: 'mock', route: 'thinq'),
          false),
      ('물리 · 실제 + 실측 L3 동작 확인',
          const KioskDoneView(
              success: true, label: '즉석밥 데워줘', executionMode: 'real',
              operationConfirmed: true, operationSource: 'real'), true),
      ('LG 가전 · 실제 상태 재조회(바꿈)',
          const KioskDoneView(
              success: true, label: '공기청정기 강풍', executionMode: 'real', route: 'thinq',
              resultConfirmation: 'state_confirmed'), true),
      ('LG 가전 · 실제 상태 재조회(이미 목표값)',
          const KioskDoneView(
              success: true, label: '공기청정기 강풍', executionMode: 'real', route: 'thinq',
              resultConfirmation: 'already_at_target'), true),
    ];
    for (final (name, view, strong) in cases) {
      testWidgets('$name → ${strong ? '가전 확인 초록' : '누름 완료 또는 미확인 구분'}', (tester) async {
        await _pump(tester, view);
        // 누름 보고만은 체크가 아니라 누른 손 아이콘(확인 수준을 높여 보이지 않는다, 평가 3차 10/18).
        expect(find.byIcon(Icons.check), strong ? findsWidgets : findsNothing);
        // 큰 결과 원은 없다(평가 17차 10/18) — 확인 수준은 띠의 아이콘·색과 제목이 말한다.
        expect(find.byKey(const ValueKey('done-ring')), findsNothing);
        // 확인 못 한 성공의 결과 원은 위 띠('?' 확인해 주세요)와 같은 물음표(평가 11차 10/18 — 원 'i'·띠 '?'가 달랐다).
        // 연습은 위 띠가 연습 표시라 종전 'i' 그대로.
        expect(find.byIcon(Icons.question_mark), findsNothing);
        // 가장 큰 글자(핵심 단계, 2026-10-16 디자인 규격)의 색도 같은 규칙 — 체크 없이 초록 글자로 성공을 암시하지 않는다.
        final headline = tester
            .widgetList<Text>(find.byType(Text))
            .firstWhere((t) => t.style?.fontSize == KioskType.key);
        // 누름 보고만도 확인 필요 결과 — 다른 확인 필요 제목과 같은 앰버(접근성 감사 10/18). 초록은 확인한 성공만.
        expect(headline.style!.color, strong ? KioskColors.confirmed : view.executionMode == 'mock' ? Colors.white : KioskColors.warning);
      });
    }
  });

  // 외부 평가 10/16 2차 k04: 연습 실패 화면에 왜 실패했는지가 없었다('실제 가전은 누르지 않았어요'만).
  // 평가 5차(10/18): 제목 '연습이 중간에 멈췄어요' 아래 '연습 누르기를 끝내지 못했어요'가 같은 말을 되풀이했다 — 한 줄로.
  testWidgets('연습 실패는 한 줄 — 연습이 중간에 멈췄어요(실제 가전은 누르지 않았다는 말은 띠)', (tester) async {
    for (final (reason, why) in [
      // 연습은 실제 가전을 누르지 않는다 — '눌렸는지 몰라요'는 쓰지 않는다(평가 4차 10/18).
      (KioskFailureReason.safetyStop, kPracticeStoppedHeadline),
      (KioskFailureReason.execution, kPracticeStoppedHeadline),
      (KioskFailureReason.serverLost, kPracticeStoppedHeadline),
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
      expect(find.byKey(const ValueKey('done-next-step')), findsNothing, reason: '$reason');
      // 실제 가전을 움직이지 않았다는 말 — 연습 띠(청록, 출시 검토 10/18) 또는 본문 한 줄이 한 번 한다.
      expect(
          find.byWidgetPredicate((w) =>
              w is RichText && w.text.toPlainText().replaceAll('⁠', '').contains(kPracticeRealUnchanged)),
          findsOneWidget,
          reason: '$reason');
    }
  });

  // 외부 평가 10/16 4차: 위 줄은 '취소' 버튼을 직접 누르라는데 아래 줄은 '정지 버튼'이라 했다 — 같은 이름으로.
  // 평가 8차(10/18): '대신 눌렀어요'는 '직접 눌러 주세요'와 엇갈렸다 — 누름 장치도 눌렀지만 확인이 안 됐다고.
  testWidgets('정지 몰라요: 누름 장치도 누른 버튼을 실제 이름으로, 확인이 안 됐다고 말한다', (tester) async {
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
    expect(find.text('취소 버튼이 눌렸는지 몰라요'), findsOneWidget);
    expect(find.textContaining('정지 버튼을 눌렀지만'), findsNothing);
    expect(find.textContaining('대신 눌렀어요'), findsNothing);
  });
}
