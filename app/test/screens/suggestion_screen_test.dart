import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:simplelay/models/appliance.dart';
import 'package:simplelay/models/suggestion.dart';
import 'package:simplelay/screens/suggestion_screen.dart';
import 'package:simplelay/widgets/button_map_grid.dart';

import '../helpers/test_helpers.dart';

Widget _buildSuggestion(
  String sequenceId, {
  List<Suggestion> suggestions = const [],
}) {
  return buildWithProviderState(
    suggestions: suggestions,
    overrides: [
      ...connectedOverrides(),
      // 제안은 자기 대상을 **설치 목록**에서 찾는다. 대상을 가진 사용자를
      // 만들지 않으면, 이 파일의 테스트는 전부 '대상 없음' 화면을 본다.
      ...installedOverrides([kTestAppliance, kTestAircon]),
    ],
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
  applianceId: 'microwave',
);

/// 서버(HTTP)에서 온 패턴 제안. 영구 억제를 실제로 지킬 수 있는 경로이고,
/// 시간대·횟수가 있어 '왜 지금'을 문장으로 만들 수 있다.
const _httpSug = Suggestion(
  sequenceId: 'test-003',
  label: '즉석밥 데우기',
  steps: ['BT-08', 'BT-03', 'BT-05'],
  applianceId: 'microwave',
  source: SuggestionSource.http,
  timeBand: '저녁',
  occurrences: 4,
);

/// 대상 가전이 지금 고른 가전과 다른 제안.
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
  testWidgets('pause is offered for server suggestions only', (tester) async {
    _useTallViewport(tester);
    await tester.pumpWidget(_buildSuggestion(_httpSug.sequenceId, suggestions: [_httpSug]));
    await tester.pump();
    await tester.tap(find.byKey(const Key('suggestion-more')));
    await tester.pumpAndSettle();
    expect(find.text('이 제안 30분 쉬기'), findsOneWidget);
    await tester.pumpWidget(const SizedBox()); // 열린 더 보기 목록을 새 화면에 남기지 않는다
    await tester.pumpWidget(_buildSuggestion(_sug.sequenceId, suggestions: [_sug]));
    await tester.pump();
    // BLE 제안은 쉬기·동작 바꾸기·다시 받지 않기가 모두 없어 '더 보기'도 없다.
    expect(find.byKey(const Key('suggestion-more')), findsNothing);
    expect(find.text('이 제안 30분 쉬기'), findsNothing);
  });

  // ── 2026-10-14 UI 정리: 아래 고정 영역은 실행·다음에만, 나머지는 '더 보기' ─────────────
  group('SuggestionScreen — 동시 선택지 줄이기', () {
    Finder barButtons() => find.descendant(
          of: find.byKey(const Key('suggestion-action-bar')),
          matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
        );

    testWidgets('아래 고정 영역의 선택지는 실행·다음에 둘뿐이다', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildSuggestion('test-003', suggestions: const [_httpSug]));
      await tester.pumpAndSettle();

      expect(barButtons(), findsNWidgets(2));
      final bar = find.byKey(const Key('suggestion-action-bar'));
      expect(find.descendant(of: bar, matching: find.text('지금 실행')), findsOneWidget);
      expect(find.descendant(of: bar, matching: find.text('이번엔 안 할게요')), findsOneWidget);
      // 두 단추는 위아래로 — 나란히 두면 좁은 폰에서 '이번엔 안 할게 / 요'로 끊겼다(UI 평가 10/17).
      final run = tester.getRect(find.descendant(of: bar, matching: find.text('지금 실행')));
      final skip = tester.getRect(find.descendant(of: bar, matching: find.text('이번엔 안 할게요')));
      expect(skip.top, greaterThan(run.bottom));
      // 쉬기·동작 바꾸기·다시 받지 않기는 처음 화면에 없다.
      for (final text in ['이 제안 30분 쉬기', '이번 동작 바꾸기', '이 제안 다시 받지 않기']) {
        expect(find.text(text), findsNothing, reason: text);
      }
    });

    testWidgets("'더 보기'를 누르면 쉬기·동작 바꾸기·다시 받지 않기가 나온다", (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildSuggestion('test-003', suggestions: const [_httpSug]));
      await tester.pumpAndSettle();

      final more = find.byKey(const Key('suggestion-more'));
      expect(more, findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('더 보기')), findsWidgets);
      await tester.tap(more);
      await tester.pumpAndSettle();
      for (final text in ['이 제안 30분 쉬기', '이번 동작 바꾸기', '이 제안 다시 받지 않기']) {
        expect(find.text(text), findsOneWidget, reason: text);
      }
    });

    // 2026-10-14 추가 확인 2: 낭독 이름이 무엇을 더 보는지 말하고, 목록을 닫으면 초점이 그 버튼으로 돌아온다.
    testWidgets("'더 보기' 낭독 이름은 '제안 옵션 더 보기'", (tester) async {
      final handle = tester.ensureSemantics();
      _useTallViewport(tester);
      await tester.pumpWidget(_buildSuggestion('test-003', suggestions: const [_httpSug]));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('제안 옵션 더 보기'), findsOneWidget);
      // 화면 글자는 그대로 '더 보기'.
      expect(find.descendant(
              of: find.byKey(const Key('suggestion-more')), matching: find.text('더 보기')),
          findsOneWidget);
      handle.dispose();
    });

    testWidgets('목록을 고르지 않고 닫으면 초점이 더 보기 버튼으로 돌아온다', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildSuggestion('test-003', suggestions: const [_httpSug]));
      await tester.pumpAndSettle();
      final more = find.byKey(const Key('suggestion-more'));
      await tester.tap(more);
      await tester.pumpAndSettle();
      expect(find.text('이 제안 30분 쉬기'), findsOneWidget);
      // 바깥(가림막)을 눌러 닫는다 — 아무것도 고르지 않았다.
      await tester.tapAt(const Offset(200, 20));
      await tester.pumpAndSettle();
      expect(find.text('이 제안 30분 쉬기'), findsNothing);
      final focused = FocusManager.instance.primaryFocus?.context;
      expect(focused, isNotNull);
      expect(
          find.descendant(of: more, matching: find.byElementPredicate((e) => e == focused)),
          findsOneWidget);
      // 닫기만 했으니 제안은 그대로다.
      expect(find.text('지금 실행'), findsOneWidget);
    });

    testWidgets('실행 대상·누를 버튼·모의 여부는 펼치지 않아도 보이고, 버튼 배치는 펼쳐야 보인다',
        (tester) async {
      _useTallViewport(tester);
      final demoMicrowave = ApplianceMap(
        id: 'microwave',
        name: '전자레인지',
        category: ApplianceCategory.microwave,
        rows: kTestAppliance.rows,
        cols: kTestAppliance.cols,
        buttons: kTestAppliance.buttons,
        isDemo: true,
      );
      await tester.pumpWidget(buildWithProviderState(
        suggestions: const [
          Suggestion(
            sequenceId: 'demo-1',
            label: '즉석밥 데우기',
            steps: ['BT-08', 'BT-03', 'BT-05'],
            applianceId: 'microwave',
            source: SuggestionSource.http,
            timeBand: '데모',
            isDemo: true,
          ),
        ],
        overrides: [
          ...connectedOverrides(),
          ...installedOverrides([demoMicrowave]),
        ],
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: const SuggestionScreen(sequenceId: 'demo-1'),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('전자레인지'), findsWidgets); // 실행 대상
      expect(find.text('즉석밥'), findsOneWidget); // 누를 버튼(순서 목록)
      expect(find.text('누를 순서'), findsOneWidget);
      expect(find.text('데모'), findsOneWidget); // 모의(표본) 가전
      expect(find.text('시연 데이터로 만든 제안'), findsOneWidget);
      // 버튼 배치(지도)는 접혀 있다 — 제목만 보이고 지도는 없다.
      expect(find.text('전자레인지의 실제 버튼 배치'), findsOneWidget);
      expect(find.byType(ButtonMapGrid), findsNothing);
      await tester.tap(find.text('전자레인지의 실제 버튼 배치'));
      await tester.pumpAndSettle();
      expect(find.byType(ButtonMapGrid), findsOneWidget);
    });

    testWidgets('글꼴 2.0에서도 고정 영역은 실행·다음에 둘, 더 보기는 위에서 닿는다', (tester) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(_buildSuggestion('test-003', suggestions: const [_httpSug]));
      await tester.pumpAndSettle();

      expect(barButtons(), findsNWidgets(2));
      expect(find.byKey(const Key('suggestion-more')).hitTestable(), findsOneWidget);
      expect(find.text('이 제안 다시 받지 않기'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('SuggestionScreen — 제안 없음', () {
    testWidgets('알 수 없는 sequenceId 시 오류 메시지', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildSuggestion('nonexistent', suggestions: []));
      await tester.pump();
      expect(find.text('제안을 찾을 수 없어요.'), findsOneWidget);
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
      // 버튼 배치(지도)는 접혀 있다 — 펼쳐서 비교한다(2026-10-14 UI 정리).
      await tester.tap(find.text('전자레인지의 실제 버튼 배치'));
      await tester.pumpAndSettle();
      // 순서 목록과 버튼 지도가 **같은 단어**를 쓴다 -- 대상 가전에 등록된
      // 라벨 그대로. 예전에는 목록이 전역 표('1분 추가')를, 지도가 가전
      // 라벨('1분')을 써서 같은 버튼을 두 이름으로 불렀다.
      expect(find.text('즉석밥'), findsAtLeastNWidgets(1));
      expect(find.text('1분'), findsNWidgets(2));
      expect(find.text('1분 추가'), findsNothing);
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
          overrides: [
            ...connectedOverrides(),
            ...installedOverrides([kTestAppliance, kTestAircon]),
          ],
          child: MaterialApp.router(
            theme: ThemeData.dark(),
            routerConfig: router,
          ),
        ),
      );
      await tester.pump();

      router.push('/suggestion/test-001');
      await tester.pumpAndSettle();

      await tester.tap(find.text('이번엔 안 할게요'));
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
          overrides: [
            ...connectedOverrides(),
            ...installedOverrides([kTestAppliance, kTestAircon]),
          ],
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
          overrides: [
            ...connectedOverrides(),
            ...installedOverrides([kTestAppliance, kTestAircon]),
          ],
          child: MaterialApp.router(
            theme: ThemeData.dark(),
            routerConfig: router,
          ),
        ),
      );
      await tester.pump();

      router.push('/suggestion/test-003');
      await tester.pumpAndSettle();

      // 다시 받지 않기는 '더 보기' 안에 있다(2026-10-14 UI 정리).
      await tester.tap(find.byKey(const Key('suggestion-more')));
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

    testWidgets('준비 안 된 가전의 제안은 실행을 내걸지 않고 이유를 말한다',
        (tester) async {
      // 서버도 412로 거절하지만, 누를 수 있는 버튼을 두고 눌러 봐야 안 된다고
      // 하면 사용자는 원인을 가전 쪽에서 찾는다.
      _useTallViewport(tester);
      final notReady = ApplianceMap(
        id: 'microwave',
        name: '전자레인지',
        category: ApplianceCategory.microwave,
        rows: kTestAppliance.rows,
        cols: kTestAppliance.cols,
        buttons: kTestAppliance.buttons,
        canExecute: false,
        readiness: 'disconnected',
        readinessReasons: const ['노드가 응답하지 않아요'],
        readinessKnown: true,
      );
      await tester.pumpWidget(
        buildWithProviderState(
          suggestions: const [_httpSug],
          overrides: [
            ...connectedOverrides(),
            ...installedOverrides([notReady]),
          ],
          child: const MaterialApp(
            home: SuggestionScreen(sequenceId: 'test-003'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final run = tester.widget<FilledButton>(
        find.ancestor(
          of: find.text('지금 실행'),
          matching: find.byType(FilledButton),
        ),
      );
      expect(run.onPressed, isNull);
      expect(find.textContaining('노드가 응답하지 않아요'), findsOneWidget);
      // 넘기는 길은 그대로 열려 있다.
      expect(find.text('이번엔 안 할게요'), findsOneWidget);
    });

    testWidgets('실행 직전에 대상과 단계 수를 한 번 더 말한다', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(
        _buildSuggestion('test-001', suggestions: const [_sug]),
      );
      await tester.pumpAndSettle();

      expect(find.text('전자레인지 · 버튼 3개'), findsOneWidget);
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

      expect(find.text('이번엔 안 할게요'), findsOneWidget);
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

      // '최근'을 붙이지 않는다 -- 서버 집계에 기간 창이 없어서, 화면이
      // 범위를 실제보다 좁게 말하는 것이 된다.
      expect(find.text('저녁 시간에 4번 하셨어요.'), findsOneWidget);
      expect(find.textContaining('최근'), findsNothing);
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
          overrides: [
            ...connectedOverrides(),
            ...installedOverrides([kTestAppliance, kTestAircon]),
          ],
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
