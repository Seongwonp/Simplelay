// 가전 회사 제품 디자인 리드 출시 검토(10/18, 폰 62점)에서 나온 폰 문제 — 단정 시험.
//
// 6. 실행 화면 — 제목은 음성 원문('즉석밥 데워줘')이 아니라 할 일 이름('즉석밥 데우기', 키오스크와 같은 규칙),
//    지금 버튼은 따옴표 없이 '시작 버튼', 진행 아래에 누를 순서를 세로로(끝낸 칸·지금 칸·남은 칸).
// 7. 설정 탭 배지는 볼 것(실패·정지 등)이 있을 때만 — 자동으로 한 일·루틴 안내뿐이면 홈 '확인이 필요해요'가 말한다.
//    (기록 'LG 가전' 꼬리표 → 작은 구름 표식, 연습 가전 'LG 가전' 빼기, '새 루틴' 여백, 연결됨 초록 점은 해당 화면 시험에서 본다.)
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/execution_status.dart';
import 'package:simplelay/providers/care_events_provider.dart';
import 'package:simplelay/providers/hub_provider.dart';
import 'package:simplelay/screens/app_shell.dart';
import 'package:simplelay/screens/status_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';

import '../helpers/test_helpers.dart';

Future<void> _pumpStatus(WidgetTester tester, ExecutionStatus status) async {
  tester.view.physicalSize = const Size(400, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(buildScreen(const StatusScreen(), executionStatus: status));
  await tester.pump();
}

class _SeededCare extends CareEventsNotifier {
  _SeededCare(super.ref, CareEventsState seed) {
    state = seed;
  }

  @override
  Future<void> refresh() async {}
}

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

Future<void> _pumpShell(WidgetTester tester, List<RpiCareEvent> events) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [
      developerModeProvider.overrideWithValue(false),
      careEventsProvider.overrideWith(
          (ref) => _SeededCare(ref, CareEventsState(events: events, status: CareInboxStatus.ready))),
    ],
    child: MaterialApp.router(routerConfig: _router()),
  ));
  await tester.pump();
  await tester.pump();
}

RpiCareEvent _event(int id, String kind) =>
    RpiCareEvent(id: id, kind: kind, message: '알림 $id', occurredAt: DateTime(2026, 10, 18, 8, id));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('6. 실행 화면', () {
    const running = ExecutionStatus(
      phase: ExecutionPhase.running,
      label: '즉석밥 데워줘',
      currentButton: '시작',
      totalSteps: 2,
      completedSteps: 1,
    );

    testWidgets("제목은 할 일 이름 '즉석밥 데우기' — 음성 원문(반말)이 아니다", (tester) async {
      await _pumpStatus(tester, running);
      expect(find.byKey(const Key('status-job-title')), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const Key('status-job-title'))).data, '즉석밥 데우기');
      expect(find.text('즉석밥 데워줘'), findsNothing);
    });

    testWidgets("지금 버튼은 따옴표 없이 '시작 버튼'", (tester) async {
      await _pumpStatus(tester, running);
      expect(find.text("'시작'"), findsNothing);
      expect(findPlainText('시작 버튼'), findsWidgets);
      expect(find.byKey(const Key('status-now-button')), findsOneWidget);
    });

    testWidgets('진행 아래 누를 순서를 세로로 — 끝낸 칸·지금 칸(버튼 이름)', (tester) async {
      await _pumpStatus(tester, running);
      expect(find.byKey(const Key('status-step-order')), findsOneWidget);
      final first = find.byKey(const Key('status-order-0'));
      final second = find.byKey(const Key('status-order-1'));
      expect(first, findsOneWidget);
      expect(second, findsOneWidget);
      expect(tester.getTopLeft(second).dy, greaterThan(tester.getTopLeft(first).dy));
      expect(find.descendant(of: first, matching: find.byIcon(Icons.check_circle)), findsOneWidget);
      expect(find.descendant(of: second, matching: findPlainText('시작 버튼')), findsOneWidget);
      expect(find.descendant(of: second, matching: find.text('지금')), findsOneWidget);
    });
  });

  group('7. 설정 탭 배지', () {
    testWidgets('자동으로 한 일·루틴 안내뿐이면 설정 탭에 배지가 없다(홈이 말한다)', (tester) async {
      await _pumpShell(tester, [_event(1, 'auto_executed'), _event(2, 'routine_notice')]);
      expect(find.byKey(const Key('settings-unread-badge')), findsNothing);
    });

    testWidgets('못 한 일이 있으면 배지가 남는다', (tester) async {
      await _pumpShell(tester, [_event(1, 'execution_failed'), _event(2, 'auto_executed')]);
      expect(find.byKey(const Key('settings-unread-badge')), findsOneWidget);
    });
  });
}
