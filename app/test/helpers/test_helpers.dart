import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:simplelay/models/execution_status.dart';
import 'package:simplelay/models/suggestion.dart';
import 'package:simplelay/providers/ble_provider.dart';
import 'package:simplelay/providers/execution_status_provider.dart';
import 'package:simplelay/providers/suggestion_provider.dart';
import 'package:simplelay/services/ble_service.dart';

// ── 샘플 데이터 ─────────────────────────────────────────────────────────────

const kTestSuggestion = Suggestion(
  sequenceId: 'test-001',
  label: '우유 데우기',
  steps: ['BT-08', 'BT-03', 'BT-05'],
);

// ── Provider overrides ───────────────────────────────────────────────────────

List<Override> connectedOverrides() => [
      bleConnectionProvider.overrideWith(
        (ref) => Stream.value(BleConnectionState.connected),
      ),
    ];

List<Override> disconnectedOverrides() => [
      bleConnectionProvider.overrideWith(
        (ref) => Stream.value(BleConnectionState.disconnected),
      ),
    ];

// ── Widget 빌더 ──────────────────────────────────────────────────────────────

/// 라우팅이 필요 없는 단순 화면 테스트용.
Widget buildScreen(
  Widget screen, {
  List<Override> overrides = const [],
  List<Suggestion>? suggestions,
  ExecutionStatus? executionStatus,
}) {
  return buildWithProviderState(
    suggestions: suggestions,
    executionStatus: executionStatus,
    overrides: overrides,
    child: MaterialApp(
      theme: ThemeData.dark(),
      home: screen,
    ),
  );
}

Widget buildWithProviderState({
  required Widget child,
  List<Override> overrides = const [],
  List<Suggestion>? suggestions,
  ExecutionStatus? executionStatus,
}) =>
    _SeededProviderScope(
      overrides: overrides,
      suggestions: suggestions,
      executionStatus: executionStatus,
      child: child,
    );

class _SeededProviderScope extends StatefulWidget {
  const _SeededProviderScope({
    required this.child,
    required this.overrides,
    this.suggestions,
    this.executionStatus,
  });

  final Widget child;
  final List<Override> overrides;
  final List<Suggestion>? suggestions;
  final ExecutionStatus? executionStatus;

  @override
  State<_SeededProviderScope> createState() => _SeededProviderScopeState();
}

class _SeededProviderScopeState extends State<_SeededProviderScope> {
  late final BleService _ble;
  late final ProviderContainer _container;

  @override
  void initState() {
    super.initState();
    _ble = BleService()..simulateConnected();
    _container = ProviderContainer(
      overrides: [
        bleServiceProvider.overrideWithValue(_ble),
        ...widget.overrides,
      ],
    );
    if (widget.suggestions case final suggestions?) {
      final notifier = _container.read(suggestionProvider.notifier);
      // Test-only seed of the real notifier; avoids overriding its concrete type.
      // ignore: invalid_use_of_protected_member
      notifier.state = suggestions;
    }
    if (widget.executionStatus case final status?) {
      final notifier = _container.read(executionStatusProvider.notifier);
      // Test-only seed of the real notifier; avoids overriding its concrete type.
      // ignore: invalid_use_of_protected_member
      notifier.state = status;
    }
  }

  @override
  void dispose() {
    _container.dispose();
    _ble.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => UncontrolledProviderScope(
        container: _container,
        child: widget.child,
      );
}

/// GoRouter 내비게이션이 필요한 화면 테스트용.
Widget buildWithRouter(
  String initialPath, {
  List<Override> overrides = const [],
  Map<String, WidgetBuilder> extraRoutes = const {},
}) {
  final routes = <RouteBase>[
    GoRoute(
      path: '/',
      builder: (_, __) => const Scaffold(body: Text('홈')),
    ),
    GoRoute(
      path: '/status',
      builder: (_, __) => const Scaffold(body: Text('상태 화면')),
    ),
    GoRoute(
      path: '/voice',
      builder: (_, __) => const Scaffold(body: Text('음성 화면')),
    ),
    GoRoute(
      path: '/settings',
      builder: (_, __) => const Scaffold(body: Text('설정 화면')),
    ),
    ...extraRoutes.entries.map(
      (e) => GoRoute(path: e.key, builder: (_, __) => e.value(_)),
    ),
  ];

  final router = GoRouter(
    initialLocation: initialPath,
    routes: routes,
  );

  return ProviderScope(
    overrides: overrides,
    child: MaterialApp.router(
      theme: ThemeData.dark(),
      routerConfig: router,
    ),
  );
}
