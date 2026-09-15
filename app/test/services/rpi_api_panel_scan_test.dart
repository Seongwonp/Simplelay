import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simplelay/services/rpi_api_service.dart';

// FastAPI처럼 charset 없이 JSON을 보낸다 — res.body로 풀면 한글이 깨지는 조건.
http.Response _json(Object body, int status) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      status,
      headers: {'content-type': 'application/json'},
    );

const _draft = {
  'rows': 2,
  'cols': 3,
  'buttons': [
    {
      'id': 'B-01',
      'label': '해동',
      'x': 0,
      'y': 0,
      'kind': 'button',
      'box': [100.0, 100.0, 250.0, 180.0],
      'center': [175.0, 140.0],
      'label_from_model': true,
      'x_mm': null,
      'y_mm': null,
    },
    {
      'id': 'B-02',
      'label': '버튼 2',
      'x': 1,
      'y': 0,
      'kind': 'dial',
      'box': [400.0, 100.0, 550.0, 180.0],
      'center': [475.0, 140.0],
      'label_from_model': false,
    },
  ],
  'dropped': ["3번 항목: 알 수 없는 종류('lever')라 뺐어요"],
  'notes': ['인식 결과는 초안이에요'],
  'model': 'vision-model-x',
  'calibration': null,
};

void main() {
  group('RpiApiService.scanPanel', () {
    test('사진을 base64로 POST /panel-scan에 보내고 초안을 파싱한다', () async {
      http.Request? captured;
      final client = MockClient((request) async {
        captured = request;
        return _json(_draft, 200);
      });
      final api =
          RpiApiService('http://rpi5.local:8000', client: client, apiKey: 'k1');

      final draft = await api.scanPanel([0x89, 0x50, 0x4E, 0x47]);

      expect(captured!.method, 'POST');
      expect(captured!.url.path, '/panel-scan');
      expect(captured!.headers['X-API-Key'], 'k1');
      expect(jsonDecode(captured!.body), {'image_base64': 'iVBORw=='});
      expect((draft.rows, draft.cols), (2, 3));
      expect(draft.buttons.map((b) => b.label), ['해동', '버튼 2']);
      expect(draft.buttons[1].kind, 'dial');
      expect(draft.buttons[1].labelFromModel, isFalse);
      expect(draft.dropped.single, contains('lever'));
      expect(draft.model, 'vision-model-x');
    });

    test('서버 오류 문장(한글)을 깨지지 않게 그대로 전한다', () async {
      final client = MockClient((_) async => _json(
          {'detail': '사진 인식이 꺼져 있어요 — 서버에 인식 서비스 설정이 필요해요'}, 503));
      final api = RpiApiService('http://rpi5.local:8000', client: client);

      await expectLater(
        () => api.scanPanel([1]),
        throwsA(isA<RpiApiException>()
            .having((e) => e.statusCode, 'statusCode', 503)
            .having((e) => e.message, 'message', contains('꺼져 있어요'))),
      );
    });

    test('검증 오류(422) 목록에서 사람이 읽을 문장만 꺼낸다', () async {
      final client = MockClient((_) async => _json({
            'detail': [
              {
                'type': 'value_error',
                'loc': ['body', 'image_base64'],
                'msg': 'Value error, 사진이 너무 커요 (최대 8MB)',
              }
            ]
          }, 422));
      final api = RpiApiService('http://rpi5.local:8000', client: client);

      await expectLater(
        () => api.scanPanel([1]),
        throwsA(isA<RpiApiException>()
            .having((e) => e.message, 'message', '사진이 너무 커요 (최대 8MB)')),
      );
    });

    test('기능이 없는 구버전 서버(404)는 업데이트 안내로 바꾼다', () async {
      final client = MockClient((_) async => _json({'detail': 'Not Found'}, 404));
      final api = RpiApiService('http://rpi5.local:8000', client: client);

      await expectLater(
        () => api.scanPanel([1]),
        throwsA(isA<RpiApiException>()
            .having((e) => e.message, 'message', contains('업데이트'))),
      );
    });

    test('연결 실패는 상태 코드 0의 안내 문장이다', () async {
      final client = MockClient((_) async => throw http.ClientException('down'));
      final api = RpiApiService('http://rpi5.local:8000', client: client);

      await expectLater(
        () => api.scanPanel([1]),
        throwsA(isA<RpiApiException>()
            .having((e) => e.statusCode, 'statusCode', 0)
            .having((e) => e.message, 'message', contains('연결하지 못했어요'))),
      );
    });
  });
}
