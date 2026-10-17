// 비상정지 걸림(2026-10-05) — /status의 새 필드 읽기와 POST /stop/ack 결과.
//
// 서버 규약(rpi/api/router.py acknowledge_estop):
// 200 {ok, latched, reason, detail} · 409 걸림 보고 없음 · 504 RPi4 무응답.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simplelay/models/estop.dart';
import 'package:simplelay/models/hub.dart';
import 'package:simplelay/services/rpi_api_service.dart';

http.Response _json(Object body, int status) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      status,
      headers: {'content-type': 'application/json'},
    );

RpiApiService _api(http.Response Function(http.Request) reply,
        {List<http.Request>? log}) =>
    RpiApiService('http://rpi5.local:8000',
        apiKey: 'k1',
        client: MockClient((r) async {
          log?.add(r);
          return reply(r);
        }));

void main() {
  group('/status 비상정지 필드', () {
    test('없으면(옛 서버) 걸리지 않음·사유 없음', () {
      final s = HubStatus.fromJson(const {'developer_mode': false});
      expect(s.estopLatched, isFalse);
      expect(s.estopDetail, isNull);
    });

    test('null도 걸리지 않음으로 본다(보고 수단 없는 실행기)', () {
      final s = HubStatus.fromJson(const {'estop_latched': null});
      expect(s.estopLatched, isFalse);
    });

    test('걸림과 사유를 읽는다', () {
      final s = HubStatus.fromJson(
          const {'estop_latched': true, 'estop_detail': '콘센트 비상정지 버튼'});
      expect(s.estopLatched, isTrue);
      expect(s.estopDetail, '콘센트 비상정지 버튼');
    });

    test('실행 상태 응답도 같은 필드를 읽는다', () async {
      final api = _api((_) => _json({
            'running': false,
            'estop_latched': true,
            'estop_detail': '버튼 눌림',
          }, 200));
      final s = await api.status();
      expect(s.estopLatched, isTrue);
      expect(s.estopDetail, '버튼 눌림');

      final old = await _api((_) => _json({'running': false}, 200)).status();
      expect(old.estopLatched, isFalse);
      expect(old.estopDetail, isNull);
    });
  });

  group('ackEstop', () {
    test('POST /stop/ack에 API 키를 싣고, ok면 해제됨', () async {
      final log = <http.Request>[];
      final api = _api((_) => _json({'ok': true, 'latched': false}, 200), log: log);
      final r = await api.ackEstop();
      expect(r.outcome, EstopAckOutcome.cleared);
      expect(r.cleared, isTrue);
      expect(log.single.method, 'POST');
      expect(log.single.url.path, '/stop/ack');
      expect(log.single.headers['X-API-Key'], 'k1');
    });

    for (final (reason, outcome) in [
      ('estop_button_pressed', EstopAckOutcome.buttonPressed),
      ('outlet_unreachable', EstopAckOutcome.outletUnreachable),
      ('estop_retriggered', EstopAckOutcome.retriggered),
      (null, EstopAckOutcome.stillLatched),
    ]) {
      test('200이어도 ok=false($reason)면 걸린 채', () async {
        final api = _api((_) => _json(
            {'ok': false, 'latched': true, 'reason': reason, 'detail': 'd'}, 200));
        final r = await api.ackEstop();
        expect(r.outcome, outcome);
        expect(r.cleared, isFalse);
        expect(r.detail, 'd');
      });
    }

    test('409는 걸림 보고 없음, 504는 무응답, 그 밖은 실패', () async {
      expect(
          (await _api((_) => _json({'detail': '이 실행기는 비상정지 걸림을 보고하지 않아요'}, 409))
                  .ackEstop())
              .outcome,
          EstopAckOutcome.notLatched);
      expect(
          (await _api((_) => _json({'detail': 'RPi4가 답하지 않았어요'}, 504)).ackEstop())
              .outcome,
          EstopAckOutcome.noAnswer);
      expect((await _api((_) => _json({'detail': 'x'}, 500)).ackEstop()).outcome,
          EstopAckOutcome.failed);
    });

    test('통신 실패는 예외 대신 실패 결과', () async {
      final api = RpiApiService('http://rpi5.local:8000',
          client: MockClient((_) async => throw http.ClientException('down')));
      final r = await api.ackEstop();
      expect(r.outcome, EstopAckOutcome.failed);
      expect(r.message, contains('연결을 보고'));
    });

    test('실패 문장은 모두 해요체 한 줄이고 서로 다르다', () {
      final messages = {
        for (final o in EstopAckOutcome.values) EstopAckResult(o).message,
      };
      expect(messages.length, EstopAckOutcome.values.length);
      for (final m in messages) {
        expect(m, endsWith('요.'));
      }
    });
  });
}
