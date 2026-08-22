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
