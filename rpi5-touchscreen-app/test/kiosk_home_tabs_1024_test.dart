// 키오스크 홈·아래 탭(시안 B 10/24, 사용자 승인) — 홈 짜임(위 줄 시계 · 무엇을 할까요 · 가전 · 오른쪽 줄 칸)과 아래 탭 4개
// (홈 · 가전 · 자동 실행 · 기록). 탭은 평소·가전 화면에서만 — 확인·제안·누르는 중·결과에서는 숨는다(정지·승인이 앞선다).
// '자동 실행'·'기록'은 읽기만 하는 화면이고, 건너뛰기는 처음 화면과 같은 길이다. 기록의 '완료'는 확인한 것만.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/ambient.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/models/kiosk_history.dart';
import 'package:simplelay_touchscreen/models/thinq.dart';
import 'package:simplelay_touchscreen/screens/kiosk_screen.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/appliance_select_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/auto_run_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/done_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/history_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/manual_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/suggestion_view.dart';

import 'kiosk_phase_test.dart' show FakeEventStream, FakeKioskApi, FakeTts;

const _at = '2026-10-24T22:00:00+09:00';

KioskNextRun _next({String id = 'rt-evening', String at = _at, String name = '저녁 공기청정기 켜기', String day = '오늘'}) =>
    KioskNextRun.fromJson({
      'routine_id': id,
      'name': name,
      'at': at,
      'day_label': day,
      'auto': true,
      'mode_label': '자동 실행',
      'skipped': false,
      'skip_action_label': '${day == '오늘' ? '오늘' : day}은 건너뛰기',
    })!;

final _purifier = applianceFromServerJson({
  'id': 'air_purifier', 'name': '공기청정기', 'category': 'other', 'rows': 0, 'cols': 0,
  'buttons': <dynamic>[], 'control_path': 'thinq', 'can_execute': true, 'readiness': 'operable',
});

const _pressDown = [
  ConnectionItem(id: 'network', state: 'ok', title: '', message: ''),
  ConnectionItem(id: 'press', state: 'error', title: '누름 장치와 연결이 끊겼어요', message: ''),
];

const _ambient = AmbientInfo(
  greeting: '좋은 오후예요.',
  weatherSource: 'kma',
  tip: AmbientTip(kind: 'rain', text: '오후 3시부터 비 예보가 있어요. 우산 챙기세요.', icon: 'rain'),
  now: AmbientHour(label: '지금', hour: 15, icon: 'cloudy', temp: 17),
  hourly: [AmbientHour(label: '18시', hour: 18, icon: 'rain', temp: 15, pop: 70, precip: true)],
);

Future<FakeKioskApi> _pumpKiosk(WidgetTester tester,
    {Size size = const Size(1920, 1080), bool banner = true, FakeKioskApi? api}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final a = api ??
      (FakeKioskApi()
        ..applianceList = [_purifier, kMicrowaveAppliance, kInductionAppliance]
        ..routinesResult = const [
          KioskRoutine(id: 'rt-30s', name: '30초 데우기', applianceIds: ['microwave'], pressCount: 2),
        ]
        ..nextRun = _next()
        ..ambientResult = _ambient
        ..air = const KioskAirReading(applianceId: 'air_purifier', grade: 'GOOD', pm25: 8, power: 'on'));
  if (banner) a.connectionsResult = _pressDown;
  await tester.pumpWidget(MaterialApp(home: KioskScreen(api: a, tts: FakeTts(), events: FakeEventStream())));
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  return a;
}

final _tabs = find.byKey(const ValueKey('kiosk-tab-bar'));
Finder _tab(String name) => find.byKey(ValueKey('kiosk-tab-$name'));

/// [f]가 화면 안에 다 있고 아래 탭 줄과 겹치지 않는다.
void _inside(WidgetTester tester, Finder f, {String? why}) {
  expect(f, findsOneWidget, reason: why ?? '$f');
  final r = tester.getRect(f);
  final screen = Offset.zero & tester.view.physicalSize;
  expect(screen.contains(r.topLeft) && screen.contains(r.bottomRight - const Offset(0.01, 0.01)), isTrue,
      reason: '${why ?? f} 화면 밖 $r');
  final bar = tester.getRect(_tabs);
  expect(r.bottom, lessThanOrEqualTo(bar.top + 0.5), reason: '${why ?? f} 이(가) 아래 탭에 걸린다 $r / $bar');
}

void main() {
  group('홈 짜임 — 띠가 있어도 잘리지 않는다', () {
    for (final size in const [Size(1920, 1080), Size(800, 480)]) {
      testWidgets('${size.width.toInt()}x${size.height.toInt()} 누름 장치 끊김 띠 + 무엇을 할까요 + 오른쪽 줄 다 보인다', (tester) async {
        await _pumpKiosk(tester, size: size);
        expect(tester.takeException(), isNull);
        expect(find.byType(KioskIdleView), findsOneWidget);
        _inside(tester, find.byKey(const ValueKey('idle-status-chip')), why: '띠');
        _inside(tester, find.byKey(const ValueKey('idle-problem-help')), why: '해결 방법 보기');
        _inside(tester, find.byKey(const ValueKey('idle-featured')), why: '무엇을 할까요');
        for (final id in ['air_purifier', 'microwave', 'induction']) {
          _inside(tester, find.byKey(ValueKey('strip-$id')), why: id);
        }
        _inside(tester, find.byKey(const ValueKey('idle-next-run')), why: '다음 자동 실행');
        _inside(tester, find.byKey(const ValueKey('idle-next-run-skip')), why: '오늘은 건너뛰기');
        expect(find.byKey(const ValueKey('idle-next-run-skip')).hitTestable(), findsOneWidget);
        _inside(tester, find.byKey(const ValueKey('idle-weather')), why: '바깥 날씨');
        _inside(tester, find.byKey(const ValueKey('idle-air')), why: '공기질');
        _inside(tester, find.byKey(const ValueKey('idle-menu')), why: '메뉴');
        // 띠는 한 줄 높이(아래 칸을 밀어내지 않는다).
        expect(tester.getRect(find.byKey(const ValueKey('idle-status-chip'))).height,
            lessThan(tester.getRect(find.byKey(const ValueKey('idle-featured'))).height));
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }

    testWidgets('바깥 날씨 줄은 무엇을 할까요 카드와 함께 있다(카드가 날씨를 밀어내지 않는다)', (tester) async {
      await _pumpKiosk(tester, banner: false);
      expect(find.byKey(const ValueKey('idle-featured')), findsOneWidget);
      expect(find.byKey(const ValueKey('idle-weather')), findsOneWidget);
      expect(find.byKey(const ValueKey('idle-weather-advice')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('홈의 오늘은 건너뛰기는 띠가 있어도 눌리고 그 회차를 보낸다', (tester) async {
      final api = await _pumpKiosk(tester);
      await tester.tap(find.byKey(const ValueKey('idle-next-run-skip')));
      await tester.pump();
      await tester.pump();
      expect(api.skipRequests, [('rt-evening', _at, true)]);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('아래 탭', () {
    testWidgets('홈에서 탭 줄이 보이고 홈이 골라져 있다 — 가전·자동 실행·기록·홈으로 오간다', (tester) async {
      final api = await _pumpKiosk(tester, banner: false);
      api.historyEntries = [
        KioskHistoryEntry.fromJson({
          'job_id': 'j1',
          'finished_at': '2026-10-24T15:12:00+09:00',
          'status': 'succeeded',
          'route': 'physical',
          'confirmation': 'reported',
          'execution_mode': 'real',
          'appliance_name': '전자레인지',
          'buttons': [
            {'button': '30초'},
            {'button': '시작'},
          ],
        })!,
      ];
      expect(_tabs, findsOneWidget);
      final semantics = tester.ensureSemantics();
      expect(tester.getSemantics(_tab('home')), isSemantics(label: '홈 탭', isButton: true, isSelected: true));
      semantics.dispose();

      await tester.tap(_tab('appliances'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(KioskApplianceSelectView), findsOneWidget);
      expect(_tabs, findsOneWidget);

      await tester.tap(_tab('auto'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(KioskAutoRunView), findsOneWidget);
      expect(find.text(KioskAutoRunView.kOffOnPhone), findsOneWidget);
      expect(api.upcomingCalls, greaterThan(0));

      await tester.tap(_tab('history'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(KioskHistoryView), findsOneWidget);
      expect(api.historyCalls, greaterThan(0));
      expect(find.text('확인 못 함'), findsOneWidget);
      expect(find.text('완료'), findsNothing);

      await tester.tap(_tab('home'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(KioskIdleView), findsOneWidget);
      expect(api.executeCalls, 0, reason: '탭은 탐색일 뿐 — 아무것도 보내지 않는다');
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('자동 실행 탭의 건너뛰기는 처음 화면과 같은 길(같은 요청)', (tester) async {
      final api = await _pumpKiosk(tester, banner: false);
      api.upcoming = [_next(), _next(id: 'rt-morning', at: '2026-10-25T07:00:00+09:00', name: '아침 공기청정기 끄기', day: '내일')];
      await tester.tap(_tab('auto'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final second = find.descendant(of: find.byKey(const ValueKey('auto-run-1')), matching: find.byKey(const ValueKey('auto-run-skip')));
      await tester.tap(second);
      await tester.pump();
      await tester.pump();
      expect(api.skipRequests, [('rt-morning', '2026-10-25T07:00:00+09:00', true)]);
      // 처음 화면의 다음 루틴(오늘 22:00)은 그 뒤 회차로 바뀌지 않는다.
      await tester.tap(_tab('home'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('idle-next-run-skip')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('누르기 확인·누르는 중·결과에서는 탭이 없고, 같은 가전 계속 조작으로 돌아오면 다시 보인다', (tester) async {
      // 저장된 동작이 없는 가전 — 조작판이 바로 버튼 판.
      final api = await _pumpKiosk(tester,
          size: const Size(800, 480), banner: false, api: FakeKioskApi()..applianceList = [kMicrowaveAppliance]);
      await tester.tap(find.byKey(const ValueKey('strip-microwave')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(KioskManualView), findsOneWidget);
      expect(_tabs, findsOneWidget, reason: '가전 화면에는 탭');
      await tester.tap(find.text('해동'));
      await tester.pump();
      await tester.pump();
      expect(find.text('누르기'), findsOneWidget);
      expect(_tabs, findsNothing, reason: '누르기 확인이 앞선다');
      await tester.tap(find.text('누르기'));
      await tester.pump();
      expect(_tabs, findsNothing, reason: '누르는 중');
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
      expect(_tabs, findsNothing, reason: '결과');
      await tester.tap(find.byKey(const ValueKey('done-continue')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(KioskManualView), findsOneWidget);
      expect(_tabs, findsOneWidget);
      expect(api.executeCalls, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('제안 카드(승인)에서는 탭이 없다', (tester) async {
      final api = FakeKioskApi()
        ..applianceList = [kMicrowaveAppliance]
        ..suggestionList = [
          const KioskSuggestion(id: 's1', purpose: '즉석밥 데워줘', occurrences: 3, applianceId: 'microwave'),
        ];
      await _pumpKiosk(tester, size: const Size(800, 480), banner: false, api: api);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(KioskSuggestionView), findsOneWidget);
      expect(_tabs, findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('기록 — 확인 수준 그대로', () {
    KioskHistoryEntry e(String id, {String status = 'succeeded', String? outcome, String route = 'physical',
            String confirmation = 'press_confirmed', String mode = 'real', String? purpose}) =>
        KioskHistoryEntry.fromJson({
          'job_id': id,
          'finished_at': '2026-10-24T12:00:00+09:00',
          'status': status,
          if (outcome != null) 'outcome': outcome,
          if (purpose != null) 'purpose': purpose,
          'route': route,
          'confirmation': confirmation,
          'execution_mode': mode,
          'buttons': const <dynamic>[],
        })!;

    test("'완료'는 실제 실행에서 확인한 것만", () {
      expect(e('a').result.$1, '완료');
      expect(e('b', route: 'thinq', confirmation: 'state_confirmed').result.$1, '완료');
      expect(e('c', confirmation: 'reported').result.$1, '확인 못 함', reason: '누름 장치 보고만');
      expect(e('d', confirmation: 'none').result.$1, '확인 못 함');
      expect(e('e', route: 'thinq', confirmation: 'none', outcome: 'unconfirmed', status: 'unconfirmed').result.$1, '확인 못 함');
      expect(e('f', mode: 'mock').result.$1, '연습', reason: '연습을 완료로 말하지 않는다');
      expect(e('g', status: 'stopped', outcome: 'stopped').result.$1, '멈춤');
      expect(e('h', status: 'failed', outcome: 'failed').result.$1, '실패');
      expect(e('i', purpose: "자동 실행 · '저녁 공기청정기 켜기' 루틴").title(), '저녁 공기청정기 켜기');
      expect(e('i', purpose: "자동 실행 · '저녁 공기청정기 켜기' 루틴").automatic, isTrue);
    });

    testWidgets('보고만 받은 기록은 화면에서도 확인 못 함 — 비었으면·못 불러오면 그 말', (tester) async {
      Future<void> show(List<KioskHistoryEntry>? entries, {VoidCallback? reload}) => tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: KioskHistoryView(entries: entries, now: DateTime(2026, 10, 24, 15), onReload: reload))));
      await show([e('c', confirmation: 'reported', purpose: '즉석밥 데워줘')]);
      expect(find.text('즉석밥 데우기'), findsOneWidget);
      expect(find.text('확인 못 함'), findsOneWidget);
      expect(find.text('완료'), findsNothing);
      await show(const []);
      expect(find.text('아직 기록이 없어요'), findsOneWidget);
      var reloads = 0;
      await show(null, reload: () => reloads++);
      expect(find.text('기록을 불러오지 못했어요'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('tab-page-reload')));
      expect(reloads, 1);
    });
  });

  testWidgets('자동 실행 화면 — 건너뛰기는 받은 콜백을 그 회차로 부르고, 아주 끄는 스위치는 없다', (tester) async {
    final taps = <KioskNextRun>[];
    final run = _next();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: KioskAutoRunView(runs: [run], onToggleSkip: taps.add))));
    await tester.tap(find.byKey(const ValueKey('auto-run-skip')));
    expect(taps.single.routineId, 'rt-evening');
    expect(find.byType(Switch), findsNothing);
    expect(find.text(KioskAutoRunView.kOffOnPhone), findsOneWidget);
    // 보내는 중에는 눌리지 않는다(같은 요청 두 번 금지).
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: KioskAutoRunView(runs: [run], busy: true, onToggleSkip: taps.add))));
    await tester.tap(find.byKey(const ValueKey('auto-run-skip')), warnIfMissed: false);
    expect(taps, hasLength(1));
  });
}
