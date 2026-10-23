import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/main.dart';
import 'package:simplelay/models/execution_status.dart';
import 'package:simplelay/screens/app_shell.dart';
import 'package:simplelay/theme/app_theme.dart';
import '../helpers/test_helpers.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('실제 경로: 네 과업 탭, 설정은 탭 밖이며 뒤로 가면 기록 복귀', (tester) async {
    final router = buildAppRouter(initialLocation: '/history');
    addTearDown(router.dispose);
    await tester.pumpWidget(buildWithProviderState(
      overrides: [...disconnectedOverrides(), ...installedOverrides([])],
      child: MaterialApp.router(theme: AppTheme.light, routerConfig: router),
    ));
    await tester.pumpAndSettle();
    expect(find.text('가전'), findsOneWidget);
    expect(find.text('자동 실행'), findsOneWidget);
    expect(find.text('설정'), findsNothing);
    await tester.tap(find.byTooltip('설정'));
    await tester.pumpAndSettle();
    expect(find.byType(AppShell), findsNothing);
    expect(find.text('설정'), findsWidgets);
    router.pop();
    await tester.pumpAndSettle();
    expect(router.routeInformationProvider.value.uri.path, '/history');
    expect(find.byType(AppShell), findsOneWidget);
  });

  for (final phase in [ExecutionPhase.running, ExecutionPhase.unknown]) {
    testWidgets('설정에서도 $phase 작업의 정지 수단 유지', (tester) async {
      final router = buildAppRouter(initialLocation: '/settings');
      addTearDown(router.dispose);
      await tester.pumpWidget(buildWithProviderState(
        executionStatus: ExecutionStatus(phase: phase, label: '시험 동작'),
        overrides: [...disconnectedOverrides(), ...installedOverrides([])],
        child: MaterialApp.router(theme: AppTheme.light, routerConfig: router),
      ));
      await tester.pumpAndSettle();
      expect(find.byType(AppShell), findsNothing);
      expect(find.byKey(const Key('shell-stop')), findsOneWidget);
    });
  }
}
