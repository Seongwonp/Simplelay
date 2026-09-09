import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'providers/execution_status_provider.dart';
import 'screens/appliance_editor_screen.dart';
import 'screens/app_shell.dart';
import 'screens/care_events_screen.dart';
import 'screens/history_screen.dart';
import 'screens/home_screen.dart';
import 'screens/manual_control_screen.dart';
import 'screens/onboarding_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/splash_screen.dart';
import 'screens/status_screen.dart';
import 'screens/suggestion_screen.dart';
import 'screens/voice_screen.dart';
import 'providers/theme_provider.dart';
import 'theme/app_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: SimpleLayApp()));
}

final _router = GoRouter(
  // 온보딩 여부와 가전 목록을 **여기서 미리 읽지 않는다.** 결정은
  // 시작 화면 하나가 내린다(`startupRouteProvider`) -- 두 군데서 정하면
  // 홈이 먼저 그려졌다가 뒤늦게 바뀌는 깜빡임이 생긴다.
  initialLocation: '/splash',
  routes: [
    GoRoute(
      path: '/splash',
      builder: (_, __) => const SplashScreen(),
    ),
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigationShell) =>
          AppShell(navigationShell: navigationShell),
      branches: [
        StatefulShellBranch(
          routes: [GoRoute(path: '/', builder: (_, __) => const HomeScreen())],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(path: '/voice', builder: (_, __) => const VoiceScreen()),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(path: '/status', builder: (_, __) => const StatusScreen()),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/settings',
              builder: (_, __) => const SettingsScreen(),
            ),
          ],
        ),
      ],
    ),
    GoRoute(
      path: '/onboarding',
      builder: (_, __) => const OnboardingScreen(),
    ),
    GoRoute(
      path: '/suggestion/:id',
      builder: (_, state) =>
          SuggestionScreen(sequenceId: state.pathParameters['id']!),
    ),
    GoRoute(
      path: '/appliance/new',
      builder: (_, __) => const ApplianceEditorScreen(),
    ),
    GoRoute(
      path: '/manual-control',
      builder: (_, __) => const ManualControlScreen(),
    ),
    GoRoute(
      path: '/history',
      builder: (_, __) => const HistoryScreen(),
    ),
    GoRoute(
      path: '/care',
      builder: (_, __) => const CareEventsScreen(),
    ),
  ],
);

class SimpleLayApp extends ConsumerWidget {
  const SimpleLayApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    // 실행 추적기를 시작부터 살려둔다. 진행 중이던 job을 기기에서 되읽어
    // 이어붙이는 일이 이 안에서 벌어지는데, 상태 화면을 열어야만 만들어지면
    // 앱을 다시 연 사용자는 홈에서 아무 흔적도 못 본다.
    ref.watch(executionStatusProvider);
    return MaterialApp.router(
      title: 'SimpleLay',
      debugShowCheckedModeBanner: false,
      routerConfig: _router,
      themeMode: themeMode,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
    );
  }
}
