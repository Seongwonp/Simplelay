import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/danger_alert_overlay.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/done_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/estop_banner.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/executing_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/hold_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/run_frame.dart';

void noop() {}
Future<void> show(WidgetTester t, Widget child, {double scale = 1}) async {
  t.view.physicalSize = const Size(800, 480);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
      home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(scale)),
    child: Scaffold(body: child),
  )));
  await t.pump(const Duration(milliseconds: 300));
}

KioskHoldView hold({String? estop, VoidCallback? stop}) => KioskHoldView(
      appliance: kMicrowaveAppliance,
      holdState: 'hovering_stop',
      stopButton: '취소',
      executionMode: 'real',
      elapsed: Duration.zero,
      operationConfirmed: true,
      operationSource: 'real',
      estopTitle: estop,
      onStop: stop ?? noop,
    );

void main() {
  testWidgets('비상 걸림: 누름 약속과 과거 동작 확인을 숨기고 정지 누름을 막는다', (t) async {
    var calls = 0;
    await show(t, hold(estop: '비상 버튼이 눌려 있어요', stop: () => calls++));
    final button =
        t.widget<ElevatedButton>(find.byKey(const ValueKey('hold-stop')));
    expect(button.onPressed, isNull);
    expect(find.textContaining('정지를 누르면'), findsNothing);
    expect(find.text('가전이 켜졌어요'), findsNothing);
    expect(find.textContaining('취소 버튼을 손으로 눌러 주세요'), findsOneWidget);
    expect(calls, 0);
  });
  testWidgets('비상 걸림에서도 정지 영역 위치와 크기는 그대로다', (t) async {
    await show(t, hold());
    final before = t.getRect(find.byKey(const ValueKey('kiosk-stop-area')));
    await show(t, hold(estop: '비상 버튼이 눌려 있어요'));
    expect(t.getRect(find.byKey(const ValueKey('kiosk-stop-area'))), before);
  });
  testWidgets('실물 누름 성공은 체크 없이 누른 손 표시와 가전 확인 안내로 구분한다', (t) async {
    await show(
        t,
        const KioskDoneView(
            success: true,
            label: '데우기',
            executionMode: 'real',
            route: 'physical',
            resultConfirmation: 'reported'));
    expect(find.text('버튼은 다 눌렀어요'), findsOneWidget);
    // 누름 보고만은 체크(확인)가 아니다 — 누른 손 아이콘(평가 3차 10/18, 확인 수준을 높여 보이지 않는다).
    expect(find.byIcon(Icons.check), findsNothing);
    expect(find.byKey(const ValueKey('done-ring')), findsNothing);
    expect(find.text('가전이 움직이는지 봐 주세요'), findsOneWidget);
  });
  testWidgets('근거 없는 ThinQ 성공에 가전 상태 확인을 만들지 않는다', (t) async {
    await show(
        t,
        const KioskDoneView(
            success: true, label: '강풍', executionMode: 'real', route: 'thinq'));
    expect(find.text('가전 상태를 확인했어요'), findsNothing);
    expect(find.byIcon(Icons.check), findsNothing);
  });
  testWidgets('실행 띠는 연습과 다른 파란 표시다', (t) async {
    await show(
        t,
        KioskExecutingView(
            executionMode: 'real',
            title: '데우기',
            target: kMicrowaveAppliance,
            lastButtons: null,
            currentButton: '시작',
            currentAttempt: 1,
            completedSteps: 1,
            totalSteps: 2,
            verificationConfidence: null,
            verificationDetail: null,
            onStop: noop));
    final color =
        t.widget<Icon>(find.byKey(const ValueKey('status-band-icon'))).color!;
    final hsv = HSVColor.fromColor(color);
    expect(hsv.saturation, greaterThan(.25));
    expect(hsv.hue, inInclusiveRange(205, 255));
  });
  testWidgets('실패 다시 시도는 확인 전에는 실행하지 않는다', (t) async {
    var calls = 0;
    await show(
        t,
        KioskDoneView(
            success: false,
            label: '데우기',
            executionMode: 'real',
            onRetry: () => calls++,
            onDismiss: noop));
    // 휴리스틱 평가(10/18): '한 번 더 하기'는 '안 움직였어요'라고 답한 뒤에만 보인다(R1).
    expect(find.text('한 번 더 하기'), findsNothing);
    await t.tap(find.byKey(const ValueKey('done-check-no')));
    await t.pump();
    await t.tap(find.text('한 번 더 하기'));
    await t.pumpAndSettle();
    expect(calls, 0);
    expect(find.byType(AlertDialog), findsOneWidget);
    await t.tap(find.text('닫기'));
    await t.pumpAndSettle();
    expect(calls, 0);
    await t.tap(find.text('한 번 더 하기'));
    await t.pumpAndSettle();
    await t.tap(find.text('네, 한 번 더 하기'));
    await t.pumpAndSettle();
    expect(calls, 1);
  });
  testWidgets('연습 실패는 실제 가전이 켜졌을 수 있다는 경고를 쓰지 않는다', (t) async {
    await show(
        t,
        KioskDoneView(
            success: false,
            label: '데우기',
            executionMode: 'mock',
            onRetry: noop,
            onDismiss: noop));
    expect(find.text('눌렸는지 확인하지 못했어요'), findsNothing);
    expect(find.textContaining('이미 켜졌다면'), findsNothing);
    expect(find.textContaining('실제 가전은 그대로예요'), findsWidgets); // 위 연습 띠(평가 4차 10/18 문장)
  });
  testWidgets('환경 미상 성공은 회색 완료가 아니라 앰버 확인 필요다', (t) async {
    await show(t, const KioskDoneView(success: true, label: '데우기'));
    expect(find.text('살펴볼 게 있어요'), findsOneWidget); // 결과 띠 말은 됐어요·확인해 주세요 두 가지(평가 3차 10/18)
    final c =
        t.widget<Icon>(find.byKey(const ValueKey('status-band-icon'))).color!;
    expect(HSVColor.fromColor(c).hue, inInclusiveRange(25, 55));
    expect(find.byIcon(Icons.check), findsNothing);
  });
  testWidgets('비상 띠는 현재 보이는 풀기 안내로 안내한다', (t) async {
    await show(
        t,
        KioskEstopBanner(
            detail: "비상 버튼이 눌려 있어요 — 풀고 '해제하기'를 눌러야 다시 쓸 수 있어요",
            onRequest: noop));
    expect(find.textContaining("'해제하기'"), findsNothing);
    expect(find.textContaining('푸는 방법 보기'), findsWidgets);
  });
  testWidgets('위험 안내는 본문 21 이상 흰 글자와 채운 확인 단추다', (t) async {
    await show(t, DangerAlertOverlay(onAcknowledge: noop));
    final line = t.widget<Text>(find.text('연기나 냄새가 나면 먼저 밖으로 나가 도움을 요청하세요'));
    expect(line.style!.fontSize, greaterThanOrEqualTo(21));
    expect(line.style!.color, Colors.white);
    expect(find.byType(FilledButton), findsOneWidget);
  });
  testWidgets('큰 글씨 설명 그림은 판 전체 대신 현재 버튼만 크게 보인다', (t) async {
    await show(
        t,
        KioskPanelPicture(
            appliance: kMicrowaveAppliance,
            current: kMicrowaveAppliance.buttons.last,
            caption: '누르는 자리',
            compact: true));
    expect(find.text('10초'), findsNothing);
    expect(find.byKey(const ValueKey('panel-current')), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
