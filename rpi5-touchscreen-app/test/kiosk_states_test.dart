// 키오스크 네 상태(UI 확정 2026-09-30 §3) — 평소 · 다가오면 · 동작 중 · 내 가전.
//
// 가짜 API(kiosk_phase_test의 FakeKioskApi)로 KioskScreen 전체를 띄워 본다.
// 실물 검증이 아니다 — 서버 응답 모양과 화면 규칙까지다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/ambient.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/screens/kiosk_screen.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/theme/kiosk_colors.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/appliance_strip.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/connection_status.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/executing_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/hold_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/kiosk_canvas.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/kiosk_timings.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/manual_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/practice_band.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/suggestion_view.dart';

import 'kiosk_phase_test.dart' show FakeEventStream, FakeKioskApi, FakeTts;

ApplianceMap _appliance(String id, String name, {String category = 'other'}) =>
    ApplianceMap(
      id: id,
      name: name,
      category: category,
      rows: 1,
      cols: 2,
      buttons: const [
        ApplianceButton(id: 'B1', label: '전원', x: 0, y: 0),
        ApplianceButton(id: 'B2', label: '시작', x: 1, y: 0),
      ],
      readiness: 'operable',
    );

final _six = [
  kMicrowaveAppliance,
  _appliance('washer', '세탁기', category: 'washing_machine'),
  _appliance('fan', '선풍기'),
  _appliance('rice', '밥솥', category: 'rice_cooker'),
  _appliance('aircon', '에어컨', category: 'air_conditioner'),
  _appliance('intercom', '인터폰'),
];

const _ambient = AmbientInfo(
  greeting: '좋은 아침이에요.',
  tip: AmbientTip(kind: 'rain', text: '오후 3시부터 비 예보가 있어요. 우산 챙기세요.', icon: 'rain'),
  hourly: [
    AmbientHour(label: '9시', icon: 'partly', temp: 16),
    AmbientHour(label: '12시', icon: 'cloudy', temp: 18),
    AmbientHour(label: '15시', icon: 'rain', temp: 17, pop: 70, precip: true),
    AmbientHour(label: '18시', icon: 'rain', temp: 15, pop: 60, precip: true),
  ],
  weatherSource: 'mock',
);

const _plugWeak = ConnectionItem(
  id: 'plug',
  state: 'warn',
  // 서버 문장(쉬운 말 4차 b039967 — 콘센트 → 전기 플러그).
  title: '전기 플러그 연결이 약해요',
  message: '가전이 끝났다는 알림이 늦거나 오지 않을 수 있어요.',
  fixes: ['전기 플러그가 벽에 끝까지 꽂혀 있는지 봐 주세요.', '그래도 안 되면 전기 플러그를 뽑았다가 10초 뒤 다시 꽂아 주세요.'],
  source: 'real',
);

Future<void> _pump(WidgetTester tester, FakeKioskApi api,
    {Size size = const Size(1920, 1080)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: KioskScreen(api: api, tts: FakeTts(), events: FakeEventStream()),
  ));
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

/// 가장자리 안전 여백(1920x1080 출력 기준 논리 48px). 플랫폼 창 관리자가
/// 가장자리에서 시작한 터치를 시스템 제스처로 가져간다(2026-09-30 실기기).
const _safe = Rect.fromLTRB(48, 48, 1920 - 48, 1080 - 48);

/// 화면이 그린 누르는 자리 — 캔버스 안의 것만 센다(Navigator·라우트 장벽 같은
/// 프레임워크 배관은 누르는 자리가 아니다). 키오스크의 모든 화면·오버레이·모달은
/// 캔버스 안에 그린다.
List<Rect> _tappableRects(WidgetTester tester) {
  final finder = find.descendant(
      of: find.byType(KioskCanvas),
      matching: find.byWidgetPredicate((w) =>
      (w is GestureDetector &&
          (w.onTap != null ||
              w.onTapDown != null ||
              w.onLongPress != null ||
              w.onHorizontalDragEnd != null)) ||
      (w is InkResponse && (w.onTap != null || w.onLongPress != null)) ||
      (w is Listener && w.onPointerDown != null)));
  return [
    for (final e in finder.evaluate())
      if (e.renderObject is RenderBox &&
          (e.renderObject! as RenderBox).hasSize &&
          !(e.renderObject! as RenderBox).size.isEmpty)
        tester.getRect(find.byElementPredicate((x) => x == e)),
  ];
}

void _expectEdgeSafe(WidgetTester tester, String state) {
  final rects = _tappableRects(tester);
  expect(rects, isNotEmpty, reason: '$state: 누를 것이 하나도 없다');
  for (final r in rects) {
    expect(
      r.left >= _safe.left - 0.5 &&
          r.top >= _safe.top - 0.5 &&
          r.right <= _safe.right + 0.5 &&
          r.bottom <= _safe.bottom + 0.5,
      isTrue,
      reason: '$state: 누르는 자리 $r가 가장자리 안전 여백 $_safe 밖',
    );
  }
}

KioskStatus _hovering({
  String state = 'hovering_stop',
  String? outcome,
  String? detail,
  String mode = 'mock',
}) =>
    KioskStatus(
      running: false,
      holdState: state,
      holdStopOutcome: outcome,
      holdDetail: detail,
      holdApplianceId: 'microwave',
      holdStopButton: '취소',
      holdExecutionMode: mode,
      lastOutcome: 'success',
      lastJobId: 'job-9',
      lastApplianceId: 'microwave',
      lastExecutionMode: mode,
      lastButtons: const [
        KioskButtonResult(button: '해동', success: true),
        KioskButtonResult(button: '1분', success: true),
        KioskButtonResult(button: '시작', success: true),
      ],
    );

void main() {
  // ── 평소 ──────────────────────────────────────────────────────────────
  group('평소', () {
    testWidgets('인사말·날씨 한 줄·예보 4칸을 서버 값 그대로 보인다', (tester) async {
      final api = FakeKioskApi()
        ..applianceList = _six
        ..ambientResult = _ambient;
      await _pump(tester, api);

      expect(find.byType(KioskIdleView), findsOneWidget);
      // 안내는 한 번에 하나 — 안내 카드가 있으면 인사말은 접는다(UI 확정 §3-1).
      expect(find.text('좋은 아침이에요'), findsNothing);
      expect(find.text('오후 3시부터 비 예보가 있어요. 우산 챙기세요'), findsOneWidget);
      // 보통 글씨에서는 안내와 예보 4칸을 함께 보인다(10/5 사용자 결정).
      expect(find.byKey(const ValueKey('ambient-hours')), findsOneWidget);
      // 예보 칸 이름은 오전/오후로(평가 4차 10/18 — 시계·루틴과 같은 표기). 지금 시각에 가까운 칸(±90분)은
      // 첫 칸 '지금'이 된다(사용자 요청 10/18) — 이 시험은 실제 시계를 쓰므로 둘 중 하나로 본다.
      {
        final shown = ['오전 9시', '오후 12시', '오후 3시', '오후 6시']
            .where((l) => find.text(l).evaluate().isNotEmpty)
            .length;
        final now = find.text('지금').evaluate().length;
        expect(now, lessThanOrEqualTo(1));
        expect(shown + now, 4, reason: '4칸');
        expect(shown, greaterThanOrEqualTo(3));
      }

      // 안내가 없으면 인사말과 예보 4칸을 서버 값 그대로 보인다.
      api.ambientResult = AmbientInfo(
          greeting: _ambient.greeting,
          // 비 확률이 높은 칸이 있으면 인사말을 뺀다(평가 14차 10/18) — 여기서는 비 소식 없는 예보로 인사말을 본다.
          hourly: [
            for (final h in _ambient.hourly)
              AmbientHour(label: h.label, hour: h.hour, icon: h.icon == 'rain' ? 'cloudy' : h.icon, temp: h.temp),
          ],
          weatherSource: _ambient.weatherSource);
      await tester.pumpWidget(const SizedBox.shrink());
      await _pump(tester, api);
      expect(find.text('좋은 아침이에요'), findsOneWidget);
      // 예보 칸 이름은 오전/오후로(평가 4차 10/18 — 시계·루틴과 같은 표기). 지금 시각에 가까운 칸(±90분)은
      // 첫 칸 '지금'이 된다(사용자 요청 10/18) — 이 시험은 실제 시계를 쓰므로 둘 중 하나로 본다.
      {
        final shown = ['오전 9시', '오후 12시', '오후 3시', '오후 6시']
            .where((l) => find.text(l).evaluate().isNotEmpty)
            .length;
        final now = find.text('지금').evaluate().length;
        expect(now, lessThanOrEqualTo(1));
        expect(shown + now, 4, reason: '4칸');
        expect(shown, greaterThanOrEqualTo(3));
      }
      // 강수확률 칸은 다른 시험(kiosk_idle_next_line_test '비 70%')이 본다 — 여기는 비 소식 없는 예보(평가 14차 10/18).
      expect(
          find.descendant(of: find.byKey(const ValueKey('ambient-hours')), matching: find.text('16°')),
          findsOneWidget);
      // 고정 명령 버튼은 없다
      expect(find.text('즉석밥'), findsNothing);
    });

    testWidgets('예보가 없으면 인사말만 — 안내·예보를 지어내지 않는다', (tester) async {
      final api = FakeKioskApi()
        ..applianceList = _six
        ..ambientResult = const AmbientInfo(greeting: '편안한 저녁이에요.');
      await _pump(tester, api);

      expect(find.text('편안한 저녁이에요'), findsOneWidget);
      expect(find.byKey(const ValueKey('ambient-tip')), findsNothing);
      expect(find.byKey(const ValueKey('ambient-hours')), findsNothing);
    });

    testWidgets('연결이 모두 정상이면 "!" 배지가 없다', (tester) async {
      final api = FakeKioskApi()..applianceList = _six;
      await _pump(tester, api);

      // 모두 괜찮으면 상태 칩이 없다(사용자 결정 10/18 — 체크·'기기 모두 정상'도 없다).
      expect(find.byKey(const ValueKey('idle-status-chip')), findsNothing);
      expect(find.text('기기 모두 정상'), findsNothing);
      expect(find.text('!'), findsNothing);
    });

    testWidgets('등록된 가전이 없으면 앱에서 추가하라고 말한다', (tester) async {
      final api = FakeKioskApi()..applianceList = const [];
      await _pump(tester, api);

      expect(find.text('휴대폰 앱에서 가전을 추가해 주세요'), findsOneWidget);
    });
  });

  // ── "!" 모달 ──────────────────────────────────────────────────────────
  group('연결 문제 "!" 모달', () {
    testWidgets('문제가 있는 연결에만 배지가 붙고, 누르면 설명·해결 방법·다시 확인하기가 뜬다',
        (tester) async {
      final api = FakeKioskApi()
        ..applianceList = _six
        ..connectionsResult = [
          const ConnectionItem(id: 'network', state: 'ok', title: '와이파이에 연결돼 있어요', message: ''),
          const ConnectionItem(id: 'press', state: 'ok', title: '누름 장치가 연결돼 있어요', message: ''),
          _plugWeak,
        ];
      await _pump(tester, api);

      // 문제가 있을 때만 앰버 칩 '연결 확인 필요 1'(사용자 결정 10/18) — 하나뿐이면 누르면 그 연결 창이 바로 열린다.
      expect(find.text('연결 확인 필요 1'), findsOneWidget);
      expect(find.text('와이파이 연결이 끊겼어요'), findsNothing);
      expect(find.text('누름 장치 연결이 끊겼어요'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('idle-status-chip')));
      await _settle(tester);

      expect(find.byType(KioskConnectionModal), findsOneWidget);
      expect(find.text('전기 플러그 연결이 약해요'), findsOneWidget);
      expect(find.textContaining('알림이 늦거나 오지 않을 수 있어요'), findsOneWidget);
      expect(find.text('전기 플러그가 벽에 끝까지 꽂혀 있는지 봐 주세요'), findsOneWidget);

      // 다시 연결하기 = 연결 상태를 다시 묻는다(서버에 재연결 명령은 없다)
      final before = api.connectionsCalls;
      api.connectionsResult = [
        const ConnectionItem(id: 'network', state: 'ok', title: '와이파이에 연결돼 있어요', message: ''),
        const ConnectionItem(id: 'press', state: 'ok', title: '누름 장치가 연결돼 있어요', message: ''),
        const ConnectionItem(id: 'plug', state: 'ok', title: '전기 플러그가 연결돼 있어요', message: '가전이 끝나면 알려 드릴게요.'),
      ];
      await tester.tap(find.text('다시 연결해 보기'));
      await _settle(tester);
      expect(api.connectionsCalls, greaterThan(before));
      expect(find.text('연결 확인 필요 1'), findsNothing); // 다 괜찮아지면 칩이 사라진다
      expect(find.text('전기 플러그가 연결돼 있어요'), findsOneWidget);

      await tester.tap(find.text('닫기'));
      await _settle(tester);
      expect(find.byType(KioskConnectionModal), findsNothing);
    });

    testWidgets('허브에 닿지 못하면 와이파이에 배지 — 모름을 정상으로 두지 않는다', (tester) async {
      final api = FakeKioskApi()
        ..connectionsResult = null
        ..healthResult = HealthStatus.disconnected;
      await _pump(tester, api);

      // 본체에 닿지 않는 것은 와이파이 탓으로 단정하지 않는다 — 칩은 '본체와 연결이 끊겼어요'(평가 7차 10/18).
      expect(find.text('본체와 연결이 끊겼어요'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('idle-status-chip')));
      await _settle(tester);
      expect(find.text('본체와 연결되지 않았어요'), findsOneWidget);
    });
  });

  // ── 가전 줄: 3개씩(큰 글씨 2개) 넘기기 + 동작 중 앞으로 ───────────────────────────────
  group('가전 줄', () {
    test('확인 필요 → 동작 중 → 나머지(등록 순서 유지)', () {
      final ordered = orderForStrip(_six,
          running: {'intercom'}, attention: {'rice'});
      expect(ordered.map((a) => a.id).toList(),
          ['rice', 'intercom', 'microwave', 'washer', 'fan', 'aircon']);
    });

    // 이름(전자레인지·거실 선풍기)을 줄이지 않으려고 보통 글씨는 한 장에 3개(10/5).
    // 평가 5차(10/18): 넓은 장 넘김 칸 때문에 3개만 들어가 오른쪽이 비었다 — 한 장에 4개 + 좁은 장 넘김(쪽 번호 아래 화살표 하나).
    testWidgets('한 번에 4개, 화살표로 넘기고 마지막 장에서는 이전 화살표 하나', (tester) async {
      final api = FakeKioskApi()..applianceList = _six;
      await _pump(tester, api);

      for (final id in ['microwave', 'washer', 'fan', 'rice']) {
        expect(find.byKey(ValueKey('strip-$id')), findsOneWidget, reason: id);
      }
      expect(find.byKey(const ValueKey('strip-aircon')), findsNothing);
      expect(find.byKey(const ValueKey('strip-intercom')), findsNothing);
      expect(find.byKey(const ValueKey('strip-prev')), findsNothing);
      expect(find.byKey(const ValueKey('strip-next')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('strip-next')));
      await _settle(tester);
      expect(find.byKey(const ValueKey('strip-aircon')), findsOneWidget);
      expect(find.byKey(const ValueKey('strip-intercom')), findsOneWidget);
      expect(find.byKey(const ValueKey('strip-microwave')), findsNothing);
      // 마지막 장 — 다음 화살표 자리에 이전 화살표(두 장이면 '이전').
      expect(find.byKey(const ValueKey('strip-next')), findsNothing);
      expect(find.byKey(const ValueKey('strip-prev')), findsOneWidget);
      expect(find.text('이전'), findsOneWidget);

      // 손가락으로 밀어도 넘어간다
      await tester.fling(find.byType(KioskApplianceStrip), const Offset(400, 0), 800);
      await _settle(tester);
      expect(find.byKey(const ValueKey('strip-microwave')), findsOneWidget);
    });

    testWidgets('뒤쪽 가전이 동작을 시작하면 맨 앞으로 올라온다', (tester) async {
      final api = FakeKioskApi()..applianceList = _six;
      await _pump(tester, api);
      expect(find.byKey(const ValueKey('strip-intercom')), findsNothing);

      // 폰에서 인터폰을 실행 — 키오스크는 실행 화면으로 갔다가
      api.statusResult = const KioskStatus(
          running: true, jobId: 'job-p', applianceId: 'intercom');
      await tester.pump(const Duration(seconds: 2));
      await _settle(tester);
      expect(find.byType(KioskExecutingView), findsOneWidget);
      // 같은 순서 규칙을 가진 줄은 평소 화면에서 본다: 끝난 뒤 실패로 확인이 필요하면 맨 앞
      api.statusResult = const KioskStatus(
          running: false,
          lastJobId: 'job-p',
          lastOutcome: 'failed',
          lastStatus: 'failed',
          lastApplianceId: 'intercom');
      await tester.pump(const Duration(seconds: 2));
      await _settle(tester);
      await tester.tap(find.text('처음 화면으로'));
      await _settle(tester);
      expect(find.byType(KioskIdleView), findsOneWidget);
      final first = tester.getRect(find.byKey(const ValueKey('strip-intercom')));
      final second = tester.getRect(find.byKey(const ValueKey('strip-microwave')));
      expect(first.left, lessThan(second.left));
      expect(find.text('확인 필요'), findsOneWidget);
    });

    testWidgets('정지 버튼 대기 중인 가전은 "동작 중"으로 맨 앞에 선다', (tester) async {
      final api = FakeKioskApi()..applianceList = _six;
      await _pump(tester, api);
      final ordered = orderForStrip(_six, running: {'aircon'}, attention: {});
      expect(ordered.first.id, 'aircon');
    });

    // 2026-10-16: ThinQ로 켜져 있다고 확인된 가전은 쉬는 가전보다 앞, 동작 중·확인 필요보다는 뒤.
    test('확인 필요 → 동작 중 → 켜짐 → 나머지', () {
      final ordered = orderForStrip(_six,
          running: {'aircon'}, attention: {'rice'}, on: {'intercom', 'rice'});
      expect(ordered.map((a) => a.id).toList(),
          ['rice', 'aircon', 'intercom', 'microwave', 'washer', 'fan']);
    });

    testWidgets('켜져 있다고 확인된 가전은 첫 장 맨 앞에 초록 "켜져 있어요"으로 선다', (tester) async {
      final api = FakeKioskApi()
        ..applianceList = _six
        ..powerOn = {'intercom'};
      await _pump(tester, api);

      expect(api.powerCalls, greaterThan(0));
      final first = tester.getRect(find.byKey(const ValueKey('strip-intercom')));
      final second = tester.getRect(find.byKey(const ValueKey('strip-microwave')));
      expect(first.left, lessThan(second.left));
      final label = find.descendant(
          of: find.byKey(const ValueKey('strip-intercom')),
          matching: find.text('켜져 있어요'));
      expect(label, findsOneWidget);
      expect(tester.widget<Text>(label).style?.color, KioskColors.confirmed);
      expect(find.text('켜져 있어요'), findsOneWidget);
    });

    testWidgets('전원 상태를 모르면 "켜져 있어요"을 달지 않고 순서도 등록 순서 그대로', (tester) async {
      final api = FakeKioskApi()..applianceList = _six;
      await _pump(tester, api);
      expect(find.text('켜져 있어요'), findsNothing);
      expect(find.byKey(const ValueKey('strip-intercom')), findsNothing);
      expect(find.byKey(const ValueKey('strip-microwave')), findsOneWidget);
    });

    testWidgets('켜짐이 늦게 확인되면 다음 조회(10초)에서 앞으로 올라온다', (tester) async {
      final api = FakeKioskApi()..applianceList = _six;
      await _pump(tester, api);
      expect(find.byKey(const ValueKey('strip-intercom')), findsNothing);
      api.powerOn = {'intercom'};
      await tester.pump(const Duration(seconds: 10));
      await tester.pump();
      expect(find.byKey(const ValueKey('strip-intercom')), findsOneWidget);
      expect(find.text('켜져 있어요'), findsOneWidget);
      // 다시 모르게 되면 표시를 내린다(지어내지 않는다).
      api.powerOn = {};
      await tester.pump(const Duration(seconds: 10));
      await tester.pump();
      expect(find.text('켜져 있어요'), findsNothing);
    });
  });

  // ── 다가오면 ──────────────────────────────────────────────────────────
  group('다가오면', () {
    testWidgets('제안 카드 한 장 — 루틴 이름·근거·누를 순서, 버튼은 시작과 이번엔 안 할게요 뿐', (tester) async {
      final api = FakeKioskApi()
        ..applianceList = _six
        ..suggestionList = const [
          KioskSuggestion(
            id: 'r1',
            purpose: '아침 데우기',
            occurrences: 5,
            timeBand: '아침',
            applianceId: 'microwave',
            steps: ['해동', '1분', '시작'],
            routineId: 'morning',
            routineName: '아침 데우기',
          ),
        ];
      await _pump(tester, api);

      expect(find.byType(KioskSuggestionView), findsOneWidget);
      // 질문이 이미 루틴 이름을 말하면 위 이름 줄은 되풀이하지 않는다(실패널 10/17).
      expect(find.textContaining('아침 데우기,'), findsOneWidget);
      expect(find.textContaining('내 루틴 "아침 데우기"'), findsNothing);
      expect(find.text('아침에 5번 하셨어요'), findsOneWidget);
      expect(find.byKey(const ValueKey('suggestion-approve')), findsOneWidget);
      expect(find.byKey(const ValueKey('suggestion-later')), findsOneWidget);
      expect(find.text('이 제안 다시 받지 않기'), findsNothing);
      expect(find.textContaining('30분 쉬기'), findsNothing);
      expect(find.text('이번 동작 바꾸기'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('suggestion-approve')));
      await tester.pump();
      expect(api.approvedIds, ['r1']);
    });

    testWidgets('다음에 = 이번만 넘기기(억제하지 않는다)', (tester) async {
      final api = FakeKioskApi()
        ..applianceList = _six
        ..suggestionList = const [
          KioskSuggestion(id: 'r1', purpose: '아침 데우기', occurrences: 0, applianceId: 'microwave'),
        ];
      await _pump(tester, api);
      await tester.tap(find.byKey(const ValueKey('suggestion-later')));
      await _settle(tester);
      expect(api.rejectedIds, ['r1']);
      expect(api.mutedIds, isEmpty);
    });
  });

  // ── 동작 중(정지 버튼 대기·보관) ─────────────────────────────────────────
  group('동작 중', () {
    testWidgets('정지 버튼 위 대기 — 근거 세 줄과 큰 정지 버튼, 연습 띠', (tester) async {
      final api = FakeKioskApi()
        ..applianceList = _six
        ..statusResult = _hovering();
      await _pump(tester, api);

      expect(find.byType(KioskHoldView), findsOneWidget);
      // 연습이면 제목이 가전이 돈다고 말하지 않는다 — 연습은 맨 위 띠로(2026-10-15).
      // 평가 6차(10/18): 제목이 상태('연습이 끝났어요'), 할 일은 한 줄 — '…연습 중' 제목과 '…마쳤어요' 본문이 부딪혔다.
      expect(find.text('연습이 끝났어요'), findsOneWidget);
      expect(find.text('전자레인지 연습 중'), findsNothing);
      // 정지 안내는 고르는 말(평가 11차 10/18).
      // 평가 14차(10/18): 연습을 마친 대기에는 정지 안내 문장을 두지 않는다.
      expect(find.textContaining('눌러 볼 수'), findsNothing);
      expect(find.text('빨간 정지를 눌러 보세요'), findsNothing);
      // 연습에는 가전 판정·끝나는 시간 줄을 두지 않는다 — 위 연습 띠('실제 가전은 그대로예요')와 부딪혔다(평가 4차 10/18).
      expect(find.text('가전이 켜졌는지는 몰라요'), findsNothing);
      expect(find.text('끝나는 시간은 몰라요'), findsNothing);
      expect(find.textContaining(RegExp(r'\d+:\d\d')), findsNothing);
      // 모의를 실물처럼 보이지 않는다
      expect(find.text(kPracticeBandText), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('hold-stop')));
      await tester.pump();
      expect(api.stopCalls, 1);
      // '보냈어요' 대신 사람이 볼 상태(평가 4차 10/18). 연습은 실제 가전이 그대로라 '가전을 봐 주세요'를 붙이지 않는다(평가 10차 10/18).
      // 평가 11차(10/18): 상태 한 문장 — 제목이 '연습을 끝내는 중이에요', '마쳤어요'는 남기지 않는다.
      expect(find.text('연습을 끝내는 중이에요'), findsOneWidget);
      expect(find.text('연습이 끝났어요'), findsNothing);

      api.statusResult = _hovering(state: 'stopping');
      await tester.pump(const Duration(seconds: 2));
      await _settle(tester);
      expect(find.text('정지 버튼을 누르는 연습 중이에요'), findsOneWidget);
    });

    testWidgets('정지됨 → 누름 장치가 제자리로 돌아갔어요를 짧게 보이고 평소 화면으로', (tester) async {
      final api = FakeKioskApi()
        ..applianceList = _six
        ..statusResult = _hovering();
      await _pump(tester, api);
      api.statusResult = _hovering(state: 'parked', outcome: 'stopped');
      await tester.pump(const Duration(seconds: 2));
      await _settle(tester);
      expect(find.text('누름 장치가 제자리로 돌아갔어요'), findsOneWidget);
      // 가전이 멈췄다는 말은 전력 하강으로 확인한 때(stopped)만 — 무엇으로 확인했는지까지.
      expect(find.text('전자레인지가 멈췄어요'), findsOneWidget);

      // 보관 표시는 완료 화면과 같은 복귀 시간(KioskTimings.doneReturn)을 쓴다.
      await tester.pump(KioskTimings.doneReturn + const Duration(seconds: 1));
      await _settle(tester);
      expect(find.byType(KioskIdleView), findsOneWidget);
    });

    testWidgets('정지 요청함·미확인은 멈췄다고 하지 않고, 사람이 닫을 때까지 남는다', (tester) async {
      final api = FakeKioskApi()
        ..applianceList = _six
        ..statusResult = _hovering();
      await _pump(tester, api);
      api.statusResult = _hovering(state: 'parked', outcome: 'requested_unconfirmed');
      await tester.pump(const Duration(seconds: 2));
      await _settle(tester);

      expect(find.textContaining('멈춘 것을'), findsNothing);
      // 상태 영역은 짧게(2026-10-16 디자인 규격 §1-2) — 무엇을 했는지는 할 일 아래 작은 줄이 말한다.
      expect(find.text('가전이 멈췄는지 몰라요'), findsOneWidget);
      // 가장 큰 글자는 할 일 한 가지 — 정지 버튼은 자리·크기·색 그대로 이름만 바뀐다(2026-10-15).
      expect(find.text('지금 전자레인지 취소 버튼을 손으로 눌러 주세요'), findsOneWidget);
      // 누름 장치가 제자리로 돌아갔으면 다시 멈출 것이 없다 — 이름은 '정지' 그대로(평가 16차 10/18).
      expect(find.text('다시 멈추기'), findsNothing);
      await tester.pump(const Duration(seconds: 10));
      await _settle(tester);
      expect(find.byType(KioskHoldView), findsOneWidget);
      await tester.tap(find.text('처음 화면으로'));
      await _settle(tester);
      expect(find.byType(KioskIdleView), findsOneWidget);
    });

    testWidgets('구동부 이상은 빨간 문구와 서버 설명을 남긴다', (tester) async {
      final api = FakeKioskApi()
        ..applianceList = _six
        ..statusResult = _hovering();
      await _pump(tester, api);
      api.statusResult = _hovering(
          state: 'fault',
          outcome: 'drive_fault',
          detail: '구동부 이상으로 정지 버튼을 누르지 못했어요 — 가전 전원을 직접 꺼 주세요');
      await tester.pump(const Duration(seconds: 2));
      await _settle(tester);
      expect(find.text('누름 장치에 문제가 생겼어요'), findsOneWidget);
      expect(find.text('구동부 이상으로 정지 버튼을 누르지 못했어요 — 가전 전원을 직접 꺼 주세요'),
          findsOneWidget);
      // 정지 버튼은 여전히 닿는다
      expect(find.byKey(const ValueKey('hold-stop')), findsOneWidget);
    });
  });

  // ── 내 가전 ───────────────────────────────────────────────────────────
  group('내 가전', () {
    testWidgets('가전 아이콘 → 버튼판과 내 루틴, 새 루틴은 휴대폰 앱에서 만든다는 안내', (tester) async {
      final api = FakeKioskApi()
        ..applianceList = _six
        ..routinesResult = const [
          KioskRoutine(id: 'morning', name: '아침 데우기', applianceIds: ['microwave'], pressCount: 3),
          KioskRoutine(id: 'laundry', name: '빨래 시작', applianceIds: ['washer'], pressCount: 2),
        ]
        ..triggerResult = const RoutineTriggerResult(
          suggestion: KioskSuggestion(
            id: 'card-1',
            purpose: '아침 데우기',
            occurrences: 0,
            applianceId: 'microwave',
            steps: ['해동', '1분', '시작'],
            routineId: 'morning',
            routineName: '아침 데우기',
          ),
        );
      await _pump(tester, api);

      await tester.tap(find.byKey(const ValueKey('strip-microwave')));
      await _settle(tester);
      expect(find.byType(KioskManualView), findsOneWidget);
      expect(find.text('전자레인지'), findsOneWidget);
      expect(find.text('아침 데우기'), findsOneWidget);
      expect(find.text('빨래 시작'), findsNothing); // 다른 가전의 루틴
      expect(find.text('새 루틴은 휴대폰 앱에서 만들어요'), findsOneWidget);

      // 루틴을 눌러도 바로 실행하지 않는다 — 카드(승인)로 간다
      await tester.tap(find.byKey(const ValueKey('routine-morning')));
      await _settle(tester);
      expect(api.triggeredRoutineIds, ['morning']);
      expect(api.approvedIds, isEmpty);
      expect(find.byType(KioskSuggestionView), findsOneWidget);
    });

    // 2026-10-14 4·5번 마감 확인 A1: 조용한 시간에도 사용자가 내 가전에서 직접 찾아 누른 루틴은 카드가 나온다
    // (서버가 '지금 실행' 카드를 사용자 요청으로 만든다). 새 제안이 저절로 뜨는 것과 구분한다.
    testWidgets('조용한 시간에도 내 가전에서 직접 누른 루틴은 카드로 간다', (tester) async {
      final api = FakeKioskApi()
        ..applianceList = _six
        ..healthResult = HealthStatus.fromJson(const {
          'ok': true,
          'quiet': {'enabled': true, 'start': '22:00', 'end': '07:00', 'active': true, 'reason': 'schedule'},
        })
        ..routinesResult = const [
          KioskRoutine(id: 'morning', name: '아침 데우기', applianceIds: ['microwave'], pressCount: 3),
        ]
        ..triggerResult = const RoutineTriggerResult(
          suggestion: KioskSuggestion(
            id: 'card-1',
            purpose: '아침 데우기',
            occurrences: 0,
            applianceId: 'microwave',
            steps: ['해동', '1분', '시작'],
            routineId: 'morning',
            routineName: '아침 데우기',
          ),
        );
      await _pump(tester, api);
      expect(find.byType(KioskSuggestionView), findsNothing); // 저절로 뜬 카드는 없다
      // 조용한 시간에는 처음 화면이 어둡다(사용자 결정 10/18) — 한 번 만져 밝게 한 뒤 고른다.
      await tester.tap(find.byKey(const ValueKey('idle-quiet-dim')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('strip-microwave')));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('routine-morning')));
      await _settle(tester);
      expect(api.triggeredRoutineIds, ['morning']);
      expect(find.byType(KioskSuggestionView), findsOneWidget);
      expect(api.approvedIds, isEmpty);
    });

    testWidgets('버튼판을 눌러도 확인 없이는 누르지 않는다', (tester) async {
      final api = FakeKioskApi()..applianceList = _six;
      await _pump(tester, api);
      await tester.tap(find.byKey(const ValueKey('strip-microwave')));
      await _settle(tester);

      await tester.tap(find.text('해동'));
      await _settle(tester);
      expect(find.byType(KioskExecutingView), findsNothing);
      expect(find.text("'해동' 버튼을 눌러 드릴까요?"), findsOneWidget);

      await tester.tap(find.text('그만두기'));
      await _settle(tester);
      expect(find.byType(KioskExecutingView), findsNothing);

      await tester.tap(find.text('해동'));
      await _settle(tester);
      await tester.tap(find.text('누르기'));
      await _settle(tester);
      expect(find.byType(KioskExecutingView), findsOneWidget);
    });
  });

  // ── 가장자리 안전 여백 ──────────────────────────────────────────────────
  group('1920x1080에서 누르는 자리는 모두 가장자리 48px 안쪽', () {
    testWidgets('평소 · 모달 · 내 가전 · 다가오면 · 동작 중 · 실행 · 실패', (tester) async {
      final api = FakeKioskApi()
        ..applianceList = _six
        ..ambientResult = _ambient
        ..connectionsResult = [
          const ConnectionItem(id: 'network', state: 'ok', title: 'ok', message: ''),
          const ConnectionItem(id: 'press', state: 'unknown', title: '누름 장치를 아직 확인하지 못했어요', message: ''),
          _plugWeak,
        ]
        ..routinesResult = const [
          KioskRoutine(id: 'morning', name: '아침 데우기', applianceIds: ['microwave'], pressCount: 3),
        ];
      await _pump(tester, api);

      // 평소 — 화살표가 두 쪽 다 보이게 한 장 넘긴 상태도 본다
      _expectEdgeSafe(tester, '평소');
      await tester.tap(find.byKey(const ValueKey('strip-next')));
      await _settle(tester);
      _expectEdgeSafe(tester, '평소(둘째 장)');
      await tester.tap(find.byKey(const ValueKey('strip-prev')));
      await _settle(tester);

      // 설정 진입은 구석이 아니다 — 메뉴 창 가운데 큰 줄(10/18). 메뉴 단추·창도 가장자리 여백 안.
      await tester.tap(find.byKey(const ValueKey('idle-menu')));
      await _settle(tester);
      _expectEdgeSafe(tester, '메뉴 창');
      final settings = tester.getCenter(find.byKey(const ValueKey('settings-entry')));
      expect(settings.dx, inInclusiveRange(1920 * 0.25, 1920 * 0.75),
          reason: '설정 진입 $settings가 구석에 있다');
      await tester.tap(find.byKey(const ValueKey('idle-sheet-close')));
      await _settle(tester);

      await tester.tap(find.byKey(const ValueKey('idle-status-chip')));
      await _settle(tester);
      _expectEdgeSafe(tester, '연결 모달');
      await tester.tap(find.text('닫기'));
      await _settle(tester);

      await tester.tap(find.byKey(const ValueKey('strip-microwave')));
      await _settle(tester);
      _expectEdgeSafe(tester, '내 가전');
      await tester.tap(find.text('해동'));
      await _settle(tester);
      _expectEdgeSafe(tester, '내 가전 누르기 확인');
      await tester.tap(find.text('그만두기'));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('kiosk-back')));
      await _settle(tester);

      // 다가오면
      api.suggestionList = const [
        KioskSuggestion(id: 's1', purpose: '아침 데우기', occurrences: 0, applianceId: 'microwave', steps: ['해동', '1분', '시작']),
      ];
      await tester.pump(const Duration(seconds: 2));
      await _settle(tester);
      expect(find.byType(KioskSuggestionView), findsOneWidget);
      _expectEdgeSafe(tester, '다가오면');

      // 실행(누르는 중) — 긴급 정지
      await tester.tap(find.byKey(const ValueKey('suggestion-approve')));
      await _settle(tester);
      api.statusResult = const KioskStatus(
          running: true, jobId: 'job-1', applianceId: 'microwave', totalSteps: 3, completedSteps: 1);
      await tester.pump(const Duration(seconds: 2));
      await _settle(tester);
      expect(find.byType(KioskExecutingView), findsOneWidget);
      _expectEdgeSafe(tester, '실행');

      // 실패 화면
      api.statusResult = const KioskStatus(
          running: false, lastJobId: 'job-1', lastOutcome: 'failed', lastStatus: 'failed', lastApplianceId: 'microwave');
      await tester.pump(const Duration(seconds: 2));
      await _settle(tester);
      await tester.pump(const Duration(seconds: 1));
      await _settle(tester);
      _expectEdgeSafe(tester, '실패');
      await tester.tap(find.text('처음 화면으로'));
      await _settle(tester);

      // 동작 중
      api.suggestionList = const [];
      api.statusResult = _hovering();
      await tester.pump(const Duration(seconds: 2));
      await _settle(tester);
      expect(find.byType(KioskHoldView), findsOneWidget);
      _expectEdgeSafe(tester, '동작 중');
    });
  });
}
