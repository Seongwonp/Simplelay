import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:simplelay/models/suggestion.dart';
import 'package:simplelay/screens/home_screen.dart';

import '../helpers/test_helpers.dart';

/// 홈은 가전 그림·제안·연결 상세까지 세로로 길다. 기본 테스트 뷰포트
/// (800x600)로는 아래쪽 위젯의 Element가 만들어지지 않아 find가 "없음"으로
/// 잘못 판정한다 -- status/settings 테스트와 같은 문제다.
void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(400, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget _buildHome({
  List<Suggestion> suggestions = const [],
  bool connected = false,
}) {
  // disconnected + suggestions은 두 override를 개별로 합산
  final overrides = [
    ...(connected ? connectedOverrides() : disconnectedOverrides()),
  ];
  return buildScreen(
    const HomeScreen(),
    overrides: overrides,
    suggestions: suggestions,
  );
}

void main() {
  group('HomeScreen — 연결 해제 상태', () {
    testWidgets('연결 필요 안내 텍스트 표시', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildHome());
      await tester.pump();
      expect(find.text('예비 연결이 꺼져 있어요'), findsOneWidget);
      expect(find.text('연결해 두면 서버가 안 될 때도 조작할 수 있어요.'), findsOneWidget);
    });

    testWidgets('"연결" TextButton 표시', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildHome());
      await tester.pump();
      expect(find.text('연결'), findsOneWidget);
    });

    testWidgets('연결이 없으면 홈이 그 사실을 먼저 말한다', (tester) async {
      // 주 행동(말로 조작)은 탭바 가운데로 옮겼다. 예전에는 홈의 버튼을
      // 비활성화해서 알렸는데, 이제는 **가전 상태 한 줄**이 그 일을
      // 한다 -- 눌러 본 뒤에 알게 하지 않는 것이 요점이었고 그건 그대로다.
      _useTallViewport(tester);
      await tester.pumpWidget(_buildHome());
      await tester.pump();
      expect(find.text('기기와 연결되면 조작할 수 있어요'), findsOneWidget);
    });

    testWidgets('제안 없음 메시지 표시', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildHome());
      await tester.pump();
      expect(find.text('지금 확인할 제안이 없어요.'), findsOneWidget);
    });
  });

  group('HomeScreen — 연결 완료 상태', () {
    testWidgets('예비 연결 안내 카드가 사라짐', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildHome(connected: true));
      await tester.pump();
      expect(find.text('예비 연결이 꺼져 있어요'), findsNothing);
    });

    testWidgets('"연결" 버튼 사라짐', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildHome(connected: true));
      await tester.pump();
      // 연결됨 상태에서는 trailing TextButton 없음
      expect(find.text('연결'), findsNothing);
    });

    testWidgets('버튼 조작 경로가 홈에 항상 보인다', (tester) async {
      // 말이 잘 안 되거나 인식이 안 되는 사용자가 같은 시도를 반복하지
      // 않으려면, 다른 길이 화면에 함께 있어야 한다. 말하는 경로는
      // 탭바 가운데에 있고(app_shell_test), 버튼 경로는 여기 있다.
      _useTallViewport(tester);
      await tester.pumpWidget(_buildHome(connected: true));
      await tester.pump();
      expect(find.text('버튼으로 조작'), findsOneWidget);
    });

    testWidgets('연결되면 조작할 수 있다고 말한다', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildHome(connected: true));
      await tester.pump();
      expect(find.text('조작 가능'), findsOneWidget);
    });
  });

  group('HomeScreen — 제안 목록', () {
    const suggestion = Suggestion(
      sequenceId: 's1',
      label: '즉석밥 데우기',
      steps: ['BT-08', 'BT-03', 'BT-05'],
    );

    testWidgets('제안 카드 1개 표시', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(
        _buildHome(connected: true, suggestions: const [suggestion]),
      );
      await tester.pump();
      expect(find.text('즉석밥 데우기, 지금 할까요?'), findsOneWidget);
      // "3단계 동작"은 몇 번 움직이는지만 알려줬다 -- 맡길지 판단하려면
      // 무엇을 누르는지가 필요하다
      expect(find.text('즉석밥 → 1분 추가 → 시작'), findsOneWidget);
      expect(find.text('지금 확인할 제안이 없어요.'), findsNothing);
    });

    testWidgets('여러 제안 카드 모두 표시', (tester) async {
      const suggestions = [
        Suggestion(sequenceId: 'a', label: '30초 가열', steps: ['BT-02', 'BT-05']),
        Suggestion(sequenceId: 'b', label: '해동', steps: ['BT-07', 'BT-05']),
      ];
      _useTallViewport(tester);
      await tester.pumpWidget(
        _buildHome(connected: true, suggestions: suggestions),
      );
      await tester.pump();
      expect(find.text('30초 가열, 지금 할까요?'), findsOneWidget);
      expect(find.text('해동, 지금 할까요?'), findsOneWidget);
    });

    testWidgets('제안 탭 시 /suggestion/:id 로 이동', (tester) async {
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

      await tester.tap(find.text('즉석밥 데우기, 지금 할까요?'));
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
