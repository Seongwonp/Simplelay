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
  group('RpiApiService.executeButtons', () {
    test('POST /execute-buttons에 버튼 목록을 보내고 결과를 파싱한다', () async {
      http.Request? captured;
      final client = MockClient((request) async {
        captured = request;
        return _jsonResponse({
          'status': 'succeeded',
          'buttons': [
            {'button': '전원', 'success': true},
          ],
        }, 200);
      });
      final api = RpiApiService('http://rpi5.local:8000', client: client);

      final result = await api.executeButtons(['전원']);

      expect(captured!.method, 'POST');
      expect(captured!.url.path, '/execute-buttons');
      expect(jsonDecode(captured!.body), {
        'buttons': ['전원'],
      });
      expect(result.status, 'succeeded');
      expect(result.buttons.single.button, '전원');
      expect(result.buttons.single.success, true);
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
}
