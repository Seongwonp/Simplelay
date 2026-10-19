// '기록 보기'는 화면에 보인 것만 '봤다'로 적는다(본체 /acks 계약 변경, 검토 10/19 #2·#3·#4) — 옛 코드에서 실패하는 것을 확인한 시험.
//
// 원인: 폰 '기록 보기'는 맨 failures_seen:true를 보냈다 — 본체는 그 순간 본체에 있는 가장 새 못 한 일과 최근 실행 기록
// 전체를 '봤다'로 올려, 폰이 아직 받아 오지 않은(화면에 없던) 새 실패까지 사라졌다. 또 '봤다'를 본체 시계 시각
// (failures_seen_until)으로 견줘, RTC 없는 본체의 시계가 뒤로 가면 새 실패가 처음부터 숨었다.
// 이제: 경고에 보인 가장 새 못 한 일 번호(failures_seen_id)와 기록 화면에 보인 실행 번호(seen_job_ids)만 보낸다.
// 본체가 failures_seen_id를 주면 번호로 견주고, 옛 본체에서만 시각으로 견준다.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/history_screen.dart';
import 'package:simplelay/screens/home_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';

import '../helpers/test_helpers.dart';

const _failureKinds = {'execution_failed', 'appliance_done_undelivered'};

/// 새 계약을 따르는 가짜 본체(`rpi/api/router.py` post_acks·`person_acks.legacy_failures_seen_until`과 같은 규칙).
class _Hub {
  final care = <Map<String, dynamic>>[];
  final history = <Map<String, dynamic>>[];
  int failuresSeenId = 0;
  final jobAnswers = <String, String>{};
  final posts = <Map<String, dynamic>>[];

  void fail(int id, String at) => care.insert(0, {
        'id': id,
        'kind': 'execution_failed',
        'message': "'공기청정기 바람 세기 중'을 끝까지 하지 못했어요.",
        'purpose': '공기청정기 바람 세기 중',
        'occurred_at': at,
      });

  void job(String id, String outcome) => history.add({
        'job_id': id,
        'finished_at': '2026-10-19T08:30:00+09:00',
        'purpose': '공기청정기 바람 세기 중',
        'status': outcome == 'success' ? 'success' : 'failed',
        'outcome': outcome,
        'execution_mode': 'real',
        'retry_count': 0,
        'buttons': const [],
      });

  int _newestCare() => care.isEmpty ? 0 : care.map((e) => e['id'] as int).reduce((a, b) => a > b ? a : b);

  String? _legacyUntil() {
    if (failuresSeenId <= 0) return null;
    DateTime? seen;
    DateTime? unseen;
    for (final e in care) {
      final at = DateTime.parse(e['occurred_at'] as String);
      if ((e['id'] as int) <= failuresSeenId) {
        if (seen == null || at.isAfter(seen)) seen = at;
      } else if (_failureKinds.contains(e['kind'])) {
        if (unseen == null || at.isBefore(unseen)) unseen = at;
      }
    }
    if (seen == null) return null;
    final until = unseen != null && unseen.subtract(const Duration(microseconds: 1)).isBefore(seen)
        ? unseen.subtract(const Duration(microseconds: 1))
        : seen;
    return until.toUtc().toIso8601String();
  }

  Map<String, dynamic> acks() => {
        'care_seen_id': 0,
        'failures_seen_id': failuresSeenId,
        'failures_seen_until': _legacyUntil(),
        'job_answers': jobAnswers,
      };

  void _post(Map<String, dynamic> body) {
    posts.add(body);
    var failuresId = body['failures_seen_id'] as int?;
    if (failuresId == null && body['failures_seen'] == true) {
      // 옛 폰 호환(커서 없음) — 본체에 있는 가장 새 못 한 일까지.
      final newest = care.where((e) => _failureKinds.contains(e['kind'])).map((e) => e['id'] as int);
      failuresId = newest.isEmpty ? null : newest.reduce((a, b) => a > b ? a : b);
    }
    if (failuresId != null) {
      final clamped = failuresId < _newestCare() ? failuresId : _newestCare();
      if (clamped > failuresSeenId) failuresSeenId = clamped;
    }
    final jobs = <String>[...((body['seen_job_ids'] as List?) ?? const []).cast<String>()];
    if (body['failures_seen'] == true && body['seen_job_ids'] == null && body['seen_until_job_id'] == null) {
      jobs.addAll(history.map((e) => e['job_id'] as String));
    }
    for (final id in jobs) {
      jobAnswers.putIfAbsent(id, () => 'seen');
    }
  }

  RpiApiService api() => RpiApiService(
        'http://rpi5.local:8000',
        client: MockClient((req) async {
          final path = req.url.path;
          if (path == '/care-events') return _json(care);
          if (path == '/acks' && req.method == 'GET') return _json(acks());
          if (path == '/acks' && req.method == 'POST') {
            _post(jsonDecode(req.body) as Map<String, dynamic>);
            return _json(acks());
          }
          if (path == '/history') return _json(history);
          if (path == '/appliances') return _json(const []);
          if (path == '/routines') return _json(const []);
          if (path == '/suggestions') return _json(const []);
          return _json({'detail': 'not found'}, 404);
        }),
      );
}

http.Response _json(Object body, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), status, headers: {'content-type': 'application/json'});

Widget _app(RpiApiService api) {
  final router = GoRouter(routes: [
    GoRoute(path: '/', builder: (_, __) => const HomeScreen()),
    GoRoute(
      path: '/history',
      builder: (context, __) => Stack(children: [
        const HistoryScreen(),
        Positioned(
          right: 0,
          bottom: 0,
          child: TextButton(key: const Key('back-home'), onPressed: () => context.go('/'), child: const Text('홈')),
        ),
      ]),
    ),
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

  testWidgets("'기록 보기' 뒤에 온(화면에 없던) 실패는 '봤다'가 되지 않는다 — 경고에 보인 번호까지만", (tester) async {
    final hub = _Hub()..fail(1, '2026-10-19T08:30:00+09:00');
    await _pump(tester, hub);
    expect(_warning, findsOneWidget);
    hub.fail(2, '2026-10-19T08:40:00+09:00'); // 본체에는 왔지만 폰은 아직 받아 오지 않았다
    await tester.tap(find.byKey(const Key('home-failure-action')));
    await _settle(tester);
    expect(hub.posts.first, {'failures_seen_id': 1}, reason: '맨 failures_seen이 아니라 경고에 보인 가장 새 못 한 일 번호');
    expect(hub.failuresSeenId, 1);
    await tester.tap(find.byKey(const Key('back-home')));
    await _settle(tester);
    await tester.pump(const Duration(seconds: 46)); // 알림 주기 조회 — 2번을 받아 온다
    await _settle(tester);
    expect(_warning, findsOneWidget, reason: '아무도 안 본 2번 실패는 남는다');
  });

  testWidgets("'기록 보기'는 기록 화면에 보인 실행만 '봤다'로 적는다", (tester) async {
    final hub = _Hub()
      ..fail(1, '2026-10-19T08:30:00+09:00')
      ..job('job-ok', 'success')
      ..job('job-bad', 'failed');
    await _pump(tester, hub);
    await tester.tap(find.byKey(const Key('home-failure-action')));
    await _settle(tester);
    // '못 한 일만'으로 열린다 — 됐어요 기록(job-ok)은 화면에 없다.
    expect(hub.posts.where((p) => p.containsKey('seen_job_ids')).toList(), [
      {
        'seen_job_ids': ['job-bad'],
      },
    ]);
    expect(hub.jobAnswers.keys, ['job-bad']);
    expect(hub.posts.any((p) => p.containsKey('failures_seen')), isFalse);
  });

  test('본체가 번호(failures_seen_id)를 주면 번호로 견준다 — 시계가 뒤로 가 시각이 이른 새 실패도 덮지 않는다', () {
    final acks = PersonAcks.fromJson({
      'care_seen_id': 0,
      'failures_seen_id': 1,
      'failures_seen_until': '2026-10-19T09:00:00+09:00',
      'job_answers': <String, String>{},
    });
    final seen = RpiCareEvent(id: 1, kind: 'execution_failed', message: '', occurredAt: DateTime(2026, 10, 19, 8, 30));
    // 본체 시계가 뒤로 갔다 — 나중에 생긴 2번의 시각이 1번보다 이르다.
    final later = RpiCareEvent(id: 2, kind: 'execution_failed', message: '', occurredAt: DateTime(2026, 10, 19, 8));
    expect(acks.covers(seen), isTrue);
    expect(acks.covers(later), isFalse);
  });

  test('옛 본체(failures_seen_id 없음)는 시각으로 견준다', () {
    final acks = PersonAcks.fromJson({
      'care_seen_id': 0,
      'failures_seen_until': '2026-10-19T09:00:00+09:00',
      'job_answers': <String, String>{},
    });
    final e = RpiCareEvent(id: 7, kind: 'execution_failed', message: '', occurredAt: DateTime(2026, 10, 19, 8, 30));
    expect(acks.covers(e), isTrue);
  });
}
