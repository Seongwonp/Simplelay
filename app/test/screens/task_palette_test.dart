import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/main.dart';
import 'package:simplelay/theme/app_colors.dart';
import 'package:simplelay/theme/app_theme.dart';
import '../helpers/test_helpers.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final light in [true, false]) {
    testWidgets('과업·설정 화면은 같은 ${light ? '라이트' : '다크'} 팔레트를 유지한다', (tester) async {
      final router = buildAppRouter(initialLocation: '/');
      addTearDown(router.dispose);
      await tester.pumpWidget(buildWithProviderState(
        overrides: [...disconnectedOverrides(), ...installedOverrides([])],
        child: MaterialApp.router(
          theme: light ? AppTheme.light : AppTheme.dark, routerConfig: router),
      ));
      for (final path in ['/', '/appliances', '/automation', '/history', '/settings']) {
        router.go(path);
        await tester.pumpAndSettle();
        final context = tester.element(find.byType(Scaffold).last);
        final theme = Theme.of(context);
        expect(theme.colorScheme.primary, light ? AppColors.primaryLight : AppColors.primary, reason: path);
        expect(theme.scaffoldBackgroundColor, light ? AppColors.backgroundLight : AppColors.background, reason: path);
        expect(theme.cardTheme.color, light ? AppColors.surfaceLowLight : AppColors.surfaceLow, reason: path);
        expect(theme.appBarTheme.backgroundColor, theme.scaffoldBackgroundColor, reason: path);
        expect(tester.takeException(), isNull, reason: path);
      }
    });
  }
}
