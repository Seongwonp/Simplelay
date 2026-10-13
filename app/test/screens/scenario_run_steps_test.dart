// G4 — 다단계 실행이 끝나면 상태 화면이 GET /scenarios/last-run으로 단계별
// 결과를 보인다(2026-09-29). **끝난 그 job의 기록일 때만** 보이고, 확인 수준은
// 기존 문구 규칙(confirmationLabel)을 그대로 쓴다 -- 미확인을 확인으로 올리지 않는다.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simplelay/models/execution_status.dart';
import 'package:simplelay/models/scenario_run.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/status_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';

import '../helpers/test_helpers.dart';

/// 두 단계 픽스처 — ThinQ 상태 확인됨 + 물리 실행기 보고.
Map<String, dynamic> _run(String jobId) => {
      'run': {
        'job_id': jobId,
        'scenario_id': 'evening_rest',
        'purpose': '저녁 쉬기',
        'status': 'succeeded',
        'finished_at': '2026-09-29T19:30:00+09:00',
        'steps': [
          {
            'target_id': 'air_purifier',
            'route': 'thinq',
            'action': 'set_wind_strength',
            'args': {'wind_strength': 'LOW'},
            'buttons': <String>[],
            'summary': '공기청정기 풍량 약하게',
            'status': 'succeeded',
            'receipt': 'accepted',
            'confirmation': 'state_confirmed',
            'execution_mode': 'mock',
            'detail': '',
          },
          {
            'target_id': 'microwave',
            'route': 'physical',
            'action': null,
            'args': <String, dynamic>{},
            'buttons': ['즉석밥', '시작'],
            'summary': '전자레인지 즉석밥',
            'status': 'succeeded',
            'receipt': 'accepted',
            'confirmation': 'reported',
            'execution_mode': 'mock',
            'detail': '',
          },
        ],
      },
    };

RpiApiService _api(Map<String, dynamic> body) => RpiApiService(
      'http://rpi5.local:8000',
      client: MockClient((request) async {
        if (request.url.path == '/scenarios/last-run') {
          return http.Response.bytes(utf8.encode(jsonEncode(body)), 200,
              headers: {'content-type': 'application/json'});
        }
        return http.Response('{}', 404);
      }),
    );

const _finished = ExecutionStatus(
  label: '저녁 쉬기',
  sequenceId: 'job-7',
  phase: ExecutionPhase.completed,
  executionMode: 'mock',
  outcome: 'success',
  route: 'physical',
  receipt: 'accepted',
  confirmation: 'reported',
);

Future<void> _pump(WidgetTester tester, RpiApiService api) async {
  tester.view.physicalSize = const Size(400, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(buildScreen(
    const StatusScreen(),
    executionStatus: _finished,
    overrides: [rpiApiServiceProvider.overrideWithValue(api)],
  ));
  await tester.pump();
  await tester.pump();
}

void main() {
  test('last-run 응답을 읽고, run이 null이면 null이다', () {
    final run = ScenarioRun.fromLastRunJson(_run('job-7'))!;
    expect(run.jobId, 'job-7');
    expect(run.steps, hasLength(2));
    expect(run.steps.first.route, 'thinq');
    expect(run.steps.last.confirmation, 'reported');
    expect(ScenarioRun.fromLastRunJson({'run': null}), isNull);
  });

  testWidgets('끝난 job의 기록이면 단계별 경로·실행 환경·확인 수준·결과를 보인다',
      (tester) async {
    await _pump(tester, _api(_run('job-7')));

    expect(find.text('단계별 결과'), findsOneWidget);
    expect(find.text('1. 공기청정기 풍량 약하게'), findsOneWidget);
    expect(find.text('2. 전자레인지 즉석밥'), findsOneWidget);
    // 확인 수준은 기존 규칙 그대로 — ThinQ는 상태 확인됨, 물리 보고는 보고만.
    // 모의 실행이면 모의 상태 확인이다(10/6 Copilot 리뷰 66990be).
    expect(find.text('ThinQ · 모의 실행 · 모의 상태 확인 · 성공'), findsOneWidget);
    expect(find.text('버튼을 대신 눌러요 · 모의 실행 · 연습(모의) 결과 · 성공'),
        findsOneWidget);
    // 보고만 받은 물리 단계를 눌림·동작 확인으로 올리지 않는다.
    expect(find.textContaining('버튼을 눌렀어요'), findsNothing);
    expect(find.textContaining('켜진 것을 확인했어요'), findsNothing);
    // 한 줄 요약(헤드라인)은 그대로 남는다.
    expect(find.text('저녁 쉬기'), findsOneWidget);
  });

  testWidgets('last-run이 다른 job이면 단계 목록을 보이지 않는다', (tester) async {
    await _pump(tester, _api(_run('job-6')));

    expect(find.text('단계별 결과'), findsNothing);
    expect(find.text('1. 공기청정기 풍량 약하게'), findsNothing);
  });

  testWidgets('확인 못 한 ThinQ 단계를 확인됨으로 올리지 않는다', (tester) async {
    final body = _run('job-7');
    final steps = (body['run'] as Map<String, dynamic>)['steps'] as List;
    (steps.first as Map<String, dynamic>)
      ..['status'] = 'unconfirmed'
      ..['confirmation'] = 'none'
      ..['receipt'] = 'unknown';
    (steps.last as Map<String, dynamic>)
      ..['status'] = 'failed'
      ..['receipt'] = 'not_dispatched'
      ..['confirmation'] = 'none';
    await _pump(tester, _api(body));

    expect(find.text('ThinQ · 모의 실행 · 가전이 받았는지 확인이 필요해요 · 확인 못 함'),
        findsOneWidget);
    expect(find.text('버튼을 대신 눌러요 · 모의 실행 · 연습(모의) · 눌렸는지 확인하지 못했어요 · 실패'),
        findsOneWidget);
    expect(find.textContaining('상태 확인됨'), findsNothing);
  });
}
