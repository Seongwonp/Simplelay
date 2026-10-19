// 검토 10/19(2·3): 접수 응답을 잃은 실행 — 모름으로 두고 정지를 남기고, 같은 요청 재질의·상태로 그 실행을 찾는다.
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/execution_status.dart';
import 'package:simplelay/providers/execution_status_provider.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/services/rpi_api_service.dart';

http.Response _json(Object body) => http.Response.bytes(utf8.encode(jsonEncode(body)), 200,
    headers: {'content-type': 'application/json; charset=utf-8'});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  ProviderContainer make(RpiApiService api) {
    final c = ProviderContainer(overrides: [rpiApiServiceProvider.overrideWithValue(api)]);
    addTearDown(c.dispose);
    return c;
  }

  test('돌고 있는 실행이 보이면 그 실행을 이어서 본다', () async {
    var running = false;
    final api = RpiApiService('http://rpi5.local:8000', client: MockClient((request) async {
      if (request.url.path == '/status') {
        return _json(running ? {'running': true, 'job_id': 'job-late'} : {'running': false});
      }
      return _json({'ok': true});
    }));
    final c = make(api);
    final n = c.read(executionStatusProvider.notifier);
    n.beginSubmissionUnknown(api: api, label: '켜기');
    expect(c.read(executionStatusProvider).phase, ExecutionPhase.unknown);
    expect(c.read(executionStatusProvider).message, ExecutionStatusNotifier.submissionUnknownNotice);

    await Future<void>.delayed(const Duration(milliseconds: 1300));
    expect(c.read(executionStatusProvider).phase, ExecutionPhase.unknown);
    running = true;
    await Future<void>.delayed(const Duration(milliseconds: 1300));
    final s = c.read(executionStatusProvider);
    expect(s.sequenceId, 'job-late');
    expect(s.phase, ExecutionPhase.running);
  });

  test('같은 요청을 다시 물어 받은 job_id를 이어서 본다', () async {
    var asked = 0;
    final api = RpiApiService('http://rpi5.local:8000',
        client: MockClient((request) async => _json({'running': false})));
    final c = make(api);
    c.read(executionStatusProvider.notifier).beginSubmissionUnknown(
        api: api,
        label: '저녁',
        recoverJobId: () async {
          asked++;
          return 'job-same';
        });
    await Future<void>.delayed(const Duration(milliseconds: 1300));
    expect(asked, 1);
    expect(c.read(executionStatusProvider).sequenceId, 'job-same');
    expect(c.read(executionStatusProvider).phase, ExecutionPhase.running);
  });

  test('본체가 거절하면 다시 묻지 않고, 정지는 남는다', () async {
    var asked = 0;
    var stops = 0;
    final api = RpiApiService('http://rpi5.local:8000', client: MockClient((request) async {
      if (request.url.path == '/stop') stops++;
      return _json({'running': false});
    }));
    final c = make(api);
    final n = c.read(executionStatusProvider.notifier);
    n.beginSubmissionUnknown(
        api: api,
        label: '저녁',
        recoverJobId: () async {
          asked++;
          throw RpiApiException(409, '이미 승인한 제안이에요');
        });
    await Future<void>.delayed(const Duration(milliseconds: 3300));
    expect(asked, 1);
    expect(c.read(executionStatusProvider).phase, ExecutionPhase.unknown);
    await n.emergencyStop();
    expect(stops, 1);
    expect(c.read(executionStatusProvider).phase, ExecutionPhase.unknown);
  });
}
