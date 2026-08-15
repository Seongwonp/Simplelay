import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:simplelay/models/suggestion.dart';
import 'package:simplelay/screens/suggestion_screen.dart';

import '../helpers/test_helpers.dart';

Widget _buildSuggestion(
  String sequenceId, {
  List<Suggestion> suggestions = const [],
}) {
  return ProviderScope(
    overrides: withSuggestions(suggestions),
    child: MaterialApp(
      theme: ThemeData.dark(),
      home: SuggestionScreen(sequenceId: sequenceId),
    ),
  );
}

const _sug = Suggestion(
  sequenceId: 'test-001',
  label: '우유 데우기',
  steps: ['BT-08', 'BT-03', 'BT-05'],
);

void main() {
  group('SuggestionScreen — 제안 없음', () {
    testWidgets('알 수 없는 sequenceId 시 오류 메시지', (tester) async {
      await tester.pumpWidget(_buildSuggestion('nonexistent', suggestions: []));
      await tester.pump();
      expect(find.text('제안을 찾을 수 없습니다.'), findsOneWidget);
    });
  });

  group('SuggestionScreen — 제안 있음', () {
    testWidgets('제안 라벨 표시', (tester) async {
      await tester.pumpWidget(
        _buildSuggestion('test-001', suggestions: const [_sug]),
      );
      await tester.pump();
      expect(find.text('우유 데우기'), findsOneWidget);
    });

    testWidgets('단계별 한국어 라벨 표시', (tester) async {
      await tester.pumpWidget(
        _buildSuggestion('test-001', suggestions: const [_sug]),
      );
      await tester.pump();
      expect(find.text('우유'), findsOneWidget);
      expect(find.text('1분 추가'), findsOneWidget);
      expect(find.text('시작'), findsOneWidget);
    });

    testWidgets('단계 번호 CircleAvatar 표시', (tester) async {
      await tester.pumpWidget(
        _buildSuggestion('test-001', suggestions: const [_sug]),
      );
      await tester.pump();
      expect(find.text('1'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
    });

    testWidgets('승인하고 실행 버튼 표시', (tester) async {
      await tester.pumpWidget(
        _buildSuggestion('test-001', suggestions: const [_sug]),
      );
      await tester.pump();
      expect(find.text('승인하고 실행'), findsOneWidget);
    });

    testWidgets('거부 버튼 탭 시 화면 pop', (tester) async {
      String? currentRoute;
      final router = GoRouter(
        initialLocation: '/suggestion/test-001',
        routes: [
          GoRoute(
            path: '/',
            builder: (_, __) => const Scaffold(body: Text('홈')),
          ),
          GoRoute(
            path: '/suggestion/:id',
            builder: (context, state) => SuggestionScreen(
              sequenceId: state.pathParameters['id']!,
            ),
          ),
        ],
        observers: [
          _RouteObserver((route) => currentRoute = route),
        ],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: withSuggestions(const [_sug]),
          child: MaterialApp.router(
            theme: ThemeData.dark(),
            routerConfig: router,
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('거부'));
      await tester.pumpAndSettle();

      // pop 후 홈으로 돌아감
      expect(find.text('홈'), findsOneWidget);
    });

    testWidgets('승인 버튼 탭 시 /status 로 이동', (tester) async {
      final router = GoRouter(
        initialLocation: '/suggestion/test-001',
        routes: [
          GoRoute(
            path: '/',
            builder: (_, __) => const Scaffold(body: Text('홈')),
          ),
          GoRoute(
            path: '/suggestion/:id',
            builder: (context, state) => SuggestionScreen(
              sequenceId: state.pathParameters['id']!,
            ),
          ),
          GoRoute(
            path: '/status',
            builder: (_, __) => const Scaffold(body: Text('상태 화면')),
          ),
        ],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: withSuggestions(const [_sug]),
          child: MaterialApp.router(
            theme: ThemeData.dark(),
            routerConfig: router,
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('승인하고 실행'));
      await tester.pumpAndSettle();

      expect(find.text('상태 화면'), findsOneWidget);

      // DemoService.runExecutionFlow()가 스케줄한 타이머(500~4000ms)를 소진
      await tester.pump(const Duration(seconds: 5));
    });
  });
}

class _RouteObserver extends NavigatorObserver {
  _RouteObserver(this.onRoute);
  final void Function(String?) onRoute;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    onRoute(route.settings.name);
  }
}
