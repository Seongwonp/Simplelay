// 홈 — "우리 집"(UI 확정 §2, 2026-09-30 개편).
//
// 예전 홈은 가전 한 대를 크게 세우고 '버튼으로 하기'을 걸었다. 이제는 허브 칩 →
// 제안 카드 한 장 → 가전 카드 2열 → 가전 추가다. 연결 문제의 **정도와 자리**
// 규칙(닿지 않으면 맨 위 경고, 예비 연결만 꺼지면 아래 조용한 안내, 확인 중은
// 끊김이 아님)은 그대로 지킨다 -- 아래 테스트가 예전 규칙을 새 배치에서 다시 본다.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:simplelay/models/appliance.dart';
import 'package:simplelay/models/execution_status.dart';
import 'package:simplelay/models/suggestion.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/home_screen.dart';
import 'package:simplelay/theme/app_colors.dart';

import '../helpers/test_helpers.dart';

/// 홈은 제안·가전·연결 상세까지 세로로 길다. 기본 테스트 뷰포트(800x600)로는
/// 아래쪽 위젯의 Element가 만들어지지 않아 find가 "없음"으로 잘못 판정한다.
void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(400, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget _buildHome({
  List<Suggestion> suggestions = const [],
  bool connected = false,
  // 기본은 **닿지 않는다고 확인된** 서버다. 확인 중은 아래 그룹이 따로 본다.
  RpiConnectionState server = RpiConnectionState.unreachable,
  List<ApplianceMap>? installed,
  ExecutionStatus? executionStatus,
}) {
  final overrides = [
    ...(connected ? connectedOverrides() : disconnectedOverrides()),
    ...installedOverrides(installed ?? [kTestAppliance]),
    rpiServerOverride(server),
  ];
  return buildScreen(
    const HomeScreen(),
    overrides: overrides,
    suggestions: suggestions,
    executionStatus: executionStatus,
  );
}

/// 가전 카드 제목(이름). 카드는 이름과 방을 따로 적는다.
Finder _cardName() => find.text(kTestAppliance.name);

void main() {
  group('HomeScreen — 머리와 구성', () {
    testWidgets('"우리 집"과 허브 칩, 가전 카드, 가전 추가가 있다', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(
          _buildHome(connected: true, server: RpiConnectionState.connected));
      await tester.pump();

      expect(find.text('우리 집'), findsOneWidget);
      expect(findPlainText('본체와 연결됐어요'), findsOneWidget);
      // 연결됨 점은 초록 — 주행동 갈색과 섞이면 정상인지 경고인지 안 읽혔다(UI 평가 10/17).
      final dot = tester.widget<Container>(find.byKey(const Key('hub-status-dot')));
      // 상태 색 표(출시 검토 10/18): 연결됨은 초록 — 라이트 성공 중립색은 검은 점이었다.
      expect((dot.decoration as BoxDecoration).color, anyOf(AppColors.confirmed, AppColors.confirmedLight));
      expect(find.byKey(Key('appliance-card-${kTestAppliance.id}')),
          findsOneWidget);
      expect(find.byKey(const Key('appliance-add-card')), findsOneWidget);
      // 고정 명령 버튼("즉석밥")도, 예전 '버튼으로 하기' 경로도 홈에 없다 --
      // 누르는 일은 가전 상세에서 확인을 거친다.
      expect(find.text('버튼으로 하기'), findsNothing);
      expect(find.text('즉석밥'), findsNothing);
    });

    testWidgets('가전 카드를 눌러도 실행하지 않고 상세로 간다', (tester) async {
      String? opened;
      final router = GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(path: '/', builder: (_, __) => const HomeScreen()),
          GoRoute(
            path: '/appliance/detail/:id',
            builder: (_, state) {
              opened = state.pathParameters['id'];
              return const Scaffold(body: Text('가전 상세'));
            },
          ),
        ],
      );
      _useTallViewport(tester);
      await tester.pumpWidget(buildWithProviderState(
        overrides: [
          ...connectedOverrides(),
          ...installedOverrides([kTestAppliance]),
          rpiServerOverride(RpiConnectionState.connected),
        ],
        child: MaterialApp.router(routerConfig: router),
      ));
      await tester.pump();

      await tester.tap(find.byKey(Key('appliance-card-${kTestAppliance.id}')));
      await tester.pumpAndSettle();
      expect(opened, kTestAppliance.id);
    });

    // 사용자 결정(10/19): 타일 화면 글자는 없앴다 — 색만으로 말하지 않는 것은 화면 읽기 이름과 진행 막대가 맡는다.
    testWidgets('실행 대상 가전 카드는 "버튼 조작 중"을 화면 읽기로 말한다', (tester) async {
      final handle = tester.ensureSemantics();
      _useTallViewport(tester);
      await tester.pumpWidget(_buildHome(
        connected: true,
        server: RpiConnectionState.connected,
        executionStatus: ExecutionStatus(
          phase: ExecutionPhase.running,
          applianceId: kTestAppliance.id,
          executionMode: 'real',
          steps: const ['BT-08', 'BT-05'],
          completedSteps: 1,
        ),
      ));
      await tester.pump();
      // 색만으로 말하지 않는다(UI 확정 §1-4). 가전이 '돌아가는 중'이라고는
      // 하지 않는다 — 아는 것은 우리 누름 장치의 버튼 조작 진행뿐이다(2026-10-13).
      // 타일 상태 줄은 낱말 중간 줄바꿈을 막는 결합 문자를 넣어 그린다(2026-10-14).
      expect(find.bySemanticsLabel(RegExp('버튼 누르는 중 1/2')), findsOneWidget);
      expect(find.byKey(Key('appliance-progress-${kTestAppliance.id}')), findsOneWidget);
      expect(find.textContaining('동작 중'), findsNothing);
      handle.dispose();
    });

    testWidgets('실행 모드를 모르면 실물·모의를 추정하지 않는다', (tester) async {
      final handle = tester.ensureSemantics();
      _useTallViewport(tester);
      await tester.pumpWidget(_buildHome(
        connected: true,
        server: RpiConnectionState.connected,
        executionStatus: ExecutionStatus(
          phase: ExecutionPhase.running,
          applianceId: kTestAppliance.id,
        ),
      ));
      await tester.pump();
      // 타일 상태 줄은 낱말 중간 줄바꿈을 막는 결합 문자를 넣어 그린다(2026-10-14).
      expect(find.bySemanticsLabel(RegExp('하는 중이에요')), findsOneWidget);
      handle.dispose();
    });
  });

  group('HomeScreen — 연결 문제의 정도와 자리', () {
    testWidgets('예비 연결로만 닿으면 칩과 연결 경고가 서로 어긋나지 않는다',
        (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildHome(connected: true));
      await tester.pump();

      expect(findPlainText('블루투스로만 연결돼요'), findsOneWidget);
      expect(find.text('본체와 연결됐어요'), findsNothing);
      expect(findPlainText('알림과 기록이 멈췄어요'), findsOneWidget);
      expect(findPlainText('연결 설정이 필요해요'), findsNothing);
    });

    testWidgets('기기에 닿지 않으면 연결 경고가 가전보다 먼저 나온다', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildHome());
      await tester.pump();

      expect(findPlainText('본체와 연결이 끊겼어요'), findsOneWidget);
      final warning = tester.getTopLeft(findPlainText('연결 설정이 필요해요')).dy;
      final name = tester.getTopLeft(_cardName()).dy;
      expect(warning, lessThan(name));
    });

    testWidgets('허브가 닿으면 예비 연결만 꺼져도 연결 줄을 두지 않는다(2026-10-14 UX)', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildHome(server: RpiConnectionState.connected));
      await tester.pump();

      expect(findPlainText('본체와 연결됐어요'), findsOneWidget);
      expect(findPlainText('연결 설정이 필요해요'), findsNothing);
      expect(findPlainText('알림과 기록이 멈췄어요'), findsNothing);
      // 조작은 되고 사용자가 할 판단이 없다 — 허브 문제일 때만 연결 줄을 둔다.
      expect(find.text('예비 연결 꺼짐'), findsNothing);
      expect(find.text('확인하기'), findsNothing);
    });

    testWidgets('서버와 예비 연결이 모두 되면 연결 줄 자체가 없다', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(
          _buildHome(connected: true, server: RpiConnectionState.connected));
      await tester.pump();

      expect(findPlainText('본체와 연결됐어요'), findsOneWidget);
      expect(find.text('확인하기'), findsNothing);
    });
  });

  group('HomeScreen — 서버 확인 중은 끊김이 아니다', () {
    for (final state in [
      RpiConnectionState.checking,
      RpiConnectionState.unconfigured, // 앱 시작 직후, 주소를 불러오기 전
    ]) {
      testWidgets('${state.name}: 맨 위 경고 없이 확인 중이라고만 말한다',
          (tester) async {
        // 켤 때마다 빨간 '연결 설정이 필요해요'가 맨 위에 잠깐 떴다(로그 ac #5).
        _useTallViewport(tester);
        await tester.pumpWidget(_buildHome(server: state));
        await tester.pump();

        expect(findPlainText('연결 설정이 필요해요'), findsNothing);
        expect(findPlainText('알림과 기록이 멈췄어요'), findsNothing);
        expect(findPlainText('본체를 찾고 있어요'), findsOneWidget);
        expect(find.text('본체와 연결이 끊겼어요'), findsNothing);
        // 확인 중에는 예비 연결이 꺼져도 연결 줄을 두지 않는다 — 허브 문제가 확인될 때만(2026-10-14 UX).
        expect(find.text('예비 연결 꺼짐'), findsNothing);
      });
    }

    testWidgets('확인 중이어도 예비 연결이 닿으면 끊겼다고 하지 않는다', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(
          _buildHome(connected: true, server: RpiConnectionState.checking));
      await tester.pump();

      expect(findPlainText('본체를 찾고 있어요'), findsOneWidget);
      expect(findPlainText('알림과 기록이 멈췄어요'), findsNothing);
    });
  });

  group('HomeScreen — 연결 해제 상태', () {
    testWidgets('연결 문제는 한 줄로 알리고 눌러야 상세가 나온다', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildHome());
      await tester.pump();

      expect(findPlainText('연결 설정이 필요해요'), findsOneWidget);
      expect(find.text('블루투스 연결이 꺼져 있어요'), findsNothing);

      await tester.tap(find.text('확인하기'));
      await tester.pump();

      expect(find.text('블루투스 연결이 꺼져 있어요'), findsOneWidget);
      expect(find.text('켜 두면 Wi-Fi가 끊겨도 가전을 쓸 수 있어요.'), findsOneWidget);
    });

    testWidgets('상세를 펼치면 복구 동선이 나온다', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildHome());
      await tester.pump();
      await tester.tap(find.text('확인하기'));
      await tester.pump();
      expect(find.text('연결'), findsOneWidget);
      expect(find.text('주소 입력'), findsOneWidget);
    });

    testWidgets('제안이 없다는 빈 문장을 두지 않는다(2026-10-13)', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildHome());
      await tester.pump();
      expect(find.text('지금 확인할 제안이 없어요.'), findsNothing);
    });
  });

  group('HomeScreen — 연결 완료 상태', () {
    testWidgets('예비 연결 안내 카드가 사라짐', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildHome(connected: true));
      await tester.pump();
      expect(find.text('블루투스 연결이 꺼져 있어요'), findsNothing);
    });

    testWidgets('"연결" 버튼 사라짐', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildHome(connected: true));
      await tester.pump();
      expect(find.text('연결'), findsNothing);
    });

    testWidgets('말로 하는 길이 홈에 함께 있다', (tester) async {
      // 누르기 어려운 사용자에게 길이 하나뿐이면 안 된다. 예전에는 탭바 가운데
      // 있었고, 이제는 홈 머리에 있다.
      _useTallViewport(tester);
      await tester.pumpWidget(_buildHome(connected: true));
      await tester.pump();
      expect(find.byTooltip('말로 하기'), findsNothing);
      // 아이콘만 두지 않고 글자도(휴리스틱 평가 10/18).
      expect(findPlainText('말로 하기'), findsOneWidget);
    });
  });

  group('HomeScreen — 제안 카드', () {
    const suggestion = Suggestion(
      sequenceId: 's1',
      label: '즉석밥 데우기',
      steps: ['BT-08', 'BT-03', 'BT-05'],
    );

    testWidgets('제안은 한 장만, 실행하기/나중에 두 버튼', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(
        _buildHome(connected: true, suggestions: const [suggestion]),
      );
      await tester.pump();
      expect(find.text('즉석밥 데우기'), findsOneWidget);
      expect(find.text('지금 하기'), findsOneWidget);
      expect(find.text('이번엔 안 할게요'), findsOneWidget);
      expect(find.text('지금 확인할 제안이 없어요.'), findsNothing);
    });

    testWidgets('여러 제안이 있어도 한 번에 한 장만 보인다', (tester) async {
      const suggestions = [
        Suggestion(sequenceId: 'a', label: '30초 가열', steps: ['BT-02', 'BT-05']),
        Suggestion(sequenceId: 'b', label: '해동', steps: ['BT-07', 'BT-05']),
      ];
      _useTallViewport(tester);
      await tester.pumpWidget(
        _buildHome(connected: true, suggestions: suggestions),
      );
      await tester.pump();
      expect(find.text('30초 가열'), findsOneWidget);
      expect(find.text('해동'), findsNothing);
      expect(find.text('지금 하기'), findsOneWidget);
    });

    testWidgets('루틴 카드는 루틴 이름을 제목으로 쓴다', (tester) async {
      const routineCard = Suggestion(
        sequenceId: 'r1',
        label: '데우기',
        steps: ['BT-08'],
        routineId: 'rt-1',
        routineName: '아침 데우기',
        reason: "루틴 '아침 데우기' · 평일 07:30 시각이에요",
      );
      _useTallViewport(tester);
      await tester.pumpWidget(
        _buildHome(connected: true, suggestions: const [routineCard]),
      );
      await tester.pump();
      expect(find.text('아침 데우기'), findsOneWidget);
      expect(find.text("루틴 '아침 데우기' · 평일 07:30 시각이에요"), findsOneWidget);
    });

    testWidgets('실행하기는 곧바로 누르지 않고 확인 화면(/suggestion/:id)을 연다',
        (tester) async {
      String? pushedRoute;

      final router = GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(
            path: '/',
            builder: (_, __) => const HomeScreen(),
          ),
          GoRoute(
            path: '/suggestion/:id',
            builder: (context, state) {
              pushedRoute = state.pathParameters['id'];
              return const Scaffold(body: Text('제안 화면'));
            },
          ),
        ],
      );

      _useTallViewport(tester);
      await tester.pumpWidget(
        ProviderScopeWrapper(
          overrides: connectedOverrides(),
          suggestions: const [suggestion],
          child: MaterialApp.router(
            theme: ThemeData.dark(),
            routerConfig: router,
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('지금 하기'));
      await tester.pumpAndSettle();

      expect(pushedRoute, 's1');
    });
  });
}

// GoRouter 테스트를 위한 ProviderScope 래퍼
class ProviderScopeWrapper extends StatelessWidget {
  const ProviderScopeWrapper({
    required this.overrides,
    required this.suggestions,
    required this.child,
    super.key,
  });
  final List<Override> overrides;
  final List<Suggestion> suggestions;
  final Widget child;

  @override
  Widget build(BuildContext context) => buildWithProviderState(
        overrides: overrides,
        suggestions: suggestions,
        child: child,
      );
}
