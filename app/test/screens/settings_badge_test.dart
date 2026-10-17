// 설정 탭 배지(2026-10-13 B안) — 숫자 대신 점. 뜻은 접근성 이름과 설정 안 건수가 말한다.
// 알림함 조회 실패는 0건과 다르게 말한다.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/providers/care_events_provider.dart';
import 'package:simplelay/providers/hub_provider.dart';
import 'package:simplelay/screens/app_shell.dart';
import 'package:simplelay/screens/settings_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';

import '../helpers/test_helpers.dart';

class _SeededCare extends CareEventsNotifier {
  _SeededCare(super.ref, CareEventsState seed) {
    state = seed;
  }

  @override
  Future<void> refresh() async {}
}

List<RpiCareEvent> _events(int n) => [
      for (var i = n; i >= 1; i--)
        RpiCareEvent(
          id: i,
          kind: 'execution_failed',
          message: '실패 $i',
          occurredAt: DateTime(2026, 10, 13, 8, i),
        ),
    ];

Override _care(CareEventsState s) =>
    careEventsProvider.overrideWith((ref) => _SeededCare(ref, s));

GoRouter _router() => GoRouter(
      initialLocation: '/',
      routes: [
        StatefulShellRoute.indexedStack(
          builder: (_, __, shell) => AppShell(navigationShell: shell),
          branches: [
            for (final p in ['/', '/routines', '/history', '/settings'])
              StatefulShellBranch(routes: [
                GoRoute(path: p, builder: (_, __) => Text('body $p')),
              ]),
          ],
        ),
      ],
    );

Future<void> _pumpShell(WidgetTester tester, CareEventsState s) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [developerModeProvider.overrideWithValue(false), _care(s)],
    child: MaterialApp.router(routerConfig: _router()),
  ));
  await tester.pump();
  await tester.pump();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('읽지 않은 알림이 있으면 숫자 대신 점, 접근성 이름은 건수를 말한다', (tester) async {
    final handle = tester.ensureSemantics();
    await _pumpShell(
        tester, CareEventsState(events: _events(13), status: CareInboxStatus.ready));
    expect(find.text('13'), findsNothing, reason: '무엇이 13개인지 모르는 숫자를 띄우지 않는다');
    expect(find.byKey(const Key('settings-unread-dot')), findsOneWidget);
    expect(find.bySemanticsLabel('설정, 읽지 않은 알림 13건'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('0건이면 점이 없다', (tester) async {
    await _pumpShell(
        tester, const CareEventsState(events: [], status: CareInboxStatus.ready));
    expect(find.byKey(const Key('settings-unread-dot')), findsNothing);
  });

  testWidgets('조회 실패는 0건으로 읽히지 않는다(탭 접근성 이름)', (tester) async {
    final handle = tester.ensureSemantics();
    await _pumpShell(
        tester, const CareEventsState(events: [], status: CareInboxStatus.failed));
    expect(find.byKey(const Key('settings-unread-dot')), findsNothing);
    expect(find.bySemanticsLabel('설정, 알림을 불러오지 못했어요'), findsOneWidget);
    handle.dispose();
  });

  Future<void> pumpSettings(WidgetTester tester, CareEventsState s) async {
    tester.view.physicalSize = const Size(400, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(buildScreen(const SettingsScreen(), overrides: [
      ...installedOverrides([kTestAppliance]),
      _care(s),
    ]));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('설정 안 보호자 알림은 건수를 그대로 말한다', (tester) async {
    await pumpSettings(
        tester, CareEventsState(events: _events(3), status: CareInboxStatus.ready));
    expect(findPlainText('읽지 않은 알림 3건'), findsOneWidget);
  });

  testWidgets('설정 안에서도 조회 실패를 "아무 일 없음"처럼 말하지 않는다', (tester) async {
    await pumpSettings(
        tester, const CareEventsState(events: [], status: CareInboxStatus.failed));
    expect(findPlainText('알림을 불러오지 못했어요'), findsOneWidget);
    expect(find.text('확인이 없으면 알림을 보내요'), findsNothing);
  });
}
