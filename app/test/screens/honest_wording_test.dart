// 화면이 실제 확인 수준보다 앞서 말하지 않는다(심사위원 시각 평가 10/18 §3-5 — 정직성 예외).
//
// - 실행 중: 서버가 눌림 판정(누름 센서 L1)을 보내지 않으면 '눌렸는지 보고 있어요'라고 하지 않는다 — 지금 실물 구성
//   (RPi4 작은 팔)은 버튼별 센서 판정 없이 집계 보고만 한다. 판정이 오면(센서를 단 구성) 그 근거를 그대로 보인다.
// - 보호자 알림: 본체와 끊겼거나 조회가 실패했으면 '새 알림이 없어요'(0건 단정)가 아니라 '못 불러왔어요'.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/execution_status.dart';
import 'package:simplelay/providers/care_events_provider.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/settings_screen.dart';
import 'package:simplelay/screens/status_screen.dart';

import '../helpers/test_helpers.dart';

class _SeededCare extends CareEventsNotifier {
  _SeededCare(super.ref, CareEventsState seed) {
    state = seed;
  }

  @override
  Future<void> refresh() async {}
}

/// 설정의 '보호자 알림' 줄 안에서만 찾는다(다른 줄 — LG 가전 연결 — 의 '못 불러왔어요'와 섞이지 않게).
Finder _careRow(String text, {bool contains = false}) => find.descendant(
    of: find.ancestor(of: findPlainText('보호자 알림'), matching: find.byType(ListTile)),
    matching: findPlainText(text, contains: contains));

Override _care(CareEventsState s) => careEventsProvider.overrideWith((ref) => _SeededCare(ref, s));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('실행 중 — 눌림 판정이 없으면 보고 있다고 하지 않는다', () {
    Future<void> pump(WidgetTester tester, ExecutionStatus s) async {
      tester.view.physicalSize = const Size(400, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(buildScreen(const StatusScreen(), executionStatus: s));
      await tester.pump();
    }

    testWidgets('판정 없음(지금 실물 구성) → 누르는 중, 확인한다는 말 없음', (tester) async {
      await pump(
        tester,
        const ExecutionStatus(
          phase: ExecutionPhase.running,
          label: '즉석밥 데워줘',
          currentButton: '시작',
          totalSteps: 2,
          completedSteps: 1,
        ),
      );
      expect(findPlainText('누르는 중'), findsOneWidget);
      expect(findPlainText('눌렸는지 보고 있어요', contains: true), findsNothing);
      expect(findPlainText('눌렸는지 보는 중', contains: true), findsNothing);
      expect(findPlainText('다 누르면 결과를 알려 드려요.'), findsOneWidget);
    });

    testWidgets('판정이 오면(센서를 단 구성) 그 근거를 보인다', (tester) async {
      await pump(
        tester,
        const ExecutionStatus(
          phase: ExecutionPhase.running,
          label: '즉석밥 데워줘',
          currentButton: '시작',
          totalSteps: 2,
          completedSteps: 1,
          verificationConfidence: 0.9,
          verificationDetail: '전류 변화 있음',
        ),
      );
      expect(findPlainText('눌렸는지 보는 중'), findsOneWidget);
      expect(find.textContaining('전류 변화 있음'), findsOneWidget);
    });
  });

  group('설정 — 보호자 알림은 모르는 상태를 없다고 하지 않는다', () {
    Future<void> pump(WidgetTester tester, CareEventsState s, RpiConnectionState hub) async {
      tester.view.physicalSize = const Size(400, 4000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(buildScreen(const SettingsScreen(), overrides: [
        ...installedOverrides([kTestAppliance]),
        rpiServerOverride(hub),
        _care(s),
      ]));
      await tester.pump();
      await tester.pump();
    }

    testWidgets('본체와 끊김(예전에 0건을 받았어도) → 본체와 연결이 끊겨 못 불러왔어요', (tester) async {
      await pump(tester, const CareEventsState(events: [], status: CareInboxStatus.ready),
          RpiConnectionState.unreachable);
      expect(_careRow('새 알림이 없어요', contains: true), findsNothing);
      expect(_careRow('본체와 연결이 끊겨 못 불러왔어요'), findsWidgets);
    });

    testWidgets('조회 실패 → 못 불러왔어요', (tester) async {
      await pump(tester, const CareEventsState(events: [], status: CareInboxStatus.failed),
          RpiConnectionState.connected);
      expect(_careRow('새 알림이 없어요', contains: true), findsNothing);
      expect(_careRow('못 불러왔어요'), findsWidgets);
    });

    testWidgets('본체 연결·조회 성공·0건일 때만 새 알림이 없어요', (tester) async {
      await pump(tester, const CareEventsState(events: [], status: CareInboxStatus.ready),
          RpiConnectionState.connected);
      expect(_careRow('새 알림이 없어요'), findsOneWidget);
    });

    testWidgets('첫 조회 전 → 알아보고 있어요', (tester) async {
      await pump(tester, const CareEventsState(status: CareInboxStatus.loading), RpiConnectionState.connected);
      expect(_careRow('새 알림이 없어요', contains: true), findsNothing);
      expect(_careRow('알아보고 있어요'), findsWidgets);
    });
  });
}
