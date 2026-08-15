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

// ── 가짜 Notifier ────────────────────────────────────────────────────────────

// _onMessage는 private이므로 override 불가 — 대신 StateNotifier<T>를 직접 서브클래싱해
// BLE 구독 없이 초기 상태만 갖는 단순 fake를 제공한다.

class FakeSuggestionNotifier extends StateNotifier<List<Suggestion>> {
  FakeSuggestionNotifier(List<Suggestion> initial) : super(initial);

  Future<void> respond(Suggestion suggestion, bool approved) async {
    state = state
        .where((item) => item.sequenceId != suggestion.sequenceId)
        .toList();
  }
}

class FakeExecutionStatusNotifier extends StateNotifier<ExecutionStatus> {
  FakeExecutionStatusNotifier(ExecutionStatus initial) : super(initial);

  void begin(Suggestion suggestion) {
    state = ExecutionStatus(
      sequenceId: suggestion.sequenceId,
      label: suggestion.label,
      steps: suggestion.steps,
      phase: ExecutionPhase.waiting,
    );
  }

  Future<void> emergencyStop() async {
    state = state.copyWith(
      phase: ExecutionPhase.failed,
      message: '긴급 정지를 전송했습니다.',
    );
  }
}

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

List<Override> withSuggestions(List<Suggestion> suggestions) => [
      ...connectedOverrides(),
      suggestionProvider.overrideWith(
        (_) => FakeSuggestionNotifier(suggestions),
      ),
    ];

List<Override> withExecutionStatus(ExecutionStatus status) => [
      executionStatusProvider.overrideWith(
        (_) => FakeExecutionStatusNotifier(status),
      ),
    ];

// ── Widget 빌더 ──────────────────────────────────────────────────────────────

/// 라우팅이 필요 없는 단순 화면 테스트용.
Widget buildScreen(
  Widget screen, {
  List<Override> overrides = const [],
}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      theme: ThemeData.dark(),
      home: screen,
    ),
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
