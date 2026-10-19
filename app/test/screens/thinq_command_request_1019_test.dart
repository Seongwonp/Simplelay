// 검토 10/19(본체 thinq_router.py): ThinQ 직접 명령은 선택 client_request_id를 받아 같은 번호면 같은 job_id를 준다.
// 폰은 보내기 **전에** 공용 실행 상태를 '보내는 중'으로 두고(정지·다른 실행 막기) 요청 번호를 실어 보낸다. 답을 잃으면
// (시간 초과·끊김) 다시 보내지 않고 GET /jobs/by-request/{번호}로 본체가 받은 실행을 찾아 이어서 본다.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/appliance.dart';
import 'package:simplelay/models/execution_status.dart';
import 'package:simplelay/providers/clock_provider.dart';
import 'package:simplelay/providers/execution_status_provider.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/appliance_detail_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';

import '../helpers/test_helpers.dart';

const _purifier = ApplianceMap(
  id: 'air_purifier',
  name: '공기청정기',
  category: ApplianceCategory.other,
  rows: 0,
  cols: 0,
  buttons: [],
  controlPath: 'thinq',
  readiness: 'operable',
  readinessKnown: true,
);

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
    utf8.encode(jsonEncode(body)), status,
    headers: {'content-type': 'application/json'});

http.Response _state() => _json({
      'appliance_id': 'air_purifier',
      'execution_mode': 'real',
      'state': {
        'airPurifierJobMode': {'currentJobMode': 'CLEAN'},
        'operation': {'airPurifierOperationMode': 'POWER_ON'},
        'airFlow': {'windStrength': 'AUTO', 'windStrengthDetail': 'AUTO'},
      },
    });

class _Hub {
  _Hub({required this.command, this.byRequest});
  final FutureOr<http.Response> Function() command;
  final http.Response Function(String id)? byRequest;
  final commands = <Map<String, dynamic>>[];
  final paths = <String>[];

  RpiApiService service() => RpiApiService('http://rpi5.local:8000', client: MockClient((req) async {
        paths.add('${req.method} ${req.url.path}');
        if (req.url.path.startsWith('/thinq/status/')) return _state();
        if (req.method == 'POST' && req.url.path == '/thinq/command') {
          commands.add(jsonDecode(req.body) as Map<String, dynamic>);
          return await command();
        }
        if (req.url.path.startsWith('/jobs/by-request/') && byRequest != null) {
          return byRequest!(req.url.pathSegments.last);
        }
        if (req.url.path == '/jobs/job-7') {
          return _json({'running': true, 'finished': false, 'job_id': 'job-7'});
        }
        return _json({'detail': 'Not Found'}, 404);
      }));
}

Widget _detail(RpiApiService api) => buildWithRouter(
      '/detail',
      overrides: [
        ...connectedOverrides(),
        ...installedOverrides([_purifier]),
        rpiServerOverride(RpiConnectionState.connected),
        rpiApiServiceProvider.overrideWithValue(api),
        nowProvider.overrideWithValue(() => DateTime(2026, 10, 19, 9, 12, 5)),
      ],
      extraRoutes: {
        '/detail': (_) => const ApplianceDetailScreen(applianceId: 'air_purifier'),
      },
    );

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _sendHigh(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('thinq-set-set_wind_strength-HIGH')));
  await _settle(tester);
  await tester.tap(find.byKey(const Key('thinq-set-confirm')));
  await _settle(tester);
}

ExecutionStatus _execution(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(MaterialApp).first)).read(executionStatusProvider);

Future<void> _teardown(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  void tall(WidgetTester tester) {
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('보내기 전에 보내는 중으로 두고 그 요청 번호를 실어 보낸다', (tester) async {
    tall(tester);
    final pending = Completer<http.Response>();
    final hub = _Hub(command: () => pending.future);
    await tester.pumpWidget(_detail(hub.service()));
    await _settle(tester);

    await _sendHigh(tester);
    expect(hub.commands.length, 1);
    final id = hub.commands.single['client_request_id'];
    expect(id, isA<String>());
    final waiting = _execution(tester);
    expect(waiting.phase, ExecutionPhase.waiting, reason: '답을 기다리는 사이에도 정지를 남긴다');
    expect(waiting.requestId, id);

    pending.complete(_json({'job_id': 'job-7'}));
    await _settle(tester);
    expect(_execution(tester).sequenceId, 'job-7');
    expect(find.text('상태 화면'), findsOneWidget);
    await _teardown(tester);
  });

  testWidgets('답을 잃으면 다시 보내지 않고 같은 요청 번호로 본체가 받은 실행을 찾아 이어서 본다', (tester) async {
    tall(tester);
    final asked = <String>[];
    final hub = _Hub(
      command: () => throw http.ClientException('Connection closed'),
      byRequest: (id) {
        asked.add(id);
        return _json({'client_request_id': id, 'job_id': 'job-7'});
      },
    );
    await tester.pumpWidget(_detail(hub.service()));
    await _settle(tester);

    await _sendHigh(tester);
    await tester.pump(const Duration(seconds: 1));
    await _settle(tester);

    expect(hub.commands.length, 1, reason: '같은 명령을 다시 보내지 않는다');
    expect(asked, [hub.commands.single['client_request_id']]);
    expect(_execution(tester).sequenceId, 'job-7');
    expect(find.text('상태 화면'), findsOneWidget);
    await _teardown(tester);
  });

  testWidgets('본체가 그 요청 번호를 모르면 받지 않았다고 말한다', (tester) async {
    tall(tester);
    final hub = _Hub(
      command: () => throw http.ClientException('Connection closed'),
      byRequest: (_) => _json({'detail': 'no job for this client_request_id'}, 404),
    );
    await tester.pumpWidget(_detail(hub.service()));
    await _settle(tester);

    await _sendHigh(tester);
    await tester.pump(const Duration(seconds: 1));
    await _settle(tester);

    expect(hub.commands.length, 1);
    final s = _execution(tester);
    expect(s.phase, ExecutionPhase.failed);
    expect(s.message, ExecutionStatusNotifier.submissionNotAcceptedNotice);
    await _teardown(tester);
  });

  testWidgets('본체가 거절하면 보내기 전 상태로 되돌리고 이유를 말한다', (tester) async {
    tall(tester);
    final hub = _Hub(command: () => _json({'detail': '비상 정지 중이에요 — 해제한 뒤 다시 해 주세요'}, 423));
    await tester.pumpWidget(_detail(hub.service()));
    await _settle(tester);

    await _sendHigh(tester);
    expect(find.textContaining('비상 정지 중이에요'), findsOneWidget);
    expect(_execution(tester).phase, ExecutionPhase.idle);
    expect(find.text('상태 화면'), findsNothing);
  });
}
