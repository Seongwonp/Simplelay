import 'models/appliance.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'models/routine.dart';
import 'providers/execution_status_provider.dart';
import 'screens/add_appliance_wizard_screen.dart';
import 'screens/app_info_screen.dart';
import 'screens/appliance_detail_screen.dart';
import 'screens/appliance_editor_screen.dart';
import 'screens/app_shell.dart';
import 'screens/standalone_task_frame.dart';
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
import 'screens/pairing_screen.dart';
import 'screens/suggestion_screen.dart';
import 'screens/voice_screen.dart';
import 'providers/theme_provider.dart';
import 'providers/voice_stop_provider.dart';
import 'theme/app_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: SimpleLayApp()));
}

final _router = buildAppRouter();

/// 앱 언어 — 한국어만. 기본(영어) 문구로 두면 화면 낭독(TalkBack)이 뒤로 가기·지우기·닫기 같은 기본 버튼을
/// 'Back'·'Delete'·'Dismiss'로 읽었다(접근성 검토 10/19). 기기 언어가 달라도 화면 글이 한국어라 맞춘다.
const kAppLocale = Locale('ko');
const kAppSupportedLocales = [kAppLocale];
const kAppLocalizationsDelegates = GlobalMaterialLocalizations.delegates;

/// 앱의 경로표. 테스트가 **실제 경로 구성**으로 뒤로 가기 같은 내비게이션
/// 동작을 확인할 수 있게 함수로 뺐다(시작 위치만 바꿀 수 있다).
GoRouter buildAppRouter({String initialLocation = '/splash'}) => GoRouter(
  // 온보딩 여부와 가전 목록을 **여기서 미리 읽지 않는다.** 결정은
  // 시작 화면 하나가 내린다(`startupRouteProvider`) -- 두 군데서 정하면
  // 홈이 먼저 그려졌다가 뒤늦게 바뀌는 깜빡임이 생긴다.
  initialLocation: initialLocation,
  redirect: (_, state) {
    final uri = state.uri;
    if (uri.scheme == 'simplelay' && uri.host == 'pair') {
      return Uri(path: '/pair', queryParameters: uri.queryParameters).toString();
    }
    return null;
  },
  routes: [
    GoRoute(path: '/pair', builder: (_, state) => PairingScreen(
      host: state.uri.queryParameters['host'], code: state.uri.queryParameters['code'])),
    GoRoute(
      path: '/splash',
      builder: (_, __) => const SplashScreen(),
    ),
    // 10/23 과업 중심 구조. 설정과 저장 동작 관리는 탭 밖에서 push로 연다.
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
              path: '/appliances',
              builder: (_, __) => const AppliancesScreen(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/automation',
              builder: (_, __) => const RoutinesScreen(automatic: true),
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
      ],
    ),
    GoRoute(path: '/settings', builder: (_, __) => const StandaloneTaskFrame(child: SettingsScreen())),
    GoRoute(path: '/routines', builder: (_, __) => const StandaloneTaskFrame(child: RoutinesScreen())),
    // 개발자 도구 — 탭이 아니라 설정 맨 아래 항목(개발 모드일 때만 보인다, 2026-10-18).
    GoRoute(path: '/dev', builder: (_, __) => const DeveloperTabScreen()),
    GoRoute(path: '/status', builder: (_, __) => const StatusScreen()),
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
      builder: (_, state) => ApplianceEditorScreen(draft: state.extra as ApplianceDraft?),
    ),
    GoRoute(
      path: '/appliance/setup',
      builder: (_, state) => AddApplianceWizardScreen(initial: state.extra as ApplianceMap, verifyOnly: state.uri.queryParameters['verify'] == '1'),
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
    // 실행 중 음성 '멈춰' 듣기(2026-10-07)도 시작부터 살려 둔다 — 실행 상태
    // 화면은 탭 shell 밖이라, shell에만 매달면 가장 필요한 순간에 사라진다.
    ref.listen(voiceStopProvider, (_, __) {});
    return MaterialApp.router(
      title: 'SimpleLay',
      debugShowCheckedModeBanner: false,
      routerConfig: _router,
      locale: kAppLocale,
      supportedLocales: kAppSupportedLocales,
      localizationsDelegates: kAppLocalizationsDelegates,
      themeMode: themeMode,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
    );
  }
}
