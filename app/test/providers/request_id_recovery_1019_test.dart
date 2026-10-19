// 검토 10/19(core5 3): 접수 답을 잃은 실행은 요청 번호(client_request_id)로 본체에 '내 실행'을 묻는다 — 그냥 돌고 있는 실행은
// 자동 실행·다른 단말의 것일 수 있어 따라가지 않는다(엉뚱한 결과를 보이고 정지로 남의 실행을 멈췄다). 옛 본체는 종전 방식.
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

  /// 다른 실행(job-other)이 돌고 있는 본체. [byRequest]가 by-request 조회의 답.
  RpiApiService hub(http.Response Function(String id) byRequest, {List<String>? paths}) =>
      RpiApiService('http://rpi5.local:8000', client: MockClient((request) async {
        final path = request.url.path;
        paths?.add(path);
        if (path.startsWith('/jobs/by-request/')) {
          return byRequest(path.substring('/jobs/by-request/'.length));
        }
        if (path == '/status') return _json({'running': true, 'job_id': 'job-other'});
        if (path == '/stop') return _json({'ok': true});
        return _json({'detail': 'Not Found'}, 404);
      }));

  /// 보내는 중 → 답 없음(모름)까지. 요청 번호를 돌려준다.
  String submitUnknown(ProviderContainer c, RpiApiService api) {
    final n = c.read(executionStatusProvider.notifier);
    final id = n.beginSubmitting(api: api, label: '켜기');
    n.beginSubmissionUnknown(api: api, label: '켜기', requestId: id, byRequest: true);
    expect(c.read(executionStatusProvider).phase, ExecutionPhase.unknown);
    return id;
  }

  test('본체가 그 요청 번호로 접수한 실행을 따라가고, 돌고 있는 다른 실행은 따라가지 않는다', () async {
    final asked = <String>[];
    final api = hub((id) {
      asked.add(id);
      return _json({'client_request_id': id, 'job_id': 'job-mine'});
    });
    final c = make(api);
    final id = submitUnknown(c, api);
    await Future<void>.delayed(const Duration(milliseconds: 1300));
    expect(asked, [id], reason: '보낸 요청 번호 그대로 묻는다');
    final s = c.read(executionStatusProvider);
    expect(s.sequenceId, 'job-mine');
    expect(s.phase, ExecutionPhase.running);
  });

  test('본체가 그 번호를 모르면(접수 안 함) 못 함으로 알리고 돌고 있는 다른 실행을 잡지 않는다', () async {
    final api = hub((_) => _json({'detail': 'no job for this client_request_id'}, 404));
    final c = make(api);
    submitUnknown(c, api);
    await Future<void>.delayed(const Duration(milliseconds: 1300));
    final s = c.read(executionStatusProvider);
    expect(s.sequenceId, isNot('job-other'));
    expect(s.phase, ExecutionPhase.failed);
    expect(s.message, ExecutionStatusNotifier.submissionNotAcceptedNotice);
  });

  test('조회가 계속 답하지 않아도 돌고 있는 다른 실행을 잡지 않는다 — 모름과 정지를 남긴다', () async {
    final paths = <String>[];
    final api = hub((_) => throw http.ClientException('끊김'), paths: paths);
    final c = make(api);
    submitUnknown(c, api);
    await Future<void>.delayed(const Duration(milliseconds: 3300));
    final s = c.read(executionStatusProvider);
    expect(s.sequenceId, isNot('job-other'));
    expect(s.phase, ExecutionPhase.unknown);
    expect(paths.where((p) => p == '/status'), isEmpty, reason: '새 본체 경로에서는 상태로 추정하지 않는다');
    await c.read(executionStatusProvider.notifier).emergencyStop();
    expect(paths, contains('/stop'), reason: '정지는 남는다');
  });

  test('옛 본체(조회 경로 없음)는 종전처럼 상태의 돌고 있는 실행을 이어서 본다', () async {
    final api = hub((_) => _json({'detail': 'Not Found'}, 404));
    final c = make(api);
    submitUnknown(c, api);
    await Future<void>.delayed(const Duration(milliseconds: 1300));
    expect(c.read(executionStatusProvider).sequenceId, 'job-other');
  });

  group('요청 번호 싣기', () {
    late List<http.Request> sent;
    RpiApiService api() => RpiApiService('http://rpi5.local:8000', client: MockClient((r) async {
          sent.add(r);
          return _json({'job_id': 'job-1', 'status': 'accepted'});
        }));
    setUp(() => sent = []);
    Map<String, dynamic> body(int i) => jsonDecode(sent[i].body) as Map<String, dynamic>;

    test('승인·말·버튼·가전 말 모두 client_request_id를 싣는다', () async {
      final a = api();
      await a.approveSuggestion('sug-1', clientRequestId: 'app-1');
      await a.execute('켜 줘', clientRequestId: 'app-2');
      await a.executeButtons(['전원'], clientRequestId: 'app-3');
      await a.executeForAppliance('켜 줘', ['전원'], clientRequestId: 'app-4');
      expect([for (var i = 0; i < 4; i++) body(i)['client_request_id']], ['app-1', 'app-2', 'app-3', 'app-4']);
      expect(sent.first.headers['content-type'], contains('application/json'));
    });

    test('번호가 없으면 종전 그대로(승인은 본문 없음)', () async {
      final a = api();
      await a.approveSuggestion('sug-1');
      await a.execute('켜 줘');
      expect(sent[0].body, isEmpty);
      expect(body(1).containsKey('client_request_id'), isFalse);
    });

    test('by-request — 찾음·모름(새 본체 404)·없음(옛 본체 404)을 가른다', () async {
      Future<RpiRequestLookup> ask(http.Response res) =>
          RpiApiService('http://rpi5.local:8000', client: MockClient((_) async => res)).jobByRequest('app-1');
      final found = await ask(_json({'client_request_id': 'app-1', 'job_id': 'job-9'}));
      expect(found.kind, RpiRequestLookupKind.found);
      expect(found.jobId, 'job-9');
      expect((await ask(_json({'detail': 'no job for this client_request_id'}, 404))).kind,
          RpiRequestLookupKind.unknown);
      expect((await ask(_json({'detail': 'Not Found'}, 404))).kind, RpiRequestLookupKind.unsupported);
      expect((await ask(_json({'running': false}))).kind, RpiRequestLookupKind.unsupported,
          reason: '이 조회의 답 모양이 아니면 옛 본체로 본다');
    });
  });
}
