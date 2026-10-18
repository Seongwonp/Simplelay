// 키오스크 문구·화면 개선(2026-10-15, docs/키오스크-문구-개선-계획-2026-10-15.md) — 단계별 회귀 시험.
//
// 원칙: 확인한 것만 말한다 · 주어를 밝힌다(누름 장치/가전) · 다음 행동 한 가지 · 정지 버튼은 그대로.
// 이 파일의 시험은 수정 전 코드에서 실패하는 것을 확인한 뒤 넣었다(CLAUDE.md 게이트) — 그래서 새 상수 대신
// 화면에 보이는 글자로 찾는다. 실사용자 시험이 아니다(골든·위젯 시험 수준).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/idle_menu.dart';
import 'package:simplelay_touchscreen/models/ambient.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/models/command_result.dart';
import 'package:simplelay_touchscreen/screens/kiosk_screen.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/theme/kiosk_colors.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/connection_status.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/practice_band.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/dnd_overlay.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/done_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/executing_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/hold_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/kiosk_canvas.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/manual_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/suggestion_view.dart';
import 'package:simplelay_touchscreen/widgets/learning_status_dialog.dart';

import 'kiosk_phase_test.dart' show FakeEventStream, FakeKioskApi, FakeTts;
import 'learning_status_dialog_test.dart' as learning;

const _fontPath = r'C:\Windows\Fonts\malgun.ttf';
final _hasFont = File(_fontPath).existsSync();

const _approveKey = ValueKey('suggestion-approve');
const _banner = ValueKey('estop-banner');
const _ack = ValueKey('estop-ack');
const _confirm = ValueKey('estop-confirm');

const _sug = KioskSuggestion(
  id: 's1',
  purpose: '즉석밥 데워줘',
  occurrences: 3,
  applianceId: 'microwave',
);

// RPi4가 실제로 보내는 문장(서버 문구 정리 2bc87e5).

/// 비상 버튼이 눌려 있으면 누름 장치 가전 타일은 '지금 못 써요'(누르면 풀기 안내, 평가 4차 10/18) — 수동 조작 화면은
/// LG 가전으로 연다(LG 가전 타일은 그대로 열린다).
const _thinqAirForEstop = ApplianceMap(
  id: 'air_purifier',
  name: '공기청정기',
  category: 'air_purifier',
  rows: 0,
  cols: 0,
  buttons: [],
  controlPath: 'thinq',
);
const _buttonDetail = "비상 버튼이 눌려 있어요 — 풀고 '해제하기'를 눌러야 다시 쓸 수 있어요";
const _rebootDetail = '가전 콘센트 장치가 다시 켜져 가전 전원이 꺼져 있어요 — 해제하면 전원을 다시 켜요';

Future<void> _pumpKiosk(WidgetTester tester, FakeKioskApi api,
    {FakeTts? tts, Size size = const Size(800, 480)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: KioskScreen(api: api, tts: tts ?? FakeTts(), events: FakeEventStream()),
  ));
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _nextPoll(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 2));
  await _settle(tester);
}

/// 제안을 승인하고 [status]로 끝낸다 — 키오스크가 시작한 실행(다시 보낼 요청이 있다).
Future<void> _finishOwn(
    WidgetTester tester, FakeKioskApi api, KioskStatus status) async {
  api.suggestionList = [];
  await tester.tap(find.byKey(_approveKey));
  await tester.pump();
  api.statusResult = status;
  await tester.pump(const Duration(seconds: 2));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 900));
}

Finder _inButton<T>(String text) => find.ancestor(
    of: find.text(text), matching: find.byWidgetPredicate((w) => w is T));

Future<void> _pumpView(WidgetTester tester, Widget view,
    {double scale = 1.0, bool malgun = false}) async {
  tester.view.physicalSize = const Size(800, 480);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: malgun
        ? ThemeData(fontFamily: 'Malgun', brightness: Brightness.dark)
        : null,
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(scale)),
      child: Scaffold(backgroundColor: KioskColors.bg, body: view),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 300));
}

void _expectOnScreen(WidgetTester tester, Finder f) {
  expect(f, findsOneWidget, reason: '$f');
  final rect = tester.getRect(f);
  final screen = Offset.zero & tester.view.physicalSize;
  expect(
      screen.contains(rect.topLeft) &&
          screen.contains(rect.bottomRight - const Offset(.01, .01)),
      isTrue,
      reason: '$f 화면 밖 $rect');
  for (final s in find.ancestor(of: f, matching: find.byType(Scrollable)).evaluate()) {
    final view = tester.getRect(find.byWidget(s.widget));
    expect(rect.top >= view.top - .5 && rect.bottom <= view.bottom + .5, isTrue,
        reason: '$f 스크롤해야 보인다');
  }
}

void main() {
  test('다시 시도 경고는 어느 가전에나 맞는 말 — 토글 전용 "꺼질 수 있어요"를 쓰지 않는다(UI 평가 10/17)', () {
    expect(kDontRetryIfOn, isNot(contains('꺼질')));
    expect(kDontRetryIfOn, contains('한 번 더 하지 마세요'));
  });

  test('연습 띠는 경로를 가리지 않는 말이다 — ThinQ 연습 중에 "누르지"라 하지 않는다(2026-10-16 결함 ⑤)', () {
    expect(kPracticeBandText, isNot(contains('누르')));
    expect(kPracticeBandText, startsWith('연습이에요'));
  });

  setUpAll(() async {
    if (!_hasFont) return;
    final bytes = File(_fontPath).readAsBytesSync();
    await (FontLoader('Malgun')..addFont(Future.value(ByteData.view(bytes.buffer))))
        .load();
  });

  // ── 1단계: 완료·정지 대기·비상 버튼 + B2 + 잘림 B7·B9 ───────────────────────
  group('1단계 · 완료 화면', () {
    // 휴리스틱 평가(10/18): 눌렸는지 모르면 주 행동은 '움직였어요 / 안 움직였어요' — 처음 화면으로는 테두리 보조,
    // 한 번 더 하기는 '안 움직였어요' 뒤(R1), 골라 누르기는 두지 않는다.
    testWidgets('실패 — 가장 큰 글자는 할 일, 가전을 보고 답하기가 먼저, 처음 화면으로는 보조, 한 번 더 하기는 답한 뒤', (tester) async {
      await _pumpView(
        tester,
        KioskDoneView(
          success: false,
          label: '즉석밥 데워줘',
          target: kMicrowaveAppliance,
          onRetry: () {},
          onManual: () {},
          onDismiss: () {},
        ),
      );
      expect(find.text('눌렸는지 몰라요'), findsOneWidget);
      final sizes = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.style?.fontSize ?? 0)
          .toList();
      final head = tester.widget<Text>(find.text('눌렸는지 몰라요'));
      expect(head.style!.fontSize, sizes.reduce((a, b) => a > b ? a : b));
      // 다시 시도 위험(열린 문제 R1) — 당부는 화면에 한 번, '다시 시도' 확인 창에만 있다(쉬운 말 10/17).
      expect(find.textContaining('이미 움직이고 있으면 한 번 더 하지 마세요'), findsNothing);
      expect(find.textContaining('두 번 누르지 않'), findsNothing);
      expect(_inButton<OutlinedButton>('처음 화면으로'), findsOneWidget);
      expect(find.text('한 번 더 하기'), findsNothing);
      expect(find.text('누름 장치로 골라 누르기'), findsNothing);
      expect(find.text('닫기'), findsNothing);
      expect(find.text('버튼으로 조작'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('done-check-no')));
      await tester.pump();
      expect(_inButton<OutlinedButton>('한 번 더 하기'), findsOneWidget);
      // 다시 시도를 누르면 확인 창이 당부를 한 번 말한다.
      await tester.tap(find.text('한 번 더 하기'));
      await tester.pumpAndSettle();
      expect(find.textContaining('이미 움직이고 있으면 한 번 더 하지 마세요'), findsOneWidget);
    });

    testWidgets('B2 — 다시 보낼 요청이 없으면(놓친 결과·폰이 시작한 실행) 다시 시도도, 그 당부도 없다',
        (tester) async {
      final api = FakeKioskApi()
        ..statusResult = const KioskStatus(
            running: false, lastJobId: 'job-0', lastStatus: 'succeeded', lastOutcome: 'success');
      await _pumpKiosk(tester, api);
      // 폰이 시작해 폴링 사이에 끝난 실행 — 키오스크가 다시 보낼 요청이 없다.
      api.statusResult = const KioskStatus(
          running: false,
          lastJobId: 'job-phone',
          lastApplianceId: 'microwave',
          lastStatus: 'failed',
          lastOutcome: 'failed',
          lastRoute: 'physical');
      await _nextPoll(tester);
      await tester.pump(const Duration(milliseconds: 900));
      expect(find.byType(KioskDoneView), findsOneWidget);
      expect(find.text('한 번 더 하기'), findsNothing);
      expect(find.textContaining('다시 시도하지 마세요'), findsNothing);
      expect(find.text('처음 화면으로'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('B2 — 이 화면이 시작한 실행이면 다시 시도가 있고 같은 요청을 다시 보낸다', (tester) async {
      final api = FakeKioskApi()..suggestionList = [_sug];
      await _pumpKiosk(tester, api);
      await _finishOwn(
          tester,
          api,
          const KioskStatus(
              running: false, lastJobId: 'job-1', lastStatus: 'failed', lastOutcome: 'failed'));
      // 휴리스틱 평가(10/18): '안 움직였어요'라고 답한 뒤에 보인다.
      await tester.tap(find.byKey(const ValueKey('done-check-no')));
      await tester.pump();
      expect(find.text('한 번 더 하기'), findsOneWidget);
      // 당부는 확인 창에만(쉬운 말 10/17).
      expect(find.textContaining('이미 움직이고 있으면 한 번 더 하지 마세요'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('성공·전력 확인 — 전력 변화를 본 것만 <가전 이름>이 켜졌어요, 할 일은 원하는 대로 됐는지 보기', (tester) async {
      await _pumpView(
        tester,
        KioskDoneView(
          success: true,
          label: '즉석밥 데워줘',
          executionMode: 'real',
          target: kMicrowaveAppliance,
          operationConfirmed: true,
          operationSource: 'real',
          onDismiss: () {},
        ),
      );
      // 띠('가전 상태 확인')·제목·본문이 같은 확인 수준(전력 변화)을 말한다(외부 평가 10/16 2차 k06).
      expect(find.text('전자레인지가 켜졌어요'), findsOneWidget);
      expect(find.text('다 눌렀어요'), findsNothing);
      // 띠도 같은 수준 — '가전 상태 확인'은 한 단계 강했다(외부 평가 10/16 3차).
      expect(find.text('됐어요'), findsOneWidget);
      expect(find.text('가전 상태 확인'), findsNothing);
      expect(find.text('원하는 대로 됐는지 봐 주세요'),
          findsOneWidget);
      expect(find.textContaining('켜진 것'), findsNothing);
      expect(find.textContaining('동작도 확인'), findsNothing);
    });

    testWidgets('사용자 정지 — mcu_ack에는 확인(✓) 표시가 없다', (tester) async {
      await _pumpView(
        tester,
        const KioskDoneView(
          success: false,
          label: '즉석밥 데워줘',
          reason: KioskFailureReason.stopped,
          executionMode: 'real',
          stopLevel: 'mcu_ack',
          stopAckMs: 12,
        ),
      );
      expect(find.byIcon(Icons.verified_outlined), findsNothing);
      expect(find.byIcon(Icons.check), findsNothing);
      // 받음은 '멈추는 중'까지 — 멈췄다고 하지 않는다(평가 4차 10/18: 기계 말 대신 사람이 볼 상태).
      expect(find.text('누름 장치가 멈췄는지 몰라요'), findsOneWidget);
      expect(find.textContaining('멈췄어요'), findsNothing);
      // 주어는 누름 장치 — 실행·기계가 멈췄다고 하지 않는다.
      expect(find.text('실행을 멈췄어요'), findsNothing);
      expect(find.textContaining('기계'), findsNothing);
    });

    for (final success in [true, false]) {
      testWidgets('B7 — 1.6배 글자에서도 ${success ? '성공' : '실패'} 화면의 처음 화면으로가 화면 안에 있다',
          (tester) async {
        if (!_hasFont) return markTestSkipped('맑은 고딕 없음');
        await _pumpView(
          tester,
          KioskDoneView(
            success: success,
            label: '냉동 만두 데워서 라면이랑 같이 먹을 준비',
            executionMode: 'mock',
            target: kMicrowaveAppliance,
            onRetry: () {},
            onManual: () {},
            onDismiss: () {},
          ),
          scale: 1.6,
          malgun: true,
        );
        expect(tester.takeException(), isNull);
        _expectOnScreen(tester, find.text('처음 화면으로'));
        expect(find.text('처음 화면으로').hitTestable(), findsOneWidget);
      });
    }
  });

  group('1단계 · 동작 중 화면', () {
    KioskStatus hover({String mode = 'real', bool? op, String? source,
            bool latched = false, String? detail}) =>
        KioskStatus(
          running: false,
          holdState: 'hovering_stop',
          holdApplianceId: 'microwave',
          holdStopButton: '취소',
          holdExecutionMode: mode,
          lastOperationConfirmed: op,
          lastOperationSource: source,
          estopLatched: latched,
          estopDetail: latched ? detail : null,
        );

    testWidgets('가전 동작을 전력으로 확인하지 못했으면 가전이 돈다고 하지 않는다 — 누름 장치가 기다린다', (tester) async {
      final api = FakeKioskApi()..statusResult = hover();
      await _pumpKiosk(tester, api);
      await _nextPoll(tester);
      expect(find.byType(KioskHoldView), findsOneWidget);
      expect(find.text('누름 장치가 전자레인지 옆에서 기다리고 있어요'), findsOneWidget);
      expect(find.textContaining('동작 중'), findsNothing);
      expect(find.text('정지를 누르면 누름 장치가 취소 버튼을 대신 눌러요'), findsOneWidget);
      // 정지 대기 안내는 흰색 — 주의색은 몰라요에만.
      final guide = tester.widget<Text>(find.text('정지를 누르면 누름 장치가 취소 버튼을 대신 눌러요'));
      expect(guide.style?.color, isNot(KioskColors.primary));
      expect(guide.style?.color, isNot(KioskColors.warning));
      // 버튼판 그림은 누르는 자리라고 말한다.
      expect(find.text('누름 장치가 누르는 자리예요. 화면은 누르지 않아도 돼요'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('전력으로 확인했으면 가전이 돌아가고 있다고 한다', (tester) async {
      final api = FakeKioskApi()..statusResult = hover(op: true, source: 'real');
      await _pumpKiosk(tester, api);
      await _nextPoll(tester);
      expect(find.text('전자레인지가 돌아가고 있어요'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('비상 버튼이 눌려 있으면 제목이 위 띠와 같은 말 — 돌아간다고 하지 않는다', (tester) async {
      final api = FakeKioskApi()
        ..statusResult = hover(op: true, source: 'real', latched: true, detail: _buttonDetail);
      await _pumpKiosk(tester, api);
      await _nextPoll(tester);
      expect(find.byType(KioskHoldView), findsOneWidget);
      expect(find.text('누름 장치를 쓸 수 없어요'), findsOneWidget);
      expect(find.textContaining('돌아가고 있어요'), findsNothing);
      // 정지 단추 자리는 그대로(같은 자리·크기), 지금은 못 누른다는 것을 글자와 흐린 테두리로 말한다
      // (UI 평가 4차 10/17 — 회색이어도 흰 테두리가 남아 누를 수 있는 것처럼 보였다).
      final stop = find.descendant(of: find.byType(KioskHoldView), matching: find.text('정지'));
      expect(stop.hitTestable(), findsOneWidget);
      final button = tester.widget<ElevatedButton>(find.byKey(const ValueKey('hold-stop')));
      expect(button.onPressed, isNull);
      final shape = button.style!.shape!.resolve({WidgetState.disabled}) as RoundedRectangleBorder;
      expect(shape.side.color, isNot(Colors.white));
      expect(find.text('비상 버튼을 풀면 정지 버튼을 다시 쓸 수 있어요'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('정지 몰라요 — 가장 큰 글자는 직접 누르라는 할 일, 단추는 다시 정지 시도(크기 그대로)', (tester) async {
      await _pumpView(
        tester,
        const KioskHoldView(
          appliance: kMicrowaveAppliance,
          holdState: 'hovering_stop',
          stopOutcome: 'requested_unconfirmed',
          stopButton: '취소',
          executionMode: 'real',
          elapsed: Duration(minutes: 1),
          onStop: _noop,
          onClose: _noop,
        ),
      );
      const todo = '지금 전자레인지 취소 버튼을 손으로 눌러 주세요';
      expect(find.text(todo), findsOneWidget);
      // 정지 단추 이름(단추 크기는 원칙 0-4로 고정)을 뺀 안내 글자 중에서 가장 크다.
      final inStop = find
          .descendant(
              of: find.byKey(const ValueKey('hold-stop')),
              matching: find.byType(Text))
          .evaluate()
          .map((e) => e.widget)
          .toSet();
      final sizes = tester
          .widgetList<Text>(find.byType(Text))
          .where((t) => !inStop.contains(t))
          .map((t) => t.style?.fontSize ?? 0);
      expect(tester.widget<Text>(find.text(todo)).style!.fontSize,
          sizes.reduce((a, b) => a > b ? a : b));
      expect(find.text('다시 멈추기'), findsOneWidget);
      final button = tester.getSize(find.byKey(const ValueKey('hold-stop')));
      expect(button.height, 96);
    });

    // B9: 큰 글씨에서 왼쪽 안내가 넘치면 잘린 채 끝나 보였다 — 스크롤 막대가 늘 보인다.
    for (final panel15 in [false, true]) {
      testWidgets('B9 — ${panel15 ? '1920x1080' : '800x480'} 큰 글씨에서 넘치는 안내에는 스크롤 막대가 보인다',
          (tester) async {
        if (!_hasFont) return markTestSkipped('맑은 고딕 없음');
        tester.view.physicalSize =
            panel15 ? const Size(1920, 1080) : const Size(800, 480);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        final hold = KioskHoldView(
          appliance: kMicrowaveAppliance,
          holdState: 'hovering_stop',
          stopButton: '취소',
          executionMode: 'mock',
          elapsed: const Duration(minutes: 1, seconds: 2),
          buttonsPressed: 3,
          operationConfirmed: true,
          operationSource: 'mock',
          stopRequested: true,
          // 2026-10-16 글자 4단계(설명은 본문 크기)로 이 조건만으로는 넘치지 않게 됐다 — 서버 상세 한 줄을 더해
          // 넘치는 경우를 계속 본다(시험의 뜻: 넘치면 막대가 보인다).
          // 평가 6차(10/18)로 연습 대기 본문이 한 줄 줄었다 — 넘치는 경우를 계속 보려고 상세를 한 문장 더 길게.
          detail: '연습용 대기예요. 정지를 누르면 누름 장치가 정지 버튼 자리를 짚고, 다 짚으면 제자리로 돌아가요. '
              '연습이라 실제 가전 전원과 전력은 바뀌지 않아요. '
              '연습을 마치면 처음 화면으로 돌아가고, 기록에는 연습이라고 남아요. '
              '실제로 쓸 때는 누름 장치가 가전 앞에서 기다리다가 정지를 누르면 바로 정지 버튼을 눌러요. '
              '그동안 화면은 누르지 않아도 되고, 가전을 직접 멈추고 싶으면 가전의 버튼을 눌러도 돼요.',
          onStop: () {},
        );
        await tester.pumpWidget(MaterialApp(
          theme: ThemeData(fontFamily: 'Malgun', brightness: Brightness.dark),
          home: Builder(builder: (context) {
            final scaled = MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(1.22)),
              child: Scaffold(backgroundColor: KioskColors.bg, body: hold),
            );
            return panel15 ? KioskCanvas(child: scaled) : scaled;
          }),
        ));
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);
        // 연습에는 '끝나는 시간은 몰라요'를 두지 않는다(평가 4차 10/18) — 서버 상세 줄로 본다.
        final left = find.ancestor(
            of: find.textContaining('연습용 대기예요'),
            matching: find.byType(RawScrollbar));
        expect(left, findsOneWidget);
        expect(tester.widget<RawScrollbar>(left).thumbVisibility, isTrue);
        final pos = tester
            .state<ScrollableState>(
                find.descendant(of: left, matching: find.byType(Scrollable)))
            .position;
        expect(pos.maxScrollExtent, greaterThan(0),
            reason: '이 시험은 넘치는 경우를 본다 — 넘치지 않으면 시험 조건을 바꿔야 한다');
      });
    }
  });

  group('1단계 · 비상 버튼 띠', () {
    testWidgets('제목·풀기 안내·풀기 — 풀어도 멈췄던 일은 이어서 하지 않는다', (tester) async {
      final api = FakeKioskApi()
        ..statusResult = const KioskStatus(
            running: false, estopLatched: true, estopDetail: _buttonDetail);
      await _pumpKiosk(tester, api);
      final banner = find.byKey(_banner);
      expect(find.descendant(of: banner, matching: find.text('비상 버튼이 눌려 있어요')), findsOneWidget);
      // 서버 문장이 제목을 되풀이하면 머리를 떼고 나머지만 — 같은 말이 띠 안에 두 번 보이지 않는다.
      expect(find.descendant(of: banner, matching: find.textContaining('비상 버튼이 눌려 있어요')),
          findsOneWidget);
      // 평소 화면 상태 칩은 '모두 정상'이 아니다(평가 4차 10/18) — 띠와 같은 문장은 되풀이하지 않고 빨강 아이콘만(평가 5차 10/18).
      final chip = find.byKey(const ValueKey('idle-status-chip'));
      expect(find.descendant(of: chip, matching: find.text('기기 모두 정상')), findsNothing);
      expect(chip, findsNothing); // 평가 14차(10/18): 연결이 괜찮으면 칩 없음(글자 없는 '!' 원은 장식)
      expect(find.text('비상 버튼이 눌려 있어요'), findsOneWidget);
      expect(find.text('빨간 비상 버튼을 돌려서 풀어 주세요'), findsOneWidget);
      expect(find.text('푸는 방법 보기'), findsOneWidget);
      await tester.tap(find.byKey(_ack));
      await _settle(tester);
      expect(find.textContaining('빨간 비상 버튼을 돌려서 풀어 주세요'), findsOneWidget);
      expect(find.textContaining('풀어도 멈췄던 일은 이어서 하지 않아요'), findsOneWidget);
      // 자동 실행 허용 규칙은 꺼지지 않는다 — 꺼진다고 말하지 않는다.
      expect(find.textContaining('자동 실행'), findsNothing);
      expect(find.text('풀기'), findsOneWidget);
      expect(api.estopAckCalls, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('가전 콘센트 장치가 다시 켜져 꺼진 걸림은 비상 버튼이라고 하지 않고, 해제하면 전원이 켜진다고 한다',
        (tester) async {
      final api = FakeKioskApi()
        ..statusResult = const KioskStatus(
            running: false, estopLatched: true, estopDetail: _rebootDetail)
        ..statusAfterAck = const KioskStatus(running: false);
      await _pumpKiosk(tester, api);
      expect(find.text('비상 버튼이 눌려 있어요'), findsNothing);
      // 사전 변경(평가 4차 10/18): 콘센트 → 전기 플러그. 같은 말은 띠 한 곳 — 칩은 아이콘만(평가 5차 10/18).
      expect(find.text('전기 플러그 전원이 꺼져 있어요'), findsOneWidget);
      await tester.tap(find.byKey(_ack));
      await _settle(tester);
      expect(find.textContaining('풀면 전기 플러그 전원이 다시 켜져요'), findsOneWidget);
      expect(find.textContaining('빨간 비상 버튼'), findsNothing);
      await tester.tap(find.byKey(_confirm));
      await _settle(tester);
      expect(find.text('풀었어요. 전기 플러그 전원을 다시 켰어요.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('제안 화면에서도 띠가 보이고, 그 화면에 있는 동안 새로 걸린 것도 보인다', (tester) async {
      final api = FakeKioskApi()..suggestionList = [_sug];
      await _pumpKiosk(tester, api);
      expect(find.byType(KioskSuggestionView), findsOneWidget);
      expect(find.byKey(_banner), findsNothing);
      api.statusResult = const KioskStatus(
          running: false, estopLatched: true, estopDetail: _buttonDetail);
      await _nextPoll(tester);
      expect(find.byType(KioskSuggestionView), findsOneWidget);
      expect(find.byKey(_banner), findsOneWidget);
      // 띠는 승인 단추를 가리지 않는다.
      expect(find.byKey(_approveKey).hitTestable(), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('수동 조작·완료 화면에서도 띠가 보인다', (tester) async {
      final api = FakeKioskApi()
        ..applianceList = const [kMicrowaveAppliance, _thinqAirForEstop]
        ..statusResult = const KioskStatus(
            running: false, estopLatched: true, estopDetail: _buttonDetail);
      await _pumpKiosk(tester, api);
      await _nextPoll(tester);
      // 누름 장치 가전은 비상 버튼 동안 '지금 못 써요' — 누르면 수동 조작이 아니라 띠의 풀기 안내가 열린다(평가 4차 10/18).
      expect(find.text('지금 못 써요'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('strip-microwave')));
      await _settle(tester);
      expect(find.byType(KioskManualView), findsNothing);
      expect(find.byKey(_confirm), findsOneWidget);
      expect(api.estopAckCalls, 0);
      await tester.tap(find.byKey(const ValueKey('estop-cancel')));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('strip-air_purifier')));
      await _settle(tester);
      expect(find.byType(KioskManualView), findsOneWidget);
      expect(find.byKey(_banner), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('kiosk-back')));
      await _settle(tester);
      // 완료 화면(놓친 결과)
      api.statusResult = const KioskStatus(
          running: false,
          lastJobId: 'job-9',
          lastApplianceId: 'microwave',
          lastStatus: 'failed',
          lastOutcome: 'failed',
          estopLatched: true,
          estopDetail: _buttonDetail);
      await _nextPoll(tester);
      await tester.pump(const Duration(milliseconds: 900));
      expect(find.byType(KioskDoneView), findsOneWidget);
      expect(find.byKey(_banner), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('잠시 쉬기 창을 열어도 띠는 가려지지 않는다', (tester) async {
      final api = FakeKioskApi()
        ..statusResult = const KioskStatus(
            running: false, estopLatched: true, estopDetail: _buttonDetail);
      await _pumpKiosk(tester, api);
      await tapIdleMenuItem(tester, 'dnd-entry');
      await _settle(tester);
      expect(find.byKey(_ack).hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });


  // ── 2단계: 실행 화면·연습 + B1 + 실행 이름 2줄 ─────────────────────────────
  group('2단계 · 실행 화면', () {
    Widget exec({
      String title = '즉석밥 데워줘',
      String mode = 'real',
      String? button = '즉석밥',
      int attempt = 1,
      int? completed = 0,
      int? total = 2,
      double? confidence,
      String? detail,
      ApplianceMap? target = kMicrowaveAppliance,
    }) =>
        KioskExecutingView(
          executionMode: mode,
          title: title,
          target: target,
          lastButtons: null,
          currentButton: button,
          currentAttempt: attempt,
          completedSteps: completed,
          totalSteps: total,
          verificationConfidence: confidence,
          verificationDetail: detail,
          onStop: () {},
        );

    testWidgets('B1 — 첫 버튼을 누르는 중이면 0단계가 아니라 1번째', (tester) async {
      await _pumpView(tester, exec(completed: 0, total: 2));
      expect(find.text('누를 버튼 2개 중 1번째'), findsOneWidget);
      expect(find.textContaining('0단계'), findsNothing);
      expect(find.textContaining('단계'), findsNothing);
    });

    testWidgets('B1 — 다 끝났으면 모두 눌렀어요', (tester) async {
      await _pumpView(tester, exec(completed: 2, total: 2));
      expect(find.text('2개 모두 눌렀어요'), findsOneWidget);
    });

    testWidgets('B1 — 스크린리더도 같은 번호를 읽는다', (tester) async {
      final handle = tester.ensureSemantics();
      await _pumpView(tester, exec(completed: 0, total: 2));
      expect(find.bySemanticsLabel(RegExp('누를 버튼 2개 중 1번째')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('0단계')), findsNothing);
      handle.dispose();
    });

    testWidgets('숫자 근거(mA·dB·%) 없이 무엇을 보는지만 말한다', (tester) async {
      await _pumpView(tester, exec(confidence: 0.93, detail: '전류 +14mA · 소리 +9dB'));
      expect(find.text('눌렀어요, 확인 중이에요'), findsOneWidget); // 결선 모의 평가 10/18 — 누른 뒤 확인 단계
      expect(find.text('가전이 켜지는지 보고 있어요'), findsNothing); // 위 상태와 같은 말 — 하나만(평가 15차 10/18)
      expect(find.textContaining('mA'), findsNothing);
      expect(find.textContaining('dB'), findsNothing);
      expect(find.textContaining('%'), findsNothing);
    });

    testWidgets('다시 누를 때 — 자리를 맞춰 다시 누르는 중, 한 번 더 눌러요(안전하다고는 하지 않는다)', (tester) async {
      await _pumpView(tester, exec(attempt: 2, confidence: 0.4, detail: '전류 +2mA'));
      expect(find.text('자리를 맞춰 다시 누르는 중'), findsOneWidget);
      expect(find.textContaining('눌렸는지 몰라서 한 번 더 눌러요'), findsOneWidget);
      expect(find.textContaining('2번째 시도'), findsOneWidget);
      expect(find.textContaining('보정'), findsNothing);
      expect(find.textContaining('두 번 누르지 않'), findsNothing);
    });

    testWidgets('버튼판 그림 위에 누르는 자리라고 말한다', (tester) async {
      await _pumpView(tester, exec());
      expect(find.text('누름 장치가 누르는 자리예요. 화면은 누르지 않아도 돼요'), findsOneWidget);
    });

    testWidgets('긴 실행 이름은 2줄까지 줄이지 않고 보인다', (tester) async {
      if (!_hasFont) return markTestSkipped('맑은 고딕 없음');
      const long = '냉동 만두 데워서 라면이랑 같이 먹을 저녁 준비';
      await _pumpView(tester, exec(title: long), malgun: true);
      // 할 일 이름은 위 띠로 올라갔다(10/18) — 띠에서 말줄임 없이.
      expect(find.textContaining(long), findsOneWidget);
      expect(tester.renderObject<RenderParagraph>(find.textContaining(long)).didExceedMaxLines,
          isFalse);
    });

    testWidgets('연습 — 맨 위 띠로 말하고 실물 동사(누르는 중·눌렸는지) 대신 짚는다', (tester) async {
      await _pumpView(tester, exec(mode: 'mock', completed: 1, total: 2, confidence: 1, detail: '모의 검증'));
      expect(find.text(kPracticeBandText), findsOneWidget);
      expect(find.text('연습 모드'), findsNothing);
      expect(find.text('누르는 연습 중'), findsOneWidget);
      expect(find.text('누를 버튼 2개 중 2번째'), findsOneWidget);
      expect(find.text('누르고 있어요'), findsNothing);
      expect(find.textContaining('눌렸는지'), findsNothing);
      expect(find.textContaining('모의'), findsNothing);
      // 띠는 1.6배 글자에서도 줄지 않는다(말줄임 없음).
    });

    testWidgets('연습 띠는 1.6배 글자에서도 말줄임 없이 화면 맨 위에 있다', (tester) async {
      if (!_hasFont) return markTestSkipped('맑은 고딕 없음');
      await _pumpView(tester, exec(mode: 'mock'), scale: 1.6, malgun: true);
      expect(tester.takeException(), isNull);
      final band = find.text(kPracticeBandText);
      expect(band, findsOneWidget);
      expect(tester.renderObject<RenderParagraph>(band).didExceedMaxLines, isFalse);
      expect(tester.getRect(band).top, lessThan(40));
    });

    test('연습 확인 칩에도 실물 동사가 없다', () {
      for (final c in ['operation_confirmed', 'press_confirmed', 'reported']) {
        final label = confirmationLabel(
            route: 'physical', confirmation: c, executionMode: 'mock')!;
        expect(label, isNot(contains('확인')), reason: label);
        expect(label, contains('연습'));
      }
    });
  });


  // ── 3단계: 쉬운 말 + B3·B4·B5·B8·B10 ─────────────────────────────────────
  group('3단계 · 쉬운 말', () {
    testWidgets('제안 — 이번엔 안 할게요 · 누름 장치가 누를 순서 · N초 뒤 닫혀요', (tester) async {
      await _pumpView(
        tester,
        KioskSuggestionView(
          suggestion: const KioskSuggestion(
              id: 's', purpose: '즉석밥 데워줘', occurrences: 3, timeBand: '아침',
              applianceId: 'microwave', steps: ['즉석밥', '시작']),
          target: kMicrowaveAppliance,
          cdRemaining: 20,
          cdTotal: 20,
          onApprove: () {},
          onReject: () {},
        ),
      );
      expect(find.text('이번엔 안 할게요'), findsOneWidget);
      expect(find.text('다음에'), findsNothing);
      // 버튼판 안내는 실행 화면과 같이 '화면은 누르지 않아도 돼요'까지(접근성 감사 10/18).
      expect(find.text('누름 장치가 누를 순서예요. 화면은 누르지 않아도 돼요'), findsOneWidget);
      expect(find.text('누르지 않으면 하지 않아요'), findsOneWidget);
      expect(find.text('20초 뒤 닫혀요'), findsOneWidget); // 남은 시간은 따로 크게(결선 모의 평가 10/18)
      // 서버 문장이 없을 때의 대체문 — 기간을 모르니 '최근'은 없다.
      expect(find.text('아침에 3번 하셨어요'), findsOneWidget);
      expect(find.textContaining('최근'), findsNothing);
    });

    testWidgets('B3 — 루틴 카드는 단계가 아니라 버튼 수·가전 설정 수·알림만', (tester) async {
      final routines = [
        KioskRoutine.fromJson({
          'id': 'a', 'name': '아침 데우기',
          'steps': [
            {'kind': 'press_sequence', 'appliance_id': 'microwave', 'buttons': ['즉석밥', '시작']},
            {'kind': 'press_sequence', 'appliance_id': 'microwave', 'buttons': ['취소']},
          ],
        }),
        KioskRoutine.fromJson({
          'id': 'b', 'name': '공기 맑게',
          'steps': [
            {'kind': 'thinq_command', 'appliance_id': 'microwave', 'action': 'set_wind_strength', 'args': {}},
          ],
        }),
        KioskRoutine.fromJson({
          'id': 'c', 'name': '약 알림', 'mode': 'notify',
          'steps': [
            {'kind': 'announce', 'appliance_id': 'microwave', 'text': '약 드세요'},
          ],
        }),
      ];
      await _pumpView(
        tester,
        KioskManualView(
          appliance: kMicrowaveAppliance,
          onExecute: (_) {},
          onCancel: () {},
          routines: routines,
          onRoutine: (_) {},
        ),
      );
      // 평가 6차(10/18): '누를 버튼 N개', LG 가전 단계는 결과 말(값이 없으면 지어내지 않고 '바람 세기 바꾸기').
      expect(find.text('누를 버튼 3개'), findsOneWidget);
      expect(find.text('전자레인지 바람 세기 바꾸기'), findsOneWidget);
      expect(find.text('알림만'), findsOneWidget);
      expect(find.textContaining('단계'), findsNothing);
      expect(find.text('새 루틴은 휴대폰 앱에서 만들어요'), findsOneWidget);
      expect(find.textContaining('녹화'), findsNothing);
    });

    testWidgets('B10 — 수동 조작 설명은 누름 장치가 대신 누른다고, 잘리지 않게(2줄 허용)', (tester) async {
      if (!_hasFont) return markTestSkipped('맑은 고딕 없음');
      await _pumpView(
        tester,
        KioskManualView(appliance: kMicrowaveAppliance, onExecute: (_) {}, onCancel: () {}),
        scale: 1.22,
        malgun: true,
      );
      const explain = '화면 버튼을 누르면 누름 장치가 전자레인지 버튼을 대신 눌러요';
      expect(find.text(explain), findsOneWidget);
      expect(tester.renderObject<RenderParagraph>(find.text(explain)).didExceedMaxLines, isFalse);
      expect(tester.renderObject<RenderParagraph>(find.text('전자레인지')).didExceedMaxLines, isFalse);
      expect(find.textContaining('허브'), findsNothing);
    });

    for (final (reason, readiness, todo) in [
      ('버튼 자리를 아직 맞추지 않았어요', 'needs_setup', '휴대폰 앱에서 이 가전 버튼 자리 맞추기를 해 주세요'),
      ('확인한 지 오래돼 다시 확인해야 해요', 'needs_setup', '휴대폰 앱에서 이 가전 버튼 자리 맞추기를 해 주세요'),
      ('모터가 아직 준비되지 않았어요', 'needs_setup', '잠시 기다려 주세요. 계속되면 누름 장치를 다시 켜 주세요'),
      ('기기와 연결되지 않았어요', 'disconnected', '처음 화면 위쪽 연결 표시를 눌러 봐 주세요'),
    ]) {
      testWidgets('준비 안 됨 — "$reason"에는 할 일 한 줄', (tester) async {
        await _pumpView(
          tester,
          KioskManualView(
            appliance: ApplianceMap(
              id: 'microwave', name: '전자레인지', category: 'microwave', rows: 1, cols: 1,
              buttons: const [ApplianceButton(id: 'BT-05', label: '시작', x: 0, y: 0)],
              canExecute: false, readiness: readiness, readinessReasons: [reason]),
            onExecute: (_) {},
            onCancel: () {},
          ),
        );
        expect(find.text(reason), findsOneWidget);
        expect(find.text(todo), findsOneWidget);
      });
    }

    KioskIdleView idle({List<ApplianceMap>? appliances, DateTime? dnd}) => KioskIdleView(
          now: DateTime(2026, 9, 30, 7, 8),
          connected: true,
          appliances: appliances,
          dndUntil: dnd,
          onSelectAppliance: (_) {},
          onOpenConnection: (_) {},
          onDndGesture: () {},
        );

    testWidgets('B5 — 빈 가전 줄 안내는 누를 수 없으니 + 아이콘이 아니다, SimpleLay 본체·휴대폰 앱', (tester) async {
      await _pumpView(tester, idle(appliances: const []));
      expect(find.text('휴대폰 앱에서 가전을 추가해 주세요'), findsOneWidget);
      expect(find.byIcon(Icons.add_circle_outline), findsNothing);
      await _pumpView(tester, idle(appliances: null));
      expect(find.text('본체와 연결되면 가전이 보여요'), findsOneWidget);
      expect(find.textContaining('허브'), findsNothing);
    });

    testWidgets('가전 줄 넘김 단추는 "다음" 글자와 몇 번째 장', (tester) async {
      await _pumpView(tester, idle(appliances: [
        kMicrowaveAppliance,
        kInductionAppliance,
        for (var i = 0; i < 3; i++)
          ApplianceMap(id: 'x$i', name: '가전$i', category: 'other', rows: 1, cols: 1, buttons: const []),
      ]));
      // '다음 1/2'을 한 줄에 두면 큰 글씨에서 잘렸다(평가 3차 10/18) — 단추 아래 '다음', 두 화살표 사이에 쪽 번호.
      expect(find.descendant(of: find.byKey(const ValueKey('strip-next')), matching: find.text('다음')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('strip-page')), findsOneWidget);
      expect(find.text('1/2'), findsOneWidget);
    });

    testWidgets('B8 — 제안 쉬는 중 칩은 큰 글씨에서 같이 커지고 남은 시간이라고 말한다', (tester) async {
      final until = DateTime(2026, 9, 30, 8, 38);
      await _pumpView(tester, idle(dnd: until));
      expect(find.text('쉬는 중'), findsOneWidget);
      expect(find.text('1시간 30분 남음'), findsOneWidget);
      final small = tester.getSize(find.text('1시간 30분 남음')).height;
      await _pumpView(tester, idle(dnd: until), scale: 1.22);
      expect(tester.takeException(), isNull);
      final large = tester.getSize(find.text('1시간 30분 남음')).height;
      expect(large, greaterThan(small));
    });

    testWidgets('잠시 쉬기 창 — 이름과 쉬는 범위, 쉬기 끝내기', (tester) async {
      await _pumpView(tester, DndOverlay(dndUntil: null, onSet: (_) {}, onClear: () {}, onDismiss: () {}));
      expect(find.text('잠시 쉬기'), findsOneWidget);
      // 자동 계열 이름 하나로(평가 4차 10/18) — 문장 안에서는 '자동으로 하는 일'.
      expect(find.text('새 제안과 자동으로 하는 일을 잠시 쉬어요'), findsOneWidget);
      expect(find.textContaining('방해 금지'), findsNothing);
      await _pumpView(
          tester,
          DndOverlay(
              dndUntil: DateTime(2026, 9, 30, 8, 38),
              dndScope: 'suggestions_only',
              onSet: (_) {},
              onClear: () {},
              onDismiss: () {}));
      expect(find.text('쉬기 끝내기'), findsOneWidget);
      expect(find.textContaining('새 제안만 쉬어요. 자동으로 하는 일은 그대로예요'), findsOneWidget);
    });

    testWidgets('B4 — 연결 창: 다시 연결해 보기, 본체 풀이 줄 없음, 큰 글씨에서 잘리지 않고 막대가 보인다', (tester) async {
      if (!_hasFont) return markTestSkipped('맑은 고딕 없음');
      await _pumpView(
        tester,
        KioskConnectionModal(
          item: const ConnectionItem(
            id: 'network',
            state: 'error',
            title: '와이파이 연결이 끊겼어요',
            message: '본체가 집 와이파이에 연결되지 않았어요. 휴대폰 앱에서 찾지 못하고, 날씨 안내도 볼 수 없어요.',
            fixes: [
              '공유기 전원이 켜져 있는지 확인해 주세요.',
              '그래도 안 되면 본체 전원을 껐다가 다시 켜 주세요.',
            ],
          ),
          checking: false,
          onRecheck: () {},
          onClose: () {},
        ),
        scale: 1.22,
        malgun: true,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('다시 연결해 보기'), findsOneWidget);
      expect(find.text('다시 연결하기'), findsNothing);
      expect(find.text('다시 연결해 보기').hitTestable(), findsOneWidget);
      expect(find.text('닫기').hitTestable(), findsOneWidget);
      final bar = find.ancestor(
          of: find.textContaining('공유기 전원이'), matching: find.byType(RawScrollbar));
      expect(bar, findsOneWidget);
      expect(tester.widget<RawScrollbar>(bar).thumbVisibility, isTrue);
      // 이름이 '본체'로 짧아져 풀이 줄은 뺐다(쉬운 말 10/17).
      expect(find.textContaining('이 화면이 달린 상자'), findsNothing);
    });

    // UI 평가 10/17: 연결 창이 글자 단위로 끊기고('주세/요.'·'선/이') 셋째 항목은 스크롤해야 보였다.
    testWidgets('연결 창(보통 글씨): 어절 단위 줄바꿈, 스크롤 없이 마지막 항목까지 보인다', (tester) async {
      if (!_hasFont) return markTestSkipped('맑은 고딕 없음');
      await _pumpView(
        tester,
        KioskConnectionModal(
          item: const ConnectionItem(
            id: 'network',
            state: 'error',
            title: '와이파이 연결이 끊겼어요',
            message: '본체가 집 와이파이에 연결되지 않았어요. 휴대폰 앱에서 찾지 못하고, 날씨 안내도 볼 수 없어요.',
            fixes: [
              '공유기 전원이 켜져 있는지 확인해 주세요.',
              '그래도 안 되면 본체 전원을 껐다가 다시 켜 주세요.',
            ],
          ),
          checking: false,
          onRecheck: () {},
          onClose: () {},
        ),
        malgun: true,
      );
      expect(tester.takeException(), isNull);
      final last = find.textContaining('껐다가');
      expect(last.hitTestable(), findsOneWidget, reason: '스크롤 없이 셋째 항목이 보인다');
      final lastRect = tester.getRect(last);
      final closeTop = tester.getRect(find.text('닫기')).top;
      expect(lastRect.bottom, lessThanOrEqualTo(closeTop), reason: '버튼 줄 위에서 끝난다');
      final scroll = tester.widget<SingleChildScrollView>(find.byType(SingleChildScrollView).first);
      expect(scroll.controller?.position.maxScrollExtent ?? 0, lessThanOrEqualTo(1), reason: '스크롤할 거리가 없다');
      expect(tester.widget<RichText>(find.descendant(of: find.textContaining('공유기 전원이').first,
              matching: find.byType(RichText)).first).text.toPlainText(includeSemanticsLabels: false),
          contains('⁠'), reason: '어절 단위 줄바꿈(단어 결합 문자)');
    });

    testWidgets('생활 습관 — 기간을 같이 말하고, 숨김은 상태로, 글자를 키웠다', (tester) async {
      await _pumpView(
        tester,
        LearningStatusDialog(load: () async => learning.status(), applianceNames: const {'mw': '주방 전자레인지'}),
      );
      await tester.pumpAndSettle();
      const days = '최근 28일 중 2일, 모두 5번';
      expect(find.text(days), findsOneWidget);
      expect(find.text('이 제안은 보이지 않게 해 뒀어요'), findsOneWidget);
      expect(find.text('추천 숨김'), findsNothing);
      expect(tester.widget<Text>(find.text(days)).style?.fontSize, greaterThanOrEqualTo(20));
      expect(find.textContaining('모의'), findsNothing);
    });

    test('사용자에게 보이는 문자열에 옛 말(허브·다시 연결하기·방해 금지·녹화·추천 숨김·작은 팔)이 없다', () {
      final literal = RegExp(r"'[^'\n]*'");
      final old = ['허브', '다시 연결하기', '방해 금지', '녹화', '추천 숨김', '작은 팔', '작은팔'];
      for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        for (final line in f.readAsLinesSync()) {
          final code = line.trimLeft();
          if (code.startsWith('//')) continue;
          for (final m in literal.allMatches(line)) {
            for (final w in old) {
              expect(m.group(0)!.contains(w), isFalse, reason: '${f.path}: $line');
            }
          }
        }
      }
    });
  });

  test('문구 금지어 — 거짓이 될 문장은 키오스크 코드에 없다', () {
    final banned = [
      '두 번 누르지 않아요', // 자동 재시도는 L1만 보고 다시 누른다(R1)
      '자동 실행도 꺼져요', // 비상 버튼 해제로 자동 실행 규칙이 꺼지지 않는다
      '버튼 조작을 마쳤어요',
      '확인하고 해제',
    ];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      final text = f.readAsStringSync();
      for (final b in banned) {
        expect(text.contains(b), isFalse, reason: '${f.path}: $b');
      }
    }
  });
}

void _noop() {}
