// 화면 구조 개편 2단계(2026-10-18) — 글 단계 3개·결과 띠와 제목·버튼 위계·연습 문구·정지 단추 이름.
//
// - 실행 중: 왼쪽은 '상태 제목 · 진행 · 한 줄', 가전·할 일은 위 띠로.
// - 결과: 띠 = 확인 수준, 제목 = 본 사실 — 같은 말을 두 번 하지 않는다.
// - 확인 필요·실패 화면의 주 단추는 골드가 아닌 중립색, 다시 시도는 보조(테두리), 그 밖은 글자 단추.
// - 정지 대기 확인 못 함: '다시 멈추기' 한 줄(자리·크기·모양은 그대로).
// - 연습: '연습 중이라 실제 가전은 움직이지 않아요' 한 줄, 실패는 '연습이 중간에 멈췄어요'.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/theme/kiosk_colors.dart';
import 'package:simplelay_touchscreen/theme/kiosk_tokens.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/done_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/executing_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/hold_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/kiosk_target_line.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/practice_band.dart';

Future<void> _pump(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(800, 480);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  await tester.pump();
}

KioskExecutingView _exec({String mode = 'real'}) => KioskExecutingView(
      executionMode: mode,
      title: '즉석밥 데워줘',
      target: kMicrowaveAppliance,
      lastButtons: null,
      currentButton: '시작',
      currentAttempt: 1,
      completedSteps: 1,
      totalSteps: 2,
      verificationConfidence: 0.9,
      verificationDetail: 'x',
      onStop: () {},
    );

/// 상태 띠 안의 글과 띠 밖의 글.
(List<String>, List<String>) _texts(WidgetTester tester) {
  final band = find.byKey(const ValueKey('status-band'));
  final inBand = tester
      .widgetList<Text>(find.descendant(of: band, matching: find.byType(Text)))
      .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
      .toList();
  final all = tester
      .widgetList<Text>(find.byType(Text))
      .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
      .toList();
  final outside = [...all];
  for (final t in inBand) {
    outside.remove(t);
  }
  return (inBand, outside);
}

String _flat(String s) => s.replaceAll(RegExp(r'[\s ⁠]'), '');

void main() {
  group('실행 중 — 글 단계 3개', () {
    testWidgets('가전·할 일은 위 띠에, 왼쪽에는 대상 줄·할 일 제목·"이번 버튼" 이름표가 없다', (tester) async {
      await _pump(tester, _exec());
      expect(tester.takeException(), isNull);
      final band = find.byKey(const ValueKey('status-band'));
      expect(find.descendant(of: band, matching: find.textContaining('전자레인지')), findsOneWidget);
      // 할 일은 명령문이 아니라 행동 이름(평가 4차 10/18).
      expect(find.descendant(of: band, matching: find.textContaining('즉석밥 데우기')), findsOneWidget);
      expect(find.byType(KioskTargetLine), findsNothing);
      expect(find.text('이번 버튼'), findsNothing);
      // 상태 제목 · 진행 · 지금 버튼은 그대로.
      expect(find.byKey(const ValueKey('status-header')), findsOneWidget);
      expect(find.byKey(const ValueKey('execution-step')), findsOneWidget);
      expect(find.text('시작 버튼'), findsOneWidget);
    });
  });

  group('결과 — 띠는 확인 수준, 제목은 본 사실(같은 말 두 번 금지)', () {
    final cases = <String, KioskDoneView>{
      '누름 보고만': KioskDoneView(
          executionMode: 'real',
          success: true,
          label: '즉석밥 데워줘',
          target: kMicrowaveAppliance,
          resultConfirmation: 'reported',
          onDismiss: () {}),
      '전력 확인': KioskDoneView(
          executionMode: 'real',
          success: true,
          label: '즉석밥 데워줘',
          target: kMicrowaveAppliance,
          resultConfirmation: 'reported',
          operationConfirmed: true,
          operationSource: 'real',
          onDismiss: () {}),
      'LG 설정 확인': KioskDoneView(
          executionMode: 'real',
          success: true,
          label: '공기청정기 전원 켜기',
          route: 'thinq',
          resultConfirmation: 'state_confirmed',
          onDismiss: () {}),
      '눌렸는지 모름': KioskDoneView(
          executionMode: 'real',
          success: false,
          label: '즉석밥 데워줘',
          target: kMicrowaveAppliance,
          reason: KioskFailureReason.execution,
          onRetry: () {},
          onManual: () {},
          onDismiss: () {}),
      '본체 연결 끊김': KioskDoneView(
          executionMode: 'real',
          success: false,
          label: '즉석밥 데워줘',
          reason: KioskFailureReason.serverLost,
          onDismiss: () {}),
    };
    for (final e in cases.entries) {
      testWidgets(e.key, (tester) async {
        await _pump(tester, e.value);
        expect(tester.takeException(), isNull);
        final (inBand, outside) = _texts(tester);
        final label = _flat(inBand.first);
        expect(label, isNotEmpty);
        for (final t in outside) {
          expect(_flat(t).contains(label), isFalse,
              reason: "띠 '${inBand.first}'와 같은 말이 아래 '$t'에 또 있다");
        }
      });
    }
  });

  group('확인 필요·실패 화면의 단추 위계', () {
    Color? fillOf(WidgetTester tester, Key key) => tester
        .widget<ButtonStyleButton>(find.byKey(key))
        .style
        ?.backgroundColor
        ?.resolve({});

    testWidgets('실패: 주 단추(처음 화면으로)는 골드가 아닌 중립 채움, 다시 시도는 테두리, 화면 조작은 글자 단추', (tester) async {
      await _pump(
          tester,
          KioskDoneView(
              executionMode: 'real',
              success: false,
              label: '즉석밥 데워줘',
              target: kMicrowaveAppliance,
              reason: KioskFailureReason.execution,
              onRetry: () {},
              onManual: () {},
              onDismiss: () {}));
      expect(fillOf(tester, const ValueKey('done-home')), isNot(KioskColors.primary));
      expect(fillOf(tester, const ValueKey('done-home')), KioskColors.neutralFill);
      expect(find.byType(ElevatedButton), findsOneWidget);
      // 평가 13차(10/18): 한 번 더 하기는 작은 테두리 보조 단추(글자 단추는 꺼진 단추로 보였다).
      expect(tester.widget(find.byKey(const ValueKey('done-retry'))), isA<OutlinedButton>());
      // 작은 팔로 골라 누르기는 밑줄 글자가 아니라 테두리 버튼(평가 5차 10/18).
      expect(tester.widget(find.byKey(const ValueKey('done-manual'))), isA<OutlinedButton>());
      // 손가락 크기(48 이상).
      expect(tester.getSize(find.byKey(const ValueKey('done-manual'))).height,
          greaterThanOrEqualTo(48));
      // 할 일은 번호 안내가 한 번만 말한다(평가 15차 10/18 — '가전을 봐 주세요' 큰 줄과 번호가 같은 뜻을 되풀이했다).
      expect(find.byKey(const ValueKey('done-next-step')), findsNothing);
      expect(find.byKey(const ValueKey('done-recovery-steps')), findsOneWidget);
    });

    testWidgets('앰버 띠(누름 보고만)에서도 처음 화면으로는 골드가 아니다', (tester) async {
      await _pump(
          tester,
          KioskDoneView(
              executionMode: 'real',
              success: true,
              label: '즉석밥 데워줘',
              target: kMicrowaveAppliance,
              resultConfirmation: 'reported',
              onDismiss: () {}));
      expect(fillOf(tester, const ValueKey('done-home')), KioskColors.neutralFill);
    });

    // 평가 11차(10/18): 나가는 단추는 모든 결과 화면에서 한 색(중립 채움) — 성공 골드·확인 필요 흰색이 화면마다 달랐다.
    testWidgets('확인한 성공에도 처음 화면으로는 같은 중립 채움', (tester) async {
      await _pump(
          tester,
          KioskDoneView(
              executionMode: 'real',
              success: true,
              label: '즉석밥 데워줘',
              target: kMicrowaveAppliance,
              resultConfirmation: 'reported',
              operationConfirmed: true,
              operationSource: 'real',
              onDismiss: () {}));
      expect(fillOf(tester, const ValueKey('done-home')), KioskColors.neutralFill);
    });
  });

  group('연습 문구', () {
    testWidgets('연습 띠는 한 줄 — 연습이에요. 실제 가전은 그대로예요', (tester) async {
      expect(kPracticeBandText, '연습이에요. 실제 가전은 그대로예요');
      await _pump(tester, _exec(mode: 'mock'));
      expect(find.textContaining('연습이에요. 실제 가전은 그대로예요'), findsOneWidget);
    });

    testWidgets('연습 실패 제목은 "연습이 중간에 멈췄어요"', (tester) async {
      await _pump(
          tester,
          KioskDoneView(
              executionMode: 'mock',
              success: false,
              label: '즉석밥 데워줘',
              reason: KioskFailureReason.execution,
              onDismiss: () {}));
      expect(find.text('연습이 중간에 멈췄어요'), findsOneWidget);
    });
  });

  group('정지 대기', () {
    testWidgets("확인 못 함이면 정지 단추 이름은 '다시 멈추기' 한 줄 — 자리·크기는 그대로", (tester) async {
      await _pump(
          tester,
          KioskHoldView(
              appliance: kMicrowaveAppliance,
              holdState: 'parked',
              stopOutcome: 'requested_unconfirmed',
              stopButton: '취소',
              executionMode: 'real',
              elapsed: Duration.zero,
              onStop: () {},
              onClose: () {}));
      expect(find.text('다시 멈추기'), findsOneWidget);
      expect(find.textContaining('다시\n'), findsNothing);
      final stop = tester.getSize(find.byKey(const ValueKey('kiosk-stop-area')));
      expect(stop, const Size(KioskSizes.stopWidth, KioskSizes.stopHeight));
    });

    testWidgets('가전 상태 줄에 뜻 없는 번개 아이콘을 달지 않는다', (tester) async {
      await _pump(
          tester,
          KioskHoldView(
              appliance: kMicrowaveAppliance,
              holdState: 'hovering_stop',
              stopButton: '취소',
              executionMode: 'real',
              elapsed: Duration.zero,
              onStop: () {}));
      expect(find.byIcon(Icons.bolt), findsNothing);
    });
  });
}
