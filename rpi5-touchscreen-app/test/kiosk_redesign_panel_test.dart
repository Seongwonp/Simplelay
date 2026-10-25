// 화면 구조 개편 1단계(2026-10-18) — 이 제품만의 그림(가전 버튼판)을 제안·실행·결과 세 화면의 **같은 자리(오른쪽)** 에.
// 제안: 누를 칸에 번호, 실행: 지금 누르는 칸 채움, 결과: 누른 칸 표시. 버튼판이 없으면 지금처럼 목록·설명.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/theme/kiosk_colors.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/done_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/executing_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/run_frame.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/suggestion_view.dart';

const _sug = KioskSuggestion(
  id: 's1',
  purpose: '즉석밥 데워줘',
  occurrences: 3,
  timeBand: '아침',
  steps: ['즉석밥', '시작'],
  applianceId: 'microwave',
);

Future<void> _pump(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(800, 480);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  await tester.pump();
}

Widget _suggestion({ApplianceMap? target = kMicrowaveAppliance, KioskSuggestion s = _sug}) =>
    KioskSuggestionView(
      suggestion: s,
      target: target,
      cdRemaining: 20,
      cdTotal: 20,
      onApprove: () {},
      onReject: () {},
    );

Widget _executing() => KioskExecutingView(
      executionMode: 'real',
      title: '즉석밥 데워줘',
      target: kMicrowaveAppliance,
      lastButtons: null,
      currentButton: '시작',
      currentAttempt: 1,
      completedSteps: 1,
      totalSteps: 2,
      verificationConfidence: null,
      verificationDetail: null,
      onStop: () {},
    );

Widget _done({List<KioskButtonResult>? pressed}) => KioskDoneView(
      executionMode: 'real',
      success: true,
      label: '즉석밥 데워줘',
      target: kMicrowaveAppliance,
      resultConfirmation: 'reported',
      pressed: pressed,
      onDismiss: () {},
    );

const _picture = ValueKey('panel-picture');

void main() {
  testWidgets('제안 — 버튼판 그림이 오른쪽에, 누를 칸에 순서 번호(①즉석밥 ②시작)', (tester) async {
    await _pump(tester, _suggestion());
    expect(tester.takeException(), isNull);
    expect(find.byKey(_picture), findsOneWidget);
    final first = find.byKey(const ValueKey('panel-order-BT-08'));
    final second = find.byKey(const ValueKey('panel-order-BT-05'));
    expect(first, findsOneWidget);
    expect(second, findsOneWidget);
    expect(find.descendant(of: first, matching: find.text('1')), findsOneWidget);
    expect(find.descendant(of: second, matching: find.text('2')), findsOneWidget);
    // 오른쪽 칸 — 화면 가운데보다 오른쪽.
    expect(tester.getRect(find.byKey(_picture)).left, greaterThan(400));
  });

  testWidgets('제안·실행·결과의 버튼판은 같은 자리·같은 폭', (tester) async {
    await _pump(tester, _suggestion());
    final s = tester.getRect(find.byKey(_picture));
    await _pump(tester, _executing());
    final e = tester.getRect(find.byKey(_picture));
    await _pump(tester, _done(pressed: const [
      KioskButtonResult(button: '즉석밥', success: true),
      KioskButtonResult(button: '시작', success: true),
    ]));
    final d = tester.getRect(find.byKey(_picture));
    expect(s.left, moreOrLessEquals(e.left, epsilon: 1));
    expect(s.width, moreOrLessEquals(e.width, epsilon: 1));
    expect(d.left, moreOrLessEquals(e.left, epsilon: 1));
    expect(d.width, moreOrLessEquals(e.width, epsilon: 1));
  });

  testWidgets('결과 — 누른 칸에 표시가 남는다(누른 것만)', (tester) async {
    await _pump(tester, _done(pressed: const [
      KioskButtonResult(button: '즉석밥', success: true),
      KioskButtonResult(button: '시작', success: true),
    ]));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('panel-pressed-BT-08')), findsOneWidget);
    expect(find.byKey(const ValueKey('panel-pressed-BT-05')), findsOneWidget);
    expect(find.byKey(const ValueKey('panel-pressed-BT-01')), findsNothing);
  });

  testWidgets('버튼판을 모르면(누른 버튼 기록 없음) 결과는 지금처럼 가운데 글', (tester) async {
    await _pump(tester, _done());
    expect(find.byKey(_picture), findsNothing);
  });

  testWidgets('제안 — 버튼판에 없는 버튼이 섞이면 그림 대신 순서 목록', (tester) async {
    await _pump(
        tester,
        _suggestion(
            s: const KioskSuggestion(
          id: 's2',
          purpose: '데워줘',
          occurrences: 1,
          steps: ['즉석밥', '없는 버튼'],
          applianceId: 'microwave',
        )));
    expect(find.byKey(_picture), findsNothing);
    expect(find.text('없는 버튼'), findsOneWidget);
  });

  testWidgets('버튼판 칸 글자는 꺼진 것처럼 흐리지 않다(50% 회색이 아님)', (tester) async {
    await _pump(tester, _executing());
    final label = tester.widget<Text>(find.descendant(
        of: find.byType(KioskPanelPicture), matching: find.text('10초')));
    expect(label.style?.color, isNot(KioskColors.panelText.withValues(alpha: 0.5)));
    expect(label.style!.color!.a, greaterThanOrEqualTo(0.7));
  });

  testWidgets("제안 주 단추는 '네'(폰과 같은 말)", (tester) async {
    await _pump(tester, _suggestion());
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('suggestion-approve')), matching: find.text('네')),
        findsOneWidget);
  });
}
