// 비상정지 걸림 배너(2026-10-05) — 어느 탭에서든 탭바 위에 뜨고, 사람이
// 확인 대화를 거쳐야만 POST /stop/ack를 보낸다(자동 해제 금지). 실행 중 정지
// 줄은 배너와 함께 남는다.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simplelay/models/estop.dart';
import 'package:simplelay/models/execution_status.dart';
import 'package:simplelay/models/hub.dart';
import 'package:simplelay/providers/estop_provider.dart';
import 'package:simplelay/providers/execution_status_provider.dart';
import 'package:simplelay/providers/hub_provider.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/app_shell.dart';
import 'package:simplelay/services/rpi_api_service.dart';

class _FakeApi extends RpiApiService {
  _FakeApi()
      : super('http://hub.test',
            client: MockClient((_) async => http.Response('{}', 500)));

  HubStatus hub = const HubStatus();
  EstopAckResult ackResult = const EstopAckResult(EstopAckOutcome.cleared);
  int ackCalls = 0;
  int statusCalls = 0;

  @override
  Future<HubStatus> hubStatus() async {
    statusCalls++;
    return hub;
  }

  @override
  Future<EstopAckResult> ackEstop() async {
    ackCalls++;
    if (ackResult.cleared) hub = const HubStatus();
    return ackResult;
  }
}

const _latched = HubStatus(estopLatched: true, estopDetail: '콘센트 모듈 버튼이 눌렸어요');

GoRouter _router() => GoRouter(
      initialLocation: '/',
      routes: [
        StatefulShellRoute.indexedStack(
          builder: (_, __, shell) => AppShell(navigationShell: shell),
          branches: [
            for (final p in ['/', '/appliances', '/automation', '/history'])
              StatefulShellBranch(routes: [
                GoRoute(path: p, builder: (_, __) => Text('body$p')),
              ]),
          ],
        ),
      ],
    );

Future<ProviderContainer> _pump(
  WidgetTester tester,
  _FakeApi api, {
  ExecutionStatus? status,
  double textScale = 1.0,
}) async {
  final container = ProviderContainer(overrides: [
    developerModeProvider.overrideWithValue(false),
    rpiApiServiceProvider.overrideWithValue(api),
    // 주기 조회는 끈다 — 테스트가 refresh()로 직접 부른다.
    estopPollIntervalProvider.overrideWithValue(null),
  ]);
  addTearDown(container.dispose);
  container.read(estopProvider); // 첫 조회 시작
  if (status != null) {
    // Test-only seed of the real notifier.
    // ignore: invalid_use_of_protected_member
    container.read(executionStatusProvider.notifier).state = status;
  }
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(
      routerConfig: _router(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return container;
}

const _banner = Key('estop-banner');
const _ackButton = Key('estop-ack');

void main() {
  testWidgets('걸리지 않았으면 배너가 없다', (tester) async {
    await _pump(tester, _FakeApi());
    expect(find.byKey(_banner), findsNothing);
    expect(find.text(kEstopTitle), findsNothing);
  });

  testWidgets('걸리면 사유와 함께 배너가 뜨고 어느 탭에서든 남는다', (tester) async {
    final api = _FakeApi()..hub = _latched;
    await _pump(tester, api);
    expect(find.byKey(_banner), findsOneWidget);
    expect(find.text(kEstopTitle), findsOneWidget);
    expect(find.text('콘센트 모듈 버튼이 눌렸어요'), findsOneWidget);
    expect(find.byKey(_ackButton), findsOneWidget);

    for (final tab in ['가전', '자동 실행', '기록', '홈']) {
      await tester.tap(find.text(tab));
      await tester.pumpAndSettle();
      expect(find.byKey(_banner), findsOneWidget, reason: tab);
    }
  });

  testWidgets('서버가 풀렸다고 하면 배너가 내려간다', (tester) async {
    final api = _FakeApi()..hub = _latched;
    final container = await _pump(tester, api);
    expect(find.byKey(_banner), findsOneWidget);

    api.hub = const HubStatus();
    await container.read(estopProvider.notifier).refresh();
    await tester.pumpAndSettle();
    expect(find.byKey(_banner), findsNothing);
    // 조회만으로 해제 요청을 보내지 않는다.
    expect(api.ackCalls, 0);
  });

  testWidgets('자동 해제 금지 — 조회를 거듭해도, 대화에서 취소해도 보내지 않는다',
      (tester) async {
    final api = _FakeApi()..hub = _latched;
    final container = await _pump(tester, api);
    for (var i = 0; i < 3; i++) {
      await container.read(estopProvider.notifier).refresh();
    }
    await tester.pumpAndSettle();
    expect(api.ackCalls, 0);

    await tester.tap(find.byKey(_ackButton));
    await tester.pumpAndSettle();
    expect(find.text(kEstopConfirmQuestion), findsOneWidget);
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    expect(api.ackCalls, 0);
    expect(find.byKey(_banner), findsOneWidget);
  });

  testWidgets('확인하고 해제 → 성공이면 상태를 다시 읽고 배너를 내린다', (tester) async {
    final api = _FakeApi()..hub = _latched;
    await _pump(tester, api);
    final before = api.statusCalls;

    await tester.tap(find.byKey(_ackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('estop-confirm')));
    await tester.pumpAndSettle();

    expect(api.ackCalls, 1);
    expect(api.statusCalls, greaterThan(before));
    expect(find.byKey(_banner), findsNothing);
    expect(find.text(const EstopAckResult(EstopAckOutcome.cleared).message),
        findsOneWidget);
  });

  for (final outcome in [
    EstopAckOutcome.buttonPressed,
    EstopAckOutcome.notLatched,
    EstopAckOutcome.noAnswer,
    EstopAckOutcome.failed,
  ]) {
    testWidgets('해제 실패($outcome)면 배너를 남기고 이유를 보인다', (tester) async {
      final api = _FakeApi()
        ..hub = _latched
        ..ackResult = EstopAckResult(outcome);
      await _pump(tester, api);

      await tester.tap(find.byKey(_ackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('estop-confirm')));
      await tester.pumpAndSettle();

      expect(api.ackCalls, 1);
      expect(find.byKey(_banner), findsOneWidget);
      expect(find.text(EstopAckResult(outcome).message), findsOneWidget);
      // 다시 시도할 수 있다.
      expect(tester.widget<FilledButton>(find.byKey(_ackButton)).onPressed,
          isNotNull);
    });
  }

  testWidgets('걸린 채 실행 중이어도 정지 줄은 닿는다', (tester) async {
    final api = _FakeApi()..hub = _latched;
    final container = await _pump(
      tester,
      api,
      status: const ExecutionStatus(phase: ExecutionPhase.running, label: '즉석밥'),
    );
    expect(find.byKey(_banner), findsOneWidget);
    final stop = find.byKey(const Key('shell-stop'));
    expect(stop, findsOneWidget);
    // 배너에 가리지 않고 실제로 눌리는 자리에 있다.
    expect(stop.hitTestable(), findsOneWidget);
    expect(tester.getRect(stop).top,
        greaterThanOrEqualTo(tester.getRect(find.byKey(_banner)).bottom));
    expect(api.ackCalls, 0);
    expect(container.read(estopProvider).latched, isTrue);
  });

  testWidgets('큰 글씨(200%)에서도 배너와 정지 줄이 넘치지 않는다', (tester) async {
    final api = _FakeApi()
      ..hub = _latched
      ..ackResult = const EstopAckResult(EstopAckOutcome.buttonPressed);
    await _pump(
      tester,
      api,
      status: const ExecutionStatus(phase: ExecutionPhase.running, label: '즉석밥'),
      textScale: 2.0,
    );
    await tester.tap(find.byKey(_ackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('estop-confirm')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(_banner), findsOneWidget);
    expect(find.byKey(const Key('shell-stop')), findsOneWidget);
    expect(find.byKey(_ackButton).hitTestable(), findsOneWidget);
    expect(find.byKey(const Key('shell-stop')).hitTestable(), findsOneWidget);
  });
}
