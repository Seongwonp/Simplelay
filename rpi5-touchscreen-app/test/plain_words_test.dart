// 쉬운 말 사전 회귀 시험(2026-10-17, docs/UI-개편안-2026-10-17.md §2·§3).
//
// 키오스크가 직접 쓰는 문장에 옛 이름(SimpleLay 본체·작은 팔 장치·가전 콘센트 장치·ThinQ)·'짚다'·문장 잇는 '—'가
// 다시 들어오지 않게 막는다. 서버가 보낸 문장(detail 등)은 이 시험의 대상이 아니다 — 그래서 서버 문장 없이 그린다.
// '다시 시도하지 마세요' 당부는 화면에 한 번, '다시 시도' 확인 창에만 있다.
// 수정 전 코드에서 실패하는 것을 확인했다(본체 풀이 줄·'—' 머리·확인 필요 띠 등).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/ambient.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/models/command_result.dart';
import 'package:simplelay_touchscreen/models/estop.dart';
import 'package:simplelay_touchscreen/theme/kiosk_colors.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/connection_status.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/done_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/executing_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/hold_view.dart';

/// 사전에서 뺀 말. '본체 화면'은 허용이고 'SimpleLay 본체'는 금지다.
// '확인 필요'는 뺐다(평가 16차 10/18) — 상태 칩 '확인 필요 N'(사용자 결정 10/18)과 같은 짧은 띠 말로 쓴다.
const _banned = ['SimpleLay 본체', '작은 팔 장치', '가전 콘센트', 'ThinQ', '짚', '—', '확인 불가', '해제'];

void _noop() {}

void _expectPlain(String text, String where) {
  for (final word in _banned) {
    expect(text.contains(word), isFalse, reason: "$where: '$word' — $text");
  }
}

/// 화면에 그려진 글자 전부(Text·RichText).
List<String> _drawnTexts(WidgetTester tester) => [
      for (final t in tester.widgetList<Text>(find.byType(Text)))
        t.data ?? t.textSpan?.toPlainText() ?? '',
      for (final r in tester.widgetList<RichText>(find.byType(RichText)))
        r.text.toPlainText(),
    ];

Future<void> _pump(WidgetTester tester, Widget view) async {
  tester.view.physicalSize = const Size(800, 480);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
      home: Scaffold(backgroundColor: KioskColors.bg, body: view)));
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  test('결과·정지·비상 버튼 문장 함수는 사전의 말만 쓴다', () {
    for (final r in KioskFailureReason.values) {
      _expectPlain(r.headline, '$r.headline');
      _expectPlain(r.detail('즉석밥 데워줘'), '$r.detail');
      _expectPlain(r.practiceWhy, '$r.practiceWhy');
      // 같은 경고는 화면에 한 번 — 할 일 문장에는 '다시 시도하지 마세요'가 없다.
      expect(r.detail('즉석밥 데워줘').contains('다시 시도하지'), isFalse, reason: '$r');
    }
    for (final level in [null, 'sent', 'mcu_ack', 'verified']) {
      _expectPlain(stopLevelHeadline(level), 'stop $level');
      _expectPlain(stopLevelNextStep(level), 'next $level');
    }
    for (final reason in ['motion_alarm: stall', 'motion_alarm: x', 'motion_reset', 'motion_timeout',
      'motion_not_ready', 'motion_position_mismatch', 'motion_link_error', 'motion_other']) {
      _expectPlain(motionAbortSentence(reason)!, reason);
    }
    for (final route in [null, 'physical', 'thinq']) {
      for (final mode in ['real', 'mock', 'unknown']) {
        for (final receipt in [null, 'accepted', 'unknown', 'not_dispatched']) {
          for (final c in [null, 'none', 'reported', 'press_confirmed', 'operation_confirmed',
            'state_confirmed', 'state_confirmed_unknown_before', 'already_at_target']) {
            for (final kind in ResultKind.values) {
              final label = confirmationLabel(
                  route: route, receipt: receipt, confirmation: c, kind: kind, executionMode: mode);
              if (label != null) _expectPlain(label, 'label $route/$mode/$receipt/$c');
              _expectPlain(
                  finishedMessage(kind: kind, executionMode: mode, route: route, receipt: receipt,
                      confirmation: c),
                  'finished $kind/$route/$mode/$c');
            }
          }
        }
      }
    }
    for (final o in EstopAckOutcome.values) {
      _expectPlain(EstopAckResult(o).messageFor(), '$o');
      _expectPlain(EstopAckResult(o).messageFor(powerRestore: true), '$o power');
    }
    _expectPlain(kEstopConfirmQuestion, 'estop confirm');
    _expectPlain(kEstopPowerConfirmQuestion, 'estop power confirm');
    _expectPlain(kEstopConfirmLabel, 'estop label');
    _expectPlain(kEstopPowerTitle, 'estop power title');
  });

  testWidgets('결과 화면(봐 주세요·못 했어요·정지)은 결과 한 줄 + 할 일 한 줄, 당부는 확인 창에만', (tester) async {
    for (final view in [
      KioskDoneView(
          success: false,
          label: '즉석밥 데워줘',
          executionMode: 'real',
          target: kMicrowaveAppliance,
          onRetry: _noop,
          onManual: _noop,
          onDismiss: _noop),
      const KioskDoneView(
          success: false,
          label: '',
          executionMode: 'real',
          reason: KioskFailureReason.serverLost,
          onDismiss: _noop),
      const KioskDoneView(
          success: false,
          label: '공기청정기 강풍',
          executionMode: 'real',
          route: 'thinq',
          reason: KioskFailureReason.receiptUnknown,
          onDismiss: _noop),
      const KioskDoneView(
          success: false,
          label: '즉석밥 데워줘',
          executionMode: 'real',
          reason: KioskFailureReason.stopped,
          stopLevel: 'mcu_ack',
          onDismiss: _noop),
      const KioskDoneView(
          success: true,
          label: '즉석밥 데워줘',
          executionMode: 'real',
          target: kMicrowaveAppliance,
          resultConfirmation: 'press_confirmed',
          onDismiss: _noop),
    ]) {
      await _pump(tester, view);
      for (final t in _drawnTexts(tester)) {
        _expectPlain(t, 'done ${view.reason}');
      }
      expect(find.textContaining('다시 시도하지 마세요'), findsNothing);
    }
    // 누름 보고만 받은 성공은 켜졌다고 하지 않는다 — 버튼은 다 눌렀어요 + 가전이 움직이는지 봐 주세요.
    expect(find.text('버튼은 다 눌렀어요'), findsOneWidget);
    expect(find.text('가전이 움직이는지 봐 주세요'), findsOneWidget);
    expect(find.text('가전이 켜졌어요'), findsNothing);
  });

  testWidgets('작동 중·멈췄는지 몰라요·비상 버튼 화면도 사전의 말만 쓴다', (tester) async {
    for (final view in const [
      KioskHoldView(
          appliance: kMicrowaveAppliance,
          holdState: 'hovering_stop',
          stopButton: '취소',
          executionMode: 'mock',
          elapsed: Duration(minutes: 1),
          buttonsPressed: 2,
          onStop: _noop),
      KioskHoldView(
          appliance: kMicrowaveAppliance,
          holdState: 'parked',
          stopOutcome: 'requested_unconfirmed',
          stopButton: '취소',
          executionMode: 'real',
          elapsed: Duration(minutes: 1),
          onStop: _noop,
          onClose: _noop),
      KioskHoldView(
          appliance: kMicrowaveAppliance,
          holdState: 'hovering_stop',
          executionMode: 'real',
          elapsed: Duration(minutes: 1),
          onStop: _noop,
          estopTitle: kEstopTitle),
    ]) {
      await _pump(tester, view);
      for (final t in _drawnTexts(tester)) {
        _expectPlain(t, 'hold ${view.holdState}');
      }
    }
    // 정지 단추 이름은 그대로.
    expect(find.text('정지'), findsOneWidget);
  });

  testWidgets('연습 실행 화면은 짚지 않고 누르는 연습이라고 말한다', (tester) async {
    await _pump(
        tester,
        KioskExecutingView(
          executionMode: 'mock',
          title: '즉석밥 데워줘',
          target: kMicrowaveAppliance,
          lastButtons: null,
          currentButton: '해동',
          currentAttempt: 1,
          completedSteps: 1,
          totalSteps: 2,
          verificationConfidence: null,
          verificationDetail: null,
          onStop: () {},
        ));
    for (final t in _drawnTexts(tester)) {
      _expectPlain(t, 'executing');
    }
    expect(find.text('누르는 연습 중'), findsOneWidget);
  });

  testWidgets('연결 창은 본체라고 부르고 풀이 줄을 붙이지 않는다', (tester) async {
    await _pump(
        tester,
        KioskConnectionModal(
            item: ConnectionItem.hubUnreachable,
            checking: false,
            onRecheck: () {},
            onClose: () {}));
    for (final t in _drawnTexts(tester)) {
      _expectPlain(t, 'connection');
    }
    expect(find.text('본체와 연결되지 않았어요'), findsOneWidget);
    expect(find.text('다시 연결해 보기'), findsOneWidget);
    expect(find.textContaining('상자예요'), findsNothing);
  });
}
