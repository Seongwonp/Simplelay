// 접근성 감사(KWCAG/WCAG, 10/18 — 본체 82점)에서 나온 키오스크 문제 — 단정 시험.
//
// 1. '한 번 더 하기'는 늘 확인 창을 거친다. 켜고 끄는 한 버튼(서버 버튼 데이터 behavior=toggle)을 다시 누를 수 있으면 그 창에
//    '가전이 이미 켜졌다면 다시 누르면 꺼질 수 있어요'. 토글 성질이 없으면 일반 경고 그대로.
// 2. 제안 자동 닫힘 — 화면을 만지면 남은 시간이 처음으로(연장), '시간 더 주기'(+60초).
// 3. 성공 결과 자동 복귀 — 'N초 뒤 처음 화면으로 돌아가요'(실제 남은 초), 글자 한 단계 크게. 만지면 멈춤(종전).
// 4. 조용한 시간 — 어두운 막을 글자 위에 덮지 않는다(배경만 어둡게). 남는 글자는 대비 4.5:1 이상.
// 5. 본체 가전 카드 '설정이 필요해요'(앰버) → 중립 회색 '가족이 설정해요'. 문제 칩·확인 필요에 넣지 않는다.
// 6. 표기 통일 — '확인 필요' 결과 제목은 같은 색(앰버). 연습 가전 이름은 '연습 세탁기'.
// 8. 제안 버튼판에 '화면은 누르지 않아도 돼요', 큰 글씨 LG 가전 상세의 상태 줄이 첫 화면에, 처음 화면 경고 띠는 하나로.
// 그 밖: '오늘은 건너뛰기'·'되돌리기'(글자 모양은 사용자 결정) 누르는 자리가 실패널에서 60px 이상.
import 'dart:math' as math;

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
import 'package:simplelay_touchscreen/widgets/kiosk/idle_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/kiosk_canvas.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/manual_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/panel_picture.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/suggestion_view.dart';

import 'kiosk_phase_test.dart' show FakeKioskApi, FakeTts, FakeEventStream;

void _noop() {}

/// 글자(평문)로 찾기 — KioskText는 낱말 사이를 붙이는 문자를 넣으므로 그 문자를 빼고 본다.
Finder _plain(String text, {bool contains = false}) => find.byWidgetPredicate((w) {
      if (w is! RichText) return false;
      final t = w.text.toPlainText().replaceAll('⁠', '').replaceAll(' ', ' ');
      return contains ? t.contains(text) : t == text;
    });

Future<void> _pumpView(WidgetTester tester, Widget child, {double textScale = 1.0}) async {
  tester.view.physicalSize = const Size(800, 480);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(size: const Size(800, 480), textScaler: TextScaler.linear(textScale)),
      child: Scaffold(backgroundColor: KioskColors.bg, body: child),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _pump15(WidgetTester tester, Widget child, {bool dim = false}) async {
  tester.view.physicalSize = const Size(1920, 1080);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: KioskCanvas(dim: dim, child: Scaffold(backgroundColor: KioskColors.bg, body: child)),
  ));
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _pumpKiosk(WidgetTester tester, FakeKioskApi api) async {
  tester.view.physicalSize = const Size(800, 480);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: KioskScreen(api: api, tts: FakeTts(), events: FakeEventStream()),
  ));
  await tester.pump();
  await tester.pump();
}

// ── 대비 계산(WCAG 상대 휘도) ────────────────────────────────────────────────
double _lum(Color c) {
  double ch(double v) => v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
}

double _ratio(Color a, Color b) {
  final la = _lum(a), lb = _lum(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// 반투명 색을 바탕 위에 얹은 색.
Color _over(Color fg, Color bg) => Color.from(
      alpha: 1,
      red: fg.r * fg.a + bg.r * (1 - fg.a),
      green: fg.g * fg.a + bg.g * (1 - fg.a),
      blue: fg.b * fg.a + bg.b * (1 - fg.a),
    );

/// 전자레인지 — 서버 버튼 데이터에 켜고 끄는 성질(behavior)이 있다.
ApplianceMap _microwave({required String startBehavior}) => applianceFromServerJson({
      'id': 'microwave',
      'name': '전자레인지',
      'category': 'microwave',
      'rows': 1,
      'cols': 2,
      'buttons': [
        {'id': 'BT-08', 'label': '즉석밥', 'x': 0, 'y': 0, 'behavior': 'idempotent'},
        {'id': 'BT-05', 'label': '시작', 'x': 1, 'y': 0, 'behavior': startBehavior},
      ],
      'can_execute': true,
      'readiness': 'operable',
    });

final _purifier = applianceFromServerJson({
  'id': 'air_purifier',
  'name': '공기청정기',
  'category': 'air_purifier',
  'rows': 0,
  'cols': 0,
  'buttons': <dynamic>[],
  'control_path': 'thinq',
  'can_execute': true,
  'readiness': 'operable',
});

final _practiceWasher = applianceFromServerJson({
  'id': 'thinq_washer',
  'name': 'LG 세탁기(연습)',
  'category': 'washing_machine',
  'rows': 0,
  'cols': 0,
  'buttons': <dynamic>[],
  'control_path': 'thinq',
  'can_execute': true,
  'readiness': 'operable',
});

void main() {
  tearDown(() => KioskColors.setHighContrast(false));

  group('1. 한 번 더 하기 — 확인 창, 켜고 끄는 버튼이면 꺼질 수 있다는 말', () {
    Widget unknown(ApplianceMap target, {required VoidCallback onRetry}) => KioskDoneView(
          success: false,
          reason: KioskFailureReason.execution,
          label: '즉석밥 데워줘',
          target: target,
          executionMode: 'real',
          pressed: const [
            KioskButtonResult(button: '즉석밥', success: true),
            KioskButtonResult(button: '시작', success: false),
          ],
          onRetry: onRetry,
          onRetryAfterCheck: onRetry,
          onDismiss: _noop,
        );

    Future<void> openRetry(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('done-check-no')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('done-retry')));
      await tester.pump();
    }

    testWidgets("'안 움직였어요' 뒤 '한 번 더 하기'는 확인 창을 거친다 — 닫으면 다시 하지 않는다", (tester) async {
      var retried = 0;
      await _pumpView(tester, unknown(_microwave(startBehavior: 'toggle'), onRetry: () => retried++));
      await openRetry(tester);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(retried, 0, reason: '창에서 고르기 전에는 다시 하지 않는다');
      await tester.tap(find.text('닫기'));
      await tester.pump();
      expect(retried, 0);
    });

    testWidgets("켜고 끄는 버튼(behavior=toggle)을 다시 누르면 — 창에 '이미 켜졌다면 다시 누르면 꺼질 수 있어요'", (tester) async {
      var retried = 0;
      await _pumpView(tester, unknown(_microwave(startBehavior: 'toggle'), onRetry: () => retried++));
      await openRetry(tester);
      final text = tester.widget<Text>(find.byKey(const ValueKey('done-retry-dialog-text'))).data!;
      expect(text, contains('가전이 이미 켜졌다면 다시 누르면 꺼질 수 있어요'));
      await tester.tap(find.text('네, 한 번 더 하기'));
      await tester.pump();
      expect(retried, 1);
    });

    testWidgets("성질을 모르는 버튼(behavior=unknown)도 토글과 같은 경고 — 두 번 누르면 되돌아갈 수 있다(검토 10/19 #5)", (tester) async {
      await _pumpView(tester, unknown(_microwave(startBehavior: 'unknown'), onRetry: _noop));
      await openRetry(tester);
      final text = tester.widget<Text>(find.byKey(const ValueKey('done-retry-dialog-text'))).data!;
      expect(text, contains('가전이 이미 켜졌다면 다시 누르면 꺼질 수 있어요'));
    });

    testWidgets('누른 버튼이 버튼판에 없으면(성질을 모름) 토글과 같은 경고(검토 10/19 #5)', (tester) async {
      await _pumpView(
          tester,
          KioskDoneView(
            success: false,
            reason: KioskFailureReason.execution,
            label: '해동 해줘',
            target: _microwave(startBehavior: 'idempotent'),
            executionMode: 'real',
            pressed: const [KioskButtonResult(button: '해동', success: false)],
            onRetry: _noop,
            onRetryAfterCheck: _noop,
            onDismiss: _noop,
          ));
      await openRetry(tester);
      final text = tester.widget<Text>(find.byKey(const ValueKey('done-retry-dialog-text'))).data!;
      expect(text, contains('가전이 이미 켜졌다면 다시 누르면 꺼질 수 있어요'));
    });

    testWidgets('되풀이해도 같은 버튼(idempotent)만이면 일반 경고 그대로 — 꺼진다고 지어내지 않는다', (tester) async {
      await _pumpView(tester, unknown(_microwave(startBehavior: 'idempotent'), onRetry: _noop));
      await openRetry(tester);
      final text = tester.widget<Text>(find.byKey(const ValueKey('done-retry-dialog-text'))).data!;
      expect(text, isNot(contains('꺼질')));
      expect(text, contains('한 번 더 하지 마세요'));
    });
  });

  group('2. 제안 자동 닫힘 — 만지면 처음으로, 시간 더 주기', () {
    String seconds(WidgetTester tester) => tester
        .widget<RichText>(find.descendant(
            of: find.byKey(const ValueKey('suggestion-countdown-seconds')), matching: find.byType(RichText)))
        .text
        .toPlainText();

    testWidgets("화면을 만지면 남은 시간이 처음(40초)으로, '시간 더 주기'는 60초 더", (tester) async {
      final api = FakeKioskApi()
        ..applianceList = [_microwave(startBehavior: 'toggle')]
        ..suggestionList = const [
          KioskSuggestion(id: 's1', purpose: '즉석밥 데워줘', occurrences: 3, applianceId: 'microwave'),
        ];
      await _pumpKiosk(tester, api);
      await tester.pump(const Duration(seconds: 1));
      // 제안은 서버 목록에 남겨 둔다(목록에서 사라지면 화면이 닫힌다). 이미 보인 카드는 다시 띄우지 않는다.
      expect(find.byType(KioskSuggestionView), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
      expect(int.parse(seconds(tester).split('초').first), lessThan(32), reason: '10초쯤 지나 30초 안팎');
      // 질문 글자(단추가 아닌 곳)를 만진다.
      await tester.tapAt(tester.getCenter(find.byKey(const ValueKey('suggestion-question'))));
      await tester.pump();
      expect(seconds(tester), startsWith('40초'));

      final more = find.byKey(const ValueKey('suggestion-more-time'));
      expect(more, findsOneWidget);
      expect(find.descendant(of: more, matching: find.text('시간 더 주기')), findsOneWidget);
      expect(tester.getSize(more).height, greaterThanOrEqualTo(48));
      await tester.tap(more);
      await tester.pump();
      expect(seconds(tester), startsWith('100초'));
      // 40초가 지나도 닫히지 않는다.
      await tester.pump(const Duration(seconds: 45));
      expect(find.byType(KioskSuggestionView), findsOneWidget);
      // 진행 막대는 1을 넘지 않는다.
      final bar = tester.widget<LinearProgressIndicator>(
          find.descendant(of: find.byType(KioskSuggestionView), matching: find.byType(LinearProgressIndicator)));
      expect(bar.value, lessThanOrEqualTo(1.0));
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('3. 성공 결과 자동 복귀 — 실제 남은 초, 한 단계 큰 글자', () {
    testWidgets("'10초 뒤 처음 화면으로 돌아가요' — 1초마다 줄고, 본문 크기 이상", (tester) async {
      final api = FakeKioskApi()
        ..applianceList = [_microwave(startBehavior: 'toggle')]
        ..suggestionList = const [
          KioskSuggestion(id: 's1', purpose: '즉석밥 데워줘', occurrences: 3, applianceId: 'microwave'),
        ];
      await _pumpKiosk(tester, api);
      await tester.pump(const Duration(seconds: 1));
      api.suggestionList = [];
      await tester.tap(find.byKey(const ValueKey('suggestion-approve')));
      await tester.pump();
      api.statusResult = const KioskStatus(
          running: false,
          lastJobId: 'job-1',
          lastStatus: 'succeeded',
          lastExecutionMode: 'real',
          lastOperationConfirmed: true,
          lastOperationSource: 'real');
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 900));
      expect(find.byType(KioskDoneView), findsOneWidget);
      final line = find.byKey(const ValueKey('done-auto-return'));
      final first = RegExp(r'^(\d+)초 뒤 처음 화면으로 돌아가요$').firstMatch(tester.widget<Text>(line).data!);
      expect(first, isNotNull, reason: tester.widget<Text>(line).data);
      final n = int.parse(first!.group(1)!);
      expect(n, inInclusiveRange(8, 10), reason: '보통 글씨는 10초에서 센다');
      expect(tester.widget<Text>(line).style!.fontSize, greaterThanOrEqualTo(KioskType.body));
      await tester.pump(const Duration(seconds: 3));
      expect(tester.widget<Text>(line).data, '${n - 3}초 뒤 처음 화면으로 돌아가요');
      await tester.pump(Duration(seconds: n - 2));
      await tester.pump(const Duration(seconds: 1)); // 화면 바뀜 애니메이션
      expect(find.byType(KioskDoneView), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('LG 가전 결과 창(확인한 성공)도 남은 초를 숫자로', (tester) async {
      await _pumpView(
          tester,
          KioskDoneView(
            success: true,
            label: '공기청정기 켜줘',
            target: _purifier,
            route: 'thinq',
            thinqOnly: true,
            executionMode: 'real',
            resultConfirmation: 'state_confirmed',
            onDismiss: _noop,
          ));
      final line = find.byKey(const ValueKey('done-auto-return'));
      expect(line, findsOneWidget);
      expect(tester.widget<Text>(line).data, matches(RegExp(r'^\d+초 뒤 처음 화면으로 돌아가요$')));
      expect(tester.widget<Text>(line).style!.fontSize, greaterThanOrEqualTo(KioskType.body));
    });
  });

  group('4. 조용한 시간 — 막을 글자 위에 덮지 않고, 남는 글자 대비 4.5:1 이상', () {
    KioskIdleView quiet() => KioskIdleView(
          now: DateTime(2026, 9, 30, 23, 12),
          quietUntil: '07:00',
          quietDim: true,
          connected: true,
          connections: const [
            ConnectionItem(id: 'network', state: 'ok', title: '', message: ''),
            ConnectionItem(id: 'press', state: 'ok', title: '', message: ''),
          ],
          appliances: const [],
          nextRun: const KioskNextRun(
            name: '아침 공기청정기 끄기',
            dayLabel: '내일',
            hhmm: '07:00',
            modeLabel: '자동 실행',
            routineId: 'rt-morning',
            at: '2026-10-01T07:00:00+09:00',
            skipActionLabel: '내일은 건너뛰기',
          ),
          onToggleNextRunSkip: (_) {},
          onSelectAppliance: (_) {},
          onOpenConnection: (_) {},
          onDndGesture: () {},
        );

    /// 그 글자가 실제로 보이는 색 — 위로 쌓인 투명도와, 화면 위에 덮인 반투명 막을 모두 계산한다.
    (Color, Color) seen(WidgetTester tester, Finder text) {
      final rich = find.descendant(of: text, matching: find.byType(RichText)).evaluate().isNotEmpty
          ? find.descendant(of: text, matching: find.byType(RichText)).first
          : text;
      final fg = tester.widget<RichText>(rich).text.style!.color!;
      var opacity = 1.0;
      for (final o in tester.widgetList<Opacity>(find.ancestor(of: rich, matching: find.byType(Opacity)))) {
        opacity *= o.opacity;
      }
      final bg = tester.widget<ColoredBox>(find.byKey(const ValueKey('idle-quiet'))).color;
      var shown = _over(fg.withValues(alpha: fg.a * opacity), bg);
      var back = bg;
      // 글자 위에 덮인 반투명 막(조용한 시간 막·패널 막).
      final overlays = <Color>[
        for (final box in tester.widgetList<ColoredBox>(
            find.descendant(of: find.byKey(const ValueKey('idle-quiet-dim')), matching: find.byType(ColoredBox))))
          box.color,
        for (final box in tester.widgetList<ColoredBox>(find.byKey(const ValueKey('kiosk-panel-dim'))))
          if (box.color.a < 1) box.color,
      ];
      for (final o in overlays) {
        if (o.a == 0) continue;
        shown = _over(o, shown);
        back = _over(o, back);
      }
      return (shown, back);
    }

    for (final contrast in [false, true]) {
      testWidgets('날짜·메뉴·내일은 건너뛰기 — 대비 4.5:1 이상${contrast ? '(고대비)' : ''}', (tester) async {
        KioskColors.setHighContrast(contrast);
        await _pump15(tester, quiet(), dim: true);
        final date = _plain('9월 30일 수요일');
        expect(date, findsOneWidget);
        for (final f in [
          date,
          find.text('메뉴'),
          find.descendant(of: find.byKey(const ValueKey('idle-next-run-skip')), matching: find.byType(RichText)),
        ]) {
          final (fg, bg) = seen(tester, f.first);
          expect(_ratio(fg, bg), greaterThanOrEqualTo(4.5), reason: '$f');
        }
      });
    }

    testWidgets('글자 위에 반투명 막이 없다 — 패널 바탕만 어둡다(불투명, 평소 바탕보다 어둡게)', (tester) async {
      await _pump15(tester, quiet(), dim: true);
      final panel = tester.widget<ColoredBox>(find.byKey(const ValueKey('kiosk-panel-dim')));
      expect(panel.color.a, 1.0, reason: '패널 막은 글자 위가 아니라 바탕이다');
      expect(_lum(panel.color), lessThan(_lum(KioskColors.bg)));
      for (final box in tester.widgetList<ColoredBox>(
          find.descendant(of: find.byKey(const ValueKey('idle-quiet-dim')), matching: find.byType(ColoredBox)))) {
        expect(box.color.a, 0, reason: '깨우는 손길만 받는 자리 — 색은 없다');
      }
      // 처음 화면 바탕도 패널과 같은 어두운 색이다(안쪽 사각형 테두리가 드러나지 않게).
      expect(tester.widget<ColoredBox>(find.byKey(const ValueKey('idle-quiet'))).color, panel.color);
    });
  });

  group("5. 본체 가전 카드 — '설정이 필요해요'는 어르신 할 일이 아니다", () {
    final setup = applianceFromServerJson({
      'id': 'intercom',
      'name': '인터폰',
      'category': 'intercom',
      'rows': 1,
      'cols': 1,
      'buttons': [
        {'id': 'IC-1', 'label': '문열림', 'x': 0, 'y': 0},
      ],
      'can_execute': false,
      'readiness': 'needs_setup',
    });
    final unmapped = applianceFromServerJson({
      'id': 'washer',
      'name': '세탁기',
      'category': 'washing_machine',
      'rows': 1,
      'cols': 1,
      'buttons': [
        {'id': 'W-1', 'label': '시작', 'x': 0, 'y': 0},
      ],
      'is_custom': true,
      'can_execute': true,
      'readiness': 'operable',
    });

    // 사용자 결정(10/19): 상태 띠 대신 오른쪽 위 톱니 표시 — 경고('!')가 아니라 설정 남음, 가족이 휴대폰에서 한다.
    test("서버 설정 필요·위치 미설정 모두 톱니 표시 — 경고 '!'가 아님, 가족이 휴대폰에서 설정", () {
      for (final a in [setup, unmapped]) {
        final issue = kioskTileIssue(a)!;
        expect(issue.mark, KioskTileMark.setup, reason: a.id);
        expect(issue.text, contains('가족이 휴대폰에서 설정해요'), reason: a.id);
      }
    });

    testWidgets('문제 칩·확인 필요 띠·테두리에 넣지 않는다', (tester) async {
      await _pumpView(
          tester,
          KioskIdleView(
            now: DateTime(2026, 9, 30, 9, 0),
            connected: true,
            connections: const [
              ConnectionItem(id: 'network', state: 'ok', title: '', message: ''),
              ConnectionItem(id: 'press', state: 'ok', title: '', message: ''),
            ],
            appliances: [setup, unmapped],
            onSelectAppliance: (_) {},
            onOpenConnection: (_) {},
            onDndGesture: () {},
          ));
      expect(find.byKey(const ValueKey('idle-status-chip')), findsNothing);
      expect(find.text('확인 필요'), findsNothing);
      expect(find.text('설정이 필요해요'), findsNothing);
      // 사용자 결정(10/19): 글자 띠 없이 톱니 표시 둘.
      expect(find.byKey(const ValueKey('tile-mark-intercom')), findsOneWidget);
      expect(find.byKey(const ValueKey('tile-mark-washer')), findsOneWidget);
    });
  });

  group('6. 표기 통일', () {
    testWidgets("'확인 필요' 결과 제목은 같은 색 — 누름 보고만('버튼은 다 눌렀어요')도 앰버", (tester) async {
      Widget done({required bool success}) => KioskDoneView(
            success: success,
            reason: success ? null : KioskFailureReason.execution,
            label: '즉석밥 데워줘',
            target: kMicrowaveAppliance,
            executionMode: 'real',
            resultConfirmation: success ? 'reported' : null,
            onDismiss: _noop,
          );
      await _pumpView(tester, done(success: true));
      final reported = tester.widget<RichText>(_plain('버튼은 다 눌렀어요').first).text.style!.color;
      await _pumpView(tester, done(success: false));
      final unknown = tester.widget<RichText>(_plain('눌렸는지 몰라요').first).text.style!.color;
      expect(unknown, KioskColors.warning);
      expect(reported, unknown);
    });

    // 사용자 결정(10/19): '확인 전이에요' 띠 대신 같은 '?' 표시(연습 가전도).
    testWidgets("전원을 모르면 '?' 표시(연습 가전도)", (tester) async {
      expect(kioskTileIssue(_practiceWasher)!.mark, KioskTileMark.unknown);
      expect(kioskTileIssue(_purifier)!.mark, KioskTileMark.unknown);
      expect(kioskTileIssue(_practiceWasher)!.text, kTilePowerUnknown);
    });

    test("연습 가전 화면 이름은 '연습 세탁기' — 서버 이름 데이터는 그대로", () {
      expect(_practiceWasher.name, 'LG 세탁기(연습)');
      expect(_practiceWasher.tileName, '연습 세탁기');
      expect(_purifier.tileName, '공기청정기');
    });

    testWidgets("처음 화면 가전 줄에 '연습 세탁기'", (tester) async {
      await _pumpView(
          tester,
          KioskIdleView(
            now: DateTime(2026, 9, 30, 9, 0),
            connected: true,
            connections: const [
              ConnectionItem(id: 'network', state: 'ok', title: '', message: ''),
              ConnectionItem(id: 'press', state: 'ok', title: '', message: ''),
            ],
            appliances: [_practiceWasher],
            onSelectAppliance: (_) {},
            onOpenConnection: (_) {},
            onDndGesture: () {},
          ));
      expect(find.text('연습 세탁기'), findsOneWidget);
      expect(find.text('LG 세탁기'), findsNothing);
    });
  });

  group('8. 작은 것', () {
    testWidgets("제안 버튼판에 '화면은 누르지 않아도 돼요'(실행 화면과 같게)", (tester) async {
      await _pump15(
          tester,
          KioskSuggestionView(
            suggestion: const KioskSuggestion(
                id: 's1', purpose: '즉석밥 데워줘', occurrences: 3, applianceId: 'microwave', steps: ['즉석밥', '시작']),
            target: kMicrowaveAppliance,
            cdRemaining: 37,
            cdTotal: 40,
            onApprove: _noop,
            onReject: _noop,
          ));
      final caption = find.byKey(const ValueKey('suggestion-panel-caption'));
      expect(caption, findsOneWidget);
      expect(tester.widget<RichText>(find.descendant(of: caption, matching: find.byType(RichText)).first)
          .text
          .toPlainText()
          .replaceAll('⁠', ''), contains(kScreenNoPress));
    });

    testWidgets('큰 글씨 LG 가전 상세 — 상태 줄이 첫 화면(스크롤 없이)에 보인다', (tester) async {
      await _pumpView(
          tester,
          KioskManualView(
            appliance: _purifier,
            onExecute: (_) {},
            onCancel: () {},
            thinqRead: () async => KioskThinqStatus(
              executionMode: 'real',
              readAt: DateTime(2026, 10, 16, 9, 7),
              state: const {
                'operation': {'airPurifierOperationMode': 'POWER_OFF'},
                'airPurifierJobMode': {'currentJobMode': 'CLEAN'},
                'airFlow': {'windStrength': 'LOW'},
                'filterInfo': {'filterRemainPercent': 87},
              },
            ),
            thinqSend: (_, __, ___) async => const KioskJobAccepted(jobId: 'j'),
            onThinqAccepted: (_, __) {},
          ),
          textScale: 1.22);
      await tester.pump(const Duration(milliseconds: 300));
      final filter = _plain('87%', contains: true);
      expect(filter, findsWidgets);
      final visible = filter.evaluate().where((e) {
        final box = e.renderObject! as RenderBox;
        final top = box.localToGlobal(Offset.zero).dy;
        return top >= 0 && top + box.size.height <= 480;
      });
      expect(visible, isNotEmpty, reason: '필터 줄이 화면 아래로 잘리지 않고 첫 화면에 보여야 한다');
    });

    testWidgets('처음 화면 경고 띠는 하나 — 연결 문제 + 확인 필요 가전 안내를 한 띠에', (tester) async {
      const tipText = '인덕션 버튼 누르기가 중간에 멈췄어요. 가전을 봐 주세요.';
      await _pumpView(
          tester,
          KioskIdleView(
            now: DateTime(2026, 9, 30, 19, 0),
            connected: true,
            connections: const [
              ConnectionItem(id: 'network', state: 'ok', title: '', message: ''),
              ConnectionItem(id: 'press', state: 'ok', title: '', message: ''),
              ConnectionItem(id: 'plug', state: 'warn', title: '', message: ''),
            ],
            appliances: [kInductionAppliance],
            attention: const {'induction'},
            ambient: const AmbientInfo(
                greeting: '편안한 저녁 보내세요.',
                tip: AmbientTip(kind: 'appliance', text: tipText, icon: 'attention')),
            onSelectAppliance: (_) {},
            onOpenConnection: (_) {},
            onDndGesture: () {},
          ),
          textScale: 1.22);
      expect(find.byKey(const ValueKey('ambient-tip')), findsNothing, reason: '따로 선 노란 테 안내 카드가 없다');
      final bar = find.byKey(const ValueKey('idle-status-chip'));
      expect(bar, findsOneWidget);
      expect(find.descendant(of: bar, matching: _plain('인덕션 버튼 누르기가 중간에 멈췄어요', contains: true)),
          findsOneWidget);
      // 해결 방법 단추는 그대로 하나.
      expect(find.byKey(const ValueKey('idle-problem-help')), findsOneWidget);
    });

    testWidgets("'내일은 건너뛰기'·'되돌리기' 누르는 자리 — 실패널에서 60px 이상(글자 모양은 그대로)", (tester) async {
      for (final skipped in [false, true]) {
        await _pump15(
            tester,
            KioskIdleView(
              now: DateTime(2026, 9, 30, 9, 0),
              connected: true,
              connections: const [
                ConnectionItem(id: 'network', state: 'ok', title: '', message: ''),
                ConnectionItem(id: 'press', state: 'ok', title: '', message: ''),
              ],
              appliances: const [],
              nextRun: KioskNextRun(
                name: '저녁 공기청정기 켜기',
                dayLabel: '오늘',
                hhmm: '22:00',
                modeLabel: '자동 실행',
                routineId: 'rt-evening',
                at: '2026-09-30T22:00:00+09:00',
                skipped: skipped,
                skipLabel: skipped ? '오늘은 건너뛰어요' : null,
                skipActionLabel: '오늘은 건너뛰기',
              ),
              onToggleNextRunSkip: (_) {},
              onSelectAppliance: (_) {},
              onOpenConnection: (_) {},
              onDndGesture: () {},
            ));
        final button = find.byKey(ValueKey(skipped ? 'idle-next-run-unskip' : 'idle-next-run-skip'));
        final hit = find.descendant(of: button, matching: find.byType(InkWell));
        final rect = tester.getRect(hit);
        expect(rect.height, greaterThanOrEqualTo(60), reason: '$skipped 높이 ${rect.height}');
        expect(rect.width, greaterThanOrEqualTo(60), reason: '$skipped 폭 ${rect.width}');
      }
    });
  });
}
