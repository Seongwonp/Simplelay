// 평가 15차(2026-10-18, 키오스크 93 → 목표 97) — 결선 심사 기준 감점 항목. 옛 코드에도 있는 공개 구성만 써서 옛 코드에서
// 실패하는 것을 확인한다(새로 생긴 구성 — '다시 멈추기' 콜백·패널 전체 어둡게 — 은 kiosk_eval_p15_api_test.dart).
//
// 1. '지금' 칸: 서버가 `now` 키를 보내면 그 값만(없으면 '지금' 칸 없음). 키가 없는 옛 서버만 3시간 칸 대체.
// 2. 실패 결과 아래 줄: 주 단추 하나('처음 화면으로') + 보조 한 줄(같은 폭·같은 높이·같은 오른쪽 끝).
// 3. 안전: 누름 장치가 멈췄는지 모르는 정지 결과에는 '누름 장치로 골라 누르기'가 없고 번호 안내가 있다.
// 4. '처음 화면으로'는 한 모양(흰 채움·집 아이콘)·한 자리(왼쪽 아래 같은 선) — 정지 미확인 대기는 크기만 보조.
// 5. 문제 칩: 원인이 하나면 첫 줄에 원인과 영향('누름 장치 연결이 끊겨 가전 N대를 못 써요'), '연결 1곳을 봐 주세요'은 남는다.
// 6. 공기 할 일은 '공기 나빠요' 바로 아래 같은 왼쪽 열.
// 7. LG 가전 '보내다' 표현 없음 — '공기청정기에 켜 달라고 했어요', '정지를 누르면 더 하지 않아요'.
// 8. '~봐 주세요' 되풀이 없음 — 번호 안내가 있으면 할 일 한 줄을 따로 두지 않는다.
// 9. LG 가전 결과(확인됨)는 내용이 위에 붙지 않고 가운데 쪽.
// 10. 지난 일 줄이 있어도 '오늘은 건너뛰기'와 가전 줄 사이 간격 토큰 이상, LG 상세 공기 블록 들여쓰기·아래 끝 맞춤,
//     알림(약 드실 시간)은 날씨 카드 밖, 실행 화면 '가전이 켜지는지 보고 있어요' 없음.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:simplelay_touchscreen/widgets/kiosk/estop_banner.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/executing_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/hold_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/kiosk_canvas.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/manual_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/past_result_line.dart';

const _fontPath = r'C:\Windows\Fonts\malgun.ttf';
final _hasFont = File(_fontPath).existsSync();

/// 1920x1080 실패널 배율(캔버스 800x480 → 2.05배, 가장자리 여백 좌우 140·위아래 48).
const double _scale = 2.05;

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

ApplianceMap _served(String id, String name, String category, {List<ApplianceButton> buttons = const []}) => ApplianceMap(
      id: id,
      name: name,
      category: category,
      rows: 1,
      cols: 1,
      buttons: buttons,
      readiness: 'operable',
      controlPath: 'physical',
    );

final _mw = _served('microwave', '전자레인지', 'microwave', buttons: kMicrowaveAppliance.buttons);
final _ind = _served('induction', '인덕션', 'induction', buttons: kInductionAppliance.buttons);
final _washer = _served('washer', '세탁기', 'washing_machine');
final _fan = _served('fan', '선풍기', 'other');

const _okConnections = [
  ConnectionItem(id: 'network', state: 'ok', title: '', message: ''),
  ConnectionItem(id: 'press', state: 'ok', title: '', message: ''),
];

const _rainAmbient = AmbientInfo(
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

KioskNextRun _next() => const KioskNextRun(
      name: '저녁 공기청정기 켜기',
      dayLabel: '오늘',
      hhmm: '22:00',
      modeLabel: '자동 실행',
      routineId: 'rt-evening',
      at: '2026-09-30T22:00:00+09:00',
      skipActionLabel: '오늘은 건너뛰기',
    );

KioskIdleView _idle({
  List<ConnectionItem> connections = _okConnections,
  AmbientInfo ambient = _rainAmbient,
  KioskAirReading? air,
  KioskNextRun? nextRun,
  List<ApplianceMap>? appliances,
  Set<String> off = const {},
  Set<String> on = const {},
}) =>
    KioskIdleView(
      now: DateTime(2026, 9, 30, 7, 38),
      connected: true,
      ambient: ambient,
      connections: connections,
      appliances: appliances ?? [_mw, _washer, _fan, _ind],
      on: on,
      off: off,
      temperature: 23,
      humidity: 58,
      air: air,
      nextRun: nextRun,
      onToggleNextRunSkip: (_) {},
      onSelectAppliance: (_) {},
      onOpenConnection: (_) {},
      onDndGesture: () {},
    );

/// 실패널(1920x1080, KioskCanvas) 그대로 — 좌표는 실패널 px.
Future<void> _pump15(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(1920, 1080);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(fontFamily: 'Malgun', brightness: Brightness.dark),
    home: KioskCanvas(child: Scaffold(backgroundColor: KioskColors.bg, body: child)),
  ));
  await tester.pump(const Duration(milliseconds: 300));
}

/// 화면에 보이는 글 전부(낱말 묶음 문자는 뗀다).
List<String> _texts(WidgetTester tester) => [
      for (final w in tester.widgetList<RichText>(find.byType(RichText)))
        w.text.toPlainText().replaceAll('\u2060', '').replaceAll('\u00A0', ' '),
    ];

int _count(List<String> texts, String needle) =>
    texts.fold(0, (n, t) => n + needle.allMatches(t).length);

Rect _rectOfText(WidgetTester tester, String text) {
  for (final e in find.byType(RichText).evaluate()) {
    final w = e.widget as RichText;
    if (w.text.toPlainText().replaceAll('\u2060', '').replaceAll('\u00A0', ' ') == text) {
      return tester.getRect(find.byWidget(w));
    }
  }
  throw StateError('글 "$text" 없음');
}

/// '처음 화면으로' 단추(채움·테두리 어느 쪽이든).
Finder _home() => find.ancestor(of: find.text('처음 화면으로'), matching: find.bySubtype<ButtonStyleButton>());

KioskDoneView _failed() => KioskDoneView(
      success: false,
      executionMode: 'real',
      label: '즉석밥 데워줘',
      target: kMicrowaveAppliance,
      onRetry: () {},
      onManual: () {},
      onDismiss: () {},
    );

KioskDoneView _userStop({String? level = 'sent'}) => KioskDoneView(
      success: false,
      executionMode: 'real',
      label: '즉석밥 데워줘',
      target: kMicrowaveAppliance,
      reason: KioskFailureReason.stopped,
      stopLevel: level,
      onRetry: () {},
      onManual: () {},
      onDismiss: () {},
    );

KioskDoneView _thinqDone({bool confirmed = true}) => KioskDoneView(
      success: confirmed,
      reason: confirmed ? null : KioskFailureReason.unconfirmed,
      executionMode: 'real',
      label: '공기청정기를 켤까요?',
      target: _purifier,
      thinqOnly: true,
      route: 'thinq',
      resultConfirmation: confirmed ? 'state_confirmed' : 'none',
      detail: confirmed ? '전원 켜기로 바꿨어요.' : '가전에 전했지만 설정이 바뀌었는지 몰라요. 가전을 봐 주세요.',
      onDismiss: () {},
    );

void main() {
  setUpAll(() async {
    if (!_hasFont) return;
    final bytes = File(_fontPath).readAsBytesSync();
    await (FontLoader('Malgun')..addFont(Future.value(ByteData.view(bytes.buffer)))).load();
  });

  group('1. 지금 칸 — 서버 `now`가 있으면 그것만', () {
    // 실패널 오후 2:21 — 서버가 '지금' 칸이 없다고(null) 보냈다. 3시 칸(비)을 '지금'으로 대신 그리면 안내 '오후 3시부터 비'와 엇갈린다.
    final at = DateTime(2026, 10, 18, 14, 21);
    Map<String, dynamic> body({bool withNowKey = true, Map<String, dynamic>? now}) => {
          'greeting': '좋은 오후예요.',
          'tip': {'kind': 'rain', 'text': '오후 3시부터 비 예보가 있어요. 우산 챙기세요.', 'icon': 'rain'},
          'hourly': [
            {'label': '15시', 'hour': 15, 'icon': 'rain', 'temp': 17, 'pop': 70, 'precip': true},
            {'label': '18시', 'hour': 18, 'icon': 'rain', 'temp': 15, 'pop': 60, 'precip': true},
          ],
          if (withNowKey) 'now': now,
          'weather_source': 'kma',
        };

    test('서버 now가 null이면 지금 칸이 없다(3시 칸을 대신 쓰지 않는다)', () {
      final slots = forecastSlots(AmbientInfo.fromJson(body()), at);
      expect(slots.where((s) => s.isNow), isEmpty);
      expect(slots.first.label, '오후 3시');
    });

    test('서버 now가 있으면 그 칸이 지금', () {
      final slots = forecastSlots(
          AmbientInfo.fromJson(body(now: {'hour': 14, 'icon': 'cloudy', 'temp': 18})), at);
      expect(slots.first.isNow, isTrue);
      expect(slots.first.hour.icon, 'cloudy');
    });

    test('now 키가 없는 옛 서버만 3시간 칸 대체', () {
      final slots = forecastSlots(AmbientInfo.fromJson(body(withNowKey: false)), at);
      expect(slots.first.isNow, isTrue);
    });
  });

  group('2·3·4·8. 결과 화면 아래 줄·처음 화면으로·번호 안내', () {
    // 휴리스틱 평가(10/18): 눌렸는지 모르면 아래 줄은 '움직였어요 / 안 움직였어요' 대등한 큰 두 단추 + 보조 '처음 화면으로'.
    // 채움 단추(흰 면)는 없다 — 어느 답도 먼저 눌리게 하지 않는다. 처음 화면으로는 오른쪽 끝(정지 자리와 같은 선).
    testWidgets('눌렸는지 모름 — 대등한 두 답 단추, 채움 단추 없음, 처음 화면으로는 오른쪽 끝 보조', (tester) async {
      await _pump15(tester, _failed());
      final yes = tester.getRect(find.byKey(const ValueKey('done-check-yes')));
      final no = tester.getRect(find.byKey(const ValueKey('done-check-no')));
      expect((yes.width - no.width).abs(), lessThan(1), reason: '같은 폭');
      expect((yes.height - no.height).abs(), lessThan(1), reason: '같은 높이');
      expect((yes.top - no.top).abs(), lessThan(1), reason: '같은 줄');
      final home = tester.getRect(_home());
      expect(home.right, closeTo(1920 - 140 - KioskSizes.stopRight * _scale, 3));
      expect(home.height, lessThan(yes.height));
      expect(find.byType(ElevatedButton), findsNothing, reason: '채움 단추 없음');
      expect(tester.takeException(), isNull);
    });

    testWidgets('번호 안내가 있으면 할 일 한 줄(가전을 봐 주세요)을 따로 두지 않는다, 봐 주세요 되풀이 없음', (tester) async {
      await _pump15(tester, _failed());
      final texts = _texts(tester);
      expect(find.byKey(const ValueKey('done-recovery-steps')), findsOneWidget);
      expect(texts.where((t) => t == '가전을 봐 주세요'), isEmpty);
      expect(_count(texts, '봐 주세요'), lessThanOrEqualTo(1));
    });

    testWidgets('안전 — 누름 장치가 멈췄는지 모르면 누름 장치로 골라 누르기가 없고 번호 안내가 있다', (tester) async {
      await _pump15(tester, _userStop());
      expect(find.text('누름 장치가 멈췄는지 몰라요'), findsOneWidget);
      expect(find.byKey(const ValueKey('done-manual')), findsNothing);
      expect(find.text(kManualEntryLabel), findsNothing);
      expect(find.byKey(const ValueKey('done-recovery-steps')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('누름 장치가 멈춘 것을 확인한 정지는 종전대로 골라 누르기를 둔다', (tester) async {
      await _pump15(tester, _userStop(level: 'verified'));
      expect(find.byKey(const ValueKey('done-manual')), findsOneWidget);
    });

    // 휴리스틱 평가(10/18): 주 행동은 왼쪽 아래 같은 자리 — 확인한 결과는 '처음 화면으로'(흰 채움), 모름 결과는 첫 답 단추.
    // 모름·정지 미확인에서 '처음 화면으로'는 보조 모양(테두리) — 이름·집 아이콘은 같다.
    testWidgets('주 행동은 같은 왼쪽 선 — 확인한 결과는 처음 화면으로(흰 채움), 모름은 답 단추, 처음 화면으로는 늘 집 아이콘', (tester) async {
      final lefts = <double>[];
      final screens = <(Widget, bool)>[
        (_failed(), false),
        (
          KioskDoneView(
              success: true,
              executionMode: 'real',
              label: '즉석밥 데워줘',
              target: kMicrowaveAppliance,
              operationConfirmed: true,
              operationSource: 'real',
              onDismiss: () {}),
          true
        ),
        (_thinqDone(confirmed: false), false),
        (_thinqDone(), true),
        (
          const KioskHoldView(
            appliance: kMicrowaveAppliance,
            holdState: 'parked',
            stopOutcome: 'requested_unconfirmed',
            stopButton: '취소',
            executionMode: 'real',
            elapsed: Duration(minutes: 1),
            onStop: _noop,
            onClose: _noop,
          ),
          false
        ),
      ];
      for (final (s, confirmed) in screens) {
        await _pump15(tester, s);
        final home = _home();
        expect(home, findsOneWidget);
        expect(find.descendant(of: home, matching: find.byIcon(Icons.home_outlined)), findsOneWidget, reason: '집 아이콘');
        if (confirmed) {
          expect(tester.widget(home), isA<ElevatedButton>(), reason: '확인한 결과 — 흰 채움');
          lefts.add(tester.getRect(home).left);
        } else {
          expect(tester.widget(home), isA<OutlinedButton>(), reason: '모름 — 보조 모양');
          final yes = find.byKey(const ValueKey('done-check-yes'));
          if (yes.evaluate().isNotEmpty) lefts.add(tester.getRect(yes).left);
        }
      }
      for (final l in lefts) {
        expect(l, closeTo(lefts.first, 2), reason: '같은 자리(왼쪽 선) — $lefts');
      }
    });
  });

  group('5. 문제 칩 — 원인과 영향', () {
    testWidgets('누름 장치 끊김 하나면 한 줄 제목이 원인·영향, 해결 방법 보기는 따로 선 단추(결선 모의 평가 10/18)', (tester) async {
      await _pump15(
          tester,
          _idle(connections: const [
            ConnectionItem(id: 'network', state: 'ok', title: '', message: ''),
            ConnectionItem(id: 'press', state: 'error', title: '누름 장치와 연결이 끊겼어요', message: ''),
          ]));
      final texts = _texts(tester);
      expect(texts, contains('누름 장치가 끊겨 가전 4대를 쓸 수 없어요'));
      expect(texts, isNot(contains('연결 1곳을 봐 주세요'))); // 한 줄 제목만(결선 모의 평가 10/18)
      expect(find.byKey(const ValueKey('idle-problem-help')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('6. 공기 할 일은 공기 나빠요 바로 아래', () {
    testWidgets('다음 루틴과 함께여도 같은 왼쪽 열, 공기 줄 바로 아래', (tester) async {
      await _pump15(
          tester,
          _idle(
              appliances: [_purifier, _mw, _ind, _washer],
              off: const {'air_purifier'},
              air: const KioskAirReading(applianceId: 'air_purifier', grade: 'BAD', pm25: 42, pm10: 90, power: 'off'),
              nextRun: _next()));
      final head = tester.getRect(find.byKey(const ValueKey('idle-air-headline')));
      final action = tester.getRect(
          find.descendant(of: find.byKey(const ValueKey('idle-air-action')), matching: find.byType(Text)));
      final clock = tester.getRect(find.byKey(const ValueKey('idle-clock')));
      final tip = tester.getRect(find.byKey(const ValueKey('ambient-tip')));
      expect(action.left, lessThan(tip.left), reason: '왼쪽 열');
      expect(action.left, closeTo(head.left, 4), reason: '공기 글과 같은 글 선');
      expect(action.top, greaterThanOrEqualTo(head.bottom - 1));
      expect(action.top - head.bottom, lessThan(24), reason: '바로 아래');
      expect(action.top, greaterThan(clock.bottom));
      final next = tester.getRect(find.byKey(const ValueKey('idle-next-run')));
      expect(next.top, greaterThanOrEqualTo(action.bottom - 1), reason: '다음 루틴은 그 아래');
      // 다 보인다(스크롤 아래로 잘리지 않는다) — 가전 줄 위.
      final strip = tester.getRect(find.byKey(const ValueKey('strip-air_purifier')));
      expect(next.bottom, lessThanOrEqualTo(strip.top + 1));
      expect(tester.takeException(), isNull);
    });
  });

  group('7. LG 가전 — 보내다 표현 없음', () {
    test('확인 못 함 큰 글자는 가전 이름 + 해 달라고 했어요', () {
      final copy = thinqResultCopy(
          applianceName: '공기청정기',
          kind: ResultKind.unconfirmed,
          receipt: 'accepted',
          confirmation: 'none',
          executionMode: 'real',
          action: thinqActionOf('공기청정기', ['공기청정기 전원 켜기']))!;
      expect(copy.headline, '공기청정기에 켜 달라고 했어요');
      expect(copy.headline + copy.sub, isNot(contains('보냈')));
    });

    // 10/19: 이미 보낸 명령을 멈추는 것처럼 읽혔다 — 되돌리지 못할 수 있다고 말한다(되돌린다고 약속하지 않는다).
    test('정지 안내는 더 보내지 않는다 + 되돌리지 못할 수 있다', () {
      expect(kThinqStopNote, '정지를 누르면 더 보내지 않아요. 이미 보낸 것은 되돌리지 못할 수 있어요');
      expect(kThinqStopNote, isNot(contains('되돌려요')));
    });

    testWidgets('보내는 중·확인 못 함 화면에 보내다 없음', (tester) async {
      await _pump15(
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
            onStop: () {},
          ));
      // 정지 안내(10/19 — 이미 보낸 것은 되돌리지 못할 수 있다)만 빼고.
      expect(_texts(tester).where((t) => t != kThinqStopNote && (t.contains('보내') || t.contains('보냈'))), isEmpty);
      await _pump15(tester, _thinqDone(confirmed: false));
      expect(_texts(tester).where((t) => t.contains('보내') || t.contains('보냈')), isEmpty);
    });
  });

  group('8. LG 가전 확인 못 함 — 봐 주세요 되풀이 없음', () {
    testWidgets('제목·한 줄·번호를 합쳐 봐 주세요 한 번 이하, 번호 줄 말끝이 서로 다르다', (tester) async {
      await _pump15(tester, _thinqDone(confirmed: false));
      final texts = _texts(tester);
      expect(_count(texts, '봐 주세요'), lessThanOrEqualTo(1));
      // 순서 안내는 '더 볼 것' 뒤에 접혀 있다(심사 의견 10/19) — 펴서도 되풀이가 없어야 한다.
      await tester.tap(find.byKey(const ValueKey('done-recovery-more')));
      await tester.pump();
      expect(_count(_texts(tester), '봐 주세요'), lessThanOrEqualTo(1));
      final steps = [
        for (var i = 0; i < 3; i++)
          tester.widget<RichText>(find.descendant(
              of: find.byKey(ValueKey('done-recovery-step-$i')), matching: find.byType(RichText))).text.toPlainText(),
      ];
      String ending(String s) => s.trim().split(RegExp(r'\s+')).last;
      expect(steps.map(ending).toSet().length, 3, reason: '말끝 다양하게 $steps');
    });
  });

  group('9. LG 가전 결과(확인됨) — 가운데가 비지 않게', () {
    testWidgets('큰 글자가 띠 바로 아래 붙지 않고 내용 아래 빈 띠가 화면 절반을 넘지 않는다', (tester) async {
      await _pump15(tester, _thinqDone());
      final band = tester.getRect(find.byKey(const ValueKey('status-band')));
      final head = tester.getRect(find.byKey(const ValueKey('thinq-result-headline')));
      final sub = tester.getRect(find.byKey(const ValueKey('thinq-result-sub')));
      final home = tester.getRect(_home());
      expect(head.top - band.bottom, greaterThan(120), reason: '위에 붙지 않는다');
      expect(home.top - sub.bottom, lessThan(1080 * 0.4), reason: '내용 아래 빈 곳');
    });
  });

  group('10. 작은 것', () {
    testWidgets('지난 일 줄이 있어도 오늘은 건너뛰기 글과 가전 줄 사이 간격 토큰 이상', (tester) async {
      await _pump15(
          tester,
          KioskEstopLayout(
            banner: KioskPastResultLine(
              result: KioskPastResult(at: DateTime(2026, 9, 30, 15, 12), label: '즉석밥 데우기', headline: '눌렸는지 몰라요'),
              onAcknowledge: _noop,
            ),
            child: _idle(appliances: [_purifier, _mw, _ind, _washer], on: const {'air_purifier'}, nextRun: _next()),
          ));
      final skip = _rectOfText(tester, '오늘은 건너뛰기');
      final strip = tester.getRect(find.byKey(const ValueKey('strip-air_purifier')));
      expect(strip.top - skip.bottom, greaterThanOrEqualTo(KioskSpace.sm * _scale - 1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('알림(약 드실 시간)은 날씨 카드 밖 — 예보 줄을 품지 않는다', (tester) async {
      await _pump15(
          tester,
          _idle(
              ambient: const AmbientInfo(
            greeting: '좋은 아침이에요.',
            tip: AmbientTip(kind: 'routine', text: '약 드실 시간이에요. 아직 안 드셨으면 지금 챙겨 드세요', icon: 'notice'),
            hourly: [
              AmbientHour(label: '9시', icon: 'partly', temp: 16),
              AmbientHour(label: '12시', icon: 'cloudy', temp: 18),
              AmbientHour(label: '15시', icon: 'rain', temp: 17, pop: 70, precip: true),
            ],
          )));
      expect(find.byKey(const ValueKey('ambient-tip')), findsOneWidget);
      expect(find.byKey(const ValueKey('ambient-hours')), findsOneWidget);
      expect(
          find.descendant(of: find.byKey(const ValueKey('ambient-tip')), matching: find.byKey(const ValueKey('ambient-hours'))),
          findsNothing);
      final tip = tester.getRect(find.byKey(const ValueKey('ambient-tip')));
      final hours = tester.getRect(find.byKey(const ValueKey('ambient-hours')));
      expect(hours.top, greaterThanOrEqualTo(tip.bottom));
    });

    testWidgets('날씨 안내는 지금처럼 예보 줄을 카드 안에 품는다', (tester) async {
      await _pump15(tester, _idle());
      expect(
          find.descendant(of: find.byKey(const ValueKey('ambient-tip')), matching: find.byKey(const ValueKey('ambient-hours'))),
          findsOneWidget);
    });

    testWidgets('LG 상세 — 공기 할 일과 미세먼지 보기가 같은 글 선, 왼쪽 카드와 오른쪽 단추 아래 끝이 같다', (tester) async {
      await _pump15(
          tester,
          KioskManualView(
            appliance: _purifier,
            onExecute: (_) {},
            onCancel: () {},
            thinqRead: () async => KioskThinqStatus(
              executionMode: 'mock',
              readAt: DateTime(2026, 10, 16, 9, 7),
              state: {
                'operation': {'airPurifierOperationMode': 'POWER_ON'},
                'airPurifierJobMode': {'currentJobMode': 'CLEAN'},
                'airFlow': {'windStrength': 'LOW'},
                'airQualitySensor': {'PM2': 42, 'PM10': 90, 'PM2Level': 'BAD', 'PM10Level': 'NORMAL'},
                'filterInfo': {'filterRemainPercent': 87},
              },
            ),
            thinqSend: (_, __, ___) async => const KioskJobAccepted(jobId: 'j'),
            onThinqAccepted: (_, __) {},
          ));
      await tester.pump(const Duration(milliseconds: 300));
      final hint = tester.getRect(find.byKey(const ValueKey('thinq-air-hint')));
      final more = tester.getRect(find.byKey(const ValueKey('thinq-air-more')));
      final summary = tester.getRect(find.byKey(const ValueKey('thinq-air-summary')));
      expect(hint.left, closeTo(summary.left, 2));
      expect(more.left, closeTo(hint.left, 2), reason: '들여쓰기 맞춤');
      // 왼쪽 상태 카드(지금 상태 제목을 품은 면)의 아래 끝과 마지막 조작 단추의 아래 끝.
      final card = tester.getRect(find
          .ancestor(of: find.text('지금 상태'), matching: find.byType(Container))
          .first);
      final auto = tester.getRect(find.byKey(const ValueKey('thinq-set-set_wind_strength-AUTO')));
      expect(card.bottom, closeTo(auto.bottom, 3));
      expect(tester.takeException(), isNull);
    });

    testWidgets('실행 화면 — 제대로 눌렸는지 보는 중과 같은 말(가전이 켜지는지 보고 있어요)을 또 두지 않는다', (tester) async {
      await _pump15(
          tester,
          KioskExecutingView(
            executionMode: 'real',
            title: '즉석밥 데워줘',
            target: kMicrowaveAppliance,
            lastButtons: null,
            currentButton: '시작',
            currentAttempt: 1,
            completedSteps: 1,
            doneButtons: const ['즉석밥'],
            totalSteps: 2,
            verificationConfidence: 0.4,
            verificationDetail: '전력 변화를 보는 중',
            onStop: () {},
          ));
      expect(find.text('눌렀어요, 확인 중이에요'), findsOneWidget); // 결선 모의 평가 10/18 — 누른 뒤 확인 단계
      expect(find.text('가전이 켜지는지 보고 있어요'), findsNothing);
    });
  });
}

void _noop() {}
