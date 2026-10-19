// 검토 10/19(11): 기록 화면의 '봤다'를 보내기 전에 지워, 보내기가 실패하면 그 확인이 사라졌다. 본체가 저장하지 못했다고
// 답해도(persisted: false) 그대로 끝났다. 이제 보내기 전에 기기에 남기고, 본체가 저장했다고 답한 뒤에만 지운다.
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

class _Hub {
  /// POST /acks의 답 — 'down'(500) · 'session'(persisted: false) · 'ok'.
  String mode = 'ok';
  final posts = <Map<String, dynamic>>[];

  RpiApiService api() => RpiApiService('http://rpi5.local:8000', client: MockClient((req) async {
        final path = req.url.path;
        if (path == '/care-events') return _json(const []);
        if (path == '/acks' && req.method == 'GET') return _json({'care_seen_id': 0});
        if (path == '/acks' && req.method == 'POST') {
          if (mode == 'down') return _json({'detail': 'boom'}, 500);
          posts.add(jsonDecode(req.body) as Map<String, dynamic>);
          return _json({'care_seen_id': 0, 'persisted': mode != 'session'});
        }
        return _json({'detail': 'not found'}, 404);
      }));
}

Future<List<String>?> _retryJobs() async {
  final raw = (await SharedPreferences.getInstance()).getString('care_acks_retry');
  if (raw == null) return null;
  return [for (final id in (jsonDecode(raw) as Map)['seen_job_ids'] as List? ?? const []) id as String];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  ProviderContainer make(_Hub hub) {
    final c = ProviderContainer(overrides: [rpiApiServiceProvider.overrideWithValue(hub.api())]);
    addTearDown(c.dispose);
    return c;
  }

  test('보내기가 실패한 확인은 기기에 남아 다음 조회 때 다시 보내고, 저장됐다는 답 뒤에 지운다', () async {
    final hub = _Hub()..mode = 'down';
    final c = make(hub);
    final n = c.read(careEventsProvider.notifier);
    await n.refresh();

    expect(await n.markJobsSeen(['J1', 'J2']), isFalse);
    expect(await _retryJobs(), ['J1', 'J2']);

    hub.mode = 'ok';
    await n.refresh();
    expect(hub.posts.last['seen_job_ids'], ['J1', 'J2']);
    expect(await _retryJobs(), isNull);
  });

  test("본체가 'persisted: false'로 답하면 남겨 두었다가 다시 보낸다", () async {
    final hub = _Hub()..mode = 'session';
    final c = make(hub);
    final n = c.read(careEventsProvider.notifier);
    await n.refresh();

    expect(await n.markJobsSeen(['J7']), isTrue, reason: '본체는 이번 세션에 적용했다');
    expect(hub.posts, hasLength(1));
    expect(await _retryJobs(), ['J7']);

    hub.mode = 'ok';
    await n.refresh();
    expect(hub.posts, hasLength(2));
    expect(hub.posts.last['seen_job_ids'], ['J7']);
    expect(await _retryJobs(), isNull);
  });
}
