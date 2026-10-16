import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simplelay/services/rpi_api_service.dart';

http.Response _jsonResponse(Object body, int status) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

void main() {
  group('thinqPowerOn — 켜진 ThinQ 가전(2026-10-16)', () {
    RpiApiService api(int status, Object body) => RpiApiService('http://hub:8000',
        client: MockClient((req) async {
          expect(req.url.path, '/thinq/power');
          return http.Response.bytes(utf8.encode(jsonEncode(body)), status,
              headers: {'content-type': 'application/json; charset=utf-8'});
        }));

    test('power가 on인 가전만', () async {
      final on = await api(200, {
        'execution_mode': 'real',
        'appliances': [
          {'appliance_id': 'air_purifier', 'power': 'on', 'age_s': 3},
          {'appliance_id': 'dehumidifier', 'power': 'off', 'age_s': 3},
          {'appliance_id': 'x', 'power': null},
        ],
      }).thinqPowerOn();
      expect(on, {'air_purifier'});
    });

    test('ThinQ 꺼짐(404)·형식 오류는 빈 집합 — 켜짐을 지어내지 않는다', () async {
      expect(await api(404, {'detail': 'off'}).thinqPowerOn(), isEmpty);
      expect(await api(200, ['bad']).thinqPowerOn(), isEmpty);
      expect(await api(500, {'detail': 'boom'}).thinqPowerOn(), isEmpty);
    });
  });

  test('routine uses simulator paths, carries auth and never retries rejected approval', () async {
    final requests = <http.Request>[];
    final api = RpiApiService('http://localhost:8768', apiKey: 'test-key', client: MockClient((r) async {
      requests.add(r);
      expect(r.headers['X-API-Key'], 'test-key');
      return _jsonResponse({'execution_mode': 'mock'}, r.method == 'GET' ? 200 : 409);
    }));
    expect((await api.routineRequest(null))['execution_mode'], 'mock');
    final event = {'session': 'one', 'revision': 1, 'event': 'approve'};
    await expectLater(api.routineRequest(event), throwsStateError);
    expect(requests.map((r) => r.url.path), ['/simulator/routine/state', '/simulator/routine/event']);
    expect(jsonDecode(requests.last.body), event);
    api.dispose();
  });
  test('revision fetches choices then returns a new preview without approval', () async {
    final paths = <String>[];
    final api = RpiApiService('http://rpi5.local:8000', client: MockClient((request) async {
      paths.add(request.url.path);
      if (request.method == 'GET') {
        return _jsonResponse({'options': {'30초 돌려줘': ['30초', '시작']}}, 200);
      }
      expect(jsonDecode(request.body), {'purpose': '30초 돌려줘'});
      return _jsonResponse({'id': 'new', 'purpose': '30초 돌려줘', 'time_band': '아침',
        'occurrences': 0, 'steps': ['30초', '시작'], 'appliance_id': 'microwave'}, 200);
    }));
    expect((await api.revisionOptions('old'))['30초 돌려줘'], ['30초', '시작']);
    expect((await api.reviseSuggestion('old', '30초 돌려줘')).id, 'new');
    expect(paths, ['/suggestions/old/revision-options', '/suggestions/old/revise']);
  });

  test('snooze uses its own endpoint and propagates failure', () async {
    var status = 200;
    final client = MockClient((request) async {
      expect(request.method, 'POST');
      expect(request.url.path, '/suggestions/s1/snooze');
      return _jsonResponse({'ok': true}, status);
    });
    final api = RpiApiService('http://rpi5.local:8000', client: client);
    await api.snoozeSuggestion('s1');
    status = 503;
    await expectLater(api.snoozeSuggestion('s1'), throwsA(isA<RpiApiException>()));
  });

  group('RpiApiService.executeButtons (job 모델)', () {
    test('POST /execute-buttons에 버튼 목록을 보내고 job_id 접수 응답을 파싱한다', () async {
      http.Request? captured;
      final client = MockClient((request) async {
        captured = request;
        return _jsonResponse({'job_id': 'job-abc123', 'status': 'accepted'}, 200);
      });
      final api = RpiApiService('http://rpi5.local:8000', client: client);

      final accepted = await api.executeButtons(['전원']);

      expect(captured!.method, 'POST');
      expect(captured!.url.path, '/execute-buttons');
      expect(jsonDecode(captured!.body), {
        'buttons': ['전원'],
      });
      expect(accepted.jobId, 'job-abc123');
    });

    test('409(동시 실행 중)를 RpiApiException으로 던진다', () async {
      final client = MockClient((request) async {
        return _jsonResponse({'detail': 'an execution is already in progress'}, 409);
      });
      final api = RpiApiService('http://rpi5.local:8000', client: client);

      await expectLater(
        () => api.executeButtons(['전원']),
        throwsA(isA<RpiApiException>()),
      );
    });
  });

  group('RpiApiService.status (job 모델 필드)', () {
    test('job_id·last_job_id·total_steps·진행 필드를 파싱한다', () async {
      final client = MockClient((request) async {
        return _jsonResponse({
          'running': true,
          'last_status': null,
          'last_buttons': null,
          'current_button': '해동',
          'current_attempt': 2,
          'completed_steps': 1,
          'total_steps': 3,
          'job_id': 'job-live',
          'last_job_id': null,
        }, 200);
      });
      final api = RpiApiService('http://rpi5.local:8000', client: client);

      final status = await api.status();

      expect(status.running, true);
      expect(status.currentButton, '해동');
      expect(status.currentAttempt, 2);
      expect(status.completedSteps, 1);
      expect(status.totalSteps, 3);
      expect(status.jobId, 'job-live');
      expect(status.lastJobId, isNull);
    });

    test('완료 후에는 last_job_id로 내 실행의 결과를 대조할 수 있다', () async {
      final client = MockClient((request) async {
        return _jsonResponse({
          'running': false,
          'last_status': 'succeeded',
          'last_buttons': [
            {'button': '전원', 'success': true},
          ],
          'job_id': null,
          'last_job_id': 'job-done',
        }, 200);
      });
      final api = RpiApiService('http://rpi5.local:8000', client: client);

      final status = await api.status();

      expect(status.running, false);
      expect(status.lastJobId, 'job-done');
      expect(status.lastStatus, 'succeeded');
      expect(status.lastButtons!.single.button, '전원');
    });
  });

  // ── API 키 헤더 ─────────────────────────────────────────────────────────
  group('RpiApiService API 키', () {
    test('apiKey가 설정되면 모든 요청에 X-API-Key 헤더가 실린다', () async {
      http.Request? captured;
      final client = MockClient((request) async {
        captured = request;
        return _jsonResponse({'running': false}, 200);
      });
      final api = RpiApiService(
        'http://rpi5.local:8000',
        client: client,
        apiKey: 'secret-123',
      );

      await api.status();

      expect(captured!.headers['X-API-Key'], 'secret-123');
    });

    test('apiKey가 없으면 헤더를 싣지 않는다', () async {
      http.Request? captured;
      final client = MockClient((request) async {
        captured = request;
        return _jsonResponse({'running': false}, 200);
      });
      final api = RpiApiService('http://rpi5.local:8000', client: client);

      await api.status();

      expect(captured!.headers.containsKey('X-API-Key'), isFalse);
    });
  });
}
