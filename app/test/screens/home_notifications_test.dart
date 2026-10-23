import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/main.dart';
import 'package:simplelay/providers/care_events_provider.dart';
import 'package:simplelay/screens/app_shell.dart';
import 'package:simplelay/screens/care_events_screen.dart';
import 'package:simplelay/models/execution_status.dart';
import 'package:simplelay/services/rpi_api_service.dart';
import 'package:simplelay/theme/app_theme.dart';
import '../helpers/test_helpers.dart';

class _Inbox extends CareEventsNotifier {
  _Inbox(super.ref, CareEventsState initial) {
    state = initial;
  }
  int opened = 0;
  @override
  Future<void> refresh() async {}
  @override
  Future<void> markAllSeen() async {
    opened++;
    state = state.copyWith(
        lastSeenId:
            state.events.fold<int>(0, (id, e) => e.id > id ? e.id : id));
  }

  void receive(RpiCareEvent event) =>
      state = state.copyWith(events: [event, ...state.events]);
}

RpiCareEvent _event(int id) => RpiCareEvent(
    id: id,
    kind: 'routine_notice',
    message: '예약 안내 $id',
    occurredAt: DateTime(2026, 10, 23));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final cached in [false, true]) {
    testWidgets('조회 실패는 0개로 단정하지 않고 기존 알림을 유지 ($cached)', (tester) async {
      final router = buildAppRouter(initialLocation: '/');
      addTearDown(router.dispose);
      await tester.pumpWidget(buildWithProviderState(
        overrides: [
          ...installedOverrides([]),
          ...disconnectedOverrides(),
          careEventsProvider.overrideWith((ref) => _Inbox(
              ref,
              CareEventsState(
                  status: CareInboxStatus.failed,
                  events: cached ? [_event(1)] : []))),
        ],
        child: MaterialApp.router(theme: AppTheme.light, routerConfig: router),
      ));
      await tester.pumpAndSettle();
      expect(
          find.bySemanticsLabel(cached
              ? '알림, 안 읽은 알림 1개, 새 알림을 불러오지 못했어요'
              : '알림, 새 알림을 불러오지 못했어요'),
          findsOneWidget);
      expect(find.byKey(const Key('notifications-unread-badge')),
          cached ? findsOneWidget : findsNothing);
      if (!cached) expect(find.text('!'), findsWidgets);
    });
  }

  for (final phase in [ExecutionPhase.running, ExecutionPhase.unknown]) {
    testWidgets('알림함에서도 $phase 작업의 정지 유지', (tester) async {
      final router = buildAppRouter(initialLocation: '/care');
      addTearDown(router.dispose);
      await tester.pumpWidget(buildWithProviderState(
        overrides: [...installedOverrides([]), ...disconnectedOverrides()],
        executionStatus: ExecutionStatus(phase: phase, label: '시험 동작'),
        child: MaterialApp.router(theme: AppTheme.light, routerConfig: router),
      ));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('shell-stop')), findsOneWidget);
    });
  }
  for (final count in [0, 3, 101]) {
    testWidgets('홈 종에 안 읽은 알림 $count개 표시, 설정에는 중복 배지 없음', (tester) async {
      final router = buildAppRouter(initialLocation: '/');
      addTearDown(router.dispose);
      await tester.pumpWidget(buildWithProviderState(
        overrides: [
          ...installedOverrides([]),
          ...disconnectedOverrides(),
          careEventsProvider.overrideWith((ref) => _Inbox(
              ref,
              CareEventsState(
                  status: CareInboxStatus.ready,
                  events: [for (var i = 1; i <= count; i++) _event(i)]))),
        ],
        child: MaterialApp.router(theme: AppTheme.light, routerConfig: router),
      ));
      await tester.pumpAndSettle();
      expect(find.byTooltip('알림'), findsOneWidget);
      expect(find.byKey(const Key('settings-unread-badge')), findsNothing);
      expect(find.byKey(const Key('notifications-unread-badge')),
          count == 0 ? findsNothing : findsOneWidget);
      if (count > 0) {
        expect(
            find.descendant(
                of: find.byKey(const Key('notifications-unread-badge')),
                matching: find.text(count > 99 ? '99+' : '$count')),
            findsOneWidget);
      }
    });
  }

  testWidgets('종 → 알림함 → 읽음 감소 → 뒤로 홈 복귀 → 새 알림 증가', (tester) async {
    final router = buildAppRouter(initialLocation: '/');
    addTearDown(router.dispose);
    late _Inbox inbox;
    await tester.pumpWidget(buildWithProviderState(
      overrides: [
        ...installedOverrides([]),
        ...disconnectedOverrides(),
        careEventsProvider.overrideWith((ref) => inbox = _Inbox(
            ref,
            CareEventsState(
                status: CareInboxStatus.ready,
                events: [_event(1), _event(2)]))),
      ],
      child: MaterialApp.router(theme: AppTheme.light, routerConfig: router),
    ));
    await tester.pumpAndSettle();
    expect(inbox.opened, 0);
    await tester.tap(find.byTooltip('알림'));
    await tester.pumpAndSettle();
    expect(find.byType(CareEventsScreen), findsOneWidget);
    expect(find.byType(AppShell), findsNothing);
    expect(inbox.opened, 1);
    expect(inbox.state.unreadCount, 0);
    router.pop();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('notifications-unread-badge')), findsNothing);
    inbox.receive(_event(3));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('notifications-unread-badge')), findsOneWidget);
    expect(inbox.state.unreadCount, 1);
  });
}
