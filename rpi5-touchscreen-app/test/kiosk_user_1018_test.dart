// 사용자 결정(2026-10-18) 다섯 가지 — 키오스크.
//
// 1. 오른쪽 위 상태 칩: 모두 괜찮으면 숨긴다. 문제가 있을 때만 '확인 필요 N', 본체에 닿지 않으면 '본체와 연결이 끊겼어요',
//    아직 확인하지 못했으면 '연결을 확인하고 있어요'(정상이라고 하지 않는다). 모두 괜찮을 때도 메뉴의 '연결'로 목록을 본다.
// 2. 조용한 시간(서버 quiet.active)에는 처음 화면만 어둡게 + 시계·다음 루틴·문제 표시만. 만지면 30초 평소 밝기.
//    제안·결과·비상 화면은 어둡게 하지 않는다.
// 3. 고대비 설정 — 큰 글씨 옆, 같은 파일에 저장. 색 토큰 대비 7:1 이상.
// 4. 처음 화면 '지난 일' 한 줄 — 실패·'확인 못 함'만, '확인'을 누를 때까지(키오스크 안 기억).
// 5. '확인 못 함' 결과에 순서 안내 2~3단계(LG 가전 확인 못 함·작은 팔 눌렸는지 모름). 자동 재시도 단추는 없다.
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/ambient.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/screens/kiosk_screen.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/services/kiosk_settings_store.dart';
import 'package:simplelay_touchscreen/theme/kiosk_colors.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/done_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/past_result_line.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/suggestion_view.dart';

import 'kiosk_phase_test.dart' show FakeKioskApi, FakeTts, FakeEventStream;
import 'support/idle_menu.dart';

const _ok = [
  ConnectionItem(id: 'network', state: 'ok', title: '와이파이에 연결돼 있어요', message: ''),
  ConnectionItem(id: 'press', state: 'ok', title: '작은 팔이 연결돼 있어요', message: ''),
];
const _two = [
  ConnectionItem(id: 'network', state: 'warn', title: '와이파이 신호가 약해요', message: ''),
  ConnectionItem(id: 'press', state: 'error', title: '작은 팔과 연결이 끊겼어요', message: ''),
];
const _checking = [
  ConnectionItem(id: 'network', state: 'ok', title: '', message: ''),
  ConnectionItem(id: 'press', state: 'unknown', title: '', message: ''),
];

final _microwave = applianceFromServerJson({
  'id': 'microwave',
  'name': '전자레인지',
  'category': 'microwave',
  'rows': 1,
  'cols': 2,
  'buttons': [
    {'id': 'BT-1', 'label': '즉석밥', 'x': 0, 'y': 0},
    {'id': 'BT-2', 'label': '시작', 'x': 1, 'y': 0},
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

void _viewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 480);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _pumpView(WidgetTester tester, Widget child) async {
  _viewport(tester);
  await tester.pumpWidget(MaterialApp(home: Scaffold(backgroundColor: KioskColors.bg, body: child)));
  await tester.pump();
}

Future<void> _pumpKiosk(WidgetTester tester, FakeKioskApi api, {KioskSettingsStore? settings}) async {
  _viewport(tester);
  await tester.pumpWidget(MaterialApp(
    home: KioskScreen(api: api, tts: FakeTts(), events: FakeEventStream(), settings: settings),
  ));
  await tester.pump();
  await tester.pump();
}

KioskIdleView _idle({List<ConnectionItem> connections = _ok, bool connected = true, ValueChanged<ConnectionItem>? onOpen}) =>
    KioskIdleView(
      now: DateTime(2026, 10, 18, 22, 30),
      connected: connected,
      connections: connections,
      appliances: [_microwave],
      onSelectAppliance: (_) {},
      onOpenConnection: onOpen ?? (_) {},
      onDndGesture: () {},
      onSettingsGesture: () {},
    );

const _quietHealth = {
  'ok': true,
  'quiet': {'enabled': true, 'start': '22:00', 'end': '07:00', 'active': true, 'reason': 'schedule'},
};

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

void main() {
  tearDown(() => KioskColors.setHighContrast(false));

  group('1. 상태 칩 — 모두 괜찮으면 숨김, 문제가 있을 때만 확인 필요 N', () {
    testWidgets('모두 괜찮으면 칩이 없다 — 체크·기기 모두 정상도 없다, 메뉴는 그대로', (tester) async {
      await _pumpView(tester, _idle());
      expect(find.byKey(const ValueKey('idle-status-chip')), findsNothing);
      expect(find.text('기기 모두 정상'), findsNothing);
      expect(find.byIcon(Icons.check_circle_outline), findsNothing);
      expect(find.byKey(const ValueKey('idle-menu')), findsOneWidget);
    });

    testWidgets("문제가 둘이면 '확인 필요 2' — 누르면 무엇이 왜인지 연결 목록", (tester) async {
      await _pumpView(tester, _idle(connections: _two));
      final chip = find.byKey(const ValueKey('idle-status-chip'));
      expect(find.descendant(of: chip, matching: find.text('확인 필요 2')), findsOneWidget);
      await tester.tap(chip);
      await tester.pump();
      expect(find.byKey(const ValueKey('conn-badge-network')), findsOneWidget);
      expect(find.byKey(const ValueKey('conn-badge-press')), findsOneWidget);
      expect(find.text('작은 팔과 연결이 끊겼어요'), findsOneWidget);
    });

    testWidgets("아직 확인하지 못했으면 숨기지 않고 '연결을 확인하고 있어요' — 정상이라고 하지 않는다", (tester) async {
      await _pumpView(tester, _idle(connections: _checking));
      expect(find.text('연결을 확인하고 있어요'), findsOneWidget);
    });

    testWidgets("본체에 닿지 않으면 그대로 '본체와 연결이 끊겼어요'", (tester) async {
      await _pumpView(tester, _idle(connected: false));
      expect(find.text('본체와 연결이 끊겼어요'), findsOneWidget);
    });

    testWidgets("모두 괜찮아도 메뉴의 '연결'로 연결 목록을 볼 수 있다", (tester) async {
      await _pumpView(tester, _idle());
      await openIdleConnections(tester);
      expect(find.byKey(const ValueKey('conn-network')), findsOneWidget);
      expect(find.byKey(const ValueKey('conn-press')), findsOneWidget);
    });
  });

  group('2. 조용한 시간 — 처음 화면만 어둡게', () {
    testWidgets('조용한 시간이면 어두운 막 + 시계·다음 루틴만(예보·가전 줄 없음), 만지면 30초 밝게', (tester) async {
      final api = FakeKioskApi()
        ..applianceList = [_microwave]
        ..healthResult = HealthStatus.fromJson(_quietHealth)
        ..ambientResult = const AmbientInfo(greeting: '편안한 밤 보내세요.', hourly: [
          AmbientHour(label: '0시', hour: 0, icon: 'clear', temp: 12),
          AmbientHour(label: '3시', hour: 3, icon: 'clear', temp: 11),
        ])
        ..nextRun = const KioskNextRun(name: '아침 공기청정기 끄기', dayLabel: '내일', hhmm: '07:00', modeLabel: '자동 실행');
      await _pumpKiosk(tester, api);
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(const ValueKey('idle-quiet-dim')), findsOneWidget);
      expect(find.byKey(const ValueKey('idle-clock')), findsOneWidget);
      expect(find.byKey(const ValueKey('idle-next-run')), findsOneWidget);
      expect(find.byKey(const ValueKey('ambient-hours')), findsNothing);
      expect(find.byKey(const ValueKey('strip-microwave')), findsNothing);
      // 막은 앱 안의 어두운 면이다(패널 밝기 장치는 건드리지 않는다). 평가 15차(10/18) — 패널 전체(가장자리 여백까지)에 얹는다.
      final dim = tester.widget<ColoredBox>(find.byKey(const ValueKey('kiosk-panel-dim')));
      expect(dim.color.a, closeTo(kQuietDimAlpha, 0.01));

      // 만지면 평소 밝기·평소 화면(가전 줄)으로.
      await tester.tap(find.byKey(const ValueKey('idle-quiet-dim')));
      await tester.pump();
      expect(find.byKey(const ValueKey('idle-quiet-dim')), findsNothing);
      expect(find.byKey(const ValueKey('strip-microwave')), findsOneWidget);
      // 30초 뒤 다시 어둡게.
      await tester.pump(kQuietWakeDuration + const Duration(seconds: 1));
      expect(find.byKey(const ValueKey('idle-quiet-dim')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('잠시 쉬기(reason pause)는 어둡게 하지 않는다 — 매일 조용한 시간에만(10/18 결정)', (tester) async {
      final api = FakeKioskApi()
        ..applianceList = [_microwave]
        ..healthResult = HealthStatus.fromJson({
          ..._quietHealth,
          'quiet': {'enabled': false, 'start': '22:00', 'end': '07:00', 'active': true, 'reason': 'pause'},
        });
      await _pumpKiosk(tester, api);
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(const ValueKey('idle-quiet-dim')), findsNothing);
      expect(find.byKey(const ValueKey('strip-microwave')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('조용한 시간이 아니면 어둡게 하지 않는다', (tester) async {
      final api = FakeKioskApi()..applianceList = [_microwave];
      await _pumpKiosk(tester, api);
      expect(find.byKey(const ValueKey('idle-quiet-dim')), findsNothing);
      expect(find.byKey(const ValueKey('strip-microwave')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('조용한 시간이라도 제안 카드는 어둡게 하지 않는다', (tester) async {
      final api = FakeKioskApi()
        ..applianceList = [_microwave]
        ..healthResult = HealthStatus.fromJson(_quietHealth)
        ..suggestionList = const [
          KioskSuggestion(id: 's1', purpose: '즉석밥 데워줘', occurrences: 3, applianceId: 'microwave'),
        ];
      await _pumpKiosk(tester, api);
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(KioskSuggestionView), findsOneWidget);
      expect(find.byKey(const ValueKey('idle-quiet-dim')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('조용한 시간이라도 비상 버튼이 걸려 있으면 어둡게 하지 않는다', (tester) async {
      final api = FakeKioskApi()
        ..applianceList = [_microwave]
        ..healthResult = HealthStatus.fromJson(_quietHealth)
        ..statusResult = const KioskStatus(running: false, estopLatched: true);
      await _pumpKiosk(tester, api);
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(const ValueKey('estop-banner')), findsOneWidget);
      expect(find.byKey(const ValueKey('idle-quiet-dim')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('조용한 시간이라도 결과 화면(눌렸는지 모름)은 어둡게 하지 않는다', (tester) async {
      final api = FakeKioskApi()
        ..applianceList = [_microwave]
        ..healthResult = HealthStatus.fromJson(_quietHealth)
        ..statusResult = const KioskStatus(running: false, lastJobId: 'job-0', lastOutcome: 'success');
      await _pumpKiosk(tester, api);
      api.statusResult = const KioskStatus(
          running: false, lastJobId: 'job-2', lastApplianceId: 'microwave', lastOutcome: 'failed', lastStatus: 'failed');
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 900));
      expect(find.byType(KioskDoneView), findsOneWidget);
      expect(find.byKey(const ValueKey('idle-quiet-dim')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('3. 고대비', () {
    test('고대비 색 — 보조 글자·상태색은 검정 바탕 위 7:1 이상, 면 위 글자도 7:1 이상', () {
      const p = KioskColors.contrast;
      expect(p.bg, const Color(0xFF000000));
      expect(p.muted, const Color(0xFFFFFFFF)); // 회색 보조 글자 → 흰색
      expect(_ratio(p.muted, p.bg), greaterThanOrEqualTo(7));
      expect(_ratio(p.panelText, p.bg), greaterThanOrEqualTo(7));
      expect(_ratio(Colors.white, p.surface), greaterThanOrEqualTo(7));
      expect(_ratio(Colors.white, p.surface2), greaterThanOrEqualTo(7));
      // 옅은 테두리 → 흰 테두리(불투명, 바탕 위 7:1 이상).
      expect(p.border.a, 1.0);
      expect(_ratio(p.border, p.bg), greaterThanOrEqualTo(7));
      for (final c in [p.primary, p.danger, p.warning, p.practice, p.running, p.confirmed, p.success]) {
        expect(_ratio(c, p.bg), greaterThanOrEqualTo(7), reason: '$c 글자·아이콘');
        expect(_ratio(p.onAccent, c), greaterThanOrEqualTo(7), reason: '$c 면 위 검정 글자');
      }
      expect(_ratio(Colors.white, p.stop), greaterThanOrEqualTo(7)); // 정지 면 위 흰 글자
      // 상태색은 뜻을 지킨다(색 계열 그대로, 평소보다 또렷하게) — 바탕 대비가 평소 이상.
      const s = KioskColors.standard;
      for (final (n, h) in [
        (s.warning, p.warning),
        (s.danger, p.danger),
        (s.confirmed, p.confirmed),
        (s.running, p.running),
        (s.practice, p.practice),
      ]) {
        expect(_ratio(h, p.bg), greaterThanOrEqualTo(_ratio(n, s.bg)));
        expect((HSVColor.fromColor(h).hue - HSVColor.fromColor(n).hue).abs(), lessThan(20));
      }
      expect(_ratio(Colors.white, p.stop), greaterThan(_ratio(Colors.white, s.stop)));
    });

    test('평소 색 — 보조 글자는 바탕 위 4.5:1 이상(종전 값 그대로)', () {
      const s = KioskColors.standard;
      expect(_ratio(s.muted, s.bg), greaterThanOrEqualTo(4.5));
      expect(KioskColors.highContrast, isFalse);
      expect(KioskColors.muted, s.muted);
    });

    testWidgets('고대비 처음 화면·결과 화면의 글자는 모두 바탕 위 7:1 이상', (tester) async {
      KioskColors.setHighContrast(true);
      Future<void> check(Widget w) async {
        await _pumpView(tester, w);
        for (final rt in tester.widgetList<RichText>(find.byType(RichText))) {
          final color = rt.text.style?.color;
          if (color == null || color == KioskColors.onAccent) continue; // 검정 글자는 채운 면 위에만 쓴다
          final shown = _over(color, KioskColors.bg);
          expect(_ratio(shown, KioskColors.bg), greaterThanOrEqualTo(7),
              reason: "'${rt.text.toPlainText()}' $color");
        }
      }

      await check(_idle(connections: _two));
      await check(KioskDoneView(
          success: false, executionMode: 'real', label: '즉석밥 데워줘', target: _microwave, onDismiss: () {}));
    });

    testWidgets("설정의 '큰 글씨' 옆 '고대비' — 켜면 색이 바뀌고 같은 파일에 저장, 다시 켜도 유지", (tester) async {
      final dir = Directory.systemTemp.createTempSync('kiosk-hc');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = KioskSettingsStore(path: '${dir.path}/settings.json');
      final api = FakeKioskApi()..applianceList = [_microwave];
      await _pumpKiosk(tester, api, settings: store);
      // 메뉴 단추 아래 이름 '메뉴'는 보조 글자색(평소 회색 → 고대비 흰색).
      Color menuColor() => tester.widget<Text>(find.text('메뉴')).style!.color!;
      expect(menuColor(), KioskColors.standard.muted);
      await tapIdleMenuItem(tester, 'settings-entry');
      await tester.pump();
      final row = find.byKey(const ValueKey('settings-high-contrast'));
      expect(row, findsOneWidget);
      expect(find.descendant(of: row, matching: find.text('고대비')), findsOneWidget);
      // 큰 글씨 바로 아래(옆) 줄.
      final large = tester.getRect(find.text('큰 글씨'));
      expect(tester.getRect(row).top - large.bottom, lessThan(60));
      await tester.ensureVisible(row);
      await tester.pump();
      await tester.tap(find.descendant(of: row, matching: find.byType(Switch)));
      await tester.pump();
      expect(KioskColors.highContrast, isTrue);
      expect(store.load().highContrast, isTrue);
      expect(File('${dir.path}/settings.json').readAsStringSync(), contains('"high_contrast":true'));
      // 고대비가 켜진 채 이미 그려진 화면도 새 색(배경 검정, 보조 글자 흰색)으로.
      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
      expect(scaffold.backgroundColor, const Color(0xFF000000));
      await tester.tap(find.byIcon(Icons.close).first); // 설정 닫기
      await tester.pump();
      expect(menuColor(), const Color(0xFFFFFFFF));
      await tester.pumpWidget(const SizedBox.shrink());
      expect(KioskColors.highContrast, isFalse); // 화면이 사라지면 평소 색으로

      // 다시 켜면 저장값대로 고대비.
      await _pumpKiosk(tester, api, settings: store);
      expect(KioskColors.highContrast, isTrue);
      expect(menuColor(), const Color(0xFFFFFFFF));
      await tester.pumpWidget(const SizedBox.shrink());
    }, skip: false);

    test('lib 화면 코드는 회색·흰색 반투명 글자를 직접 쓰지 않는다(색 토큰만 — 고대비가 따라간다)', () {
      final bad = <String>[];
      for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart') || f.path.replaceAll('\\', '/').endsWith('theme/kiosk_colors.dart')) continue;
        final lines = f.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          if (RegExp(r'Colors\.(grey|blueGrey|white(10|12|24|30|38|54|60))\b').hasMatch(lines[i])) {
            bad.add('${f.path}:${i + 1}');
          }
          // 회색 계열 직접 색(평소 보조 글자 0xFFAEB3C0 같은) — 토큰(KioskColors.muted)을 쓴다.
          if (RegExp(r'Color\(0xFF(AEB3C0|C4C8D2|9|8|7|6)').hasMatch(lines[i])) bad.add('${f.path}:${i + 1}');
        }
      }
      expect(bad, isEmpty);
    });
  });

  group('4. 처음 화면 지난 일 한 줄', () {
    test("한 줄 꼴 — '오후 3:12 즉석밥 데우기 — 눌렸는지 몰라요'", () {
      expect(
          KioskPastResult(at: DateTime(2026, 10, 18, 15, 12), label: '즉석밥 데우기', headline: '눌렸는지 몰라요').text,
          '오후 3:12 즉석밥 데우기 — 눌렸는지 몰라요');
      expect(KioskPastResult(at: DateTime(2026, 10, 18, 9, 5), label: '', headline: '어떻게 됐는지 몰라요').text,
          '오전 9:05 — 어떻게 됐는지 몰라요');
    });

    test('남기는 것은 실패·확인 못 함만 — 성공·연습·확인한 정지는 남기지 않는다', () {
      KioskDoneView v({
        bool success = false,
        String mode = 'real',
        KioskFailureReason? reason,
        String? route,
        String? confirmation,
        String? stopLevel,
        bool thinqOnly = false,
        ApplianceMap? target,
      }) =>
          KioskDoneView(
            success: success,
            executionMode: mode,
            label: '즉석밥 데워줘',
            reason: reason,
            route: route,
            resultConfirmation: confirmation,
            stopLevel: stopLevel,
            thinqOnly: thinqOnly,
            target: target,
          );
      expect(v(reason: KioskFailureReason.execution).pastHeadline, '눌렸는지 몰라요');
      expect(v(reason: KioskFailureReason.serverLost).pastHeadline, '어떻게 됐는지 몰라요');
      expect(v(reason: KioskFailureReason.unconfirmed, route: 'thinq').pastHeadline, '보냈지만 됐는지 몰라요');
      expect(v(reason: KioskFailureReason.stopped, stopLevel: 'sent').pastHeadline, '작은 팔이 멈췄는지 몰라요');
      expect(v(reason: KioskFailureReason.stopped, stopLevel: 'verified').pastHeadline, isNull);
      expect(v(success: true, confirmation: 'reported').pastHeadline, isNull);
      expect(v(success: true, confirmation: 'none').pastHeadline, '눌렸는지 몰라요');
      expect(v(mode: 'mock', reason: KioskFailureReason.execution).pastHeadline, isNull);
      expect(v(success: true, route: 'thinq', confirmation: 'state_confirmed', thinqOnly: true, target: _purifier).pastHeadline,
          isNull);
      expect(
          v(reason: KioskFailureReason.unconfirmed, route: 'thinq', thinqOnly: true, target: _purifier).pastHeadline,
          isNotNull);
    });

    testWidgets("실패 결과를 닫으면 처음 화면에 한 줄로 남고 '확인'을 누를 때까지 있다 — 성공은 남지 않는다", (tester) async {
      final api = FakeKioskApi()
        ..applianceList = [_microwave]
        ..statusResult = const KioskStatus(running: false, lastJobId: 'job-0', lastOutcome: 'success');
      await _pumpKiosk(tester, api);
      api.statusResult = const KioskStatus(
          running: false,
          lastJobId: 'job-2',
          lastApplianceId: 'microwave',
          lastOutcome: 'failed',
          lastStatus: 'failed',
          lastExecutionMode: 'real');
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 900));
      expect(find.byType(KioskDoneView), findsOneWidget);
      expect(find.byKey(const ValueKey('idle-past-result')), findsNothing); // 결과 화면에는 두지 않는다
      await tester.tap(find.byKey(const ValueKey('done-home')));
      await tester.pump();
      final line = find.byKey(const ValueKey('idle-past-result'));
      expect(line, findsOneWidget);
      final text = tester.widget<Text>(find.byKey(const ValueKey('idle-past-result-text'))).data!;
      expect(text, contains('전자레인지'));
      expect(text, endsWith('— 눌렸는지 몰라요'));
      expect(text, matches(RegExp(r'^(오전|오후|밤) \d{1,2}:\d{2} ')));
      // 시간이 지나도(다른 조회가 돌아도) 남는다.
      await tester.pump(const Duration(minutes: 2));
      expect(find.byKey(const ValueKey('idle-past-result')), findsOneWidget);
      // '확인' — 누르는 자리 48 이상.
      final ok = find.byKey(const ValueKey('idle-past-result-ok'));
      expect(tester.getSize(ok).height, greaterThanOrEqualTo(48));
      await tester.tap(ok);
      await tester.pump();
      expect(find.byKey(const ValueKey('idle-past-result')), findsNothing);

      // 성공은 남기지 않는다.
      api.statusResult = const KioskStatus(
          running: false,
          lastJobId: 'job-3',
          lastApplianceId: 'microwave',
          lastOutcome: 'success',
          lastStatus: 'succeeded',
          lastExecutionMode: 'real',
          lastConfirmation: 'reported');
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 900));
      expect(find.byType(KioskDoneView), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('done-home')));
      await tester.pump();
      expect(find.byKey(const ValueKey('idle-past-result')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group("5. '확인 못 함' 순서 안내", () {
    List<String> steps(WidgetTester tester) => [
          for (var i = 0; i < 3; i++)
            if (find.byKey(ValueKey('done-recovery-step-$i')).evaluate().isNotEmpty)
              tester
                  .widget<RichText>(find.descendant(
                      of: find.byKey(ValueKey('done-recovery-step-$i')), matching: find.byType(RichText)))
                  .text
                  .toPlainText()
                  .replaceAll('⁠', '')
                  .replaceAll(' ', ' '),
        ];

    testWidgets('작은 팔 눌렸는지 모름 — 세 단계, 자동 재시도 단추는 없다', (tester) async {
      await _pumpView(
          tester,
          KioskDoneView(
              success: false, executionMode: 'real', label: '즉석밥 데워줘', target: _microwave, onDismiss: () {}));
      expect(find.byKey(const ValueKey('done-recovery-steps')), findsOneWidget);
      expect(steps(tester), kPressRecoverySteps);
      expect(find.text('한 번 더 하기'), findsNothing);
      expect(find.byKey(const ValueKey('done-retry')), findsNothing);
    });

    testWidgets('LG 가전 확인 못 함(결과 창) — 전원·와이파이 → 휴대폰 앱 → 가전 직접', (tester) async {
      await _pumpView(
          tester,
          KioskDoneView(
            success: false,
            executionMode: 'real',
            label: '공기청정기를 켤까요?',
            target: _purifier,
            reason: KioskFailureReason.unconfirmed,
            route: 'thinq',
            thinqOnly: true,
            onDismiss: () {},
          ));
      expect(find.byKey(const ValueKey('thinq-result')), findsOneWidget);
      expect(steps(tester), kThinqRecoverySteps);
      expect(kThinqRecoverySteps[1], contains('휴대폰 앱'));
    });

    testWidgets('LG 가전 받았는지 모름(종전 결과 화면)에도 같은 안내', (tester) async {
      await _pumpView(
          tester,
          KioskDoneView(
            success: false,
            executionMode: 'real',
            label: '바람 세게',
            target: _purifier,
            reason: KioskFailureReason.receiptUnknown,
            route: 'thinq',
            onDismiss: () {},
          ));
      expect(steps(tester), kThinqRecoverySteps);
    });

    testWidgets('확인한 결과·연습·사용자 정지·작은 팔 걸림에는 두지 않는다', (tester) async {
      for (final view in [
        KioskDoneView(
            success: true,
            executionMode: 'real',
            label: '즉석밥',
            target: _microwave,
            resultConfirmation: 'reported',
            onDismiss: () {}),
        KioskDoneView(success: false, executionMode: 'mock', label: '즉석밥', target: _microwave, onDismiss: () {}),
        KioskDoneView(
            success: false,
            executionMode: 'real',
            label: '즉석밥',
            target: _microwave,
            reason: KioskFailureReason.stopped,
            stopLevel: 'verified',
            onDismiss: () {}),
        KioskDoneView(
            success: false,
            executionMode: 'real',
            label: '즉석밥',
            target: _microwave,
            reason: KioskFailureReason.safetyStop,
            abortReason: 'motion_alarm: stall',
            onDismiss: () {}),
      ]) {
        await _pumpView(tester, view);
        expect(find.byKey(const ValueKey('done-recovery-steps')), findsNothing);
      }
    });

    test('안내는 짧은 말 2~3단계, 엔지니어 말 없음', () {
      for (final list in [kPressRecoverySteps, kThinqRecoverySteps]) {
        expect(list.length, inInclusiveRange(2, 3));
        for (final s in list) {
          expect(s.length, lessThanOrEqualTo(26), reason: s);
          for (final w in ['서버', '클라우드', '재시도', '엔코더', 'API', 'ThinQ', '네트워크', '모듈']) {
            expect(s, isNot(contains(w)));
          }
        }
      }
    });
  });
}
