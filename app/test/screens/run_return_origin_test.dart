// 2026-10-13 에뮬레이터: 홈 큰 루틴 카드 '실행하기' → 승인 화면 '지금 하기' →
// 실행 상태 화면 '확인'을 누르면 이미 처리된 승인 화면으로 돌아가
// "이 알림을 찾을 수 없어요."만 있는 빈 화면에 갇혔다. 실행을 시작한 뒤의
// 확인·닫기는 실행을 시작한 곳(홈·루틴 목록·편집기)으로 돌아가야 한다.
//
// 세 진입점(홈·루틴 목록·편집기 '지금 하기')은 모두 `runRoutineNow`로 승인
// 화면을 연다. 그래서 출발 화면 하나가 `runRoutineNow`를 부르게 두고, 승인
// 화면은 진짜 SuggestionScreen이다.
//
// 실행 상태 화면은 두 가지로 본다(외부 평가 2026-10-13 L1):
//  - 대역(`_StatusStandIn`): StatusScreen의 돌아가기 규칙(`canPop`이면 pop, 아니면 홈)을 복제한
//    것 — 수정 전 2건 실패는 이 대역 경로의 실패다(ecb90e9).
//  - 실제 StatusScreen: 허브가 실행 완료를 알리면 아래 '확인'·'닫기'·안드로이드 뒤로가기가
//    출발한 곳(홈·루틴 목록)으로 돌아가는지. 편집기 출발은 같은 `runRoutineNow`라 여기서 따로 보지 않는다.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/status_screen.dart';
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
          // 실제 StatusScreen이 따라가는 실행 — 접수 뒤 바로 끝난 것으로 알린다.
          if (path == '/status') {
            return _json({
              'running': false,
              'job_id': null,
              'last_job_id': approved ? 'job-1' : null,
              'last_status': approved ? 'succeeded' : null,
              'last_outcome': approved ? 'success' : null,
              'last_execution_mode': 'mock',
              'last_route': 'physical',
              'last_buttons': <Object>[],
            });
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

Widget _build(_Hub hub, String initial, {bool realStatus = false}) {
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
      GoRoute(
          path: '/status',
          builder: (_, __) =>
              realStatus ? const StatusScreen() : const _StatusStandIn()),
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
  expect(find.text('지금 하기'), findsOneWidget, reason: '승인 화면이 열린다');

  await tester.tap(find.text('지금 하기'));
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

      expect(find.text('이 물음을 찾을 수 없어요. 홈으로 돌아가 주세요.'), findsNothing);
      expect(find.text('출발 $name'), findsOneWidget);
      // 폴링 타이머를 정리한다.
      await tester.pumpWidget(const SizedBox());
    });
  }

  // 실제 StatusScreen(L1). 버튼마다·뒤로가기마다 출발한 곳으로 돌아가는지.
  for (final (initial, name) in [('/', '홈'), ('/routines', '루틴 목록')]) {
    // 성공 뒤에는 '확인' 하나만 둔다('닫기'는 다시 시도할 때만, 외부 평가 10/16 p08).
    for (final how in ['닫기', '뒤로가기']) {
      testWidgets('실제 실행 상태 화면: $name 출발 → 완료 뒤 $how → $name', (tester) async {
        _tall(tester);
        final hub = _Hub();
        await tester.pumpWidget(_build(hub, initial, realStatus: true));
        await _settle(tester);

        await tester.tap(find.text('실행하기'));
        await _settle(tester);
        await tester.tap(find.text('지금 하기'));
        await _settle(tester);
        expect(hub.approved, isTrue);
        expect(find.byType(StatusScreen), findsOneWidget);
        // 폴링(1초)이 완료를 받을 때까지.
        await tester.pump(const Duration(seconds: 2));
        await _settle(tester);
        expect(find.text('닫기'), findsOneWidget, reason: '완료 뒤 아래 버튼');

        if (how == '뒤로가기') {
          await tester.binding.handlePopRoute();
        } else {
          await tester.tap(find.text(how));
        }
        await _settle(tester);
        await tester.pump(const Duration(seconds: 1)); // 화면 전환이 끝나도록

        expect(find.byType(StatusScreen), findsNothing);
        expect(find.text('이 물음을 찾을 수 없어요. 홈으로 돌아가 주세요.'), findsNothing);
        expect(find.text('출발 $name'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
