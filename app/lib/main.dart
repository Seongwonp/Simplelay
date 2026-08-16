import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'screens/appliance_editor_screen.dart';
import 'screens/app_shell.dart';
import 'screens/home_screen.dart';
import 'screens/manual_control_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/status_screen.dart';
import 'screens/suggestion_screen.dart';
import 'screens/voice_screen.dart';
import 'providers/theme_provider.dart';
import 'theme/app_theme.dart';

void main() => runApp(const ProviderScope(child: SimpleLayApp()));

final _router = GoRouter(
  initialLocation: '/',
  routes: [
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
  ],
);

class SimpleLayApp extends ConsumerWidget {
  const SimpleLayApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
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
