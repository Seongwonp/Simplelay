// 결선 심사 모의 평가(10/18, 합의 78점)에서 나온 키오스크 문제 — 단정 시험.
//
// 1. 전력 확인 결과('전자레인지가 켜졌어요')는 무엇으로 확인했는지 제목 바로 아래 한 줄(본문 크기·흰 글자).
// 2. 실행 중 상태는 실제 단계대로 — 서버 진행 보고가 누른 뒤 확인 결과를 실어 오면 '눌렀어요, 확인하고 있어요',
//    확인 결과 없이 버튼만 오면 '누르고 있어요'. 예전 '제대로 눌렸는지 보는 중'은 누르는 중인지 확인 중인지 헷갈렸다.
// 3. 보조 글씨 키우기 — 제안 카운트다운(키오스크 타이머 40초, 남은 초를 따로 크게), 버튼판 안내, 가전 타일 회색 띠 글자,
//    사용 방법 본문.
// 4. 경보음 화면 — '위급하면 119에 전화하세요'를 크게. 가족 휴대폰에 알렸다고 쓰지 않는다(서버는 보호자 알림함에 기록만
//    하고 폰이 45초마다 당겨 온다 — 보냈다는 근거가 화면에 없다).
// 5. 연습 실패 — 위 띠 한 줄(연습 표시는 짧게 '연습'), 주 단추 하나 + 보조 단추 같은 격자.
// 6. 연결 끊김 — 한 줄 제목(본문보다 큰 글자) + 따로 선 '해결 방법 보기' 단추.
// 7. 직접 누르기 — 버튼판이 오른쪽에 큰 빈자리를 남기지 않는다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/ambient.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/theme/kiosk_colors.dart';
import 'package:simplelay_touchscreen/theme/kiosk_tokens.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/danger_alert_overlay.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/done_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/executing_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/help_guide.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/kiosk_canvas.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/kiosk_timings.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/manual_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/practice_band.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/suggestion_view.dart';

const _panel = Size(1920, 1080);

Future<void> _pump15(WidgetTester tester, Widget child, {double textScale = 1.0}) async {
  tester.view.physicalSize = _panel;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: KioskCanvas(child: Scaffold(backgroundColor: KioskColors.bg, body: child)),
      ),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 300));
}

/// 그 글자를 그리는 RichText의 첫 글자 모양(크기·색).
TextStyle _styleOf(WidgetTester tester, Finder text) {
  final rich = tester.widget<RichText>(find.descendant(of: text, matching: find.byType(RichText)).first);
  return rich.text.style ?? const TextStyle();
}

/// 글자(평문)로 찾기 — KioskText는 낱말 사이를 붙이는 문자를 넣으므로 그 문자를 빼고 본다.
Finder _plain(String text, {bool contains = false}) => find.byWidgetPredicate((w) {
      String? s;
      if (w is RichText) s = w.text.toPlainText();
      if (s == null) return false;
      final t = s.replaceAll('⁠', '').replaceAll(' ', ' ');
      return contains ? t.contains(text) : t == text;
    });

void _noop() {}

void main() {
  group('1. 전력 확인 결과 — 무엇으로 확인했는지 제목 바로 아래', () {
    Widget done({required bool verified}) => KioskDoneView(
          success: true,
          label: '즉석밥 데워줘',
          target: kMicrowaveAppliance,
          executionMode: 'real',
          resultConfirmation: 'reported',
          operationConfirmed: verified ? true : null,
          operationSource: verified ? 'real' : null,
          pressed: const [
            KioskButtonResult(button: '즉석밥', success: true),
            KioskButtonResult(button: '시작', success: true),
          ],
          onDismiss: _noop,
        );

    testWidgets("전력 실측(L3 real)이면 '전기를 쓰기 시작한 걸 확인했어요' — 본문 크기 이상·흰 글자, 제목과 할 일 사이", (tester) async {
      await _pump15(tester, done(verified: true));
      final evidence = find.byKey(const ValueKey('done-evidence'));
      expect(evidence, findsOneWidget);
      expect(_plain('전기를 쓰기 시작한 걸 확인했어요'), findsOneWidget);
      final style = _styleOf(tester, evidence);
      expect(style.fontSize, greaterThanOrEqualTo(KioskType.body));
      expect(style.color, KioskColors.ink);
      // 제목(전자레인지가 켜졌어요) 바로 아래, 할 일('원하는 대로 됐는지 봐 주세요')보다 위.
      final title = _plain('전자레인지가 켜졌어요');
      expect(title, findsOneWidget);
      final sub = find.byKey(const ValueKey('done-sub'));
      expect(tester.getTopLeft(evidence).dy, greaterThan(tester.getBottomLeft(title).dy - 1));
      expect(tester.getTopLeft(sub).dy, greaterThan(tester.getBottomLeft(evidence).dy - 1));
    });

    testWidgets('누름 보고만이면 근거 줄을 두지 않는다(확인 안 된 것을 확인됐다고 쓰지 않음)', (tester) async {
      await _pump15(tester, done(verified: false));
      expect(find.byKey(const ValueKey('done-evidence')), findsNothing);
      expect(_plain('전기', contains: true), findsNothing);
    });
  });

  group('2. 실행 중 상태는 실제 단계대로', () {
    Widget exec({double? confidence, String? detail, int attempt = 1, String mode = 'real'}) => KioskExecutingView(
          executionMode: mode,
          title: '즉석밥 데워줘',
          target: kMicrowaveAppliance,
          lastButtons: null,
          currentButton: '시작',
          currentAttempt: attempt,
          completedSteps: 1,
          doneButtons: const ['즉석밥'],
          totalSteps: 2,
          verificationConfidence: confidence,
          verificationDetail: detail,
          onStop: _noop,
        );

    testWidgets("누른 뒤 확인 결과가 오면 '눌렀어요, 확인하고 있어요' — '보는 중'이 아니다", (tester) async {
      await _pump15(tester, exec(confidence: 0.93, detail: '전류 +14mA'));
      expect(find.text('눌렀어요, 확인하고 있어요'), findsOneWidget);
      expect(find.text('제대로 눌렸는지 보는 중'), findsNothing);
      expect(find.text('누르고 있어요'), findsNothing);
    });

    testWidgets("확인 결과 없이 버튼만 오면 '누르고 있어요'", (tester) async {
      await _pump15(tester, exec());
      expect(find.text('누르고 있어요'), findsOneWidget);
      expect(find.text('눌렀어요, 확인하고 있어요'), findsNothing);
      expect(find.text('누르는 중'), findsNothing);
    });

    testWidgets('다시 누르는 중·연습은 다시 누른다는 뜻 그대로(R1 — 다시 누르기를 숨기지 않는다, 말끝만 해요체 10/19)', (tester) async {
      await _pump15(tester, exec(attempt: 2, confidence: 0.4));
      expect(find.text('자리를 맞춰 다시 누르고 있어요'), findsOneWidget);
      expect(find.text('눌렀어요, 확인하고 있어요'), findsNothing);
      await _pump15(tester, exec(mode: 'mock', confidence: 0.9));
      expect(find.text('연습으로 누르고 있어요'), findsOneWidget);
      expect(find.text('눌렀어요, 확인하고 있어요'), findsNothing);
    });
  });

  group('3. 보조 글씨 키우기', () {
    const suggestion = KioskSuggestion(
      id: 's1',
      purpose: '즉석밥 데워줘',
      occurrences: 3,
      timeBand: '아침',
      steps: ['즉석밥', '시작'],
    );

    test('제안 자동 닫힘은 키오스크 타이머 — 기본 40초', () {
      expect(KioskTimings.countdownSeconds, 40);
      expect(KioskTimings.countdownChoices, contains(40));
    });

    testWidgets('제안 카운트다운 — 본문 크기·흰 글자, 남은 초는 따로 굵게, 진행 막대는 굵게', (tester) async {
      await _pump15(
          tester,
          KioskSuggestionView(
            suggestion: suggestion,
            target: kMicrowaveAppliance,
            cdRemaining: 37,
            cdTotal: 40,
            onApprove: () {},
            onReject: () {},
          ));
      final note = find.byKey(const ValueKey('suggestion-countdown'));
      expect(note, findsOneWidget);
      final style = _styleOf(tester, note);
      expect(style.fontSize, greaterThanOrEqualTo(KioskType.body));
      expect(style.color, KioskColors.ink);
      final secs = find.byKey(const ValueKey('suggestion-countdown-seconds'));
      expect(secs, findsOneWidget);
      expect(_plain('37초', contains: true), findsWidgets);
      final bar = tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator));
      expect(bar.minHeight, greaterThanOrEqualTo(6));
    });

    testWidgets("연습 버튼판 안내('연습으로 누르는 자리예요…')는 본문 크기 이상", (tester) async {
      await _pump15(
          tester,
          KioskExecutingView(
            executionMode: 'mock',
            title: '즉석밥 데워줘',
            target: kMicrowaveAppliance,
            lastButtons: null,
            currentButton: '시작',
            currentAttempt: 1,
            completedSteps: 1,
            totalSteps: 2,
            verificationConfidence: null,
            verificationDetail: null,
            onStop: _noop,
          ));
      final caption = find.byKey(const ValueKey('exec-panel-caption'));
      expect(caption, findsOneWidget);
      // 실행 중에는 한 줄(출시 검토 10/18) — 연습은 위 청록 띠가 말한다.
      expect(_plain(kExecPanelCaption), findsOneWidget);
      expect(_styleOf(tester, caption).fontSize, greaterThanOrEqualTo(KioskType.body));
    });

    // 사용자 결정(10/19): 띠 글자는 없앴다 — 대신 쓸 수 없음 표시가 있고 누르는 자리가 넉넉하다.
    testWidgets('가전 타일 쓸 수 없음 표시 — 누르는 자리 60px 이상', (tester) async {
      await _pump15(
          tester,
          KioskIdleView(
            now: DateTime(2026, 9, 30, 7, 38),
            connected: true,
            connections: const [
              ConnectionItem(id: 'network', state: 'ok', title: '', message: ''),
              ConnectionItem(id: 'press', state: 'error', title: '누름 장치와 연결이 끊겼어요', message: ''),
            ],
            appliances: const [kMicrowaveAppliance],
            onSelectAppliance: (_) {},
            onOpenConnection: (_) {},
            onDndGesture: () {},
          ));
      final mark = find.byKey(const ValueKey('tile-mark-microwave'));
      expect(mark, findsOneWidget);
      expect(tester.getSize(mark).shortestSide, greaterThanOrEqualTo(60));
    });

    testWidgets('사용 방법 본문은 상태 크기(한 단계 위)', (tester) async {
      await _pump15(tester, KioskHelpGuide(onClose: () {}));
      final body = find.byKey(const ValueKey('help-body'));
      expect(_styleOf(tester, body).fontSize, greaterThanOrEqualTo(KioskType.status));
      expect(_styleOf(tester, find.byKey(const ValueKey('help-page-number'))).fontSize,
          greaterThanOrEqualTo(KioskType.body));
    });
  });

  group('4. 경보음 화면', () {
    testWidgets("'위급하면 119에 전화하세요'를 크게 — 가족에게 알렸다고 쓰지 않는다", (tester) async {
      await _pump15(tester, DangerAlertOverlay(onAcknowledge: () {}));
      final call = find.byKey(const ValueKey('danger-119'));
      expect(call, findsOneWidget);
      expect(_plain('위급하면 119에 전화하세요'), findsOneWidget);
      final style = _styleOf(tester, call);
      expect(style.fontSize, greaterThanOrEqualTo(KioskType.status));
      expect(_plain('알렸어요', contains: true), findsNothing);
      expect(_plain('가족', contains: true), findsNothing);
    });
  });

  group('5. 연습 실패 — 띠 한 줄, 단추 격자', () {
    Widget failed() => KioskDoneView(
          success: false,
          executionMode: 'mock',
          label: '즉석밥 데워줘',
          target: kMicrowaveAppliance,
          onRetry: () {},
          onManual: () {},
          onDismiss: () {},
        );

    // 출시 검토(10/18)에서 바꿈: 연습 실패(확인 필요)는 앰버가 아니라 청록 연습 띠 — 글자는 짧게 '연습'(한 줄).
    testWidgets("위 띠는 한 줄 — 청록 연습 띠, 연습 표시는 짧게 '연습'", (tester) async {
      await _pump15(tester, failed());
      final band = find.byKey(const ValueKey('status-band'));
      expect(find.descendant(of: band, matching: _plain(kPracticeBandText)), findsNothing);
      expect(find.descendant(of: band, matching: _plain('연습')), findsOneWidget);
      final box = tester.widget<Container>(band).decoration as BoxDecoration;
      expect((box.border as Border).left.color, KioskColors.practice);
      // 한 줄 띠 — 기본 높이(캔버스 40 = 실제 82px) 그대로(getSize는 캔버스 단위).
      expect(tester.getSize(band).height, closeTo(KioskSizes.bandHeight, 1), reason: "캔버스 단위 — 한 줄 띠 높이");
    });

    testWidgets('주 단추 하나 + 보조 둘 — 같은 폭 격자, 왼쪽 선이 같다', (tester) async {
      await _pump15(tester, failed());
      final retry = find.byKey(const ValueKey('done-retry'));
      final home = find.byKey(const ValueKey('done-home'));
      final manual = find.byKey(const ValueKey('done-manual'));
      expect(tester.widget(retry), isA<ElevatedButton>());
      expect(tester.widget(home), isA<OutlinedButton>());
      expect(tester.widget(manual), isA<OutlinedButton>());
      // 보조 둘은 같은 크기.
      expect(tester.getSize(home).width, closeTo(tester.getSize(manual).width, 1));
      expect(tester.getSize(home).height, closeTo(tester.getSize(manual).height, 1));
      // 주 단추와 보조 칸의 폭이 같은 격자이고, 왼쪽 선이 같다.
      expect(tester.getSize(retry).width, closeTo(tester.getSize(home).width, 1));
      expect(tester.getTopLeft(retry).dx, closeTo(tester.getTopLeft(home).dx, 1));
      // 보조 둘은 한 줄에 나란히.
      expect(tester.getTopLeft(home).dy, closeTo(tester.getTopLeft(manual).dy, 1));
    });
  });

  group('6. 연결 끊김 — 한 줄 제목 + 따로 선 해결 방법 단추', () {
    Widget idle({void Function(ConnectionItem)? onOpen}) => KioskIdleView(
          now: DateTime(2026, 9, 30, 7, 38),
          connected: true,
          connections: const [
            ConnectionItem(id: 'network', state: 'ok', title: '', message: ''),
            ConnectionItem(id: 'press', state: 'error', title: '누름 장치와 연결이 끊겼어요', message: ''),
          ],
          appliances: const [kMicrowaveAppliance, kInductionAppliance],
          onSelectAppliance: (_) {},
          onOpenConnection: onOpen ?? (_) {},
          onDndGesture: () {},
        );

    testWidgets('제목은 한 줄·본문보다 큰 글자, 해결 방법 보기는 제목 밖의 단추', (tester) async {
      ConnectionItem? opened;
      await _pump15(tester, idle(onOpen: (i) => opened = i));
      final cause = find.byKey(const ValueKey('idle-problem-cause'));
      expect(cause, findsOneWidget);
      expect(_plain('누름 장치가 끊겨 가전 2대를 쓸 수 없어요'), findsOneWidget);
      final style = _styleOf(tester, cause);
      expect(style.fontSize, greaterThanOrEqualTo(KioskType.status));
      // 한 줄 — 높이가 글자 두 줄에 못 미친다(캔버스 단위).
      expect(tester.getSize(cause).height, lessThan(KioskType.status * 2));
      final help = find.byKey(const ValueKey('idle-problem-help'));
      expect(help, findsOneWidget);
      expect(tester.widget(help), isA<ButtonStyleButton>());
      expect(find.descendant(of: help, matching: _plain('해결 방법 보기', contains: true)), findsOneWidget);
      // 단추는 제목 칩 밖에 따로 선다.
      final chip = find.byKey(const ValueKey('idle-status-chip'));
      expect(find.descendant(of: chip, matching: help), findsNothing);
      final chipRect = tester.getRect(chip);
      final helpRect = tester.getRect(help);
      expect(chipRect.overlaps(helpRect), isFalse);
      await tester.tap(help);
      await tester.pump();
      expect(opened?.id, 'press');
    });
  });

  group('7. 직접 누르기 — 오른쪽 빈자리', () {
    testWidgets('버튼판이 화면 폭을 고르게 쓴다(오른쪽 빈자리 15% 미만)', (tester) async {
      await _pump15(
          tester,
          KioskManualView(appliance: kMicrowaveAppliance, onExecute: (_) {}, onCancel: () {}));
      final start = find.text('시작');
      expect(start, findsOneWidget);
      // 가장 오른쪽 열의 버튼('시작') 오른쪽 끝 — 캔버스 오른쪽 끝(1920 − 140)에서 15% 안.
      const contentRight = 1920 - 140.0;
      const contentWidth = 1920 - 280.0;
      final cell = find.ancestor(of: start, matching: find.byType(InkWell)).first;
      final right = tester.getRect(cell).right;
      expect(contentRight - right, lessThan(contentWidth * 0.15),
          reason: '오른쪽 빈자리 ${contentRight - right}px');
    });
  });
}
