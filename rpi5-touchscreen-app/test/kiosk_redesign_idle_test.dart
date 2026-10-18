// 화면 구조 개편 3단계(2026-10-18) — 대기 화면 위쪽 정리·가전 타일·공기 한 줄, LG 상세 공기 '자세히', 연결 창 문구.
//
// - 위쪽 아이콘 4~5개 → 상태 칩 하나(모두 괜찮으면 없음 / 문제가 있을 때만 앰버 '확인 필요 N', 사용자 결정 10/18) + 메뉴(잠시 쉬기·설정).
//   설정은 구석이 아니다(메뉴는 화면 가운데 큰 창으로 열린다). 누르는 자리는 48 이상.
// - 가전 줄은 큰 사각 타일(아이콘·이름·상태 줄).
// - 공기는 '공기 좋아요/보통이에요/나빠요' 한 줄 + 색. 숫자·'종합은 가전이 매긴 등급'은 LG 상세의 '자세히' 안.
// - LG 상세 상태 이름은 단추와 같은 말(약풍 → 약).
// - 연결 창: 단추 '다시 연결해 보기', 화면이 직접 쓰는 끊김 안내는 할 일 두 단계(공유기 → 본체 껐다 켜기).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/ambient.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/models/thinq.dart';
import 'package:simplelay_touchscreen/theme/kiosk_colors.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/connection_status.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/thinq_panel.dart';

const _ok = [
  ConnectionItem(id: 'network', state: 'ok', title: '와이파이에 연결돼 있어요', message: ''),
  ConnectionItem(id: 'press', state: 'ok', title: '작은 팔이 연결돼 있어요', message: ''),
];
const _pressDown = [
  ConnectionItem(id: 'network', state: 'ok', title: '와이파이에 연결돼 있어요', message: ''),
  ConnectionItem(id: 'press', state: 'error', title: '작은 팔과 연결이 끊겼어요', message: ''),
];
const _twoProblems = [
  ConnectionItem(id: 'network', state: 'warn', title: '와이파이 신호가 약해요', message: ''),
  ConnectionItem(id: 'press', state: 'error', title: '작은 팔과 연결이 끊겼어요', message: ''),
];

Future<void> _pump(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(800, 480);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  await tester.pump();
}

KioskIdleView _idle({
  List<ConnectionItem> connections = _ok,
  ValueChanged<ConnectionItem>? onOpen,
  VoidCallback? onSettings,
  VoidCallback? onDnd,
  DateTime? dnd,
  KioskAirReading? air,
}) =>
    KioskIdleView(
      now: DateTime(2026, 10, 18, 8, 30),
      connected: true,
      connections: connections,
      dndUntil: dnd,
      air: air,
      appliances: const [kMicrowaveAppliance, kInductionAppliance],
      onSelectAppliance: (_) {},
      onOpenConnection: onOpen ?? (_) {},
      onDndGesture: onDnd ?? () {},
      onSettingsGesture: onSettings ?? () {},
    );

void main() {
  group('위쪽 — 상태 칩 하나 + 메뉴', () {
    testWidgets('모두 괜찮으면 상태 칩이 없다 — 메뉴는 그대로(사용자 결정 10/18)', (tester) async {
      await _pump(tester, _idle());
      expect(tester.takeException(), isNull);
      expect(find.byType(KioskConnectionIcons), findsNothing);
      expect(find.byKey(const ValueKey('idle-status-chip')), findsNothing);
      expect(find.text('기기 모두 정상'), findsNothing);
      expect(find.byIcon(Icons.check_circle_outline), findsNothing);
      expect(find.byKey(const ValueKey('idle-menu')), findsOneWidget);
    });

    testWidgets("문제가 있을 때만 앰버 '확인 필요 1' — 누르면 그 연결 창", (tester) async {
      ConnectionItem? opened;
      await _pump(tester, _idle(connections: _pressDown, onOpen: (i) => opened = i));
      final chip = find.byKey(const ValueKey('idle-status-chip'));
      expect(find.descendant(of: chip, matching: find.text('확인 필요 1')), findsOneWidget);
      expect(tester.getSize(chip).height, greaterThanOrEqualTo(48));
      // 화면 읽기는 무엇이 문제인지까지 읽는다.
      expect(tester.getSemantics(chip).label, contains('작은 팔 연결이 끊겼어요'));
      final icon = tester.widget<Icon>(find.descendant(of: chip, matching: find.byType(Icon)).first);
      expect(icon.color, KioskColors.warning);
      await tester.tap(chip);
      await tester.pump();
      expect(opened?.id, 'press');
    });

    testWidgets("문제가 둘이면 '확인 필요 2' — 누르면 연결 목록, 항목을 누르면 그 연결 창", (tester) async {
      ConnectionItem? opened;
      await _pump(tester, _idle(connections: _twoProblems, onOpen: (i) => opened = i));
      expect(find.text('확인 필요 2'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('idle-status-chip')));
      await tester.pump();
      expect(find.byKey(const ValueKey('conn-network')), findsOneWidget);
      expect(find.byKey(const ValueKey('conn-press')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('conn-network')));
      await tester.pump();
      expect(opened?.id, 'network');
    });

    testWidgets('메뉴에 잠시 쉬기·설정 — 설정은 구석이 아니고 48 이상', (tester) async {
      var settings = 0;
      var dnd = 0;
      await _pump(tester, _idle(onSettings: () => settings++, onDnd: () => dnd++));
      final menu = find.byKey(const ValueKey('idle-menu'));
      expect(menu, findsOneWidget);
      expect(tester.getSize(menu).height, greaterThanOrEqualTo(48));
      expect(tester.getSize(menu).width, greaterThanOrEqualTo(48));
      expect(find.byKey(const ValueKey('settings-entry')), findsNothing);
      await tester.tap(menu);
      await tester.pump();
      final entry = find.byKey(const ValueKey('settings-entry'));
      expect(entry, findsOneWidget);
      expect(tester.getCenter(entry).dx, inInclusiveRange(800 * 0.25, 800 * 0.75));
      expect(tester.getSize(entry).height, greaterThanOrEqualTo(48));
      expect(tester.getSize(find.byKey(const ValueKey('dnd-entry'))).height, greaterThanOrEqualTo(48));
      await tester.tap(entry);
      await tester.pump();
      expect(settings, 1);
      await tester.tap(menu);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('dnd-entry')));
      await tester.pump();
      expect(dnd, 1);
    });

    testWidgets('쉬는 중이면 위쪽에 쉬는 중 칩 — 상태 칩·메뉴 자리는 그대로', (tester) async {
      await _pump(tester, _idle(connections: _pressDown));
      final chipOff = tester.getRect(find.byKey(const ValueKey('idle-status-chip')));
      final menuOff = tester.getRect(find.byKey(const ValueKey('idle-menu')));
      await _pump(tester, _idle(connections: _pressDown, dnd: DateTime(2026, 10, 18, 9, 30)));
      expect(find.byKey(const ValueKey('dnd-chip')), findsOneWidget);
      expect(find.text('쉬는 중'), findsOneWidget);
      expect(tester.getRect(find.byKey(const ValueKey('idle-status-chip'))), chipOff);
      expect(tester.getRect(find.byKey(const ValueKey('idle-menu'))), menuOff);
    });
  });

  group('가전 — 큰 사각 타일(상태 줄 포함)', () {
    testWidgets('타일은 넓고 높다, 상태 줄이 늘 있다', (tester) async {
      await _pump(tester, _idle());
      final tile = find.byKey(const ValueKey('strip-microwave'));
      final size = tester.getSize(tile);
      expect(size.width, greaterThanOrEqualTo(140));
      expect(size.height, greaterThanOrEqualTo(96));
      expect(find.byKey(const ValueKey('tile-status-microwave')), findsOneWidget);
      expect(find.byKey(const ValueKey('tile-status-induction')), findsOneWidget);
    });
  });

  group('공기 — 한 줄 + 색', () {
    testWidgets("'공기 나빠요' — 숫자·'종합은 가전이 매긴 등급'은 대기 화면에 없다", (tester) async {
      final air = KioskAirReading.fromJson({
        'appliance_id': 'air_purifier', 'grade': 'BAD', 'grade_source': 'total',
        'pm25': 8, 'pm25_level': 'GOOD', 'pm10': 8, 'pm10_level': 'GOOD', 'power': 'on', 'age_s': 3.0,
      })!;
      expect(air.sentence, '공기 나빠요');
      await _pump(tester, _idle(air: air));
      expect(find.textContaining('나빠요'), findsOneWidget);
      expect(find.textContaining('종합은 가전이 매긴 등급'), findsNothing);
      expect(find.textContaining('미세먼지'), findsNothing);
    });

    // 사용자 결정(10/18): 평소(좋음·보통)에는 공기 줄이 없다 — 그 자리에 다음 루틴을 적는다.
    testWidgets("'공기 보통이에요'는 대기 화면에 두지 않는다", (tester) async {
      final air = KioskAirReading.fromJson({
        'appliance_id': 'air_purifier', 'grade': 'NORMAL', 'pm25': 8, 'power': 'on', 'age_s': 3.0,
      })!;
      await _pump(tester, _idle(air: air));
      expect(find.textContaining('보통이에요'), findsNothing);
      expect(find.byKey(const ValueKey('idle-air')), findsNothing);
    });

    test('등급 말 — 좋아요 · 보통이에요 · 나빠요 · 아주 나빠요', () {
      String s(String g) => KioskAirReading(applianceId: 'a', grade: g).sentence;
      expect(s('GOOD'), '공기 좋아요');
      expect(s('NORMAL'), '공기 보통이에요');
      expect(s('BAD'), '공기 나빠요');
      expect(s('VERY_BAD'), '공기 아주 나빠요');
    });
  });

  group('LG 상세', () {
    test('바람 세기 이름은 단추와 같은 말(약풍 → 약)', () {
      final rows = thinqStateRows({
        'airFlow': {'windStrength': 'LOW'},
      });
      expect(rows.single.value, '약');
      expect(thinqStateRows({'airFlow': {'windStrength': 'HIGH'}}).single.value, '강');
    });

    testWidgets("공기는 한 줄 — 먼지 숫자·등급은 '자세히'를 눌러야 보인다", (tester) async {
      final state = {
        'operation': {'airPurifierOperationMode': 'POWER_ON'},
        'airFlow': {'windStrength': 'LOW'},
        'airQualitySensor': {
          'PM2': 42, 'PM10': 90, 'PM2Level': 'BAD', 'PM10Level': 'VERY_BAD', 'totalPollutionLevel': 'BAD',
        },
      };
      final purifier = applianceFromServerJson({
        'id': 'air_purifier', 'name': '공기청정기', 'category': 'other', 'rows': 0, 'cols': 0,
        'buttons': <dynamic>[], 'control_path': 'thinq', 'can_execute': true, 'readiness': 'operable',
      });
      await _pump(
          tester,
          KioskThinqPanel(
            appliance: purifier,
            readStatus: () async => KioskThinqStatus(
                state: state, executionMode: 'real', readAt: DateTime(2026, 10, 18, 9, 7)),
            sendCommand: null,
            onAccepted: (_, __) {},
          ));
      await tester.pump();
      expect(find.text('공기 나빠요'), findsOneWidget);
      expect(find.byKey(const ValueKey('thinq-row-초미세먼지')), findsNothing);
      expect(find.textContaining('42'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('thinq-air-more')));
      await tester.pump();
      expect(find.byKey(const ValueKey('thinq-row-초미세먼지')), findsOneWidget);
      expect(find.textContaining('종합은 가전이 매긴 등급'), findsOneWidget);
    });
  });

  group('연결 창', () {
    testWidgets("단추는 '다시 연결해 보기', 화면이 쓰는 끊김 안내는 두 단계·'SimpleLay 본체' 없음", (tester) async {
      const item = ConnectionItem.hubUnreachable;
      expect(item.fixes, hasLength(2));
      expect(item.fixes.first, contains('공유기'));
      expect(item.fixes.last, contains('본체'));
      expect(item.fixes.last, contains('껐다가 다시 켜'));
      await _pump(
          tester,
          KioskConnectionModal(item: item, checking: false, onRecheck: () {}, onClose: () {}));
      expect(find.text('다시 연결해 보기'), findsOneWidget);
      expect(find.text('새로 보기'), findsNothing);
      expect(find.textContaining('SimpleLay 본체'), findsNothing);
      // 할 일은 번호가 붙은 단계.
      expect(find.text('1'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
    });
  });
}
