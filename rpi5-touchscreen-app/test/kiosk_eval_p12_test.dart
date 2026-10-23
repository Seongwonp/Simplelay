// 평가 12차(2026-10-18) 지적 수리 — 키오스크. 옛 코드에도 있는 공개 구성만 써서 옛 코드에서 실패하는 것을 확인한다.
//
// 1. 연습 대기(누르기를 다 마치고 정지를 기다림) — '처음 화면으로' 주 단추(연습일 때만, 정지 단추 자리·이름 그대로).
//    누르고 나가면 같은 연습 대기로 되돌아오지 않는다(서버 대기는 그대로 — 새 실행이 풀거나 연습 가전이 끝나면 보관).
//    실제 대기에는 나가는 단추가 없다(정지가 닿아야 한다). 기다리는 칸은 진행색(파랑)으로 채우지 않는다.
// 2. 실패·사용자 정지 결과 — 보조 단추 '누름 장치로 골라 누르기'는 두 화면에서 같은 꼴(테두리), '한 번 더 하기'는 안내 문장
//    바로 옆 작은 글자 단추(주 출구 하나 + 보조 묶음).
// 3. LG 가전 조작 — 공기 나쁨일 때만 할 일 한 줄(켜져 있으면 '바람을 세게 해 보세요', 꺼져 있으면 '켜 보세요'), 큰 글씨에서도
//    상태 줄이 맨 위.
// 4. 1~2 m 가독 — 예보 강수확률은 기온과 같은 크기, 넓은 글꼴(글자마다 넓힌 조건) + 다음 루틴 카드에서도 예보 줄이 보인다.
//    공기 줄 낱말 단위 줄바꿈, 가전 고르기 칸의 '지난번' 칩 자리 고정, LG 가전 보내는 중 주의문은 왼쪽 정렬 한 문장.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/appliance_art.dart';
import 'package:simplelay_touchscreen/models/ambient.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/models/thinq.dart';
import 'package:simplelay_touchscreen/screens/kiosk_screen.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/theme/kiosk_colors.dart';
import 'package:simplelay_touchscreen/theme/kiosk_tokens.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/appliance_select_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/done_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/executing_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/hold_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/manual_view.dart';

import 'kiosk_phase_test.dart' show FakeKioskApi, FakeTts, FakeEventStream;

void _noop() {}

const _windHint = '바람을 세게 해 보세요';
const _powerHint = '공기청정기를 켜 보세요';

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

/// 화면에 보이는 글 전부. 낱말 묶음 문자(U+2060·U+00A0)는 뗀다.
List<String> _texts(WidgetTester tester) => [
      for (final w in tester.widgetList<RichText>(find.byType(RichText)))
        w.text.toPlainText().replaceAll('⁠', '').replaceAll(' ', ' '),
    ];

Future<void> _pumpView(WidgetTester tester, Widget child, {double scale = 1.0, double letterSpacing = 0}) async {
  tester.view.physicalSize = const Size(800, 480);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(size: const Size(800, 480), textScaler: TextScaler.linear(scale)),
      child: Scaffold(
          backgroundColor: KioskColors.bg,
          body: DefaultTextStyle.merge(style: TextStyle(letterSpacing: letterSpacing), child: child)),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 300));
}

double _fontOf(WidgetTester tester, Finder text) {
  final rich = tester.widget<RichText>(find.descendant(of: text, matching: find.byType(RichText)).first);
  var size = rich.text.style?.fontSize;
  rich.text.visitChildren((s) {
    size ??= s.style?.fontSize;
    return size == null;
  });
  return size!;
}

// ── 1. 연습 대기 ───────────────────────────────────────────
KioskHoldView _hold({String mode = 'mock', VoidCallback? onClose}) => KioskHoldView(
      appliance: kMicrowaveAppliance,
      holdState: 'hovering_stop',
      stopButton: '취소',
      executionMode: mode,
      elapsed: const Duration(minutes: 1),
      buttonsPressed: 3,
      operationConfirmed: true,
      operationSource: mode,
      onStop: _noop,
      onClose: onClose,
    );

Finder _homeButton() => find.ancestor(
    of: find.text('처음 화면으로'), matching: find.byWidgetPredicate((w) => w is ElevatedButton));

KioskStatus _holdStatus({String mode = 'mock', String job = 'job-7'}) => KioskStatus(
      running: false,
      holdState: 'hovering_stop',
      holdApplianceId: 'microwave',
      holdStopButton: '취소',
      holdExecutionMode: mode,
      lastJobId: job,
      lastOutcome: 'success',
      lastApplianceId: 'microwave',
      lastButtons: const [KioskButtonResult(button: '해동', success: true)],
    );

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

Future<void> _poll(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 2));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

// ── 2. 결과 화면 ───────────────────────────────────────────
KioskDoneView _failed({bool userStop = false}) => KioskDoneView(
      success: false,
      executionMode: 'real',
      label: '즉석밥 데워줘',
      target: kMicrowaveAppliance,
      reason: userStop ? KioskFailureReason.stopped : null,
      // 멈춘 것을 확인한 정지 — 멈췄는지 모르면 골라 누르기 대신 '다시 멈추기'(평가 15차 10/18).
      stopLevel: userStop ? 'verified' : null,
      onRetry: _noop,
      onManual: _noop,
      onDismiss: _noop,
    );

// ── 3. LG 가전 조작 ───────────────────────────────────────
Map<String, dynamic> _state({String power = 'POWER_ON', String? level = 'BAD', String wind = 'LOW'}) => {
      'operation': {'airPurifierOperationMode': power},
      'airPurifierJobMode': {'currentJobMode': 'CLEAN'},
      'airFlow': {'windStrength': wind},
      if (level != null) 'airQualitySensor': {'PM2': 42, 'PM10': 90, 'PM2Level': level, 'PM10Level': 'NORMAL'},
      'filterInfo': {'filterRemainPercent': 87},
    };

Future<void> _pumpThinq(WidgetTester tester, Map<String, dynamic> state, {double scale = 1.0}) async {
  await _pumpView(
      tester,
      KioskManualView(
        appliance: _purifier,
        onExecute: (_) {},
        onCancel: () {},
        thinqRead: () async =>
            KioskThinqStatus(state: state, executionMode: 'real', readAt: DateTime(2026, 10, 16, 9, 7)),
        thinqSend: (_, __, ___) async => const KioskJobAccepted(jobId: 'j'),
        onThinqAccepted: (_, __) {},
      ),
      scale: scale);
  await tester.pump();
  await tester.pump();
}

// ── 4. 평소 화면 ───────────────────────────────────────────
const _hourly = [
  AmbientHour(label: '9시', hour: 9, icon: 'partly', temp: 16),
  AmbientHour(label: '12시', hour: 12, icon: 'cloudy', temp: 18),
  AmbientHour(label: '15시', hour: 15, icon: 'rain', temp: 17, pop: 70, precip: true),
  AmbientHour(label: '18시', hour: 18, icon: 'rain', temp: 15, pop: 60, precip: true),
];

KioskIdleView _idle({AmbientTip? tip, KioskNextRun? next, KioskAirReading? air}) => KioskIdleView(
      now: DateTime(2026, 9, 30, 7, 38),
      connected: true,
      ambient: AmbientInfo(greeting: '좋은 아침이에요.', tip: tip, hourly: _hourly, weatherSource: 'mock'),
      connections: const [
        ConnectionItem(id: 'network', state: 'ok', title: '', message: ''),
        ConnectionItem(id: 'press', state: 'ok', title: '', message: ''),
      ],
      appliances: [_purifier, kMicrowaveAppliance, kInductionAppliance],
      attention: const {},
      temperature: 23,
      humidity: 58,
      air: air,
      nextRun: next,
      onSelectAppliance: (_) {},
      onOpenConnection: (_) {},
      onDndGesture: () {},
    );

const _rainTip = AmbientTip(kind: 'rain', text: '오후 3시부터 비 예보가 있어요. 우산 챙기세요.', icon: 'rain');
const _nextRun = KioskNextRun(name: '저녁 공기청정기 켜기', dayLabel: '오늘', hhmm: '22:00', modeLabel: '자동 실행');
const _normalAir = KioskAirReading(applianceId: 'air_purifier', grade: 'NORMAL', pm25: 20, power: 'on');

/// [text] 안 [from]~[to] 글자가 한 줄에 있나 — 그린 글(낱말 묶음 문자 포함)에서 자리를 찾아 줄의 높이를 비교한다.
bool _sameLine(WidgetTester tester, Finder rich, String word) {
  final render = tester.renderObject<RenderParagraph>(rich);
  final drawn = render.text.toPlainText();
  final clean = drawn.replaceAll('⁠', '').replaceAll(' ', ' ');
  final at = clean.indexOf(word);
  expect(at, greaterThanOrEqualTo(0), reason: '$word가 화면 글에 있다');
  // 그린 글에서의 자리 — 묶음 문자를 세며 옮긴다.
  int drawnIndex(int cleanIndex) {
    var c = 0;
    for (var i = 0; i < drawn.length; i++) {
      if (drawn[i] == '⁠') continue;
      if (c == cleanIndex) return i;
      c++;
    }
    return drawn.length;
  }

  final first = render.getOffsetForCaret(TextPosition(offset: drawnIndex(at)), Rect.zero).dy;
  final last = render.getOffsetForCaret(TextPosition(offset: drawnIndex(at + word.length - 1)), Rect.zero).dy;
  return (first - last).abs() < 1;
}

void main() {
  group('1. 연습 대기 — 처음 화면으로 주 단추, 정지는 그대로', () {
    testWidgets('연습: 처음 화면으로(집 아이콘·중립 채움) + 정지 자리·이름 그대로', (tester) async {
      await _pumpView(tester, _hold());
      final stopBefore = tester.getRect(find.byKey(const ValueKey('kiosk-stop-area')));
      await _pumpView(tester, _hold(onClose: _noop));
      expect(_homeButton(), findsOneWidget);
      expect(find.descendant(of: _homeButton(), matching: find.byIcon(Icons.home_outlined)), findsOneWidget);
      final b = tester.widget<ButtonStyleButton>(_homeButton());
      expect(b.style!.backgroundColor!.resolve({}), KioskColors.neutralFill);
      expect(tester.getRect(find.byKey(const ValueKey('kiosk-stop-area'))), stopBefore, reason: '정지 자리 그대로');
      expect(find.descendant(of: find.byKey(const ValueKey('hold-stop')), matching: find.text('정지')), findsOneWidget);
      final home = tester.getRect(_homeButton());
      expect(home.right, lessThan(stopBefore.left), reason: '정지와 겹치지 않는 왼쪽');
      expect(home.bottom, greaterThan(480 * 0.6), reason: '비어 있던 왼쪽 아래');
      expect(tester.takeException(), isNull);
    });

    testWidgets('큰 글씨에서도 처음 화면으로·정지가 다 보인다', (tester) async {
      await _pumpView(tester, _hold(onClose: _noop), scale: 1.22);
      expect(_homeButton().hitTestable(), findsOneWidget);
      expect(find.byKey(const ValueKey('hold-stop')).hitTestable(), findsOneWidget);
      expect(tester.getRect(_homeButton()).bottom, lessThanOrEqualTo(480));
      expect(tester.takeException(), isNull);
    });

    testWidgets('기다리는 칸은 진행색(파랑)으로 채우지 않는다', (tester) async {
      await _pumpView(tester, _hold(onClose: _noop));
      // 연습을 마친 대기는 칸을 강조하지 않는다(평가 16차 10/18) — 진행색도 흰 테도 없다.
      expect(find.byKey(const ValueKey('panel-current')), findsNothing);
    });

    testWidgets('화면 — 연습 대기에서 처음 화면으로 나가면 같은 대기로 되돌아오지 않는다', (tester) async {
      final api = FakeKioskApi()..statusResult = _holdStatus();
      await _pumpKiosk(tester, api);
      await _poll(tester);
      expect(find.byType(KioskHoldView), findsOneWidget);
      await tester.tap(_homeButton());
      await tester.pump();
      expect(find.byType(KioskIdleView), findsOneWidget);
      for (var i = 0; i < 3; i++) {
        await _poll(tester);
      }
      expect(find.byType(KioskHoldView), findsNothing, reason: '서버는 아직 연습 대기 — 같은 대기는 다시 띄우지 않는다');
      expect(api.stopCalls, 0, reason: '나가기는 정지를 보내지 않는다');
      // 새 실행의 대기는 다시 보인다.
      api.statusResult = _holdStatus(job: 'job-8');
      await _poll(tester);
      expect(find.byType(KioskHoldView), findsOneWidget);
    });

    testWidgets('화면 — 실제 대기에는 나가는 단추가 없다(정지가 닿아야 한다)', (tester) async {
      final api = FakeKioskApi()..statusResult = _holdStatus(mode: 'real');
      await _pumpKiosk(tester, api);
      await _poll(tester);
      expect(find.byType(KioskHoldView), findsOneWidget);
      expect(find.text('처음 화면으로'), findsNothing);
    });
  });

  group('2. 결과 화면 — 보조 단추 한 꼴, 한 번 더 하기는 안내 옆', () {
    // 휴리스틱 평가(10/18): 눌렸는지 모르는 결과에는 '누름 장치로 골라 누르기'를 두지 않는다(가전을 보고 답한다, R1) —
    // 멈춘 것을 확인한 정지에만 남는다.
    testWidgets('눌렸는지 모름 — 골라 누르기 없음, 가전을 보고 답한다', (tester) async {
      await _pumpView(tester, _failed());
      expect(find.byKey(const ValueKey('done-manual')), findsNothing);
      expect(find.byKey(const ValueKey('done-check-yes')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    for (final userStop in [true]) {
      testWidgets(userStop ? '사용자 정지' : '눌렸는지 모름', (tester) async {
        await _pumpView(tester, _failed(userStop: userStop));
        final manual = find.byKey(const ValueKey('done-manual'));
        expect(tester.widget(manual), isA<OutlinedButton>(), reason: '두 화면 같은 꼴(테두리)');
        expect(find.descendant(of: manual, matching: find.text(kManualEntryLabel)), findsOneWidget);
        expect(kManualEntryLabel, contains('누름 장치'), reason: '손으로 누르라는 말과 헷갈리지 않게');
        expect(kManualEntryLabel.length, lessThan('누름 장치로 누를 버튼 고르기'.length), reason: '짧게');
        expect(tester.getSize(manual).height, greaterThanOrEqualTo(48));
        expect(tester.takeException(), isNull);
      });
    }

    // 평가 13차(10/18): 글자 단추는 꺼진 단추로 보였다 — 작은 테두리 보조 단추. 평가 15차(10/18): 주 단추 하나 + 보조 한 줄
    // (같은 폭·같은 높이·같은 오른쪽 끝) — 안내 문장 묶음 대신 누르면 뜨는 확인 창이 말한다.
    // 휴리스틱 평가(10/18): '한 번 더 하기'는 '안 움직였어요'라고 답한 뒤 — '손으로 할게요'와 같은 크기의 테두리 단추,
    // '손으로 할게요'가 앞(왼쪽). 안내 문장 묶음 대신 누르면 뜨는 확인 창이 말한다.
    testWidgets('한 번 더 하기는 안 움직였어요 뒤 손으로 할게요와 같은 꼴, 손으로 할게요가 앞', (tester) async {
      await _pumpView(tester, _failed());
      expect(find.byKey(const ValueKey('done-retry')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('done-check-no')));
      await tester.pump();
      expect(find.byKey(const ValueKey('done-retry-hint')), findsNothing);
      final retry = find.byKey(const ValueKey('done-retry'));
      expect(tester.widget(retry), isA<OutlinedButton>());
      final r = tester.getRect(retry);
      final h = tester.getRect(find.byKey(const ValueKey('done-check-hand')));
      expect((r.width - h.width).abs(), lessThan(1), reason: '같은 폭');
      expect((r.height - h.height).abs(), lessThan(1), reason: '같은 높이');
      expect(h.left, lessThan(r.left), reason: '손으로 할게요가 앞');
      expect(r.bottom, lessThanOrEqualTo(480));
      expect(tester.takeException(), isNull);
    });

    testWidgets('큰 글씨에서도 잘리지 않는다', (tester) async {
      await _pumpView(tester, _failed(), scale: 1.22);
      await tester.tap(find.byKey(const ValueKey('done-check-no')));
      await tester.pump();
      expect(find.byKey(const ValueKey('done-retry')).hitTestable(), findsOneWidget);
      expect(tester.getRect(find.byKey(const ValueKey('done-retry'))).bottom, lessThanOrEqualTo(480));
      expect(tester.takeException(), isNull);
    });
  });

  group('3. LG 가전 조작 — 공기 나쁠 때만 할 일 한 줄, 큰 글씨도 상태 줄이 맨 위', () {
    testWidgets('켜짐·나쁨·바람 약 → 바람을 세게 해 보세요', (tester) async {
      await _pumpThinq(tester, _state());
      expect(_texts(tester), contains(_windHint));
      expect(tester.takeException(), isNull);
    });

    testWidgets('꺼짐·나쁨 → 켜 보세요(꺼진 채 바람은 못 바꾼다)', (tester) async {
      await _pumpThinq(tester, _state(power: 'POWER_OFF'));
      expect(_texts(tester), isNot(contains(_windHint)));
      expect(_texts(tester), contains(_powerHint));
    });

    for (final (why, state) in [
      ('공기 보통', _state(level: 'NORMAL')),
      ('공기 값 없음', _state(level: null)),
      ('이미 바람 강', _state(wind: 'HIGH')),
    ]) {
      testWidgets('$why → 할 일 줄 없음', (tester) async {
        await _pumpThinq(tester, state);
        expect(_texts(tester), isNot(contains(_windHint)));
        expect(_texts(tester), isNot(contains(_powerHint)));
      });
    }

    testWidgets('큰 글씨 — 상태 줄이 조작 단추보다 위', (tester) async {
      await _pumpThinq(tester, _state(power: 'POWER_OFF', level: null), scale: 1.22);
      final line = tester.getRect(find.byKey(const ValueKey('thinq-state-headline')));
      final power = tester.getRect(find.byKey(const ValueKey('thinq-set-set_power-POWER_ON')));
      expect(line.bottom, lessThanOrEqualTo(power.top));
      expect(line.top, lessThan(120), reason: '첫 화면 위쪽');
      expect(find.byKey(const ValueKey('thinq-set-set_power-POWER_ON')).hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('4. 1~2 m 가독', () {
    testWidgets('예보 강수확률은 기온과 같은 크기', (tester) async {
      for (final tip in [null, _rainTip]) {
        await _pumpView(tester, _idle(tip: tip));
        final hours = find.byKey(const ValueKey('ambient-hours'));
        final pop = find.descendant(of: hours, matching: find.text('비 70%'));
        final temp = find.descendant(of: hours, matching: find.text('17°'));
        expect(_fontOf(tester, pop), greaterThanOrEqualTo(_fontOf(tester, temp)), reason: 'tip=$tip');
      }
    });

    // 실패널 글꼴은 시험 글꼴보다 넓다 — 글자마다 넓힌 조건(본문 21의 약 10%·약 15%)에서도 다음 루틴 카드와 예보가 함께 보인다.
    for (final spacing in [2.1, 3.0]) {
      testWidgets('넓은 글꼴(글자마다 +$spacing) + 날씨 안내 + 다음 루틴 + 공기 — 예보 줄이 보인다', (tester) async {
        await _pumpView(tester, _idle(tip: _rainTip, next: _nextRun, air: _normalAir), letterSpacing: spacing);
        final hours = find.byKey(const ValueKey('ambient-hours'));
        expect(hours, findsOneWidget);
        expect(find.descendant(of: hours, matching: find.text('비 70%')), findsOneWidget);
        final h = tester.getRect(hours);
        final next = tester.getRect(find.byKey(const ValueKey('idle-next-run')));
        // 다음 루틴은 시계 아래 왼쪽 칸(사용자 결정 10/18) — 예보와 다른 칸이라 겹치지 않는다.
        expect(next.right, lessThanOrEqualTo(h.left), reason: '예보와 다음 루틴이 겹치지 않는다');
        final tile = tester.getRect(find.text('공기청정기').last);
        expect(next.bottom, lessThanOrEqualTo(tile.top), reason: '다음 루틴이 가전 줄에 걸리지 않는다');
        expect(find.byKey(const ValueKey('ambient-tip')), findsOneWidget, reason: '날씨 안내는 그대로');
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('큰 글씨 공기 줄 — 낱말 가운데서 꺾이지 않는다', (tester) async {
      await _pumpView(
          tester,
          _idle(
              tip: _rainTip,
              air: const KioskAirReading(applianceId: 'air_purifier', grade: 'VERY_BAD', pm25: 120, power: 'on')),
          scale: 1.22);
      final rich = find.descendant(of: find.byKey(const ValueKey('idle-air-headline')), matching: find.byType(RichText));
      expect(_sameLine(tester, rich, '나빠요'), isTrue, reason: "'나빠 / 요'로 꺾이지 않는다");
      expect(tester.takeException(), isNull);
    });

    testWidgets("가전 고르기 — '지난번' 칩이 있어도 칸마다 아이콘·이름 높이가 같다", (tester) async {
      await _pumpView(
          tester,
          KioskApplianceSelectView(
            appliances: const [kMicrowaveAppliance, kInductionAppliance],
            lastUsedId: 'microwave',
            onSelect: (_) {},
            onCancel: () {},
          ));
      final a = tester.getRect(find.text('전자레인지'));
      final b = tester.getRect(find.text('인덕션'));
      expect(a.top, b.top, reason: '이름 높이');
      // 아이콘 대신 폰과 같은 가전 그림 칸(시안 B 10/24).
      Rect art(String name) => tester.getRect(find.descendant(
          of: find.ancestor(of: find.text(name), matching: find.byType(Column)).first,
          matching: find.byType(KioskArtTile)));
      final ia = art('전자레인지');
      final ib = art('인덕션');
      expect(ia.top, ib.top, reason: '아이콘 높이');
      expect(find.text('지난번'), findsOneWidget);
    });

    testWidgets('LG 가전 보내는 중 — 정지 옆 주의문은 왼쪽 정렬 한 문장', (tester) async {
      await _pumpView(
          tester,
          KioskExecutingView(
            executionMode: 'real',
            title: '공기청정기를 켤까요?',
            target: _purifier,
            thinqOnly: true,
            lastButtons: null,
            currentButton: null,
            currentAttempt: null,
            completedSteps: null,
            totalSteps: 1,
            verificationConfidence: null,
            verificationDetail: null,
            onStop: _noop,
          ));
      final note = find.byKey(const ValueKey('thinq-stop-note'));
      expect(note, findsOneWidget);
      final rich = tester.widget<RichText>(find.descendant(of: note, matching: find.byType(RichText)).first);
      expect(rich.textAlign, anyOf(TextAlign.start, TextAlign.left));
      final text = rich.text.toPlainText().replaceAll('⁠', '').replaceAll(' ', ' ');
      expect(text, isNot(contains('\n')));
      // 10/19: 두 짧은 문장까지 — 더 보내지 않는다 + 이미 보낸 것은 되돌리지 못할 수 있다.
      expect('.'.allMatches(text.replaceAll(RegExp(r'\.$'), '')).length, lessThanOrEqualTo(1), reason: '두 문장 이하');
      expect(text, contains('더 보내지 않'));
      expect(text, contains('되돌리지 못할 수 있어요'));
      expect(text, isNot(contains('그대로일 수 있어요')), reason: '평가 14차(10/18): 엔지니어 설명투 없이 한 줄');
      final stop = tester.getRect(find.byKey(const ValueKey('kiosk-stop-area')));
      final r = tester.getRect(note);
      expect(r.left, lessThan(KioskSizes.runLeft + 8), reason: '왼쪽 선에서 시작');
      expect(r.right, lessThanOrEqualTo(stop.left));
      expect(tester.takeException(), isNull);
    });
  });
}
