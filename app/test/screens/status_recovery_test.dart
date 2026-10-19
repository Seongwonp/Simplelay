// 실패·확인 못 함 결과는 할 일 한 가지를 먼저 크게(심사 의견 2026-10-19, HW는 동작한다고 보고).
//
// 가전 불빛·누름 장치 자리·손으로 누르기를 한꺼번에 말하면 눈이 어둡거나 나이 든 사용자에게 많았다. 본 사실 한 문장 → 할 일
// 하나(크게) → 다시 하기 전 주의(늘 보임) → 나머지는 '더 볼 것' 뒤. 결과 문장의 말은 버리지 않고, 화면 읽기는 전부 듣는다.
// 볼 것은 키오스크 순서 안내 첫 줄과 같다('가전 화면이 바뀌었는지'), 말투는 폰 규칙('집에서 확인').
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay/models/command_result.dart';
import 'package:simplelay/models/execution_status.dart';
import 'package:simplelay/screens/status_screen.dart';
import 'package:simplelay/theme/app_tokens.dart';

import '../helpers/test_helpers.dart';

Future<void> _pump(WidgetTester tester, ExecutionStatus status) async {
  tester.view.physicalSize = const Size(400, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(buildScreen(const StatusScreen(), executionStatus: status));
  await tester.pump();
}

String _action(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('status-next-action'))).semanticsLabel!;

void main() {
  final safetyMessage = finishedMessage(kind: ResultKind.safetyStop, executionMode: 'real');
  final safetyStop = ExecutionStatus(
    phase: ExecutionPhase.failed,
    label: '즉석밥 데우기',
    outcome: 'safety_stop',
    executionMode: 'real',
    message: safetyMessage,
  );

  testWidgets('눌렸는지 몰라 멈춤 — 본 사실 한 문장, 할 일 하나를 크게, 다시 하기 주의는 늘 보인다', (tester) async {
    await _pump(tester, safetyStop);
    expect(findPlainText('눌렸는지 몰라서 멈췄어요.'), findsOneWidget);
    expect(_action(tester), kPressFirstCheck);
    expect(kPressFirstCheck, contains('가전 화면이 바뀌었는지')); // 키오스크 첫 줄과 같은 볼 것
    expect(kPressFirstCheck, contains('집에서'));
    final action = tester.widget<Text>(find.byKey(const Key('status-next-action')));
    expect(action.style?.fontSize, AppFont.tabTitle);
    // 다시 하기에 걸린 주의는 접지 않는다.
    expect(findPlainText('$kDontRetryIfOn.'), findsOneWidget);
    expect(findPlainText('다시 하기 전에 집에서 가전을 확인해야 해요.'), findsOneWidget);
    // 결과 문장 전체를 한 덩어리로 늘어놓지 않는다.
    expect(findPlainText(safetyMessage), findsNothing);
  });

  testWidgets('화면 읽기는 결과 문장 전부와 할 일을 듣는다', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pump(tester, safetyStop);
    expect(find.bySemanticsLabel(RegExp(RegExp.escape(kDontRetryIfOn))), findsWidgets);
    expect(find.bySemanticsLabel(RegExp(RegExp.escape(kPressFirstCheck))), findsWidgets);
    semantics.dispose();
  });

  testWidgets('그 밖의 확인할 것(서버 근거 줄)은 더 볼 것 뒤에 접혀 있다가 펴진다', (tester) async {
    await _pump(
      tester,
      ExecutionStatus(
        phase: ExecutionPhase.failed,
        label: '즉석밥 데우기',
        outcome: 'failed',
        receipt: 'accepted',
        executionMode: 'real',
        detail: '시작 버튼을 세 번 눌러 봤어요',
        message: finishedMessage(kind: ResultKind.failed, executionMode: 'real', receipt: 'accepted'),
      ),
    );
    expect(findPlainText('끝까지 하지 못했어요.'), findsOneWidget);
    expect(_action(tester), kPressFirstCheck);
    // 할 일 줄이 이미 말한 '집에서 가전을 확인'은 또 두지 않는다.
    expect(findPlainText('집에서 가전을 확인해야 해요.'), findsNothing);
    expect(findPlainText('시작 버튼을 세 번 눌러 봤어요'), findsNothing);
    final more = find.byKey(const Key('status-more-checks'));
    expect(tester.getSize(more).height, greaterThanOrEqualTo(48));
    expect(findPlainText('더 볼 것 1가지'), findsOneWidget);
    await tester.tap(more);
    await tester.pump();
    expect(findPlainText('시작 버튼을 세 번 눌러 봤어요'), findsOneWidget);
  });

  testWidgets('누름 장치가 걸려 멈춤 — 할 일은 가전과 누름 장치, 다시 누르지 않았다는 말은 보인다', (tester) async {
    await _pump(
      tester,
      ExecutionStatus(
        phase: ExecutionPhase.failed,
        label: '즉석밥 데우기',
        outcome: 'safety_stop',
        executionMode: 'real',
        abortReason: 'motion_alarm: stall',
        message: finishedMessage(
            kind: ResultKind.safetyStop, executionMode: 'real', abortReason: 'motion_alarm: stall'),
      ),
    );
    expect(findPlainText('누름 장치가 움직이지 못해 멈췄어요.'), findsOneWidget);
    expect(_action(tester), kMotionAbortCheck);
    expect(findPlainText('다시 누르지 않았어요.'), findsOneWidget);
    expect(find.byKey(const Key('status-more-checks')), findsNothing);
  });

  testWidgets('LG 가전 확인 못 함 — 할 일은 집에서 가전을 직접, 다시 보내기 주의는 보인다', (tester) async {
    await _pump(
      tester,
      ExecutionStatus(
        phase: ExecutionPhase.unconfirmed,
        label: '공기청정기 켜기',
        outcome: 'unconfirmed',
        route: 'thinq',
        receipt: 'unknown',
        executionMode: 'real',
        message: unconfirmedSentence(receipt: 'unknown'),
      ),
    );
    expect(findPlainText('보냈지만 가전이 받았는지 몰라요.'), findsOneWidget);
    expect(_action(tester), kThinqFirstCheck);
    expect(findPlainText('다시 보내기 전에 집에서 가전을 확인해야 해요.'), findsOneWidget);
  });

  testWidgets('시작 못 함·보내지 못함·사용자 정지·연습은 종전대로 한 문장', (tester) async {
    for (final s in [
      const ExecutionStatus(
          phase: ExecutionPhase.failed, label: '즉석밥', message: '실행을 시작하지 못했어요. 연결 상태를 확인하고 다시 시도해 주세요.'),
      ExecutionStatus(
          phase: ExecutionPhase.failed,
          label: '즉석밥',
          outcome: 'failed',
          receipt: 'not_dispatched',
          executionMode: 'real',
          message: finishedMessage(kind: ResultKind.failed, executionMode: 'real', receipt: 'not_dispatched')),
      ExecutionStatus(
          phase: ExecutionPhase.failed,
          label: '즉석밥',
          outcome: 'stopped',
          executionMode: 'real',
          message: finishedMessage(kind: ResultKind.stopped, executionMode: 'real', stopLevel: 'sent')),
      ExecutionStatus(
          phase: ExecutionPhase.failed,
          label: '즉석밥',
          outcome: 'safety_stop',
          executionMode: 'mock',
          message: finishedMessage(kind: ResultKind.safetyStop, executionMode: 'mock')),
    ]) {
      await tester.pumpWidget(const SizedBox.shrink()); // 앞 화면의 ProviderScope를 비운다
      await _pump(tester, s);
      expect(find.byKey(const Key('status-next-action')), findsNothing, reason: s.message);
      expect(findPlainText(s.message!), findsOneWidget, reason: s.message);
      expect(find.byKey(const Key('status-more-checks')), findsNothing);
    }
  });
}
