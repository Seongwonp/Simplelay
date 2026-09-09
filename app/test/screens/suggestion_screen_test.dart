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

/// 서버(HTTP)에서 온 패턴 제안. 영구 억제를 실제로 지킬 수 있는 경로이고,
/// 시간대·횟수가 있어 '왜 지금'을 문장으로 만들 수 있다.
const _httpSug = Suggestion(
  sequenceId: 'test-003',
  label: '즉석밥 데우기',
  steps: ['BT-08', 'BT-03', 'BT-05'],
  source: SuggestionSource.http,
  timeBand: '저녁',
  occurrences: 4,
);

/// 대상 가전이 전역 선택(기본: 전자레인지)과 다른 제안.
const _airconSug = Suggestion(
  sequenceId: 'test-002',
  label: '에어컨 켜줘',
  steps: ['전원', '냉방'],
  applianceId: 'aircon',
  reason: '지금 31°C · 습도 72% — 더워요',
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

    testWidgets('제안은 전역 선택이 아니라 자기 대상 가전으로 그린다', (tester) async {
      // 전자레인지를 고른 상태에서 냉방 제안을 받으면, 예전에는 전자레인지
      // 버튼 지도가 붙었다 -- 화면과 실제 실행 대상이 어긋나는 계약 공백.
      _useTallViewport(tester);
      await tester.pumpWidget(
        buildWithProviderState(
          suggestions: const [_airconSug],
          overrides: connectedOverrides(),
          child: const MaterialApp(
            home: SuggestionScreen(sequenceId: 'test-002'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 대상 가전을 먼저 알려준다
      expect(find.text('에어컨'), findsOneWidget);
      expect(find.text('에어컨의 실제 버튼 배치'), findsOneWidget);
      // 기본 선택(전자레인지)의 지도가 아니어야 한다
      expect(find.text('전자레인지의 실제 버튼 배치'), findsNothing);
      // 환경 근거도 함께 보인다
      expect(find.text('지금 31°C · 습도 72% — 더워요'), findsOneWidget);
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
          suggestions: const [_httpSug],
          overrides: connectedOverrides(),
          child: MaterialApp.router(
            theme: ThemeData.dark(),
            routerConfig: router,
          ),
        ),
      );
      await tester.pump();

      router.push('/suggestion/test-003');
      await tester.pumpAndSettle();

      await tester.tap(find.text('이 제안 다시 받지 않기'));
      await tester.pumpAndSettle();

      expect(find.text('홈'), findsOneWidget);
    });

    testWidgets('대상 가전을 모르면 실행 버튼을 내걸지 않는다', (tester) async {
      // 예전에는 알 수 없는 id를 현재 선택 가전으로 조용히 바꿔 그렸다.
      // 그러면 지운 선풍기의 제안이 전자레인지 지도를 달고 나오고, 승인까지
      // 눌린다. 서버도 그 실행을 404로 거절하므로(R1) 누를 수 있는데 안 되는
      // 버튼이 된다 -- 무엇이 눌릴지 말할 수 없으면 실행을 권하지 않는다.
      _useTallViewport(tester);
      await tester.pumpWidget(
        _buildSuggestion(
          'test-ghost',
          suggestions: const [
            Suggestion(
              sequenceId: 'test-ghost',
              label: '선풍기 켜줘',
              steps: ['F-01'],
              source: SuggestionSource.http,
              applianceId: 'deleted_fan',
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('대상 가전 정보를 확인해 주세요.'), findsOneWidget);
      expect(find.text('지금 실행'), findsNothing);
      // 기본 선택 가전으로 바꿔 그리지 않는다
      expect(find.text('전자레인지의 실제 버튼 배치'), findsNothing);
    });

    testWidgets('BLE 제안에는 "다시 받지 않기"를 내걸지 않는다', (tester) async {
      // 영구 억제는 서버의 억제 목록에만 남는다. BLE 경로에서는 '이번만
      // 넘기기'와 똑같은 거절 메시지가 되므로, 버튼이 있으면 지키지 못할
      // 약속이 된다 -- 두 버튼이 같은 일을 하면서 다른 말을 하게 된다.
      _useTallViewport(tester);
      await tester.pumpWidget(
        _buildSuggestion('test-001', suggestions: const [_sug]),
      );
      await tester.pumpAndSettle();

      expect(find.text('이번만 넘기기'), findsOneWidget);
      expect(find.text('이 제안 다시 받지 않기'), findsNothing);
    });

    testWidgets('패턴 제안은 시간대·횟수로 왜 지금인지 말한다', (tester) async {
      // 서버는 time_band·occurrences를 주는데 앱이 옮기며 버렸다 -- 사용자는
      // 왜 이 카드가 떴는지 알 수 없었다.
      _useTallViewport(tester);
      await tester.pumpWidget(
        _buildSuggestion('test-003', suggestions: const [_httpSug]),
      );
      await tester.pumpAndSettle();

      expect(find.text('최근 저녁 시간에 4번 하셨어요.'), findsOneWidget);
    });

    testWidgets('데모 제안은 지어낸 횟수를 근거처럼 말하지 않는다', (tester) async {
      // 데모 트리거는 패턴 감지를 우회하려고 횟수를 지어낸다. 그걸 '이만큼
      // 하셨어요'로 보여주면 화면이 사실이 아닌 말을 하게 된다.
      _useTallViewport(tester);
      await tester.pumpWidget(
        _buildSuggestion(
          'test-004',
          suggestions: const [
            Suggestion(
              sequenceId: 'test-004',
              label: '즉석밥 데우기',
              steps: ['BT-08'],
              source: SuggestionSource.http,
              timeBand: '데모',
              occurrences: 3,
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('하셨어요'), findsNothing);
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
