// 독립 휴리스틱 평가(닐슨 10원칙, 10/18)와 2차 독립 평가(어르신 첫 사용 과업 걷기, 10/18)에서 나온 키오스크 문제 — 단정 시험.
//
// 1. 실패·모름 결과의 단추 위계: 가장 큰 흰 단추가 '처음 화면으로'라 해결 없이 나갔다. → 모름 결과는 '가전을 보고 알려 주세요'
//    두 개의 대등한 큰 단추('움직였어요 / 안 움직였어요', LG 가전 '켜졌어요 / 안 켜졌어요'), '처음 화면으로'는 보조(테두리).
//    '한 번 더 하기'는 '안 …'이라고 답한 뒤에만, 확인 창을 거쳐서(R1). 정지 미확인은 정지가 주인공, 처음 화면은 보조.
//    확실한 실패는 다시 하는 것이 안전할 때만 '한 번 더 하기'가 주. 버튼 누름 보고만(C)도 같은 흐름 — 자동으로 닫지 않는다.
// 2. 비상 띠 전체가 누르는 자리, '푸는 방법 보기'는 보조 단추 높이·본문 글자. 문제 칩 둘째 줄 본문 글자. 가전 타일 상태 본문 글자.
// 3. '멈추는 중'에 돌아가는 표시와 기다림 상한(kiosk_screen이 실제로 끊는 시간).
// 4. 직접 누르기 — 빈 칸은 점선, 판 위 '○○ 버튼 자리 그대로예요', 확인 창 '누름 장치가 ○○ □□ 버튼을 눌러요'.
// 5. 메뉴의 '사용 방법' 세 장.
// 6. LG 가전 타일에 누름 장치의 손가락 '준비됐어요'를 쓰지 않는다. 연습 가전은 연습 색.
// 7. 누름 장치 실행 화면은 그림이 없거나 큰 글씨여도 '화면은 누르지 않아도 돼요'.
// A. 실제 LG 가전 상세에는 연습 문구가 나오지 않는다(가전별 실행 환경 값이 mock일 때만).
// B. 건너뛴 다음 루틴은 머리말에 '오늘은 안 해요'.
// D. 연습이 끝난 대기의 정지는 흐리게 + '이미 끝났어요'. 실제 대기의 정지는 그대로.
// E. LG 가전 확인 못 함 순서 안내에 '휴대폰 앱'이 없다.
// F. 세탁기 '휴대폰으로 시작할 수 있어요'.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/ambient.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/models/thinq.dart';
import 'package:simplelay_touchscreen/screens/kiosk_screen.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/theme/kiosk_colors.dart';
import 'package:simplelay_touchscreen/theme/kiosk_tokens.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/appliance_strip.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/done_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/estop_banner.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/executing_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/hold_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_top.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/kiosk_timings.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/manual_view.dart';

import 'kiosk_phase_test.dart' show FakeKioskApi, FakeTts, FakeEventStream;
import 'support/idle_menu.dart';

final _microwave = applianceFromServerJson({
  'id': 'microwave',
  'name': '전자레인지',
  'category': 'microwave',
  'rows': 2,
  'cols': 2,
  'buttons': [
    {'id': 'BT-1', 'label': '즉석밥', 'x': 0, 'y': 0},
    {'id': 'BT-2', 'label': '시작', 'x': 1, 'y': 0},
    {'id': 'BT-3', 'label': '취소', 'x': 1, 'y': 1},
  ],
  'can_execute': true,
  'readiness': 'operable',
});

ApplianceMap _thinq(String id, String name, String category) => applianceFromServerJson({
      'id': id,
      'name': name,
      'category': category,
      'rows': 0,
      'cols': 0,
      'buttons': <dynamic>[],
      'control_path': 'thinq',
      'can_execute': true,
      'readiness': 'operable',
    });

final _purifier = _thinq('air_purifier', '공기청정기', 'air_purifier');
final _practiceWasher = _thinq('thinq_washer', 'LG 세탁기(연습)', 'washing_machine');

void _viewport(WidgetTester tester, {Size size = const Size(800, 480)}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _pump(WidgetTester tester, Widget child, {double textScale = 1.0}) async {
  _viewport(tester);
  await tester.pumpWidget(MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(size: const Size(800, 480), textScaler: TextScaler.linear(textScale)),
      child: Scaffold(backgroundColor: KioskColors.bg, body: child),
    ),
  ));
  await tester.pump();
}

/// 보조(테두리) 단추인가 — 채움 단추(ElevatedButton)가 아니다.
bool _isOutlined(WidgetTester tester, String key) =>
    tester.widget(find.byKey(ValueKey(key))) is OutlinedButton;

String _plain(WidgetTester tester, Finder f) => tester
    .widgetList<RichText>(find.descendant(of: f, matching: find.byType(RichText)))
    .map((r) => r.text.toPlainText())
    .join()
    .replaceAll('⁠', '')
    .replaceAll(' ', ' ');

void main() {
  tearDown(() => KioskColors.setHighContrast(false));

  group('1. 모름 결과 — 가전을 보고 알려 주세요', () {
    testWidgets('눌렸는지 모름: 대등한 큰 두 단추, 처음 화면은 보조, 재시도는 처음에 없다', (tester) async {
      await _pump(
          tester,
          KioskDoneView(
            success: false,
            executionMode: 'real',
            label: '즉석밥 데워줘',
            target: _microwave,
            onRetry: () {},
            onManual: () {},
            onDismiss: () {},
          ));
      final yes = find.byKey(const ValueKey('done-check-yes'));
      final no = find.byKey(const ValueKey('done-check-no'));
      expect(yes, findsOneWidget);
      expect(no, findsOneWidget);
      // 무엇을 보면 되는지 말한다(첫 사용 검토 10/19 #11) — '움직였나요?'는 '30초'만 누른 뒤처럼 화면·불빛·소리만 바뀌는 때에 헷갈렸다.
      expect(_plain(tester, yes), contains('바뀌었어요'));
      expect(_plain(tester, no), contains('안 바뀌었어요'));
      // 같은 크기 — 어느 쪽도 먼저 눌리게 하지 않는다.
      expect(tester.getSize(yes), tester.getSize(no));
      expect(tester.getSize(yes).height, greaterThanOrEqualTo(KioskSizes.primaryButton));
      // '처음 화면으로'는 보조 모양(테두리)이고 두 단추보다 낮다.
      expect(_isOutlined(tester, 'done-home'), isTrue);
      expect(tester.getSize(find.byKey(const ValueKey('done-home'))).height,
          lessThan(tester.getSize(yes).height));
      // 다시 누르기는 답하기 전에는 없다(R1). 누름 장치로 골라 누르기도 두지 않는다.
      expect(find.byKey(const ValueKey('done-retry')), findsNothing);
      expect(find.byKey(const ValueKey('done-manual')), findsNothing);
      expect(_plain(tester, find.byKey(const ValueKey('done-check-prompt'))), contains('전자레인지 화면·불빛·소리가 바뀌었나요?'));
    });

    testWidgets("'안 움직였어요' → '손으로 할게요'가 앞, '한 번 더 하기'는 확인 창(같은 버튼 경고)", (tester) async {
      var retried = 0;
      bool? answered;
      await _pump(
          tester,
          KioskDoneView(
            success: false,
            executionMode: 'real',
            label: '즉석밥 데워줘',
            target: _microwave,
            onRetry: () => retried++,
            onDismiss: () {},
            onChecked: (v) => answered = v,
          ));
      await tester.tap(find.byKey(const ValueKey('done-check-no')));
      await tester.pump();
      expect(_plain(tester, find.byKey(const ValueKey('done-check-prompt'))), contains('가전이 안 바뀌었다고'));
      final hand = find.byKey(const ValueKey('done-check-hand'));
      final retry = find.byKey(const ValueKey('done-retry'));
      expect(hand, findsOneWidget);
      expect(retry, findsOneWidget);
      // '손으로 할게요'가 왼쪽(먼저 읽히는 자리), 크기는 같다.
      expect(tester.getTopLeft(hand).dx, lessThan(tester.getTopLeft(retry).dx));
      expect(tester.getSize(hand), tester.getSize(retry));
      await tester.tap(retry);
      await tester.pumpAndSettle();
      // 버튼 성질을 모르면(behavior 없음 → unknown) 토글과 같은 경고 — 두 번 누르면 되돌아갈 수 있다(검토 10/19 #5).
      expect(find.text('$kRetryToggleWarning. 같은 버튼이 한 번 더 눌려요.'), findsOneWidget);
      expect(retried, 0); // 창에서 '네'를 누르기 전에는 보내지 않는다
      await tester.tap(find.text('네, 한 번 더 하기'));
      await tester.pumpAndSettle();
      expect(retried, 1);
      expect(answered, isNull);
      await tester.tap(hand);
      await tester.pump();
      expect(answered, isFalse);
    });

    testWidgets("'움직였어요'는 사람 확인으로 답한다", (tester) async {
      bool? answered;
      await _pump(
          tester,
          KioskDoneView(
              success: false,
              executionMode: 'real',
              label: '즉석밥 데워줘',
              target: _microwave,
              onDismiss: () {},
              onChecked: (v) => answered = v));
      await tester.tap(find.byKey(const ValueKey('done-check-yes')));
      await tester.pump();
      expect(answered, isTrue);
    });

    testWidgets("LG 가전 켜졌는지 모름(결과 창) — '켜졌어요 / 안 켜졌어요', 처음 화면은 보조", (tester) async {
      await _pump(
          tester,
          KioskDoneView(
            success: false,
            executionMode: 'real',
            label: '공기청정기를 켤까요?',
            thinqActionText: '공기청정기 켜기',
            target: _purifier,
            reason: KioskFailureReason.unconfirmed,
            route: 'thinq',
            thinqOnly: true,
            onDismiss: () {},
          ));
      expect(find.byKey(const ValueKey('thinq-result')), findsOneWidget);
      expect(_plain(tester, find.byKey(const ValueKey('done-check-yes'))), contains('켜졌어요'));
      expect(_plain(tester, find.byKey(const ValueKey('done-check-no'))), contains('안 켜졌어요'));
      expect(_isOutlined(tester, 'thinq-result-close'), isTrue);
    });

    testWidgets('누름 장치가 멈췄는지 모름 — 다시 멈추기(정지 자리)가 주, 처음 화면은 보조', (tester) async {
      await _pump(
          tester,
          KioskDoneView(
            success: false,
            executionMode: 'real',
            label: '즉석밥 데워줘',
            target: _microwave,
            reason: KioskFailureReason.stopped,
            stopLevel: 'sent',
            onRetry: () {},
            onManual: () {},
            onStopAgain: () {},
            onDismiss: () {},
          ));
      expect(find.byKey(const ValueKey('done-stop-again')), findsOneWidget);
      expect(find.byKey(const ValueKey('done-check-yes')), findsNothing);
      expect(_isOutlined(tester, 'done-home'), isTrue);
    });

    testWidgets('정지 대기 화면 정지 미확인 — 처음 화면은 보조(테두리)', (tester) async {
      await _pump(
          tester,
          const KioskHoldView(
            appliance: kMicrowaveAppliance,
            holdState: 'parked',
            stopOutcome: 'requested_unconfirmed',
            stopButton: '취소',
            executionMode: 'real',
            elapsed: Duration(minutes: 1),
            onStop: _noop,
            onClose: _noop,
          ));
      expect(_isOutlined(tester, 'hold-home'), isTrue);
      expect(tester.widget<ElevatedButton>(find.byKey(const ValueKey('hold-stop'))).onPressed, isNotNull);
    });

    testWidgets('확실한 실패(LG 가전이 거절) — 다시 하는 것이 안전해 한 번 더 하기가 주, 처음 화면은 보조', (tester) async {
      await _pump(
          tester,
          KioskDoneView(
            success: false,
            executionMode: 'real',
            label: '바람 세게',
            target: _purifier,
            reason: KioskFailureReason.notExecuted,
            route: 'thinq',
            onRetry: () {},
            onDismiss: () {},
          ));
      expect(tester.widget(find.byKey(const ValueKey('done-retry'))), isA<ElevatedButton>());
      expect(_isOutlined(tester, 'done-home'), isTrue);
      expect(find.byKey(const ValueKey('done-check-yes')), findsNothing);
    });

    testWidgets('버튼 누름 보고만(C) — 두 단추 흐름, 자동 복귀 말 없음', (tester) async {
      await _pump(
          tester,
          KioskDoneView(
            success: true,
            executionMode: 'real',
            resultConfirmation: 'reported',
            label: '즉석밥 데워줘',
            target: _microwave,
            onDismiss: () {},
          ));
      expect(find.byKey(const ValueKey('done-check-yes')), findsOneWidget);
      expect(find.byKey(const ValueKey('done-auto-return')), findsNothing);
      expect(find.textContaining('뒤 처음 화면으로 돌아가요'), findsNothing);
    });

    test('확인한 성공·연습·사용자 정지에는 사람 확인 흐름이 없다', () {
      expect(
          KioskDoneView(
                  success: true,
                  executionMode: 'real',
                  label: '즉석밥',
                  target: _microwave,
                  operationConfirmed: true,
                  operationSource: 'real')
              .personCheck,
          isNull);
      expect(KioskDoneView(success: false, executionMode: 'mock', label: '즉석밥').personCheck, isNull);
      expect(
          KioskDoneView(
                  success: false,
                  executionMode: 'real',
                  label: '즉석밥',
                  reason: KioskFailureReason.stopped,
                  stopLevel: 'sent')
              .personCheck,
          isNull);
      expect(
          KioskDoneView(
                  success: true,
                  executionMode: 'real',
                  label: '공기청정기 켜기',
                  route: 'thinq',
                  thinqOnly: true,
                  target: _purifier,
                  resultConfirmation: 'state_confirmed')
              .personCheck,
          isNull);
      // 버튼 누름 보고만은 답하지 않고 나가면 처음 화면에 남는다.
      expect(
          KioskDoneView(success: true, executionMode: 'real', label: '즉석밥', resultConfirmation: 'reported')
              .pastHeadline,
          kPressDonePastHeadline);
    });

    testWidgets('키오스크 화면: 답하면 처음 화면에 지난 일이 남지 않고, 답하지 않고 나가면 남는다. 누름 보고만은 자동으로 닫지 않는다',
        (tester) async {
      _viewport(tester);
      final api = FakeKioskApi()
        ..applianceList = [_microwave]
        ..statusResult = const KioskStatus(running: false, lastJobId: 'job-0', lastOutcome: 'success');
      await tester.pumpWidget(MaterialApp(
        home: KioskScreen(api: api, tts: FakeTts(), events: FakeEventStream()),
      ));
      await tester.pump();
      await tester.pump();
      Future<void> result(String job, {required bool ok}) async {
        api.statusResult = KioskStatus(
            running: false,
            lastJobId: job,
            lastApplianceId: 'microwave',
            lastOutcome: ok ? 'success' : 'failed',
            lastStatus: ok ? 'succeeded' : 'failed',
            lastExecutionMode: 'real',
            lastConfirmation: ok ? 'reported' : null);
        await tester.pump(const Duration(seconds: 2));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 900));
        expect(find.byType(KioskDoneView), findsOneWidget);
      }

      // 답함 → 지난 일 없음.
      await result('job-2', ok: false);
      await tester.tap(find.byKey(const ValueKey('done-check-yes')));
      await tester.pump();
      expect(find.byType(KioskDoneView), findsNothing);
      expect(find.byKey(const ValueKey('idle-past-result')), findsNothing);
      final checks = (tester.state(find.byType(KioskScreen)) as dynamic).personChecks as List;
      expect(checks, hasLength(1));
      expect((checks.single as dynamic).worked, isTrue);

      // 누름 보고만 — 오래 두어도 닫지 않는다, 답하지 않고 나가면 지난 일이 남는다.
      await result('job-3', ok: true);
      await tester.pump(KioskTimings.doneReturnLarge + const Duration(seconds: 5));
      expect(find.byType(KioskDoneView), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('done-home')));
      await tester.pump();
      expect(find.byKey(const ValueKey('idle-past-result')), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const ValueKey('idle-past-result-text'))).data,
          endsWith(kPressDonePastHeadline));
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('2. 비상·연결 안내 단추 크기', () {
    testWidgets("비상 띠 전체가 누르는 자리, '푸는 방법 보기'는 보조 단추 높이·본문 글자", (tester) async {
      var opened = 0;
      await _pump(
          tester,
          KioskEstopLayout(
            banner: KioskEstopBanner(detail: '비상 버튼이 눌려 있어요', onRequest: () => opened++),
            child: const SizedBox.expand(),
          ));
      final ack = find.byKey(const ValueKey('estop-ack'));
      expect(tester.getSize(ack).height, greaterThanOrEqualTo(KioskSizes.secondaryButton));
      final label = tester.widget<Text>(find.descendant(of: ack, matching: find.byType(Text)));
      expect(label.style!.fontSize, KioskType.body);
      // 띠 왼쪽(제목 글자)을 눌러도 안내가 열린다.
      await tester.tapAt(tester.getTopLeft(find.byKey(const ValueKey('estop-banner'))) + const Offset(60, 20));
      await tester.pump();
      expect(opened, 1);
    });

    testWidgets('연결 문제 줄 — 제목은 상태 글자, 해결 방법 단추는 본문 글자(결선 모의 평가 10/18)', (tester) async {
      await _pump(
          tester,
          KioskIdleStatusChip(
            items: const [
              ConnectionItem(id: 'network', state: 'ok', title: '', message: ''),
              ConnectionItem(id: 'press', state: 'error', title: '누름 장치와 연결이 끊겼어요', message: ''),
            ],
            onTap: () {},
          ));
      final help = tester.widget<Text>(find.byKey(const ValueKey('idle-problem-help-text')));
      expect(help.style!.fontSize, KioskType.body);
      final cause = tester.widget<Text>(find.byKey(const ValueKey('idle-problem-cause')));
      expect(cause.style!.fontSize, KioskType.status);
    });

    // 사용자 결정(10/19): 상태 띠 글자는 없앴다 — 모르면 '?' 표시, 누르는 자리 60px 이상.
    testWidgets("가전 타일 — 준비된 누름 장치 가전은 표시도 글자도 없다", (tester) async {
      await _pump(
          tester,
          KioskIdleView(
            now: DateTime(2026, 10, 18, 9),
            connected: true,
            connections: const [],
            appliances: [_microwave],
            onSelectAppliance: (_) {},
            onOpenConnection: (_) {},
            onDndGesture: () {},
          ));
      expect(find.byKey(const ValueKey('tile-mark-microwave')), findsNothing);
      expect(find.text('준비됐어요'), findsNothing);
    });
  });

  group('3. 멈추는 중', () {
    testWidgets('돌아가는 표시와 기다림 상한(실제 끊는 시간), 정지를 다시 누르지 않아도 된다는 말', (tester) async {
      await _pump(
          tester,
          KioskDoneView(
            success: false,
            executionMode: 'real',
            label: '즉석밥 데워줘',
            target: _microwave,
            reason: KioskFailureReason.stopped,
            stopPending: true,
            onDismiss: () {},
          ));
      expect(find.byKey(const ValueKey('done-pending-spinner')), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(_plain(tester, find.byKey(const ValueKey('done-next-step'))), kStopPendingDetail);
      final note = _plain(tester, find.byKey(const ValueKey('done-pending-note')));
      expect(note, contains('${KioskTimings.stopConfirmMaxWait.inSeconds}초'));
      expect(note, contains('정지를 다시 누르지 않아도 돼요'));
      // 상한은 kiosk_screen이 끊는 틱과 같다 — 1초 간격 · 세 번 묻기 · (세 번 + 2)를 넘는 틱.
      expect(KioskTimings.stopConfirmMaxWait,
          KioskTimings.stopFollowInterval * (KioskTimings.stopFollowTries + 3));
      expect(find.byKey(const ValueKey('done-home')), findsNothing);
    });
  });

  group('4. 직접 누르기 격자', () {
    testWidgets('빈 칸은 점선 빈 자리, 판 위 한 줄, 확인 창에 누름 장치가 무엇을 누르는지', (tester) async {
      await _pump(
          tester,
          KioskManualView(appliance: _microwave, onExecute: (_) {}, onCancel: () {}));
      // 2x2 판에 버튼 셋 — 빈 자리 하나(0,1).
      expect(find.byKey(const ValueKey('manual-empty-0-1')), findsOneWidget);
      expect(_plain(tester, find.byKey(const ValueKey('manual-layout-note'))), '전자레인지 버튼 자리 그대로예요');
      await tester.tap(find.byKey(const ValueKey('manual-cell-즉석밥')));
      await tester.pump();
      expect(_plain(tester, find.byKey(const ValueKey('manual-press-note'))),
          '누르면 누름 장치가 전자레인지 즉석밥 버튼을 눌러요');
    });
  });

  group('5. 사용 방법', () {
    testWidgets("메뉴에 '사용 방법' — 여섯 장(처음 화면 · 누름 장치 · LG 가전 · 정지 · 확인하지 못했어요 · 물어볼 곳), 닫기", (tester) async {
      await _pump(
          tester,
          KioskIdleView(
            now: DateTime(2026, 10, 18, 9),
            connected: true,
            connections: const [],
            appliances: [_microwave],
            onSelectAppliance: (_) {},
            onOpenConnection: (_) {},
            onDndGesture: () {},
          ));
      await tapIdleMenuItem(tester, 'help-entry');
      await tester.pump();
      expect(find.byKey(const ValueKey('help-guide')), findsOneWidget);
      String title() => _plain(tester, find.byKey(const ValueKey('help-title')));
      String body() => _plain(tester, find.byKey(const ValueKey('help-body')));
      String number() => _plain(tester, find.byKey(const ValueKey('help-page-number')));
      Future<void> next() async {
        await tester.tap(find.byKey(const ValueKey('help-next')));
        await tester.pump();
      }

      // 화면 읽기가 '/'를 이상하게 읽어 'n장 중 i장'(R11).
      expect(number(), '사용 방법 6장 중 1장');
      expect(title(), contains('처음 화면'));
      expect(body(), contains("'메뉴'"));
      await next();
      expect(title(), contains('누름 장치'));
      expect(body(), contains("'지금 하기'"));
      await next();
      expect(title(), contains('LG 가전'));
      await next();
      expect(title(), contains('정지'));
      // 음성 정지는 실물 확인 전이라 넣지 않는다(10/18 결정).
      expect(body(), allOf(contains('정지'), isNot(contains('말해도')), isNot(contains('멈춰'))));
      await next();
      expect(title(), contains('결과를 확인하지 못했을 때'));
      expect(body(), contains('가전 상태를 직접 확인해 주세요'));
      await next();
      expect(number(), '사용 방법 6장 중 6장');
      expect(title(), contains('가족'));
      expect(find.byKey(const ValueKey('help-next')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('help-done')));
      await tester.pump();
      expect(find.byKey(const ValueKey('help-guide')), findsNothing);
    });
  });

  group('6. LG 가전·연습 가전 타일', () {
    // 사용자 결정(10/19): 상태 띠를 없앴다 — LG 가전은 전원을 모르면 '?' 표시, 읽은 켜짐이면 표시 없음(아이콘 강조색).
    test("LG 가전은 누름 장치 가전처럼 '준비됨'으로 두지 않는다 — 모르면 '?'", () {
      expect(kioskTileIssue(_purifier)?.mark, KioskTileMark.unknown);
      expect(kioskTileIssue(_purifier, on: true), isNull);
      expect(kioskTileStateWord(_purifier, on: true), '켜져 있어요');
      // 누름 장치 가전 준비됨은 표시 없음.
      expect(kioskTileIssue(_microwave), isNull);
    });

    test("연습 가전 — 전원을 읽었으면 표시 없음, 모르면 '?'", () {
      expect(kioskTileIssue(_practiceWasher)?.mark, KioskTileMark.unknown);
      expect(kioskTileIssue(_practiceWasher, on: true), isNull);
      expect(kioskTileStateWord(_practiceWasher, on: true), '켜져 있어요');
    });

    testWidgets('처음 화면 연습 세탁기 타일에 손가락 아이콘이 없다', (tester) async {
      await _pump(
          tester,
          KioskIdleView(
            now: DateTime(2026, 10, 18, 9),
            connected: true,
            connections: const [],
            appliances: [_purifier, _microwave, _practiceWasher],
            onSelectAppliance: (_) {},
            onOpenConnection: (_) {},
            onDndGesture: () {},
          ));
      for (final id in ['thinq_washer', 'air_purifier']) {
        expect(
            find.descendant(
                of: find.byKey(ValueKey('strip-$id')), matching: find.byIcon(Icons.touch_app_outlined)),
            findsNothing,
            reason: id);
      }
    });
  });

  group("7. '화면은 누르지 않아도 돼요'가 누름 장치 실행 화면 모두 같은 자리에", () {
    KioskExecutingView exec({ApplianceMap? target, String? button}) => KioskExecutingView(
          title: '즉석밥 데워줘',
          target: target,
          executionMode: 'real',
          lastButtons: null,
          currentButton: button,
          currentAttempt: 1,
          completedSteps: 0,
          totalSteps: 2,
          verificationConfidence: null,
          verificationDetail: null,
          onStop: () {},
        );

    testWidgets('버튼판 그림이 없을 때(대상을 모름)', (tester) async {
      await _pump(tester, exec(target: null, button: '즉석밥'));
      expect(find.textContaining('화면은 누르지 않아도 돼요'), findsOneWidget);
    });

    testWidgets('지금 버튼이 판에 없을 때', (tester) async {
      await _pump(tester, exec(target: _microwave, button: '해동'));
      expect(find.textContaining('화면은 누르지 않아도 돼요'), findsOneWidget);
    });

    testWidgets('큰 글씨(줄인 그림)', (tester) async {
      await _pump(tester, exec(target: _microwave, button: '즉석밥'), textScale: 1.22);
      expect(find.byKey(const ValueKey('panel-no-press')), findsOneWidget);
    });
  });

  group('A. 실제 LG 가전 상세에 연습 문구가 나오지 않는다', () {
    Widget detail(ApplianceMap a, String mode) => KioskManualView(
          appliance: a,
          onExecute: (_) {},
          onCancel: () {},
          thinqRead: () async => KioskThinqStatus(
            executionMode: mode,
            readAt: DateTime(2026, 10, 18, 9, 7),
            state: const {
              'operation': {'airPurifierOperationMode': 'POWER_ON'},
              'airFlow': {'windStrength': 'LOW'},
            },
          ),
          thinqSend: (_, __, ___) async => const KioskJobAccepted(jobId: 'j'),
          onThinqAccepted: (_, __) {},
        );

    testWidgets('실제(real) — 연습 문구·연습 배지 없음', (tester) async {
      await _pump(tester, detail(_purifier, 'real'));
      await tester.pump();
      expect(find.byKey(const ValueKey('thinq-practice')), findsNothing);
      expect(find.textContaining('연습'), findsNothing);
    });

    testWidgets('연습 가전(mock) — 연습 문구와 머리의 연습 배지', (tester) async {
      await _pump(tester, detail(_practiceWasher, 'mock'));
      await tester.pump();
      expect(find.byKey(const ValueKey('thinq-practice')), findsOneWidget);
      expect(find.byKey(const ValueKey('manual-practice-badge')), findsOneWidget);
      expect(find.text('LG 세탁기(연습)'), findsNothing); // 이름의 '(연습)'은 배지가 말한다
    });
  });

  group('B. 건너뛴 다음 루틴', () {
    testWidgets("머리말에 '오늘은 안 해요' — 시각·이름은 남는다", (tester) async {
      await _pump(
          tester,
          KioskIdleView(
            now: DateTime(2026, 9, 30, 7, 38),
            connected: true,
            connections: const [],
            appliances: [_microwave],
            nextRun: const KioskNextRun(
              name: '저녁 공기청정기 켜기',
              dayLabel: '오늘',
              hhmm: '22:00',
              modeLabel: '자동 실행',
              routineId: 'rt',
              at: '2026-09-30T22:00:00+09:00',
              skipped: true,
              skipLabel: '오늘은 건너뛰어요',
              skipActionLabel: '오늘은 건너뛰기',
            ),
            onToggleNextRunSkip: (_) {},
            onSelectAppliance: (_) {},
            onOpenConnection: (_) {},
            onDndGesture: () {},
          ));
      expect(tester.widget<Text>(find.byKey(const ValueKey('idle-next-run-skipped-head'))).data, '오늘은 안 해요');
      expect(find.byKey(const ValueKey('idle-next-run-text')), findsOneWidget);
    });

    test('건너뛰지 않았거나 조용한 시간 건너뜀이면 없다', () {
      expect(
          const KioskNextRun(name: 'a', dayLabel: '내일', hhmm: '07:00', modeLabel: '', skipped: true).skippedHead,
          '내일은 안 해요');
      expect(const KioskNextRun(name: 'a', dayLabel: '오늘', hhmm: '07:00', modeLabel: '').skippedHead, isNull);
      expect(
          const KioskNextRun(name: 'a', dayLabel: '오늘', hhmm: '07:00', modeLabel: '', skipped: true, quietSkip: true)
              .skippedHead,
          isNull);
    });
  });

  group('D. 연습이 끝난 대기', () {
    testWidgets("정지는 흐리게(못 누름) + '이미 끝났어요'", (tester) async {
      await _pump(
          tester,
          const KioskHoldView(
            appliance: kMicrowaveAppliance,
            holdState: 'hovering_stop',
            stopButton: '취소',
            executionMode: 'mock',
            elapsed: Duration(minutes: 1),
            onStop: _noop,
            onClose: _noop,
          ));
      expect(tester.widget<ElevatedButton>(find.byKey(const ValueKey('hold-stop'))).onPressed, isNull);
      expect(find.byKey(const ValueKey('hold-practice-done-note')), findsOneWidget);
      expect(find.byKey(const ValueKey('kiosk-stop-area')), findsOneWidget); // 자리는 그대로
    });

    testWidgets('실제 가전 대기의 정지는 그대로 누를 수 있다', (tester) async {
      await _pump(
          tester,
          const KioskHoldView(
            appliance: kMicrowaveAppliance,
            holdState: 'hovering_stop',
            stopButton: '취소',
            executionMode: 'real',
            elapsed: Duration(minutes: 1),
            onStop: _noop,
          ));
      expect(tester.widget<ElevatedButton>(find.byKey(const ValueKey('hold-stop'))).onPressed, isNotNull);
      expect(find.byKey(const ValueKey('hold-practice-done-note')), findsNothing);
    });
  });

  test("E. LG 가전 확인 못 함 안내에 '휴대폰 앱'이 없다 — 가전을 직접 보고, 모르면 가족에게", () {
    expect(kThinqRecoverySteps.any((s) => s.contains('휴대폰')), isFalse);
    expect(kThinqRecoverySteps.first, contains('직접'));
    expect(kThinqRecoverySteps.last, contains('가족'));
  });

  test("F. 세탁기 원격 시작 — '휴대폰으로 시작할 수 있어요'", () {
    final rows = thinqStateRows({
      'remoteControlEnable': {'remoteControlEnabled': true},
    });
    final r = rows.single;
    expect('${r.label} ${r.value}', '휴대폰으로 시작할 수 있어요');
  });
}

void _noop() {}

/// 같은 버튼 재누름 경고(종전 정책 그대로, R1).
const kDontRetryIfOnText = '가전이 이미 움직이고 있으면 한 번 더 하지 마세요. 같은 버튼이 한 번 더 눌려요';
