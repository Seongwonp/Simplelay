import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'screens/app_shell.dart';
import 'screens/home_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/status_screen.dart';
import 'screens/suggestion_screen.dart';
import 'screens/voice_screen.dart';

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
  ],
);

class SimpleLayApp extends StatelessWidget {
  const SimpleLayApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp.router(
        title: 'SimpleLay',
        debugShowCheckedModeBanner: false,
        routerConfig: _router,
        themeMode: ThemeMode.dark,
        darkTheme: ThemeData(
          brightness: Brightness.dark,
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF4FC3F7),
            brightness: Brightness.dark,
            primary: const Color(0xFF4FC3F7),
          ),
          scaffoldBackgroundColor: const Color(0xFF0D1117),
          cardTheme:
              const CardThemeData(color: Color(0xFF171D25), elevation: 0),
          navigationBarTheme: const NavigationBarThemeData(
            backgroundColor: Color(0xFF171D25),
          ),
          filledButtonTheme: FilledButtonThemeData(
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          useMaterial3: true,
        ),
      );
}
