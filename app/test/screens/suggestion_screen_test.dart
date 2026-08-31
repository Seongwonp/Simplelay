import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:simplelay/models/suggestion.dart';
import 'package:simplelay/screens/suggestion_screen.dart';

import '../helpers/test_helpers.dart';

Widget _buildSuggestion(
  String sequenceId, {
  List<Suggestion> suggestions = const [],
}) {
  return buildWithProviderState(
    suggestions: suggestions,
    overrides: connectedOverrides(),
    child: MaterialApp(
      theme: ThemeData.dark(),
      home: SuggestionScreen(sequenceId: sequenceId),
    ),
  );
}

const _sug = Suggestion(
  sequenceId: 'test-001',
  label: '즉석밥 데우기',
  steps: ['BT-08', 'BT-03', 'BT-05'],
);

// 이 화면도 ListView라, 버튼맵 그리드까지 합치면 기본 테스트 뷰포트(800x600)보다
// 콘텐츠가 길어져서 하단의 승인/거부 버튼이 스크롤 밑에 있는 채로 Element 자체가
// 안 만들어진다 — status_screen_test.dart와 동일한 문제, 동일한 해결책.
void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(400, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  group('SuggestionScreen — 제안 없음', () {
    testWidgets('알 수 없는 sequenceId 시 오류 메시지', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildSuggestion('nonexistent', suggestions: []));
      await tester.pump();
      expect(find.text('제안을 찾을 수 없습니다.'), findsOneWidget);
    });
  });

  group('SuggestionScreen — 제안 있음', () {
    testWidgets('제안 라벨 표시', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(
        _buildSuggestion('test-001', suggestions: const [_sug]),
      );
      await tester.pump();
      expect(find.text('즉석밥 데우기, 지금 할까요?'), findsOneWidget);
    });

    testWidgets('단계별 한국어 라벨 표시', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(
        _buildSuggestion('test-001', suggestions: const [_sug]),
      );
      await tester.pump();
      // 버튼맵 그리드와 단계 타임라인 둘 다 같은 라벨을 보여주므로(그리드 하이라이트
      // + 타임라인), 정확히 1개가 아니라 "적어도 하나는 보인다"만 확인한다.
      expect(find.text('즉석밥'), findsAtLeastNWidgets(1));
      expect(find.text('1분 추가'), findsAtLeastNWidgets(1));
      expect(find.text('시작'), findsAtLeastNWidgets(1));
    });

    testWidgets('단계 번호 CircleAvatar 표시', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(
        _buildSuggestion('test-001', suggestions: const [_sug]),
      );
      await tester.pump();
      // 버튼맵 그리드도 순서 뱃지를 보여주지만 CircleAvatar가 아니라 Container라서,
      // CircleAvatar 안쪽으로 범위를 좁혀야 타임라인의 단계 번호만 정확히 잡힌다.
      Finder inCircleAvatar(String text) => find.descendant(
            of: find.byType(CircleAvatar),
            matching: find.text(text),
          );
      expect(inCircleAvatar('1'), findsOneWidget);
      expect(inCircleAvatar('2'), findsOneWidget);
      expect(inCircleAvatar('3'), findsOneWidget);
    });

    testWidgets('지금 실행 버튼 표시', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(
        _buildSuggestion('test-001', suggestions: const [_sug]),
      );
      await tester.pump();
      expect(find.text('지금 실행'), findsOneWidget);
    });

    testWidgets('거부 버튼 탭 시 화면 pop', (tester) async {
      _useTallViewport(tester);
      final router = GoRouter(
        initialLocation: '/',
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
      );

      await tester.pumpWidget(
        buildWithProviderState(
          suggestions: const [_sug],
          overrides: connectedOverrides(),
          child: MaterialApp.router(
            theme: ThemeData.dark(),
            routerConfig: router,
          ),
        ),
      );
      await tester.pump();

      router.push('/suggestion/test-001');
      await tester.pumpAndSettle();

      await tester.tap(find.text('이번만 넘기기'));
      await tester.pumpAndSettle();

      // pop 후 홈으로 돌아감
      expect(find.text('홈'), findsOneWidget);
    });

    testWidgets('"이 제안 다시 받지 않기" 탭 시 화면 pop', (tester) async {
      _useTallViewport(tester);
      final router = GoRouter(
        initialLocation: '/',
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
      );

      await tester.pumpWidget(
        buildWithProviderState(
          suggestions: const [_sug],
          overrides: connectedOverrides(),
          child: MaterialApp.router(
            theme: ThemeData.dark(),
            routerConfig: router,
          ),
        ),
      );
      await tester.pump();

      router.push('/suggestion/test-001');
      await tester.pumpAndSettle();

      await tester.tap(find.text('이 제안 다시 받지 않기'));
      await tester.pumpAndSettle();

      expect(find.text('홈'), findsOneWidget);
    });

    testWidgets('승인 버튼 탭 시 /status 로 이동', (tester) async {
      _useTallViewport(tester);
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
        buildWithProviderState(
          suggestions: const [_sug],
          overrides: connectedOverrides(),
          child: MaterialApp.router(
            theme: ThemeData.dark(),
            routerConfig: router,
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('지금 실행'));
      await tester.pumpAndSettle();

      expect(find.text('상태 화면'), findsOneWidget);

      // DemoService.runExecutionFlow()가 스케줄한 타이머(500~4000ms)를 소진
      await tester.pump(const Duration(seconds: 5));
    });
  });
}
