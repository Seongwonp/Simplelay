// 사람이 '확인함'을 본체에 적는다(사용자 보고 버그 2026-10-19) — 옛 코드에서 실패하는 것을 확인한 시험.
//
// 원인: 홈 '못 한 일 … 기록 보기' 경고는 보호자 알림 가운데 안 본 것으로 정해지는데, '안 봄'의 기준이 이 폰 안에만
// 기억하는 '알림함을 연 시점'이었다 — '기록 보기'로 기록을 보고 와도 경고·설정 탭 배지가 그대로였고, 키오스크에서 그
// 실패를 확인해도 폰은 몰랐다.
// 이제: '기록 보기'를 누르면 본체 POST /acks(경고에 보인 failures_seen_id)에 적고 경고가 사라진다. 다른 기기(키오스크)에서 확인한 것도
// GET /acks로 읽어 사라진다. 새 실패는 다시 뜬다.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/home_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';

import '../helpers/test_helpers.dart';

/// 상태를 가진 가짜 본체 — 보호자 알림과 '확인함'.
class _Hub {
  final care = <Map<String, dynamic>>[];
  Map<String, dynamic> acks = {'care_seen_id': 0, 'failures_seen_until': null, 'job_answers': <String, String>{}};
  final posts = <Map<String, dynamic>>[];

  /// 본체 시계 — 확인 시각으로 쓴다.
  String now = '2026-10-19T09:00:00+09:00';

  void fail(int id, String at) => care.insert(0, {
        'id': id,
        'kind': 'execution_failed',
        'message': "'공기청정기 바람 세기 중'을 끝까지 하지 못했어요.",
        'purpose': '공기청정기 바람 세기 중',
        'occurred_at': at,
      });

  RpiApiService api() => RpiApiService(
        'http://rpi5.local:8000',
        client: MockClient((req) async {
          final path = req.url.path;
          if (path == '/care-events') return _json(care);
          if (path == '/acks' && req.method == 'GET') return _json(acks);
          if (path == '/acks' && req.method == 'POST') {
            final body = jsonDecode(req.body) as Map<String, dynamic>;
            posts.add(body);
            // 화면에 보인 못 한 일 번호까지(검토 10/19 계약) — 시각은 옛 앱 호환 값.
            if (body['failures_seen_id'] case final int id) acks = {...acks, 'failures_seen_id': id, 'failures_seen_until': now};
            return _json(acks);
          }
          if (path == '/appliances') return _json(const []);
          if (path == '/routines') return _json(const []);
          if (path == '/suggestions') return _json(const []);
          if (path == '/history') return _json(const []);
          return _json({'detail': 'not found'}, 404);
        }),
      );
}

http.Response _json(Object body, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), status, headers: {'content-type': 'application/json'});

Widget _app(RpiApiService api) {
  final router = GoRouter(routes: [
    GoRoute(path: '/', builder: (_, __) => const HomeScreen()),
    GoRoute(path: '/history', builder: (context, __) => Scaffold(
          body: TextButton(key: const Key('back-home'), onPressed: () => context.go('/'), child: const Text('기록 화면')),
        )),
  ]);
  return buildWithProviderState(
    overrides: [
      ...connectedOverrides(),
      ...installedOverrides(const []),
      rpiServerOverride(RpiConnectionState.connected),
      rpiApiServiceProvider.overrideWithValue(api),
    ],
    child: MaterialApp.router(theme: ThemeData.light(), routerConfig: router),
  );
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 16; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _pump(WidgetTester tester, _Hub hub) async {
  tester.view.physicalSize = const Size(411, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_app(hub.api()));
  await _settle(tester);
}

final _warning = find.byKey(const Key('home-failure'));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets("'기록 보기'로 보고 오면 못 한 일 경고가 사라진다 — 본체에 확인을 적는다", (tester) async {
    final hub = _Hub()..fail(1, '2026-10-19T08:30:00+09:00');
    await _pump(tester, hub);
    expect(_warning, findsOneWidget);
    await tester.tap(find.byKey(const Key('home-failure-action')));
    await _settle(tester);
    expect(hub.posts, [
      {'failures_seen_id': 1},
    ]);
    await tester.tap(find.byKey(const Key('back-home')));
    await _settle(tester);
    expect(_warning, findsNothing);
  });

  testWidgets('다른 기기(키오스크)에서 확인한 실패는 폰에도 뜨지 않는다', (tester) async {
    final hub = _Hub()
      ..fail(1, '2026-10-19T08:30:00+09:00')
      ..acks = {
        'care_seen_id': 0,
        'failures_seen_until': '2026-10-19T08:31:00+09:00',
        'job_answers': {'job-1': 'moved'},
      };
    await _pump(tester, hub);
    expect(_warning, findsNothing);
  });

  testWidgets('확인한 뒤 새 실패가 생기면 다시 뜬다', (tester) async {
    final hub = _Hub()
      ..fail(1, '2026-10-19T08:30:00+09:00')
      ..acks = {'care_seen_id': 0, 'failures_seen_until': '2026-10-19T08:31:00+09:00', 'job_answers': <String, String>{}};
    await _pump(tester, hub);
    expect(_warning, findsNothing);
    hub.fail(2, '2026-10-19T08:45:00+09:00');
    await tester.pump(const Duration(seconds: 46)); // 알림 주기 조회
    await _settle(tester);
    expect(_warning, findsOneWidget);
  });

  test("확인 표시는 '못 한 일'만 지운다 — 위험 소리는 알림함을 열어야", () {
    const acks = PersonAcks(failuresSeenUntil: null);
    final at = DateTime(2026, 10, 19, 8, 30);
    final danger = RpiCareEvent(id: 3, kind: 'danger_sound', message: '', occurredAt: at);
    final failed = RpiCareEvent(id: 4, kind: 'execution_failed', message: '', occurredAt: at);
    final seen = PersonAcks(failuresSeenUntil: DateTime(2026, 10, 19, 9));
    expect(acks.covers(failed), isFalse);
    expect(seen.covers(failed), isTrue);
    expect(seen.covers(danger), isFalse);
    expect(const PersonAcks(careSeenId: 3).covers(danger), isTrue);
  });
}
