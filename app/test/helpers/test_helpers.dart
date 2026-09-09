import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:simplelay/models/execution_status.dart';
import 'package:simplelay/models/suggestion.dart';
import 'package:simplelay/providers/ble_provider.dart';
import 'package:simplelay/providers/clock_provider.dart';
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
  void Function(ProviderContainer)? onContainerReady,
}) {
  return buildWithProviderState(
    suggestions: suggestions,
    executionStatus: executionStatus,
    overrides: overrides,
    onContainerReady: onContainerReady,
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
  void Function(ProviderContainer)? onContainerReady,
}) =>
    _SeededProviderScope(
      overrides: overrides,
      suggestions: suggestions,
      executionStatus: executionStatus,
      onContainerReady: onContainerReady,
      child: child,
    );

class _SeededProviderScope extends StatefulWidget {
  const _SeededProviderScope({
    required this.child,
    required this.overrides,
    this.suggestions,
    this.executionStatus,
    this.onContainerReady,
  });

  final Widget child;
  final List<Override> overrides;
  final List<Suggestion>? suggestions;
  final ExecutionStatus? executionStatus;
  final void Function(ProviderContainer)? onContainerReady;

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
        // 시각을 고정한다. 인사 문구가 시간대로 갈리므로 고정하지 않으면
        // 골든이 실행 시각을 타서, 진짜 회귀와 시간 차이를 구분할 수 없다.
        // 09시는 예시 제안의 '아침' 시간대와 같은 이야기를 하게 맞춘 값이다.
        nowProvider.overrideWithValue(() => DateTime(2026, 9, 9, 9)),
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
    widget.onContainerReady?.call(_container);
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
