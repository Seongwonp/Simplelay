import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'models/routine.dart';
import 'providers/execution_status_provider.dart';
import 'screens/add_appliance_wizard_screen.dart';
import 'screens/app_info_screen.dart';
import 'screens/appliance_detail_screen.dart';
import 'screens/appliance_editor_screen.dart';
import 'screens/app_shell.dart';
import 'screens/care_events_screen.dart';
import 'screens/developer_console_screen.dart';
import 'screens/history_screen.dart';
import 'screens/home_screen.dart';
import 'screens/manual_control_screen.dart';
import 'screens/onboarding_screen.dart';
import 'screens/routine_editor_screen.dart';
import 'screens/routine_record_screen.dart';
import 'screens/routines_screen.dart';
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

final _router = buildAppRouter();

/// 앱의 경로표. 테스트가 **실제 경로 구성**으로 뒤로 가기 같은 내비게이션
/// 동작을 확인할 수 있게 함수로 뺐다(시작 위치만 바꿀 수 있다).
GoRouter buildAppRouter({String initialLocation = '/splash'}) => GoRouter(
  // 온보딩 여부와 가전 목록을 **여기서 미리 읽지 않는다.** 결정은
  // 시작 화면 하나가 내린다(`startupRouteProvider`) -- 두 군데서 정하면
  // 홈이 먼저 그려졌다가 뒤늦게 바뀌는 깜빡임이 생긴다.
  initialLocation: initialLocation,
  routes: [
    GoRoute(
      path: '/splash',
      builder: (_, __) => const SplashScreen(),
    ),
    // 탭 순서: 홈 · 루틴 · 기록 · 설정 (+ 개발자 모드일 때만 개발자).
    // 2026-09-30 UI 확정 §2. 실행 상태·음성은 탭이 아니라 홈 위에 얹는
    // 화면이다 -- `context.go('/status')`는 그대로 쓰이고, 탭바는 남는다.
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigationShell) =>
          AppShell(navigationShell: navigationShell),
      branches: [
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/',
              builder: (_, __) => const HomeScreen(),
              routes: [
                GoRoute(
                  path: 'status',
                  builder: (_, __) => const StatusScreen(),
                ),
                GoRoute(
                  path: 'voice',
                  builder: (_, __) => const VoiceScreen(),
                ),
              ],
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/routines',
              builder: (_, __) => const RoutinesScreen(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/history',
              builder: (_, __) => const HistoryScreen(),
            ),
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
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/dev',
              builder: (_, __) => const DeveloperTabScreen(),
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
    // 가전 추가 5단계(사진 → 모서리 → 버튼 → 정지·쉬는 자리 → 확인 주행).
    GoRoute(
      path: '/appliance/add',
      builder: (_, __) => const AddApplianceWizardScreen(),
    ),
    // 사진 없이 버튼판으로 등록하는 예전 편집기. 가전 추가 1단계에서 들어온다.
    GoRoute(
      path: '/appliance/new',
      builder: (_, __) => const ApplianceEditorScreen(),
    ),
    GoRoute(
      path: '/appliance/detail/:id',
      builder: (_, state) =>
          ApplianceDetailScreen(applianceId: state.pathParameters['id']!),
    ),
    GoRoute(
      path: '/routine/record/:applianceId',
      builder: (_, state) => RoutineRecordScreen(
          applianceId: state.pathParameters['applianceId']!),
    ),
    GoRoute(
      path: '/routine/edit',
      builder: (_, state) =>
          RoutineEditorScreen(initial: state.extra as Routine?),
    ),
    GoRoute(
      path: '/manual-control',
      builder: (_, __) => const ManualControlScreen(),
    ),
    GoRoute(
      path: '/care',
      builder: (_, __) => const CareEventsScreen(),
    ),
    GoRoute(
      path: '/settings/hub',
      builder: (_, __) => const HubSettingsScreen(),
    ),
    GoRoute(
      path: '/settings/info',
      builder: (_, __) => const AppInfoScreen(),
    ),
    // 개발자 도구 — 개발자 탭에서만 들어온다. 서버에서 개발자 모드를
    // 켜지 않았으면 화면이 그 사실을 말하고 아무것도 조작하지 못한다.
    GoRoute(
      path: '/developer',
      builder: (_, __) => const DeveloperConsoleScreen(),
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
