// 평가 8차(2026-10-18) 지적 수리 — 키오스크. 옛 코드에도 있는 공개 구성(+ 새 선택 인자)만 써서 옛 코드에서 실패하는 것을 확인한다.
//
// 1. 결과 화면의 정지 — '멈추는 중이에요'(진행 중 말)를 끝난 화면에 쓰지 않는다. 결과는 '누름 장치가 멈췄어요'(엔코더 확인,
//    verified) 또는 '누름 장치가 멈췄는지 확인하지 못했어요'(그 밖) 둘뿐. 정지 확인을 아직 기다리는 동안(stopPending)만 진행 상태로
//    '멈추는 중이에요'를 보이고 처음 화면 단추를 숨긴다.
// 2. 정지 미확인 대기 — 오른쪽 버튼판은 '실제 가전에서 눌러 주세요' + 취소 칸 주의색. '누름 장치가 … 대신 눌렀어요' 대신
//    '누름 장치도 … 눌렀지만 눌렸는지 확인이 안 됐어요'.
// 3. 결과 화면 보조 단추 — '화면에서 직접 누르기'는 손으로 가전을 누르라는 말과 헷갈렸다 → '누름 장치로 골라 누르기'.
// 4. 문구 통일 — 잠시 쉬기 설명 하나(새 제안과 자동으로 하는 일), 실행 화면 누를 순서에 머리말·끝낸 칸 이름 자리,
//    결과 화면 할 일 줄은 마침표 없이.
// 5. 제안 질문 — 사람 명령문('즉석밥 데워줘')이 아니라 할 일 이름('즉석밥 데우기, 지금 할까요?').
// 6. 내 가전 화면의 내 루틴 카드 — 누르면 한다는 표시 '지금 하기 ›'.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/ambient.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/theme/kiosk_colors.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/done_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/executing_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/hold_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/manual_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/panel_picture.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/suggestion_view.dart';

Future<void> _pump(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(800, 480);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: MediaQuery(
      data: const MediaQueryData(size: Size(800, 480)),
      child: Scaffold(backgroundColor: KioskColors.bg, body: child),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 300));
}

void _noop() {}

/// 화면에 보이는 글 전부(Text·RichText). 낱말 묶음 문자(U+2060·U+00A0)는 뗀다.
List<String> _texts(WidgetTester tester) => [
      for (final w in tester.widgetList<RichText>(find.byType(RichText)))
        w.text.toPlainText().replaceAll('⁠', '').replaceAll(' ', ' '),
    ];

KioskDoneView _stopped(String? level, {String mode = 'real', bool pending = false}) => KioskDoneView(
      success: false,
      label: '즉석밥 데워줘',
      target: kMicrowaveAppliance,
      executionMode: mode,
      reason: KioskFailureReason.stopped,
      stopLevel: level,
      stopPending: pending,
      onRetry: _noop,
      onManual: _noop,
      onDismiss: _noop,
    );

void main() {
  testWidgets('연습 중 비상정지는 실제 가전 취소를 누르게 안내하지 않는다', (tester) async {
    await _pump(tester, const KioskHoldView(
      appliance: kMicrowaveAppliance,
      holdState: 'hovering_stop',
      stopButton: '취소',
      executionMode: 'mock',
      elapsed: Duration.zero,
      estopTitle: '비상 버튼이 눌려 있어요',
      onStop: _noop,
    ));
    final all = _texts(tester).join('\n');
    expect(all, contains('연습 중이라 실제 가전은 조작하지 않았어요'));
    expect(all, isNot(contains('취소 버튼을 손으로 눌러 주세요')));
    expect(all, isNot(contains('실제 가전에서 눌러 주세요')));
    expect(tester.widget<ElevatedButton>(find.byKey(const ValueKey('hold-stop'))).onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('연습 요청 미확인은 접수 여부 대신 전달 여부로 말한다', (tester) async {
    await _pump(tester, KioskDoneView(
      success: false,
      label: '공기청정기 켜기',
      executionMode: 'mock',
      reason: KioskFailureReason.receiptUnknown,
      onRetry: _noop,
      onManual: _noop,
      onDismiss: _noop,
    ));
    expect(_texts(tester).join('\n'), contains('연습 요청이 전달됐는지 확인하지 못했어요'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('실제 가전에서 누를 위치임을 알리고 화면 정지는 계속 사용할 수 있다', (tester) async {
    var stops = 0;
    await _pump(tester, KioskHoldView(
      appliance: kMicrowaveAppliance,
      holdState: 'parked',
      stopOutcome: 'requested_unconfirmed',
      stopButton: '취소',
      executionMode: 'real',
      elapsed: const Duration(minutes: 1),
      onStop: () => stops++,
      onClose: _noop,
    ));
    expect(_texts(tester).join('\n'), contains('실제 가전에서 눌러 주세요'));
    final picture = find.byKey(const ValueKey('panel-picture'));
    expect(find.descendant(of: picture, matching: find.byType(InkWell)), findsNothing);
    await tester.tap(find.byKey(const ValueKey('hold-stop')));
    expect(stops, 1);
    expect(tester.takeException(), isNull);
  });

  group('1. 결과 화면의 정지 — 멈췄어요 / 멈췄는지 확인하지 못했어요 둘뿐', () {
    for (final level in ['sent', 'mcu_ack', null]) {
      testWidgets('확인 안 된 정지($level)는 끝난 화면에서 "누름 장치가 멈췄는지 확인하지 못했어요", 진행 말 없음', (tester) async {
        await _pump(tester, _stopped(level));
        final all = _texts(tester).join('\n');
        expect(all, contains('누름 장치가 멈췄는지 확인하지 못했어요'));
        expect(all, isNot(contains('중이에요')));
        expect(all, isNot(contains('멈췄어요')));
        // 물음표는 위 띠가 말한다 — 순서 안내가 있으면 큰 원을 두지 않는다(평가 15차 10/18).
        expect(find.byIcon(Icons.help_outline), findsOneWidget);
        expect(find.byKey(const ValueKey('done-home')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('엔코더로 확인한 정지(verified)만 "누름 장치가 멈췄어요"', (tester) async {
      await _pump(tester, _stopped('verified'));
      final all = _texts(tester).join('\n');
      expect(all, contains('누름 장치가 멈췄어요'));
      expect(all, isNot(contains('확인하지 못했어요')));
      expect(find.byKey(const ValueKey('done-ring')), findsNothing);
    });

    testWidgets('연습 정지는 연습을 멈췄다고만 — 누름 장치가 멈췄는지 모른다고 겁주지 않는다', (tester) async {
      await _pump(tester, _stopped(null, mode: 'mock'));
      final all = _texts(tester).join('\n');
      expect(all, contains('연습을 멈췄어요'));
      expect(all, isNot(contains('중이에요')));
    });

    testWidgets('정지 확인을 아직 기다리면 진행 상태 — "멈추는 중이에요"·처음 화면 단추 없음', (tester) async {
      await _pump(tester, _stopped(null, pending: true));
      final all = _texts(tester).join('\n');
      expect(all, contains('멈추는 중이에요'));
      expect(all, isNot(contains('확인하지 못했어요')));
      expect(find.byKey(const ValueKey('done-home')), findsNothing);
      expect(find.byKey(const ValueKey('done-manual')), findsNothing);
      expect(find.byKey(const ValueKey('done-pending')), findsOneWidget);
      expect(find.byIcon(Icons.question_mark), findsNothing);
    });
  });

  group('2. 정지 미확인 대기 — 직접 누를 칸, 정직한 한 줄', () {
    testWidgets('오른쪽은 직접 누를 버튼(취소 칸 주의색), 대신 눌렀다는 단정 없음', (tester) async {
      await _pump(
          tester,
          const KioskHoldView(
            appliance: kMicrowaveAppliance,
            holdState: 'parked',
            stopOutcome: 'requested_unconfirmed',
            stopButton: '취소',
            executionMode: 'real',
            elapsed: Duration(minutes: 1, seconds: 40),
            onStop: _noop,
            onClose: _noop,
          ));
      final all = _texts(tester).join('\n');
      expect(all, contains('지금 전자레인지 취소 버튼을 손으로 눌러 주세요'));
      expect(all, contains('실제 가전에서 눌러 주세요'));
      expect(all, isNot(contains(kPanelCaption)));
      expect(all, isNot(contains('대신 눌렀어요')));
      expect(all, contains('취소 버튼이 눌렸는지 확인하지 못했어요'));
      final picture = tester.widget<KioskPanelPicture>(find.byType(KioskPanelPicture));
      expect(picture.caution, isTrue);
      expect(picture.current?.label, '취소');
      expect(find.byKey(const ValueKey('panel-current')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('3. 결과 화면 보조 단추 — 누름 장치가 누른다는 말', () {
    for (final stop in [false, true]) {
      testWidgets('${stop ? '사용자 정지' : '실패'}: "화면에서 직접 누르기" 대신 "누름 장치로 골라 누르기"', (tester) async {
        await _pump(
            tester,
            stop
                ? _stopped('verified')
                // 휴리스틱 평가(10/18): 골라 누르기는 확실히 못 한 결과(연습 실패)에 남는다 — 눌렸는지 모르면 가전을 보고 답한다.
                : const KioskDoneView(
                    success: false,
                    label: '즉석밥 데워줘',
                    target: kMicrowaveAppliance,
                    executionMode: 'mock',
                    onRetry: _noop,
                    onManual: _noop,
                    onDismiss: _noop));
        expect(find.text('화면에서 직접 누르기'), findsNothing);
        expect(
            find.descendant(
                of: find.byKey(const ValueKey('done-manual')), matching: find.text('누름 장치로 골라 누르기')),
            findsOneWidget);
      });
    }
  });

  group('4. 문구 통일', () {
    testWidgets('메뉴의 잠시 쉬기 설명은 잠시 쉬기 창과 같은 말(새 제안과 자동으로 하는 일)', (tester) async {
      await _pump(
          tester,
          KioskIdleView(
            now: DateTime(2026, 9, 30, 7, 8),
            connected: true,
            connections: const [],
            appliances: const [kMicrowaveAppliance],
            onSelectAppliance: (_) {},
            onOpenConnection: (_) {},
            onDndGesture: () {},
          ));
      await tester.tap(find.byKey(const ValueKey('idle-menu')));
      await tester.pump();
      final all = _texts(tester).join('\n');
      expect(all, contains('새 제안과 자동으로 하는 일을 잠시 쉬어요'));
      expect(all, isNot(contains('새 제안을 잠시 쉬어요')));
    });

    for (final mock in [false, true]) {
      testWidgets('실행 화면 누를 순서(${mock ? '연습' : '실제'}) — 머리말, 끝낸 칸 이름을 몰라도 빈칸이 아님', (tester) async {
        await _pump(
            tester,
            KioskExecutingView(
              executionMode: mock ? 'mock' : 'real',
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
            ));
        final trail = find.byKey(const ValueKey('exec-step-trail'));
        expect(trail, findsOneWidget);
        expect(find.descendant(of: trail, matching: find.text(mock ? '연습으로 누를 순서' : '누를 순서')),
            findsOneWidget);
        final done = find.byKey(const ValueKey('step-0-done'));
        final labels = [
          for (final w in tester.widgetList<Text>(find.descendant(of: done, matching: find.byType(Text))))
            w.data ?? '',
        ].where((s) => s.trim().isNotEmpty).toList();
        expect(labels, ['1번째']);
      });
    }

    testWidgets('실행 화면 누를 순서 — 화면이 본 이름이 있으면 그 이름', (tester) async {
      await _pump(
          tester,
          KioskExecutingView(
            title: '즉석밥 데워줘',
            target: kMicrowaveAppliance,
            lastButtons: null,
            currentButton: '시작',
            currentAttempt: 1,
            completedSteps: 1,
            doneButtons: const ['즉석밥'],
            totalSteps: 2,
            verificationConfidence: null,
            verificationDetail: null,
            onStop: () {},
          ));
      final done = find.byKey(const ValueKey('step-0-done'));
      expect(find.descendant(of: done, matching: find.text('즉석밥')), findsOneWidget);
    });

    for (final reason in KioskFailureReason.values) {
      for (final mode in ['real', 'mock']) {
        testWidgets('결과 화면 할 일 줄은 마침표 없이 — $reason $mode', (tester) async {
          await _pump(
              tester,
              KioskDoneView(
                success: false,
                label: '즉석밥 데워줘',
                target: kMicrowaveAppliance,
                executionMode: mode,
                reason: reason,
                onDismiss: _noop,
              ));
          final next = find.byKey(const ValueKey('done-next-step'));
          if (next.evaluate().isEmpty) return;
          final text = tester.widget<Text>(next).textSpan!.toPlainText().replaceAll('⁠', '').trim();
          expect(text.endsWith('.'), isFalse, reason: text);
        });
      }
    }

    test('실패 이유 문장 — 끝 마침표 없음', () {
      for (final r in KioskFailureReason.values) {
        expect(r.detail('').endsWith('.'), isFalse, reason: '$r');
        expect(r.practiceWhy.endsWith('.'), isFalse, reason: '$r');
      }
    });
  });

  group('5. 제안 질문 — 할 일 이름으로', () {
    testWidgets('"즉석밥 데워줘" → "즉석밥 데우기, 지금 할까요?"', (tester) async {
      await _pump(
          tester,
          KioskSuggestionView(
            suggestion: const KioskSuggestion(
              id: 's1',
              purpose: '즉석밥 데워줘',
              occurrences: 3,
              timeBand: '아침',
              steps: ['즉석밥', '시작'],
            ),
            target: kMicrowaveAppliance,
            cdRemaining: 20,
            cdTotal: 20,
            onApprove: () {},
            onReject: () {},
          ));
      final q = tester.widget<Text>(find.byKey(const ValueKey('suggestion-question')));
      final text = q.textSpan!.toPlainText().replaceAll('⁠', '').replaceAll(' ', ' ');
      expect(text, '즉석밥 데우기,\n지금 할까요?');
      expect(_texts(tester).join('\n'), isNot(contains('데워줘,')));
    });

    testWidgets('끝 동사를 모르는 말은 그대로 둔다(억지 변환 금지)', (tester) async {
      await _pump(
          tester,
          KioskSuggestionView(
            suggestion: const KioskSuggestion(
              id: 's2',
              purpose: '아침 준비',
              occurrences: 3,
              timeBand: '아침',
              steps: ['즉석밥', '시작'],
            ),
            target: kMicrowaveAppliance,
            cdRemaining: 20,
            cdTotal: 20,
            onApprove: () {},
            onReject: () {},
          ));
      final q = tester.widget<Text>(find.byKey(const ValueKey('suggestion-question')));
      final text = q.textSpan!.toPlainText().replaceAll('⁠', '').replaceAll(' ', ' ');
      expect(text, '아침 준비,\n지금 할까요?');
    });
  });

  group('6. 내 루틴 카드 — 누르면 한다는 표시', () {
    testWidgets('카드마다 "지금 하기 ›"', (tester) async {
      await _pump(
          tester,
          KioskManualView(
            appliance: kMicrowaveAppliance,
            onExecute: (_) {},
            onCancel: () {},
            routines: const [
              KioskRoutine(id: 'morning', name: '아침 데우기', pressCount: 3),
              KioskRoutine(id: 'evening', name: '저녁 데우기', pressCount: 4),
            ],
            onRoutine: (_) {},
          ));
      for (final id in ['morning', 'evening']) {
        final card = find.byKey(ValueKey('routine-$id'));
        final all = [
          for (final w in tester.widgetList<RichText>(find.descendant(of: card, matching: find.byType(RichText))))
            w.text.toPlainText().replaceAll('⁠', '').replaceAll(' ', ' '),
        ].join(' ');
        expect(all, contains('지금 하기 ›'), reason: id);
      }
      expect(tester.takeException(), isNull);
    });
  });
}
