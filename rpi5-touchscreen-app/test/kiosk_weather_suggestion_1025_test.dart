// 키오스크 날씨 줄·자세히 창, 제안 단추 '아니요/네'·'이 제안 앞으로 받지 않기'(docs/키오스크-날씨·제안-개편-계획-2026-10-25.md §2·§3).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simplelay_touchscreen/models/ambient.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/models/kiosk_time.dart';
import 'package:simplelay_touchscreen/models/thinq.dart';
import 'package:simplelay_touchscreen/screens/kiosk_screen.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/kiosk_tab_bar.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/suggestion_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/weather_detail_sheet.dart';

import 'kiosk_phase_test.dart' show FakeKioskApi, FakeTts, FakeEventStream;

const _hours = [
  AmbientHour(label: '9시', hour: 9, icon: 'cloudy', temp: 14),
  AmbientHour(label: '12시', hour: 12, icon: 'clear', temp: 18),
  AmbientHour(label: '15시', hour: 15, icon: 'rain', temp: 17, pop: 70, precip: true),
  AmbientHour(label: '18시', hour: 18, icon: 'rain', temp: 15, pop: 60, precip: true),
  AmbientHour(label: '21시', hour: 21, icon: 'cloudy', temp: 13, pop: 20),
];

const _wind = AmbientWarning(
    kind: '강풍', level: '주의보', title: '강풍주의보', icon: 'wind', advice: '바람이 강해요. 외출할 때 조심하세요.');

AmbientInfo _amb({
  List<AmbientHour> hourly = _hours,
  List<AmbientWarning> warnings = const [],
  AmbientTip? tip,
  AmbientTip? weatherTip,
  bool nowKnown = false,
  AmbientHour? now,
}) =>
    AmbientInfo(
      greeting: '좋은 아침이에요.',
      tip: tip,
      hourly: hourly,
      weatherSource: 'kma',
      warnings: warnings,
      weatherTip: weatherTip,
      today: const AmbientToday(high: 21, low: 12),
      fetchedAt: '2026-10-25T15:05:12+09:00',
      nowKnown: nowKnown,
      now: now,
    );

Future<void> _pumpIdle(WidgetTester tester, AmbientInfo? ambient,
    {DateTime? now, double scale = 1.0, Size size = const Size(800, 480)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
          data: MediaQueryData(size: size, textScaler: TextScaler.linear(scale)),
          child: Scaffold(
            body: KioskIdleView(
              now: now ?? DateTime(2026, 10, 25, 8, 20),
              connected: true,
              ambient: ambient,
              appliances: const [kMicrowaveAppliance],
              onSelectAppliance: (_) {},
              onOpenConnection: (_) {},
              onDndGesture: () {},
            ),
          ))));
  await tester.pump();
}

String _plain(WidgetTester tester, Finder f) =>
    tester.widget<Text>(f).textSpan!.toPlainText().replaceAll('⁠', '').replaceAll(' ', ' ');

final _row = find.byKey(const ValueKey('idle-weather'));
final _head = find.byKey(const ValueKey('idle-weather-head'));
final _advice = find.byKey(const ValueKey('idle-weather-advice'));
final _detail = find.byKey(const ValueKey('weather-detail'));

const _sug = KioskSuggestion(
  id: 's1',
  purpose: '즉석밥 데워줘',
  occurrences: 3,
  timeBand: '아침',
  steps: ['즉석밥', '시작'],
  applianceId: 'microwave',
);
const _routineSug = KioskSuggestion(
  id: 'r1',
  purpose: '저녁 데우기',
  occurrences: 0,
  steps: ['즉석밥', '시작'],
  applianceId: 'microwave',
  routineId: 'rt-1',
  routineName: '저녁 데우기',
);
const _mute = ValueKey('suggestion-mute');
const _later = ValueKey('suggestion-later');
const _approve = ValueKey('suggestion-approve');

Future<void> _pumpSuggestion(WidgetTester tester, KioskSuggestion s,
    {bool startedByUser = false, bool checked = false, ValueChanged<bool>? onMute}) async {
  tester.view.physicalSize = const Size(800, 480);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: KioskSuggestionView(
        suggestion: s,
        target: kMicrowaveAppliance,
        cdRemaining: 20,
        cdTotal: 20,
        onApprove: () {},
        onReject: () {},
        startedByUser: startedByUser,
        muteChecked: checked,
        onMuteChanged: onMute ?? (_) {},
      ),
    ),
  ));
}

Future<FakeKioskApi> _pumpKiosk(WidgetTester tester, List<KioskSuggestion> suggestions) async {
  tester.view.physicalSize = const Size(800, 480);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final api = FakeKioskApi()..suggestionList = suggestions;
  await tester.pumpWidget(MaterialApp(home: KioskScreen(api: api, tts: FakeTts(), events: FakeEventStream())));
  await tester.pump();
  await tester.pump();
  return api;
}

void main() {
  group('모델·시각 말', () {
    test('weather_tip·today·warnings·fetched_at — 없거나 모양이 달라도 깨지지 않는다', () {
      final a = AmbientInfo.fromJson({
        'greeting': '',
        'weather_tip': {'kind': 'rain', 'text': '오후 3시부터 비 예보가 있어요. 우산 챙기세요.', 'icon': 'rain'},
        'today': {'high': 21, 'low': 12},
        'warnings': [
          {'kind': '강풍', 'level': '주의보', 'title': '강풍주의보', 'icon': 'wind', 'advice': '바람이 강해요.'},
          {'title': ''},
          'x',
        ],
        'fetched_at': '2026-10-25T15:05:00+09:00',
      });
      expect(a.weatherTip!.text, startsWith('오후 3시부터'));
      expect((a.today!.high, a.today!.low), (21, 12));
      expect(a.warnings.map((w) => w.title), ['강풍주의보']);
      expect(a.fetchedAt, '2026-10-25T15:05:00+09:00');
      final old = AmbientInfo.fromJson({'greeting': '', 'today': {'high': null}, 'warnings': null});
      expect(old.weatherTip, isNull);
      expect(old.today, isNull);
      expect(old.warnings, isEmpty);
      expect(old.fetchedAt, isNull);
    });

    test("예보 칸 이름 — 12시는 '낮 12시', 0시는 '밤 12시'(서버 _hour_label과 같은 규칙)", () {
      expect(hourLabel12('12시'), '낮 12시');
      expect(hourLabel12('0시'), '밤 12시');
      expect(hourLabel12('13시'), '오후 1시');
      expect(hourLabel12('11시'), '오전 11시');
    });
  });

  group('처음 화면 날씨 줄', () {
    testWidgets("머리말 없이 '14° · 특보 제목 ›', 아래 특보 안내 — 줄 전체가 누르는 자리", (tester) async {
      await _pumpIdle(tester, _amb(warnings: const [_wind]));
      expect(tester.takeException(), isNull);
      expect(find.text('바깥 날씨'), findsNothing);
      expect(_plain(tester, _head), '14° · 강풍주의보');
      expect(_plain(tester, _advice), '바람이 강해요. 외출할 때 조심하세요', reason: '키오스크 줄 끝 마침표는 뺀다(kioskLine)');
      expect(find.byKey(const ValueKey('idle-weather-more')), findsOneWidget);
      final tap = tester.getSize(find.byKey(const ValueKey('idle-weather-tap')));
      // 캔버스 48(실패널 약 98px) 이상.
      expect(tap.height, greaterThanOrEqualTo(48));
      expect(find.bySemanticsLabel(RegExp(r'^날씨 자세히 보기\. 14도, 흐림, 강풍주의보')), findsOneWidget);
    });

    testWidgets('특보가 없으면 하늘 말 — 안내는 weather_tip(위 안내가 확인할 일이어도)', (tester) async {
      await _pumpIdle(
          tester,
          _amb(
            tip: const AmbientTip(kind: 'appliance', text: '전자레인지를 확인해 주세요', icon: 'attention'),
            weatherTip: const AmbientTip(kind: 'rain', text: '오후 3시부터 비 예보가 있어요. 우산 챙기세요.', icon: 'rain'),
          ));
      expect(_plain(tester, _head), '14° · 흐림');
      expect(_plain(tester, _advice), '오후 3시부터 비 예보가 있어요. 우산 챙기세요');
    });

    testWidgets("지금 칸이 없으면 작게 '낮 12시 예보'", (tester) async {
      await _pumpIdle(tester, _amb(hourly: _hours.sublist(1), nowKnown: true), now: DateTime(2026, 10, 25, 10, 30));
      expect(_plain(tester, _head), '18° · 맑음 · 낮 12시 예보');
    });

    testWidgets('예보가 없고 특보만 있으면 특보만', (tester) async {
      await _pumpIdle(tester, _amb(hourly: const [], warnings: const [_wind]));
      expect(_row, findsOneWidget);
      expect(_plain(tester, _head), '강풍주의보');
    });

    testWidgets('아무것도 없으면 줄이 없다(지어내지 않는다)', (tester) async {
      await _pumpIdle(tester, _amb(hourly: const []));
      expect(_row, findsNothing);
    });
  });

  group('날씨 자세히 창', () {
    for (final scale in [1.0, 1.3]) {
      testWidgets('누르면 열리고 닫기·바깥으로 닫힌다, 아래 탭은 숨긴다(글씨 x$scale)', (tester) async {
        await _pumpIdle(tester, _amb(warnings: const [_wind]), scale: scale);
        expect(_detail, findsNothing);
        await tester.tap(find.byKey(const ValueKey('idle-weather-tap')));
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(_detail, findsOneWidget);
        expect(find.byType(KioskTabBarSuppress), findsOneWidget);
        expect(find.byKey(const ValueKey('weather-detail-now')), findsOneWidget);
        expect(find.text('오늘 최고 21° · 최저 12°'), findsOneWidget);
        final hours = find.byKey(const ValueKey('weather-detail-hours'));
        // 지금 칸(9시)은 위에 — 예보는 그 뒤 4칸.
        for (final label in ['낮 12시', '오후 3시', '오후 6시', '오후 9시']) {
          expect(find.descendant(of: hours, matching: find.text(label)), findsOneWidget, reason: label);
        }
        expect(find.descendant(of: hours, matching: find.text('강수 70%')), findsOneWidget);
        expect(find.byKey(const ValueKey('weather-detail-warning')), findsOneWidget);
        expect(find.textContaining('외출할 때 조심하세요', findRichText: true), findsWidgets);
        expect(find.text('오후 3시 5분에 받은 예보'), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('idle-sheet-close')));
        await tester.pump();
        expect(_detail, findsNothing);
        expect(find.byType(KioskTabBarSuppress), findsNothing);

        await tester.tap(find.byKey(const ValueKey('idle-weather-tap')));
        await tester.pump();
        expect(_detail, findsOneWidget);
        await tester.tapAt(const Offset(10, 470));
        await tester.pump();
        expect(_detail, findsNothing);
      });
    }

    testWidgets('예보를 새로 받지 못했으면 그 사실을 작게', (tester) async {
      await _pumpIdle(
          tester,
          const AmbientInfo(
              greeting: '', hourly: _hours, weatherSource: 'kma', stale: true, fetchedAt: '2026-10-25T06:00:00'));
      await tester.tap(find.byKey(const ValueKey('idle-weather-tap')));
      await tester.pump();
      expect(find.text('오전 6시에 받은 예보 · 새 예보를 받지 못해 지난 예보예요'), findsOneWidget);
    });
  });

  group('제안 단추 아니요 / 네', () {
    testWidgets("단추는 '아니요'·'네', 접근성 이름은 무엇이 일어나는지", (tester) async {
      await _pumpSuggestion(tester, _sug);
      expect(find.descendant(of: find.byKey(_later), matching: find.textContaining('아니요')), findsOneWidget);
      expect(find.descendant(of: find.byKey(_approve), matching: find.text('네')), findsOneWidget);
      expect(find.bySemanticsLabel('네. 전자레인지 버튼을 눌러요'), findsOneWidget);
      expect(find.bySemanticsLabel('아니요. 이번에는 하지 않아요'), findsOneWidget);
      expect(find.text("'네'를 누르기 전에는 아무것도 하지 않아요"), findsOneWidget);
    });

    testWidgets("'이 제안 앞으로 받지 않기' — '아니요' 바로 위, 줄 전체가 누르는 자리, 체크 상자로 읽힌다", (tester) async {
      final changes = <bool>[];
      await _pumpSuggestion(tester, _sug, onMute: changes.add);
      expect(tester.takeException(), isNull);
      final row = find.byKey(_mute);
      expect(row, findsOneWidget);
      final rowRect = tester.getRect(row);
      final later = tester.getRect(find.byKey(_later));
      expect(rowRect.height, greaterThanOrEqualTo(48));
      expect(rowRect.bottom, lessThanOrEqualTo(later.top + 0.5));
      expect((rowRect.left - later.left).abs(), lessThan(1));
      expect(tester.getSemantics(row), matchesSemantics(label: '이 제안 앞으로 받지 않기', hasCheckedState: true));
      await tester.tapAt(tester.getRect(row).centerRight - const Offset(8, 0));
      expect(changes, [true]);
    });

    testWidgets('내가 연 카드·루틴 카드에는 체크 줄이 없다', (tester) async {
      await _pumpSuggestion(tester, _sug, startedByUser: true);
      expect(find.byKey(_mute), findsNothing);
      await _pumpSuggestion(tester, _routineSug);
      expect(find.byKey(_mute), findsNothing);
    });
  });

  group('제안 다시 받지 않기 — 화면', () {
    testWidgets("체크하고 '아니요' → mute=true, 안내 문장", (tester) async {
      final api = await _pumpKiosk(tester, const [_sug]);
      await tester.tap(find.byKey(_mute));
      await tester.pump();
      api.suggestionList = [];
      await tester.tap(find.byKey(_later));
      await tester.pump();
      expect(api.rejectedIds, ['s1']);
      expect(api.mutedIds, ['s1']);
      expect(find.text(kSuggestionMutedNotice), findsOneWidget);
      expect(kSuggestionMutedNotice, '이 제안은 다시 띄우지 않아요. 휴대폰 앱에서 다시 켤 수 있어요.');
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets("체크하지 않은 '아니요'는 이번만(mute 없이)", (tester) async {
      final api = await _pumpKiosk(tester, const [_sug]);
      api.suggestionList = [];
      await tester.tap(find.byKey(_later));
      await tester.pump();
      expect(api.rejectedIds, ['s1']);
      expect(api.mutedIds, isEmpty);
      expect(find.text(kSuggestionMutedNotice), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets("숨기기가 본체에 닿지 않으면 카드를 두고 '숨기지 못했어요'", (tester) async {
      final api = await _pumpKiosk(tester, const [_sug]);
      api.rejectError = Exception('offline');
      await tester.tap(find.byKey(_mute));
      await tester.pump();
      await tester.tap(find.byKey(_later));
      await tester.pump();
      expect(find.byType(KioskSuggestionView), findsOneWidget);
      expect(find.text('숨기지 못했어요. 다시 눌러 주세요.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('루틴 카드에는 체크 줄이 없다', (tester) async {
      await _pumpKiosk(tester, const [_routineSug]);
      expect(find.byType(KioskSuggestionView), findsOneWidget);
      expect(find.byKey(_mute), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    test('rejectSuggestion은 본문에 mute를 그대로 보낸다', () async {
      final bodies = <Object?>[];
      for (final mute in [true, false]) {
        await http.runWithClient(
            () => KioskApiService(baseUrl: 'http://hub.test').rejectSuggestion('s1', mute: mute),
            () => MockClient((req) async {
                  expect(req.url.path, '/suggestions/s1/reject');
                  bodies.add(jsonDecode(req.body));
                  return http.Response('{"ok":true}', 200);
                }));
      }
      expect(bodies, [
        {'mute': true},
        {'mute': false},
      ]);
    });

    test("'이미 했어요'는 본문에 reason=already_done을 싣는다(2026-10-26)", () async {
      Object? body;
      await http.runWithClient(
          () => KioskApiService(baseUrl: 'http://hub.test').rejectSuggestion('s1', reason: 'already_done'),
          () => MockClient((req) async {
                body = jsonDecode(req.body);
                return http.Response('{"ok":true}', 200);
              }));
      expect(body, {'mute': false, 'reason': 'already_done'});
    });

    test('신호·이미 했어요 표시는 서버 값 그대로 읽는다(없으면 빈 목록·거짓)', () {
      final s = KioskSuggestion.fromJson({
        'id': 'x', 'purpose': 'p', 'occurrences': 0,
        'signals': [
          {'label': '집에 계심', 'ok': true},
          {'label': ' ', 'ok': true},
          {'label': '불을 끄심', 'ok': false},
        ],
        'can_mark_done': true,
      });
      expect(s.signals.map((e) => e.label), ['집에 계심', '불을 끄심']);
      expect(s.signals.last.ok, isFalse);
      expect(s.canMarkDone, isTrue);
      final old = KioskSuggestion.fromJson({'id': 'y', 'purpose': 'p', 'occurrences': 0});
      expect(old.signals, isEmpty);
      expect(old.canMarkDone, isFalse);
    });
  });

  test('예보 받은 시각 — 본체가 UTC로 보내도 한국 시각으로(10/25 실패널: 11시 10분이 2시 10분으로 보였다)', () {
    expect(KioskWeatherDetailSheet.fetchedLine('2026-10-25T02:10:33.120000+00:00'), '오전 11시 10분에 받은 예보');
    expect(KioskWeatherDetailSheet.fetchedLine('2026-10-25T15:05:00+09:00'), '오후 3시 5분에 받은 예보');
    expect(KioskWeatherDetailSheet.fetchedLine('엉뚱한 값'), isNull);
  });

  test("꺼진 공기청정기의 모드는 '지금'이 아니라 '운전 모드'(10/25 실패널: 꺼져 있는데 '지금 잘 때 운전')", () {
    Map<String, dynamic> st(String power) => {
          'operation': {'airPurifierOperationMode': power},
          'airPurifierJobMode': {'currentJobMode': 'SLEEP'},
        };
    String? label(List<ThinqStateRow> rows) => rows.where((r) => r.value == '잘 때 운전').map((r) => r.label).firstOrNull;
    expect(label(thinqStateRows(st('POWER_OFF'))), '운전 모드');
    expect(label(thinqStateRows(st('POWER_ON'))), '지금');
  });
}
