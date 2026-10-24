// 평가 11차(2026-10-18) 지적 수리 — 키오스크. 옛 코드에도 있는 공개 구성만 써서 옛 코드에서 실패하는 것을 확인한다.
//
// 1. 시간대 예보 칸 — 모든 칸이 '아이콘 + 기온' 한 꼴, 강수확률은 작은 둘째 줄('비 70%'가 기온 자리를 차지하지 않는다).
// 2. 결과 화면 나가는 단추 — LG 가전 결과·누름 장치 결과 모두 '⌂ 처음 화면으로' 한 이름·아이콘·색.
//    자동으로 닫지 않는 결과(확인 안 됨·실패)에는 카운트다운 문구가 없다.
// 3. LG 가전 확인 못 함 — 제목에 가전 이름: '공기청정기에 켜 달라고 했어요'(평가 15차) / '켜졌는지는 아직 확인하지 못했어요'('명령' 없이).
// 4. 연습 대기 — 상태 한 문장(정지를 보낸 뒤 '연습이 끝났어요' + '멈추는 중이에요'를 함께 두지 않는다),
//    정지 안내는 고르는 말([kPracticeStopHint] — 평가 13차 10/18에 '정지 단추도 눌러 볼 수 있어요'로 줄였다).
// 5. LG 가전 조작 — 전원·바람 세기 상태는 단추의 ✓ 하나로(왼쪽 상태 줄 두 번 금지), '자세히' → '미세먼지 보기',
//    큰 상태 한 줄('공기청정기가 켜져 있어요 · 바람 약').
// 6. 위 띠 '?'와 결과 원 'i' 불일치 → 같은 물음표. 사용자 정지 결과의 '누름 장치로 골라 누르기'는 글자 단추로 한 단계 낮춘다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/ambient.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/models/command_result.dart';
import 'package:simplelay_touchscreen/models/thinq.dart';
import 'package:simplelay_touchscreen/models/thinq_run.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/theme/kiosk_colors.dart';
import 'package:simplelay_touchscreen/theme/kiosk_tokens.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/done_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/hold_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/manual_view.dart';

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

void _noop() {}

/// 화면에 보이는 글 전부. 낱말 묶음 문자(U+2060·U+00A0)는 뗀다.
List<String> _texts(WidgetTester tester) => [
      for (final w in tester.widgetList<RichText>(find.byType(RichText)))
        w.text.toPlainText().replaceAll('⁠', '').replaceAll(' ', ' '),
    ];

Future<void> _pumpView(WidgetTester tester, Widget child, {double scale = 1.0}) async {
  tester.view.physicalSize = const Size(800, 480);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(size: const Size(800, 480), textScaler: TextScaler.linear(scale)),
      child: Scaffold(backgroundColor: KioskColors.bg, body: child),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 300));
}

// ── 1. 예보 칸 ─────────────────────────────────────────────
const _hourly = [
  AmbientHour(label: '9시', hour: 9, icon: 'partly', temp: 16),
  AmbientHour(label: '12시', hour: 12, icon: 'cloudy', temp: 18),
  AmbientHour(label: '15시', hour: 15, icon: 'rain', temp: 17, pop: 70, precip: true),
  AmbientHour(label: '18시', hour: 18, icon: 'rain', temp: 15, pop: 60, precip: true),
];

KioskIdleView _idle({AmbientTip? tip}) => KioskIdleView(
      now: DateTime(2026, 9, 30, 7, 38),
      connected: true,
      ambient: AmbientInfo(greeting: '좋은 아침이에요.', tip: tip, hourly: _hourly, weatherSource: 'mock'),
      connections: const [
        ConnectionItem(id: 'network', state: 'ok', title: '', message: ''),
        ConnectionItem(id: 'press', state: 'ok', title: '', message: ''),
      ],
      appliances: const [kMicrowaveAppliance],
      attention: const {},
      temperature: 23,
      humidity: 58,
      onSelectAppliance: (_) {},
      onOpenConnection: (_) {},
      onDndGesture: () {},
    );

final _weatherIcon = find.byWidgetPredicate((w) => w.runtimeType.toString() == '_WeatherIcon');

double _fontOf(WidgetTester tester, Finder text) {
  final rich = tester.widget<RichText>(find.descendant(of: text, matching: find.byType(RichText)).first);
  var size = rich.text.style?.fontSize;
  rich.text.visitChildren((s) {
    size ??= s.style?.fontSize;
    return size == null;
  });
  return size!;
}

// ── 2·3. 결과 화면 ─────────────────────────────────────────
KioskDoneView _thinqDone({required bool confirmed}) => KioskDoneView(
      success: confirmed,
      reason: confirmed ? null : KioskFailureReason.unconfirmed,
      executionMode: 'real',
      label: '공기청정기를 켤까요?',
      target: _purifier,
      thinqOnly: true,
      route: 'thinq',
      resultConfirmation: confirmed ? 'state_confirmed' : 'none',
      detail: confirmed ? '전원 켜기로 바꿨어요.' : '가전에 전했지만 설정이 바뀌었는지 확인하지 못했어요. 가전을 봐 주세요.',
      onDismiss: _noop,
    );

// 휴리스틱 평가(10/18): 모름·확인 필요 결과에서는 '처음 화면으로'가 보조 모양(테두리)이다 — 이름·집 아이콘은 같다.
Finder _exitButton() => find.ancestor(
    of: find.text('처음 화면으로'),
    matching: find.byWidgetPredicate((w) => w is ElevatedButton || w is OutlinedButton));

void _expectHomeButton(WidgetTester tester, String why) {
  expect(find.text('닫기'), findsNothing, reason: '$why — 닫기라는 다른 이름이 없다');
  expect(_exitButton(), findsOneWidget, reason: '$why — 처음 화면으로');
  expect(find.descendant(of: _exitButton(), matching: find.byIcon(Icons.home_outlined)), findsOneWidget,
      reason: '$why — 집 아이콘');
  final b = tester.widget<ButtonStyleButton>(_exitButton());
  if (b is ElevatedButton) {
    expect(b.style!.backgroundColor!.resolve({}), KioskColors.primary, reason: '$why — 한 색(10/24 primary)');
  } else {
    expect(b.style!.foregroundColor!.resolve({}), KioskColors.ink, reason: '$why — 보조 모양은 글자색');
  }
}

// ── 5. LG 가전 조작 ───────────────────────────────────────
Map<String, dynamic> _state({String power = 'POWER_ON'}) => {
      'operation': {'airPurifierOperationMode': power},
      'airPurifierJobMode': {'currentJobMode': 'CLEAN'},
      'airFlow': {'windStrength': 'LOW'},
      if (power == 'POWER_ON')
        'airQualitySensor': {'PM2': 42, 'PM10': 90, 'PM2Level': 'BAD', 'PM10Level': 'NORMAL'},
      'filterInfo': {'filterRemainPercent': 87},
    };

Future<void> _pumpThinq(WidgetTester tester, {String power = 'POWER_ON', double scale = 1.0}) async {
  await _pumpView(
      tester,
      KioskManualView(
        appliance: _purifier,
        onExecute: (_) {},
        onCancel: () {},
        thinqRead: () async => KioskThinqStatus(
            state: _state(power: power), executionMode: 'real', readAt: DateTime(2026, 10, 16, 9, 7)),
        thinqSend: (_, __, ___) async => const KioskJobAccepted(jobId: 'j'),
        onThinqAccepted: (_, __) {},
      ),
      scale: scale);
  await tester.pump();
  await tester.pump();
}

KioskHoldView _practiceHold({bool stopRequested = false}) => KioskHoldView(
      appliance: kMicrowaveAppliance,
      holdState: 'hovering_stop',
      stopButton: '취소',
      executionMode: 'mock',
      elapsed: const Duration(minutes: 1, seconds: 2),
      buttonsPressed: 3,
      operationConfirmed: true,
      operationSource: 'mock',
      stopRequested: stopRequested,
      onStop: _noop,
    );

void main() {
  // 시안 B(10/24): 예보 4칸 줄 대신 오른쪽 '바깥 날씨' 줄 — 지금 아이콘 + 기온, 그 아래 가까운 비 소식('오후 3시 비 70%').
  group('1. 바깥 날씨 줄 — 아이콘 + 기온, 비 소식은 아래 작은 줄', () {
    for (final (name, tip) in [
      ('안내 없음', null),
      ('알림 안내와 함께', const AmbientTip(kind: 'routine', text: '약 드실 시간이에요', icon: 'notice')),
    ]) {
      testWidgets(name, (tester) async {
        await _pumpView(tester, _idle(tip: tip));
        final row = find.byKey(const ValueKey('idle-weather'));
        expect(row, findsOneWidget);
        final now = find.byKey(const ValueKey('idle-weather-now'));
        expect(find.descendant(of: now, matching: _weatherIcon), findsOneWidget);
        expect(find.descendant(of: now, matching: find.textContaining('16°', findRichText: true)), findsWidgets);
        final pop = find.byKey(const ValueKey('idle-weather-advice'));
        expect(tester.widget<Text>(pop).textSpan!.toPlainText().replaceAll('⁠', '').replaceAll(' ', ' '),
            '오후 3시 비 70%');
        expect(tester.getRect(pop).top, greaterThanOrEqualTo(tester.getRect(now).bottom - 1), reason: '기온 아래 줄');
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('2. 결과 화면 나가는 단추는 하나 — 처음 화면으로·집 아이콘·한 색', () {
    testWidgets('LG 가전 결과(확인됨)', (tester) async {
      await _pumpView(tester, _thinqDone(confirmed: true));
      _expectHomeButton(tester, 'LG 가전 확인됨');
      expect(find.textContaining('뒤 처음 화면으로'), findsOneWidget, reason: '자동으로 닫히는 결과는 카운트다운');
    });

    testWidgets('LG 가전 결과(확인 못 함) — 자동으로 닫지 않아 카운트다운 없음', (tester) async {
      await _pumpView(tester, _thinqDone(confirmed: false));
      _expectHomeButton(tester, 'LG 가전 확인 못 함');
      expect(find.textContaining('초 뒤'), findsNothing);
    });

    testWidgets('누름 장치 결과(전력 확인 성공)', (tester) async {
      await _pumpView(
          tester,
          KioskDoneView(
              success: true,
              executionMode: 'real',
              label: '즉석밥 데워줘',
              target: kMicrowaveAppliance,
              operationConfirmed: true,
              operationSource: 'real',
              onDismiss: _noop));
      _expectHomeButton(tester, '누름 장치 확인된 성공');
    });

    testWidgets('누름 장치 결과(누름 보고만·실패)', (tester) async {
      await _pumpView(
          tester,
          KioskDoneView(
              success: true,
              executionMode: 'real',
              label: '즉석밥 데워줘',
              target: kMicrowaveAppliance,
              resultConfirmation: 'reported',
              onDismiss: _noop));
      _expectHomeButton(tester, '누름 보고만');
      await _pumpView(
          tester,
          KioskDoneView(
              success: false,
              executionMode: 'real',
              label: '즉석밥 데워줘',
              target: kMicrowaveAppliance,
              onDismiss: _noop));
      _expectHomeButton(tester, '실패');
      expect(find.textContaining('초 뒤'), findsNothing, reason: '실패는 자동으로 닫지 않는다');
    });
  });

  group('3. LG 가전 확인 못 함 — 제목에 가전 이름', () {
    test('켜기·끄기·바람', () {
      ThinqResultCopy copy(String action) => thinqResultCopy(
          applianceName: '공기청정기',
          kind: ResultKind.unconfirmed,
          receipt: 'accepted',
          confirmation: 'none',
          executionMode: 'real',
          action: thinqActionOf('공기청정기', [action]))!;
      // 평가 15차(10/18): '보냈어요'(기계가 한 일) 대신 '해 달라고 했어요' — 가전 이름은 그대로 제목에(평가 11차).
      expect(copy('공기청정기 전원 켜기').headline, '공기청정기에 켜 달라고 했어요');
      expect(copy('공기청정기 전원 켜기').sub, startsWith('켜졌는지는 아직 확인하지 못했어요'));
      expect(copy('공기청정기 전원 끄기').headline, '공기청정기에 꺼 달라고 했어요');
      expect(copy('공기청정기 바람 세기 강').headline, '공기청정기에 바람을 세게 해 달라고 했어요');
      expect(copy('공기청정기 바람 세기 강').sub, startsWith('바람이 세게 바뀌었는지는 아직 확인하지 못했어요'));
      for (final a in ['공기청정기 전원 켜기', '공기청정기 전원 끄기', '공기청정기 바람 세기 강', '']) {
        final c = copy(a);
        expect('${c.headline} ${c.sub}', isNot(contains('보냈')));
        expect('${c.headline} ${c.sub}', isNot(contains('명령')));
        expect(c.headline, startsWith('공기청정기'));
      }
    });

    testWidgets('화면 — 이름이 제목에 있고 아래 작은 회색 이름 줄은 없다', (tester) async {
      await _pumpView(tester, _thinqDone(confirmed: false));
      final texts = _texts(tester);
      expect(texts, contains('공기청정기에 켜 달라고 했어요'));
      // 이름은 위 띠 오른쪽에만(평가 17차 10/18) — 본문에는 작은 이름 줄이 없다.
      expect(find.descendant(of: find.byKey(const ValueKey('thinq-result')), matching: find.text('공기청정기')), findsNothing);
      expect(texts.any((t) => t.contains('보냈')), isFalse);
    });
  });

  group('4. 연습 대기 — 상태 한 문장, 정지 안내는 고르는 말', () {
    testWidgets('정지 전', (tester) async {
      await _pumpView(tester, _practiceHold());
      final texts = _texts(tester);
      expect(texts, contains('연습이 끝났어요'));
      // 평가 14차(10/18): 연습을 마친 대기에는 정지 안내 문장을 두지 않는다.
      expect(texts.any((t) => t.contains('눌러 볼 수')), isFalse);
      expect(texts.any((t) => t.contains('빨간 정지를 눌러 보세요')), isFalse);
    });

    for (final scale in [1.0, 1.22]) {
      testWidgets('정지를 보낸 뒤(글씨 $scale) — 마쳤어요와 멈추는 중을 함께 두지 않는다', (tester) async {
        await _pumpView(tester, _practiceHold(stopRequested: true), scale: scale);
        final texts = _texts(tester);
        expect(texts, contains('연습을 끝내는 중이에요'));
        expect(texts.any((t) => t.contains('마쳤어요')), isFalse);
        expect(texts.where((t) => t.contains('끝내는 중')), hasLength(1), reason: '한 문장');
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('5. LG 가전 조작 — 상태는 ✓ 하나로, 큰 상태 한 줄, 미세먼지 보기', () {
    testWidgets('켜짐', (tester) async {
      await _pumpThinq(tester);
      expect(find.byKey(const ValueKey('thinq-row-전원')), findsNothing, reason: '전원은 단추 ✓가 말한다');
      expect(find.byKey(const ValueKey('thinq-row-바람 세기')), findsNothing, reason: '바람 세기도 단추 ✓');
      final line = find.byKey(const ValueKey('thinq-state-headline'));
      expect(_texts(tester), contains('공기청정기가 켜져 있어요 · 바람 약'));
      expect(_fontOf(tester, line), greaterThanOrEqualTo(KioskType.status));
      expect(_texts(tester).contains('자세히'), isFalse);
      final more = find.byKey(const ValueKey('thinq-air-more'));
      expect(find.descendant(of: more, matching: find.byType(RichText)).evaluate().map((e) =>
              (e.widget as RichText).text.toPlainText().replaceAll('⁠', '').replaceAll(' ', ' ')),
          contains('미세먼지 보기'));
      expect(find.text('42 · 나쁨'), findsNothing);
      await tester.tap(more);
      await tester.pump();
      expect(find.text('42 · 나쁨'), findsOneWidget);
      expect(find.text('87%'), findsOneWidget, reason: '단추에 없는 값은 남는다');
      expect(tester.takeException(), isNull);
    });

    testWidgets('꺼짐·큰 글씨', (tester) async {
      await _pumpThinq(tester, power: 'POWER_OFF', scale: 1.22);
      expect(_texts(tester), contains('공기청정기가 꺼져 있어요'));
      expect(find.byKey(const ValueKey('thinq-row-전원')), findsNothing);
      expect(find.byKey(const ValueKey('thinq-set-set_power-POWER_ON')).hitTestable(), findsOneWidget,
          reason: '큰 글씨에서도 켜기가 첫 화면에');
      expect(tester.takeException(), isNull);
    });
  });

  group('6. 아이콘 한 가지·사용자 정지의 보조 단추 한 단계 낮춤', () {
    testWidgets('누름 보고만(환경 모름) — 위 띠와 결과 원이 같은 물음표', (tester) async {
      await _pumpView(
          tester, KioskDoneView(success: true, label: '즉석밥 데워줘', target: kMicrowaveAppliance, onDismiss: _noop));
      // 큰 결과 원은 없다(평가 17차 10/18) — 띠의 물음표 하나.
      expect(find.byKey(const ValueKey('done-ring')), findsNothing);
      expect(find.descendant(of: find.byKey(const ValueKey('status-band')), matching: find.byIcon(Icons.help_outline)),
          findsOneWidget);
    });

    // 평가 12차(10/18): 실패 화면과 꼴이 달랐다 — 두 화면 같은 테두리 보조 단추(주 단추 '처음 화면으로'보다 낮다).
    testWidgets("사용자 정지 — '누름 장치로 골라 누르기'는 실패 화면과 같은 테두리 보조 단추", (tester) async {
      await _pumpView(
          tester,
          KioskDoneView(
              success: false,
              executionMode: 'real',
              label: '즉석밥 데워줘',
              target: kMicrowaveAppliance,
              reason: KioskFailureReason.stopped,
              // 멈춘 것을 확인한 정지만 골라 누르기를 둔다(평가 15차 10/18 — 모르면 '다시 멈추기').
              stopLevel: 'verified',
              onRetry: _noop,
              onManual: _noop,
              onDismiss: _noop));
      expect(tester.widget(find.byKey(const ValueKey('done-manual'))), isA<OutlinedButton>());
      expect(tester.getSize(find.byKey(const ValueKey('done-manual'))).height, greaterThanOrEqualTo(48));
      _expectHomeButton(tester, '사용자 정지');
    });
  });
}
