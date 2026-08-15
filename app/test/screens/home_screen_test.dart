import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:simplelay/models/suggestion.dart';
import 'package:simplelay/providers/suggestion_provider.dart';
import 'package:simplelay/screens/home_screen.dart';

import '../helpers/test_helpers.dart';

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
      await tester.pumpWidget(_buildHome());
      await tester.pump();
      expect(find.text('기기 연결 필요'), findsOneWidget);
      expect(find.text('설정에서 SimpleLay 기기를 연결하세요.'), findsOneWidget);
    });

    testWidgets('"연결" TextButton 표시', (tester) async {
      await tester.pumpWidget(_buildHome());
      await tester.pump();
      expect(find.text('연결'), findsOneWidget);
    });

    testWidgets('말하기 FAB 비활성화', (tester) async {
      await tester.pumpWidget(_buildHome());
      await tester.pump();
      final fab = tester.widget<FloatingActionButton>(
        find.byType(FloatingActionButton),
      );
      // onPressed가 null이면 disabled
      expect(fab.onPressed, isNull);
    });

    testWidgets('제안 없음 메시지 표시', (tester) async {
      await tester.pumpWidget(_buildHome());
      await tester.pump();
      expect(find.text('새로운 제안이 없습니다.'), findsOneWidget);
    });
  });

  group('HomeScreen — 연결 완료 상태', () {
    testWidgets('기기 연결됨 텍스트 표시', (tester) async {
      await tester.pumpWidget(_buildHome(connected: true));
      await tester.pump();
      expect(find.text('기기 연결됨'), findsOneWidget);
      expect(find.text('명령을 보낼 준비가 되었습니다.'), findsOneWidget);
    });

    testWidgets('"연결" 버튼 사라짐', (tester) async {
      await tester.pumpWidget(_buildHome(connected: true));
      await tester.pump();
      // 연결됨 상태에서는 trailing TextButton 없음
      expect(find.text('연결'), findsNothing);
    });

    testWidgets('말하기 FAB 활성화', (tester) async {
      await tester.pumpWidget(_buildHome(connected: true));
      await tester.pump();
      final fab = tester.widget<FloatingActionButton>(
        find.byType(FloatingActionButton),
      );
      expect(fab.onPressed, isNotNull);
    });
  });

  group('HomeScreen — 제안 목록', () {
    const suggestion = Suggestion(
      sequenceId: 's1',
      label: '우유 데우기',
      steps: ['BT-08', 'BT-03', 'BT-05'],
    );

    testWidgets('제안 카드 1개 표시', (tester) async {
      await tester.pumpWidget(
        _buildHome(connected: true, suggestions: const [suggestion]),
      );
      await tester.pump();
      expect(find.text('우유 데우기'), findsOneWidget);
      expect(find.text('3단계 동작'), findsOneWidget);
      expect(find.text('새로운 제안이 없습니다.'), findsNothing);
    });

    testWidgets('여러 제안 카드 모두 표시', (tester) async {
      const suggestions = [
        Suggestion(sequenceId: 'a', label: '30초 가열', steps: ['BT-02', 'BT-05']),
        Suggestion(sequenceId: 'b', label: '해동', steps: ['BT-07', 'BT-05']),
      ];
      await tester.pumpWidget(
        _buildHome(connected: true, suggestions: suggestions),
      );
      await tester.pump();
      expect(find.text('30초 가열'), findsOneWidget);
      expect(find.text('해동'), findsOneWidget);
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

      await tester.tap(find.text('우유 데우기'));
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
