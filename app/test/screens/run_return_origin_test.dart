// 2026-10-13 에뮬레이터: 홈 큰 루틴 카드 '실행하기' → 승인 화면 '지금 실행' →
// 실행 상태 화면 '확인'을 누르면 이미 처리된 승인 화면으로 돌아가
// "제안을 찾을 수 없어요."만 있는 빈 화면에 갇혔다. 실행을 시작한 뒤의
// 확인·닫기는 실행을 시작한 곳(홈·루틴 목록·편집기)으로 돌아가야 한다.
//
// 세 진입점(홈·루틴 목록·편집기 '지금 실행')은 모두 `runRoutineNow`로 승인
// 화면을 연다. 그래서 출발 화면 하나가 `runRoutineNow`를 부르게 두고, 승인
// 화면은 진짜 SuggestionScreen, 실행 상태 화면은 StatusScreen의 돌아가기
// 규칙(`canPop`이면 pop, 아니면 홈)과 같은 대역으로 둔다.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/suggestion_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';
import 'package:simplelay/widgets/routine_run.dart';

import '../helpers/test_helpers.dart';

const _routineCard = {
  'id': 'sug-1',
  'purpose': "'아침 데우기' 루틴을 실행할까요?",
  'time_band': '루틴',
  'occurrences': 0,
  'steps': <String>[],
  'reason': "루틴 '아침 데우기'",
  'appliance_id': 'microwave',
  'is_demo': false,
  'routine_id': 'rt-1',
  'routine_name': '아침 데우기',
  'commands': [
    {
      'target_id': 'microwave',
      'route': 'physical',
      'action': null,
      'args': <String, dynamic>{},
      'buttons': ['즉석밥', '시작'],
      'summary': '전자레인지 즉석밥 → 시작',
    },
  ],
};

class _Hub {
  bool triggered = false;
  bool approved = false;

  http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
        utf8.encode(jsonEncode(body)),
        status,
        headers: {'content-type': 'application/json'},
      );

  RpiApiService api() => RpiApiService(
        'http://rpi5.local:8000',
        client: MockClient((req) async {
          final path = req.url.path;
          if (path == '/routines/rt-1/trigger') {
            triggered = true;
            return _json({
              'kind': 'suggestion',
              'suggestion': {'id': 'sug-1'},
            });
          }
          // 승인되면 서버는 카드를 내린다.
          if (path == '/suggestions') {
            return _json(triggered && !approved ? [_routineCard] : []);
          }
          if (path == '/suggestions/sug-1/approve') {
            approved = true;
            return _json({'job_id': 'job-1'});
          }
          if (path == '/readiness/microwave') {
            return _json({
              'appliance_id': 'microwave',
              'route': 'physical',
              'state': 'operable',
              'can_execute': true,
              'reasons': <String>[],
            });
          }
          return _json({'detail': 'not found'}, 404);
        }),
      );
}

class _Origin extends ConsumerWidget {
  const _Origin(this.name);
  final String name;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
        body: Column(children: [
          Text('출발 $name'),
          TextButton(
            onPressed: () => runRoutineNow(context, ref, 'rt-1'),
            child: const Text('실행하기'),
          ),
        ]),
      );
}

/// StatusScreen._returnToOrigin과 같은 규칙: 쌓인 화면이 있으면 pop, 없으면 홈.
class _StatusStandIn extends StatelessWidget {
  const _StatusStandIn();

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Column(children: [
          const Text('상태 화면'),
          TextButton(
            onPressed: () {
              if (Navigator.of(context).canPop()) {
                Navigator.of(context).pop();
              } else {
                context.go('/');
              }
            },
            child: const Text('확인'),
          ),
        ]),
      );
}

Widget _build(_Hub hub, String initial) {
  final router = GoRouter(
    initialLocation: initial,
    routes: [
      GoRoute(path: '/', builder: (_, __) => const _Origin('홈')),
      GoRoute(path: '/routines', builder: (_, __) => const _Origin('루틴 목록')),
      GoRoute(
        path: '/suggestion/:id',
        builder: (_, state) =>
            SuggestionScreen(sequenceId: state.pathParameters['id']!),
      ),
      GoRoute(path: '/status', builder: (_, __) => const _StatusStandIn()),
    ],
  );
  return buildWithProviderState(
    overrides: [
      ...connectedOverrides(),
      rpiApiServiceProvider.overrideWithValue(hub.api()),
    ],
    child: MaterialApp.router(
      theme: ThemeData.dark().copyWith(splashFactory: InkRipple.splashFactory),
      routerConfig: router,
    ),
  );
}

void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(900, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _runAndConfirm(WidgetTester tester, _Hub hub) async {
  await tester.tap(find.text('실행하기'));
  await _settle(tester);
  expect(find.text('지금 실행'), findsOneWidget, reason: '승인 화면이 열린다');

  await tester.tap(find.text('지금 실행'));
  await _settle(tester);
  expect(hub.approved, isTrue);
  expect(find.text('상태 화면'), findsOneWidget);

  await tester.tap(find.text('확인'));
  await _settle(tester);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final (initial, name) in [('/', '홈'), ('/routines', '루틴 목록')]) {
    testWidgets('$name에서 실행을 시작하면 확인은 처리된 승인 화면이 아니라 $name(으)로 돌아간다',
        (tester) async {
      _tall(tester);
      final hub = _Hub();
      await tester.pumpWidget(_build(hub, initial));
      await _settle(tester);

      await _runAndConfirm(tester, hub);

      expect(find.text('제안을 찾을 수 없어요.'), findsNothing);
      expect(find.text('출발 $name'), findsOneWidget);
      // 폴링 타이머를 정리한다.
      await tester.pumpWidget(const SizedBox());
    });
  }
}
