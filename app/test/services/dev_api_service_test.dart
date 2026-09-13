// 개발자 API 클라이언트 — 권한 헤더, 거절 코드, 정지 미확인 해석.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simplelay/services/dev_api_service.dart';

Map<String, dynamic> _state({String phase = 'idle', bool? mock = true}) => {
      'phase': phase,
      if (mock != null) 'mock': mock,
      'shutting_down': false,
      'session': null,
      'fault_reason': phase == 'fault' ? 'stop_unconfirmed:emergency_stop' : null,
      'heartbeat_ttl_s': 2.0,
      'max_jog_mm': 5.0,
      'max_command_len': 64,
      'allowed_commands': ['status'],
    };

http.Response _json(Object body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

void main() {
  test('모든 요청에 개발자 토큰을, 세션 요청에만 비밀값을 싣는다', () async {
    final seen = <http.Request>[];
    final api = DevApiService(
      'http://rpi.test:8000',
      devToken: 'dev-tok',
      apiKey: 'api-key',
      client: MockClient((request) async {
        seen.add(request);
        return _json(_state());
      }),
    );

    await api.state();
    await api.heartbeat('s1', 'secret-1');

    expect(seen[0].headers['X-Dev-Token'], 'dev-tok');
    expect(seen[0].headers['X-API-Key'], 'api-key');
    expect(seen[0].headers.containsKey('X-Dev-Session-Secret'), isFalse);
    expect(seen[1].url.path, '/dev/sessions/s1/heartbeat');
    expect(seen[1].headers['X-Dev-Session-Secret'], 'secret-1');
  });

  test('명령은 대상 가전과 request_id를 함께 보낸다', () async {
    late http.Request sent;
    final api = DevApiService(
      'http://rpi.test:8000',
      devToken: 'dev-tok',
      client: MockClient((request) async {
        sent = request;
        return _json({
          'accepted': true,
          'request_id': 'r1',
          'normalized': 'home',
          'sensor': null,
          'state': _state(phase: 'active'),
        });
      }),
    );

    final result = await api.command('s1', 'sec',
        applianceId: 'microwave', text: 'home', requestId: 'r1');

    final body = jsonDecode(sent.body) as Map<String, dynamic>;
    expect(body, {'appliance_id': 'microwave', 'text': 'home', 'request_id': 'r1'});
    expect(result.normalized, 'home');
    expect(result.state.phase, 'active');
  });

  test('서버 거절은 code를 가진 예외가 된다', () async {
    final api = DevApiService(
      'http://rpi.test:8000',
      devToken: 'dev-tok',
      client: MockClient((_) async => _json({
            'detail': {'code': 'stopping', 'message': '정리 중'},
          }, 409)),
    );

    await expectLater(
      api.start('microwave', nodeId: 'phone-console'),
      throwsA(isA<DevApiException>()
          .having((e) => e.statusCode, 'status', 409)
          .having((e) => e.code, 'code', 'stopping')),
    );
  });

  test('서버에 닿지 않으면 network 코드다', () async {
    final api = DevApiService(
      'http://rpi.test:8000',
      devToken: 'dev-tok',
      client: MockClient((_) async => throw http.ClientException('down')),
    );

    await expectLater(
      api.stop(),
      throwsA(isA<DevApiException>()
          .having((e) => e.isNetwork, 'isNetwork', isTrue)
          .having((e) => e.code, 'code', 'network')),
    );
  });

  test('정지 미확인은 confirmed=false와 fault 국면으로 읽힌다', () async {
    final api = DevApiService(
      'http://rpi.test:8000',
      devToken: 'dev-tok',
      client: MockClient((_) async => _json({
            'confirmed': false,
            'message': '확인 못 함',
            'state': _state(phase: 'fault'),
          })),
    );

    final result = await api.stop();

    expect(result.confirmed, isFalse);
    expect(result.state.phase, 'fault');
    expect(result.state.faultReason, isNotNull);
  });

  test('mock 필드가 없는 응답은 모의라고 믿지 않는다', () {
    expect(DevState.fromJson(_state(mock: null)).mock, isFalse);
    expect(DevState.fromJson(_state()).mock, isTrue);
  });
}
