import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/appliance.dart';
import 'package:simplelay/models/execution_status.dart';
import 'package:simplelay/providers/execution_status_provider.dart';
import 'package:simplelay/providers/appliance_provider.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/manual_control_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';
import '../helpers/test_helpers.dart';

const _testAppliance = ApplianceMap(
  id: 'custom_test',
  name: '테스트가전',
  category: ApplianceCategory.other,
  rows: 1,
  cols: 2,
  isCustom: true,
  buttons: [
    ApplianceButton(id: 'b1', label: '켜기', x: 0, y: 0),
    ApplianceButton(id: 'b2', label: '끄기', x: 1, y: 0),
  ],
);

Widget _buildScreen(ProviderContainer container) => UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: ManualControlScreen()),
    );

Future<ProviderContainer> _makeContainerWithAppliance(
  WidgetTester tester, {
  List<Override> extra = const [],
}) async {
  final container = ProviderContainer(overrides: extra);
  addTearDown(container.dispose);
  await container.read(customAppliancesProvider.notifier).ensureLoaded();
  await container.read(customAppliancesProvider.notifier).add(_testAppliance);
  await container.read(selectedApplianceProvider.notifier).select(_testAppliance);
  return container;
}

/// 서버가 "아직 맡길 수 없다"고 한 가전 (F1).
const _notReady = ApplianceMap(
  id: 'custom_test',
  name: '테스트가전',
  category: ApplianceCategory.other,
  rows: 1,
  cols: 2,
  isCustom: true,
  canExecute: false,
  readiness: 'needs_setup',
  readinessReasons: ['눌림을 확인할 센서가 아직 준비되지 않았어요'],
  buttons: [
    ApplianceButton(id: 'b1', label: '켜기', x: 0, y: 0),
    ApplianceButton(id: 'b2', label: '끄기', x: 1, y: 0),
  ],
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('준비 안 된 가전 (F1)', () {
    testWidgets('실행을 막고 무엇이 남았는지 말한다', (tester) async {
      // 누를 수 있는데 안 되는 버튼을 두면, 서버가 막은 것을 사용자는
      // 가전 고장으로 오해한다. 서버도 412로 거절한다(이중 방어).
      var executed = 0;
      final api = RpiApiService(
        'http://rpi5.local:8000',
        client: MockClient((request) async {
          if (request.url.path == '/execute-buttons') executed++;
          return http.Response('{"job_id":"J1"}', 200);
        }),
      );
      final container = ProviderContainer(
        overrides: [rpiApiServiceProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await container.read(customAppliancesProvider.notifier).ensureLoaded();
      await container.read(customAppliancesProvider.notifier).add(_notReady);
      await container.read(selectedApplianceProvider.notifier).select(_notReady);

      await tester.pumpWidget(_buildScreen(container));
      await tester.pump();

      expect(find.text('아직 준비가 안 됐어요'), findsOneWidget);
      expect(
        find.text('눌림을 확인할 센서가 아직 준비되지 않았어요'),
        findsOneWidget,
      );

      await tester.tap(find.text('켜기'));
      await tester.pump();
      expect(executed, 0);
      // 서버 가전 목록 조회의 완료가 남긴 0초 타이머를 비운다.
      await tester.pump(Duration.zero);
    });
  });

  testWidgets('RPi 서버가 연결 안 되어 있으면 설정 안내 화면을 보여준다', (tester) async {
    final container = await _makeContainerWithAppliance(
      tester,
      extra: [rpiApiServiceProvider.overrideWithValue(null)],
    );
    await tester.pumpWidget(_buildScreen(container));
    await tester.pump();

    // 내부 이름(RPi·URL)을 사용자에게 말하지 않는다.
    expect(find.text('본체와 아직 연결되지 않았어요'),
        findsOneWidget);
    expect(find.textContaining('RPi'), findsNothing);
    expect(find.textContaining('URL'), findsNothing);
  });

  testWidgets('RPi URL이 있으면 선택된 가전의 버튼 그리드를 보여준다', (tester) async {
    final client = MockClient((_) async => http.Response('{}', 200));
    final api = RpiApiService('http://rpi5.local:8000', client: client);
    final container = await _makeContainerWithAppliance(
      tester,
      extra: [rpiApiServiceProvider.overrideWithValue(api)],
    );

    await tester.pumpWidget(_buildScreen(container));
    await tester.pump();

    // 어느 가전인지가 본문 머리에 온다(사진/실루엣 + 이름).
    expect(find.text('테스트가전'), findsOneWidget);
    // 설명은 한 줄 하나(평가 7차 10/18).
    expect(findPlainText(kManualHint), findsOneWidget);
    expect(find.text('켜기'), findsOneWidget);
    expect(find.text('끄기'), findsOneWidget);
    // 서버 가전 목록 조회의 완료가 남긴 0초 타이머를 비운다.
    await tester.pump(Duration.zero);
  });

  http.Response jsonRes(Object body) => http.Response.bytes(
        utf8.encode(jsonEncode(body)),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );

  testWidgets('버튼을 탭하면 /execute-buttons 접수 후 /status 완료로 성공 표시된다', (tester) async {
    http.Request? captured;
    final client = MockClient((request) async {
      if (request.url.path == '/execute-buttons') {
        captured = request;
        return jsonRes({'job_id': 'job-m1', 'status': 'accepted'});
      }
      // job 완료 상태 — _waitJobDone이 last_job_id 대조로 성공 판정
      return jsonRes({
        'running': false,
        'last_status': 'succeeded',
        'last_buttons': [
          {'button': '켜기', 'success': true},
        ],
        'last_job_id': 'job-m1',
      });
    });
    final api = RpiApiService('http://rpi5.local:8000', client: client);
    final container = await _makeContainerWithAppliance(
      tester,
      extra: [rpiApiServiceProvider.overrideWithValue(api)],
    );

    await tester.pumpWidget(_buildScreen(container));
    await tester.pump();

    await tester.tap(find.text('켜기'));
    await tester.pump(); // 접수 요청 발송
    await tester.pump(const Duration(milliseconds: 1100)); // 첫 상태 폴링(공용 실행 상태, 1초)
    await tester.pump();

    expect(jsonDecode(captured!.body), {
      'buttons': ['켜기'],
      'appliance_id': 'custom_test',
      'client_request_id': matches(RegExp(r'^[A-Za-z0-9_-]{1,64}$')), // 요청 번호(검토 10/19)
    });
    expect(find.byIcon(Icons.check), findsOneWidget);
    // 셀 색만이 아니라 문장으로도 말한다. 확인 근거가 없으면(실행 환경·확인 수준 모름) 눌림을 확인했다고 하지 않는다(2026-10-15).
    expect(find.text("'켜기' 누름 장치가 눌렀다고 알려 왔어요. 가전은 집에서 확인해야 해요"), findsOneWidget);

    // 2초 뒤 결과 표시가 사라진다.
    await tester.pump(const Duration(seconds: 3));
    expect(find.byIcon(Icons.check), findsNothing);
  });

  // 검토 10/19(11): 정한 시간 안에 내 결과를 못 보면 실패로 보이고 버튼이 풀려, 아직 돌거나 이미 눌린 버튼을
  // 한 번 더 누를 수 있었다. 이제 '아직 모름'으로 남겨 계속 보고, 같은 버튼은 확인을 받은 뒤에만 다시 보낸다.
  testWidgets('결과를 못 기다리면 모름으로 남기고, 같은 버튼은 확인 뒤에만 다시 보낸다', (tester) async {
    var executeCallCount = 0;
    var finished = false;
    final client = MockClient((request) async {
      if (request.url.path == '/execute-buttons') {
        executeCallCount++;
        return jsonRes({'job_id': 'job-t$executeCallCount', 'status': 'accepted'});
      }
      if (finished) {
        return jsonRes({
          'running': false,
          'last_status': 'succeeded',
          'last_buttons': [
            {'button': '켜기', 'success': true},
          ],
          'last_job_id': 'job-t$executeCallCount',
        });
      }
      return jsonRes({'running': true, 'job_id': 'job-t1'});
    });
    final api = RpiApiService('http://rpi5.local:8000', client: client);
    final container = await _makeContainerWithAppliance(
      tester,
      extra: [rpiApiServiceProvider.overrideWithValue(api)],
    );

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: ManualControlScreen(resultWait: Duration.zero)),
    ));
    await tester.pump();

    await tester.tap(find.text('켜기'));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10)); // 기다림 시간(0)이 지나 모름으로
    expect(executeCallCount, 1);
    expect(find.text("'켜기' 아직 결과를 몰라요. 같은 버튼을 다시 누르면 두 번 눌릴 수 있어요"), findsOneWidget);
    expect(find.byIcon(Icons.cancel_outlined), findsNothing, reason: '모름을 실패로 보이지 않는다');

    // 같은 버튼 — 묻고, 그만두면 보내지 않는다.
    await tester.tap(find.text('켜기'));
    await tester.pump();
    expect(find.text('다시 누를까요?'), findsOneWidget);
    await tester.tap(find.text('그만두기'));
    await tester.pump();
    expect(executeCallCount, 1);

    // 계속 지켜보다 결과가 오면 그 결과를 말한다.
    finished = true;
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(find.text("'켜기' 누름 장치가 눌렀다고 알려 왔어요. 가전은 집에서 확인해야 해요"), findsOneWidget);

    // 결과를 안 뒤에는 묻지 않는다.
    await tester.pump(const Duration(seconds: 3)); // 셀 결과 표지가 걷힌다
    finished = false;
    await tester.tap(find.text('켜기'));
    await tester.pump();
    expect(find.text('다시 누를까요?'), findsNothing);
    expect(executeCallCount, 2);
    finished = true;
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('실행 중에는 다른 버튼 탭이 무시된다', (tester) async {
    var executeCallCount = 0;
    final client = MockClient((request) async {
      if (request.url.path == '/execute-buttons') {
        executeCallCount++;
        await Future<void>.delayed(const Duration(milliseconds: 100));
        return jsonRes({'job_id': 'job-m2', 'status': 'accepted'});
      }
      return jsonRes({
        'running': false,
        'last_status': 'succeeded',
        'last_buttons': [
          {'button': '켜기', 'success': true},
        ],
        'last_job_id': 'job-m2',
      });
    });
    final api = RpiApiService('http://rpi5.local:8000', client: client);
    final container = await _makeContainerWithAppliance(
      tester,
      extra: [rpiApiServiceProvider.overrideWithValue(api)],
    );

    await tester.pumpWidget(_buildScreen(container));
    await tester.pump();

    await tester.tap(find.text('켜기'));
    await tester.pump(const Duration(milliseconds: 10));
    // 첫 실행이 아직 진행 중일 때 다른 버튼을 탭 — 무시되어야 함.
    await tester.tap(find.text('끄기'));
    await tester.pump(const Duration(milliseconds: 200)); // 접수 응답 도착
    await tester.pump(const Duration(milliseconds: 1100)); // 완료 폴링(공용 실행 상태, 1초)
    await tester.pump(const Duration(seconds: 3)); // 결과 표시 타이머 정리

    expect(executeCallCount, 1);
  });

  // 2026-10-15 키오스크 문구 개선 안 A: 눌림을 확인했다고는 실제 실행에서 눌림·동작을 확인했을 때만 말한다.
  for (final (mode, confirmation, sentence) in [
    ('real', 'press_confirmed', "'켜기' 눌린 것을 확인했어요"),
    ('mock', 'press_confirmed', "'켜기' 연습으로 눌렀어요. 실제 가전은 누르지 않았어요"),
    ('real', 'reported', "'켜기' 누름 장치가 눌렀다고 알려 왔어요. 가전은 집에서 확인해야 해요"),
  ]) {
    testWidgets('결과 한 줄은 확인한 만큼 — $mode · $confirmation', (tester) async {
      final client = MockClient((request) async {
        if (request.url.path == '/execute-buttons') {
          return jsonRes({'job_id': 'job-w1', 'status': 'accepted'});
        }
        return jsonRes({
          'running': false,
          'last_status': 'succeeded',
          'last_execution_mode': mode,
          'last_confirmation': confirmation,
          'last_buttons': [
            {'button': '켜기', 'success': true},
          ],
          'last_job_id': 'job-w1',
        });
      });
      final api = RpiApiService('http://rpi5.local:8000', client: client);
      final container = await _makeContainerWithAppliance(
        tester,
        extra: [rpiApiServiceProvider.overrideWithValue(api)],
      );
      await tester.pumpWidget(_buildScreen(container));
      await tester.pump();
      await tester.tap(find.text('켜기'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1100)); // 공용 실행 상태의 첫 조회(1초)
      await tester.pump();
      expect(find.text(sentence), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });
  }
  // 검토 10/19(12): 결과를 last_status만 보고 갈라, 사람이 멈춘 것·스스로 멈춘 것도 같은 빨간 '눌렸는지 몰라요'였다.
  for (final (outcome, status, sentence) in [
    ('stopped', 'safety_stopped', "'켜기' 멈추라고 해서 멈췄어요. 눌렸는지는 가전을 보고 확인해 주세요"),
    ('safety_stop', 'safety_stopped', "'켜기' 눌렸는지 확인이 안 돼 스스로 멈췄어요. 가전을 보고 확인해 주세요"),
    ('failed', 'failed', "'켜기' 하지 못했어요. 눌렸는지는 집에서 가전을 확인해야 해요"),
    ('unconfirmed', 'unconfirmed', "'켜기' 보냈지만 눌렸는지 확인하지 못했어요. 집에서 가전을 확인해야 해요"),
  ]) {
    testWidgets('끝난 결과는 last_outcome으로 가른다 — $outcome', (tester) async {
      final client = MockClient((request) async {
        if (request.url.path == '/execute-buttons') {
          return jsonRes({'job_id': 'job-k1', 'status': 'accepted'});
        }
        return jsonRes({
          'running': false,
          'last_status': status,
          'last_outcome': outcome,
          'last_job_id': 'job-k1',
        });
      });
      final api = RpiApiService('http://rpi5.local:8000', client: client);
      final container = await _makeContainerWithAppliance(
        tester,
        extra: [rpiApiServiceProvider.overrideWithValue(api)],
      );
      await tester.pumpWidget(_buildScreen(container));
      await tester.pump();
      await tester.tap(find.text('켜기'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1100)); // 공용 실행 상태의 첫 조회(1초)
      await tester.pump();
      expect(find.text(sentence), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(seconds: 4)); // 멈춤 결과의 정지 단계 후속 조회
    });
  }
  // 검토 10/19(2): 접수 응답이 사라지면(본체는 받아 누르기 시작했을 수 있다) '못 함'으로 보이고 버튼이 풀려, 같은 버튼을
  // 확인 없이 또 보낼 수 있었고 정지도 남지 않았다.
  testWidgets('접수 답이 사라지면 모름으로 두고 같은 버튼은 확인 뒤에만, 정지는 남긴다', (tester) async {
    var executeCallCount = 0;
    var stops = 0;
    final client = MockClient((request) async {
      if (request.url.path == '/execute-buttons') {
        executeCallCount++;
        throw http.ClientException('응답 유실');
      }
      if (request.url.path == '/stop') {
        stops++;
        return jsonRes({'ok': true});
      }
      return jsonRes({'running': false});
    });
    final api = RpiApiService('http://rpi5.local:8000', client: client);
    final container = await _makeContainerWithAppliance(
      tester,
      extra: [rpiApiServiceProvider.overrideWithValue(api)],
    );
    await tester.pumpWidget(_buildScreen(container));
    await tester.pump();

    await tester.tap(find.text('켜기'));
    await tester.pump();
    await tester.pump();
    expect(executeCallCount, 1);
    expect(find.text("'켜기' 아직 결과를 몰라요. 같은 버튼을 다시 누르면 두 번 눌릴 수 있어요"), findsOneWidget);
    expect(find.byIcon(Icons.cancel_outlined), findsNothing, reason: '모름을 못 함으로 보이지 않는다');
    expect(container.read(executionStatusProvider).phase, ExecutionPhase.unknown,
        reason: '정지 띠·음성 정지가 남는 단계');

    await tester.tap(find.text('켜기'));
    await tester.pump();
    expect(find.text('다시 누를까요?'), findsOneWidget);
    await tester.tap(find.text('그만두기'));
    await tester.pump();
    expect(executeCallCount, 1);

    await container.read(executionStatusProvider.notifier).emergencyStop();
    expect(stops, 1, reason: '그 본체로 정지를 보낸다');
    await tester.pump(const Duration(seconds: 16)); // 상태 확인 차례를 다 쓴다
  });

  // 검토 10/19(core6 9): 접수 답을 잃은 누름은 공용 상태가 요청 번호로 그 실행을 찾아 끝내도 이 화면의 '다시 누를까요?'
  // 잠금이 풀리지 않았다(이 화면은 그 결과를 보지 않았다).
  testWidgets('접수 답을 잃은 누름도 공용 상태가 요청 번호로 찾아 끝내면 결과를 말하고 잠금을 거둔다', (tester) async {
    var executeCallCount = 0;
    final client = MockClient((request) async {
      final path = request.url.path;
      if (path == '/execute-buttons') {
        executeCallCount++;
        if (executeCallCount == 1) throw http.ClientException('응답 유실');
        return jsonRes({'job_id': 'job-r2', 'status': 'accepted'});
      }
      if (path.startsWith('/jobs/by-request/')) {
        return jsonRes({'client_request_id': path.substring('/jobs/by-request/'.length), 'job_id': 'job-r1'});
      }
      return jsonRes({
        'running': false,
        'last_status': 'succeeded',
        'last_buttons': [
          {'button': '켜기', 'success': true},
        ],
        'last_job_id': executeCallCount == 1 ? 'job-r1' : 'job-r2',
      });
    });
    final api = RpiApiService('http://rpi5.local:8000', client: client);
    final container = await _makeContainerWithAppliance(
      tester,
      extra: [rpiApiServiceProvider.overrideWithValue(api)],
    );
    await tester.pumpWidget(_buildScreen(container));
    await tester.pump();

    await tester.tap(find.text('켜기'));
    await tester.pump();
    await tester.pump();
    expect(find.text("'켜기' 아직 결과를 몰라요. 같은 버튼을 다시 누르면 두 번 눌릴 수 있어요"), findsOneWidget);

    // 공용 상태가 요청 번호로 실행을 찾고(1초), 그 실행의 끝을 본다(1초).
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 600));
    }
    expect(container.read(executionStatusProvider).phase, ExecutionPhase.completed);
    expect(find.text("'켜기' 누름 장치가 눌렀다고 알려 왔어요. 가전은 집에서 확인해야 해요"), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
    await tester.tap(find.text('켜기'));
    await tester.pump();
    expect(find.text('다시 누를까요?'), findsNothing, reason: '결과를 안 뒤에는 묻지 않는다');
    expect(executeCallCount, 2);
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 3));
  });

  // 검토 10/19(core6 10): 이 화면이 공용 상태와 따로 같은 job을 0.5초마다 또 묻고, 45초 뒤에는 2초마다 기한 없이 물어
  // 본체가 잊은 job은 화면이 열려 있는 동안 끝없이 물었다. 이제 묻는 것은 공용 상태 하나이고, 그 상태가 끝을 정한다.
  testWidgets('결과를 모르는 누름도 화면이 따로 끝없이 묻지 않는다', (tester) async {
    var polls = 0;
    final client = MockClient((request) async {
      if (request.url.path == '/execute-buttons') {
        return jsonRes({'job_id': 'job-gone', 'status': 'accepted'});
      }
      final path = request.url.path;
      if (path == '/status' || path.startsWith('/jobs/')) polls++;
      return jsonRes({'running': false}); // 본체가 이 job을 잊었다(재시작 등)
    });
    final api = RpiApiService('http://rpi5.local:8000', client: client);
    final container = await _makeContainerWithAppliance(
      tester,
      extra: [rpiApiServiceProvider.overrideWithValue(api)],
    );
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: ManualControlScreen(resultWait: Duration(seconds: 5))),
    ));
    await tester.pump();
    await tester.tap(find.text('켜기'));
    await tester.pump();
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(polls, lessThanOrEqualTo(7), reason: '1초에 한 번(공용 상태)만 묻는다 — 첫 번은 job 조회가 없어 상태로 한 번 더');
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(container.read(executionStatusProvider).phase, ExecutionPhase.unknown);
    final settled = polls;
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(polls, settled, reason: '모름으로 끝난 뒤에는 더 묻지 않는다');
    expect(find.text("'켜기' 아직 결과를 몰라요. 같은 버튼을 다시 누르면 두 번 눌릴 수 있어요"), findsOneWidget);
  });

  // 검토 10/19(core7 3): 같은 버튼 다시 보냄 잠금이 화면 안에만 있어, 화면을 나갔다 다시 들어오면 아직 모르는 누름의 같은
  // 버튼을 확인 없이 새 요청 번호로 또 보냈다(켜기·끄기 버튼이면 두 번 눌린다). 잠금은 공용 실행 상태에서 읽는다.
  testWidgets('화면을 나갔다 다시 들어와도 결과를 모르는 같은 버튼은 확인 뒤에만 보낸다', (tester) async {
    var executeCallCount = 0;
    final client = MockClient((request) async {
      if (request.url.path == '/execute-buttons') {
        executeCallCount++;
        throw http.ClientException('응답 유실');
      }
      return jsonRes({'running': false});
    });
    final api = RpiApiService('http://rpi5.local:8000', client: client);
    final container = await _makeContainerWithAppliance(
      tester,
      extra: [rpiApiServiceProvider.overrideWithValue(api)],
    );
    await tester.pumpWidget(_buildScreen(container));
    await tester.pump();
    await tester.tap(find.text('켜기'));
    await tester.pump();
    await tester.pump();
    expect(executeCallCount, 1);
    expect(container.read(executionStatusProvider).phase, ExecutionPhase.unknown);

    // 화면을 나갔다가 다시 들어온다 — 새 화면 상태.
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: SizedBox()),
    ));
    await tester.pumpWidget(_buildScreen(container));
    await tester.pump();
    expect(find.text("'켜기' 아직 결과를 몰라요. 같은 버튼을 다시 누르면 두 번 눌릴 수 있어요"), findsOneWidget,
        reason: '왜 묻는지 다시 들어와서도 말한다');

    await tester.tap(find.text('켜기'));
    await tester.pump();
    expect(find.text('다시 누를까요?'), findsOneWidget);
    await tester.tap(find.text('그만두기'));
    await tester.pump();
    expect(executeCallCount, 1, reason: '그만두면 보내지 않는다');
    await tester.pump(const Duration(seconds: 16)); // 상태 확인 차례를 다 쓴다
  });

  testWidgets('다시 들어왔을 때 앞 누름의 접수 답을 기다리는 중이면 버튼을 잠근다', (tester) async {
    var executeCallCount = 0;
    final client = MockClient((request) async {
      if (request.url.path == '/execute-buttons') executeCallCount++;
      return jsonRes({'running': false});
    });
    final api = RpiApiService('http://rpi5.local:8000', client: client);
    final container = await _makeContainerWithAppliance(
      tester,
      extra: [rpiApiServiceProvider.overrideWithValue(api)],
    );
    // 앞 화면이 보내고 접수 답을 기다리는 중에 나갔다.
    container.read(executionStatusProvider.notifier).beginSubmitting(api: api, label: '켜기', steps: ['켜기']);
    await tester.pumpWidget(_buildScreen(container));
    await tester.pump();

    await tester.tap(find.text('끄기'));
    await tester.pump();
    expect(executeCallCount, 0, reason: '늦은 답이 새 실행과 정지 대상을 엇갈리게 한다');
  });
}
