import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:simplelay/models/appliance.dart';
import 'package:simplelay/models/execution_status.dart';
import 'package:simplelay/providers/appliance_provider.dart';
import 'package:simplelay/models/suggestion.dart';
import 'package:simplelay/providers/ble_provider.dart';
import 'package:simplelay/providers/clock_provider.dart';
import 'package:simplelay/providers/execution_status_provider.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/providers/suggestion_provider.dart';
import 'package:simplelay/services/ble_service.dart';

// ── 샘플 데이터 ─────────────────────────────────────────────────────────────

const kTestSuggestion = Suggestion(
  sequenceId: 'test-001',
  label: '즉석밥 데우기',
  steps: ['BT-08', 'BT-03', 'BT-05'],
);

/// 테스트가 쓰는 '설치된 가전 한 대'.
///
/// 예전에는 선택 가전이 항상 전자레인지로 채워져서, 아무 테스트나 그냥
/// 화면을 띄우면 가전이 있는 것처럼 굴었다. 이제 가전을 가진 상태는
/// **테스트가 직접 만들어야 한다** -- 제품에서도 그게 사용자가 한 일이다.
final kTestAppliance = kApplianceTemplates.first;

/// 대상이 다른 제안을 다루는 테스트용 두 번째 가전.
final kTestAircon =
    kApplianceTemplates.firstWhere((a) => a.id == 'aircon');

/// prefs에 넣을 모양. 시작 경로 테스트가 저장된 가전을 흉내낼 때 쓴다.
String applianceJsonString(ApplianceMap a) => jsonEncode(a.toJson());

// ── Provider overrides ───────────────────────────────────────────────────────

/// 이 폰에 가전이 설치돼 있는 상태.
///
/// 비우면(기본값) 아직 아무것도 추가하지 않은 사용자다 -- 그것도 정상 상태고,
/// 화면은 크래시하지 않고 '가전 추가'로 안내해야 한다.
List<Override> installedOverrides(
  List<ApplianceMap> appliances, {
  ApplianceMap? selected,
}) =>
    [
      customAppliancesProvider
          .overrideWith((ref) => CustomAppliancesNotifier.seeded(appliances)),
      selectedApplianceProvider.overrideWith(
        (ref) => SelectedApplianceNotifier.seeded(
          ref,
          selected ?? appliances.firstOrNull,
        ),
      ),
    ];

/// 서버 연결 상태를 고정한다. 실제 알림자는 주소를 불러오면 스스로 확인을
/// 시작해 상태를 바꾸므로, 확인 자체를 막는다.
class FixedRpiConnection extends RpiConnectionNotifier {
  FixedRpiConnection(super.ref, RpiConnectionState fixed) {
    state = fixed;
  }

  @override
  Future<void> check() async {}

  // 고정된 연결 상태 — 주기 /status 결과로 바꾸지 않는다(평가 M2의 반영은 connection_poll_test가 본다).
  @override
  void reportHubPoll({required bool reachable}) {}
}

Override rpiServerOverride(RpiConnectionState state) =>
    rpiConnectionProvider.overrideWith((ref) => FixedRpiConnection(ref, state));

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
