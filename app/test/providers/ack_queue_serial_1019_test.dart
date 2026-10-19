// 검토 10/19(core5 7): 홈의 '못 한 일 봤다'와 기록 화면의 '실행 봤다'가 거의 함께 불리면, 둘 다 같은 옛 대기열을 읽고 서로 다른
// 목록을 저장해 늦게 저장한 쪽이 다른 확인을 지웠다. 보내는 중이면 뒤에 온 확인은 보내지도 않고 실패로 끝났다. 이제 대기열의
// 더하기·저장·보내기를 한 줄로 세운다.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/providers/care_events_provider.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/services/rpi_api_service.dart';

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
    utf8.encode(jsonEncode(body)), status,
    headers: {'content-type': 'application/json; charset=utf-8'});

final _failure = RpiCareEvent(
    id: 9, kind: 'execution_failed', message: '못 했어요', occurredAt: DateTime(2026, 10, 19, 9));

Future<Map<String, dynamic>?> _retry() async {
  final raw = (await SharedPreferences.getInstance()).getString('care_acks_retry');
  return raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  ProviderContainer make(Future<http.Response> Function(http.Request) postAcks) {
    final api = RpiApiService('http://rpi5.local:8000', client: MockClient((req) async {
      if (req.url.path == '/care-events') return _json(const []);
      if (req.url.path == '/acks' && req.method == 'GET') return _json({'care_seen_id': 0});
      if (req.url.path == '/acks' && req.method == 'POST') return postAcks(req);
      return _json({'detail': 'not found'}, 404);
    }));
    final c = ProviderContainer(overrides: [rpiApiServiceProvider.overrideWithValue(api)]);
    addTearDown(c.dispose);
    return c;
  }

  test('본체에 닿지 못할 때 거의 함께 남긴 두 확인이 모두 기기에 남는다', () async {
    final c = make((_) async => _json({'detail': 'down'}, 500));
    final n = c.read(careEventsProvider.notifier);
    await n.refresh();

    final failures = n.markFailuresSeen([_failure]); // 홈은 기다리지 않고 기록 화면으로 간다
    final jobs = n.markJobsSeen(['J1']);
    expect(await failures, isFalse);
    expect(await jobs, isFalse);

    final kept = await _retry();
    expect(kept?['failures_seen_id'], 9, reason: '뒤에 저장한 쪽이 앞의 확인을 지우지 않는다');
    expect(kept?['seen_job_ids'], ['J1']);
  });

  test('앞의 확인을 보내는 사이 더한 확인은 그 뒤에 이어서 보낸다', () async {
    final posts = <Map<String, dynamic>>[];
    final firstReply = Completer<void>();
    final c = make((req) async {
      posts.add(jsonDecode(req.body) as Map<String, dynamic>);
      if (posts.length == 1) await firstReply.future;
      return _json({'care_seen_id': 0, 'persisted': true});
    });
    final n = c.read(careEventsProvider.notifier);
    await n.refresh();

    final failures = n.markFailuresSeen([_failure]);
    await Future<void>.delayed(const Duration(milliseconds: 20)); // 첫 보내기가 본체 답을 기다리는 중
    final jobs = n.markJobsSeen(['J1']);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    firstReply.complete();

    expect(await failures, isTrue);
    expect(await jobs, isTrue, reason: '보내는 중이라고 버리지 않고 이어서 보낸다');
    expect(posts.any((p) => (p['seen_job_ids'] as List?)?.contains('J1') ?? false), isTrue);
    expect(await _retry(), isNull, reason: '본체가 저장한 확인은 모두 지운다');
  });
}
