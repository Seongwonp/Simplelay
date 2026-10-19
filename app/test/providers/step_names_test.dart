// 폰 실행 화면 '누르는 순서'가 '1번째 버튼 / 2번째 버튼'만 보이던 것(10/19) — 키오스크는 이름을 보였다.
//
// 서버 /status는 실행 중 **지금 버튼**(`current_button`)만 주고 끝난 칸 이름은 주지 않는다. 키오스크는 폴링에서 본
// 지금 버튼을 기억해 끝낸 칸 이름으로 썼고, 폰은 버렸다. 끝나면 `last_buttons`에 누른 순서 이름이 온다 — 폰은 그것도
// 쓰지 않았다. 폰도 본 이름(칸 번호에 묶어)과 끝난 뒤 `last_buttons`를 쓴다. 이름을 못 봤으면 번호 그대로(지어내지 않는다).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/execution_status.dart';
import 'package:simplelay/providers/execution_status_provider.dart';
import 'package:simplelay/screens/status_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';

import '../helpers/test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('폴링에서 본 지금 버튼을 칸 번호에 묶어 기억하고, 끝나면 last_buttons 이름을 쓴다', () async {
    final replies = <Map<String, Object?>>[
      {
        'running': true,
        'last_status': null,
        'last_buttons': null,
        'current_button': '즉석밥',
        'completed_steps': 0,
        'total_steps': 2,
        'job_id': 'job-1',
        'last_job_id': null,
      },
      {
        'running': true,
        'last_status': null,
        'last_buttons': null,
        'current_button': '시작',
        'completed_steps': 1,
        'total_steps': 2,
        'job_id': 'job-1',
        'last_job_id': null,
      },
      {
        'running': false,
        'last_status': 'succeeded',
        'last_outcome': 'success',
        'last_buttons': [
          {'button': '즉석밥', 'success': true},
          {'button': '시작', 'success': true},
        ],
        'last_job_id': 'job-1',
      },
    ];
    var poll = 0;
    final client = MockClient((request) async {
      final body = replies[poll < replies.length ? poll : replies.length - 1];
      poll++;
      return http.Response.bytes(utf8.encode(jsonEncode(body)), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container.read(executionStatusProvider.notifier).beginHttpJob(
          api: RpiApiService('http://rpi5.local:8000', client: client),
          jobId: 'job-1',
          label: '즉석밥 데워줘',
        );

    await Future<void>.delayed(const Duration(milliseconds: 1300));
    await Future<void>.delayed(const Duration(milliseconds: 1000));
    var status = container.read(executionStatusProvider);
    expect(status.phase, ExecutionPhase.running);
    expect(status.currentButton, '시작');
    expect(status.stepNames.first, '즉석밥');

    await Future<void>.delayed(const Duration(milliseconds: 1000));
    status = container.read(executionStatusProvider);
    expect(status.phase, ExecutionPhase.completed);
    expect(status.stepNames, ['즉석밥', '시작']);
  });

  Future<void> pumpStatus(WidgetTester tester, ExecutionStatus status) async {
    tester.view.physicalSize = const Size(400, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(buildScreen(const StatusScreen(), executionStatus: status));
    await tester.pump();
  }

  testWidgets('실행 중 끝낸 칸은 본 버튼 이름으로', (tester) async {
    await pumpStatus(
      tester,
      const ExecutionStatus(
        phase: ExecutionPhase.running,
        label: '즉석밥 데워줘',
        currentButton: '시작',
        totalSteps: 2,
        completedSteps: 1,
        stepNames: ['즉석밥', '시작'],
      ),
    );
    final first = find.byKey(const Key('status-order-0'));
    expect(find.descendant(of: first, matching: findPlainText('즉석밥 버튼')), findsOneWidget);
    expect(find.textContaining('1번째 버튼'), findsNothing);
  });

  testWidgets('끝난 뒤에도 칸마다 버튼 이름 — 번호로 돌아가지 않는다', (tester) async {
    await pumpStatus(
      tester,
      const ExecutionStatus(
        phase: ExecutionPhase.completed,
        label: '즉석밥 데워줘',
        currentButton: '시작',
        totalSteps: 2,
        completedSteps: 2,
        stepNames: ['즉석밥', '시작'],
      ),
    );
    expect(find.descendant(
        of: find.byKey(const Key('status-order-0')), matching: findPlainText('즉석밥 버튼')),
        findsOneWidget);
    expect(find.descendant(
        of: find.byKey(const Key('status-order-1')), matching: findPlainText('시작 버튼')),
        findsOneWidget);
    expect(find.textContaining('번째 버튼'), findsNothing);
  });

  testWidgets('이름을 못 본 칸만 번호로 남긴다', (tester) async {
    await pumpStatus(
      tester,
      const ExecutionStatus(
        phase: ExecutionPhase.running,
        label: '즉석밥 데워줘',
        currentButton: '시작',
        totalSteps: 3,
        completedSteps: 2,
        stepNames: [null, '취소'],
      ),
    );
    expect(find.descendant(
        of: find.byKey(const Key('status-order-0')), matching: findPlainText('1번째 버튼')),
        findsOneWidget);
    expect(find.descendant(
        of: find.byKey(const Key('status-order-1')), matching: findPlainText('취소 버튼')),
        findsOneWidget);
  });
}
