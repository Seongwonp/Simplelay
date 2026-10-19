// 검토 10/19(core6 2·3): 늦게 온 옛 보냄의 답·실패가 새 보냄(과 그 정지 대상)을 덮지 않는다. 답을 모르는 보냄의 '다시
// 확인'도 처음처럼 요청 번호로 찾는다 — 그냥 돌고 있는 실행(자동 실행·다른 단말)을 내 실행으로 잡지 않는다.
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

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
    utf8.encode(jsonEncode(body)), status,
    headers: {'content-type': 'application/json; charset=utf-8'});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  ProviderContainer make(RpiApiService api) {
    final c = ProviderContainer(overrides: [rpiApiServiceProvider.overrideWithValue(api)]);
    addTearDown(c.dispose);
    return c;
  }

  RpiApiService hub({List<String>? paths}) =>
      RpiApiService('http://rpi5.local:8000', client: MockClient((request) async {
        final path = request.url.path;
        paths?.add(path);
        if (path.startsWith('/jobs/by-request/')) throw http.ClientException('끊김');
        if (path == '/status') return _json({'running': true, 'job_id': 'job-other'});
        return _json({'detail': 'Not Found'}, 404);
      }));

  test('늦게 온 옛 보냄의 접수 답은 새 보냄을 덮지 않는다', () {
    final api = hub();
    final c = make(api);
    final n = c.read(executionStatusProvider.notifier);
    final first = n.beginSubmitting(api: api, label: '켜기');
    final second = n.beginSubmitting(api: api, label: '끄기');
    n.beginHttpJob(api: api, jobId: 'job-first', label: '켜기', requestId: first);
    final s = c.read(executionStatusProvider);
    expect(s.sequenceId, 'submit-$second');
    expect(s.requestId, second);
    expect(n.admissionInFlight, isTrue);
  });

  test('늦게 온 옛 보냄의 답 없음은 보낸 적 없는 번호로 새 보냄을 덮지 않는다', () {
    final api = hub();
    final c = make(api);
    final n = c.read(executionStatusProvider.notifier);
    final first = n.beginSubmitting(api: api, label: '켜기');
    final second = n.beginSubmitting(api: api, label: '끄기');
    n.beginSubmissionUnknown(api: api, label: '켜기', requestId: first, byRequest: true);
    final s = c.read(executionStatusProvider);
    expect(s.phase, ExecutionPhase.waiting);
    expect(s.requestId, second);
    // 새 보냄의 답은 그대로 받는다.
    n.beginHttpJob(api: api, jobId: 'job-second', label: '끄기', requestId: second);
    expect(c.read(executionStatusProvider).sequenceId, 'job-second');
  });
}
