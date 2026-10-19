import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simplelay/models/appliance.dart';
import 'package:simplelay/services/rpi_api_service.dart';

/// 서버 `GET /appliances` 한 항목 — 폰이 고치지 않는 필드(다이얼·누름 시간·목적)가 실려 있다.
Map<String, dynamic> _serverItem() => {
      'id': 'custom_1',
      'name': '가스레인지',
      'category': 'other',
      'icon': 'custom',
      'rows': 1,
      'cols': 2,
      'is_custom': true,
      'revision': 4,
      'buttons': [
        {
          'id': 'D1', 'label': '불세기', 'x': 0, 'y': 0, //
          'kind': 'dial', 'detents': 6, 'behavior': 'unknown', 'press_ms': null,
          'x_mm': 40.0, 'y_mm': 50.0, 'future_field': 'keep',
        },
        {
          'id': 'B1', 'label': '시작', 'x': 1, 'y': 0, //
          'kind': 'button', 'detents': null, 'behavior': 'toggle', 'press_ms': 300,
          'x_mm': 80.0, 'y_mm': 50.0,
        },
      ],
      'functions': {
        '약불': ['불세기:+1', '시작'],
      },
    };

void main() {
  // 검토 10/19 #2: 폰이 읽을 때 확장 필드를 버리고, 다음 동기화 PUT이 빈 버튼(기본 누름 버튼)과 빈 목적으로 덮었다.
  Future<Map<String, dynamic>> sentBody(
      Future<void> Function(RpiApiService api, ApplianceMap a) send) async {
    Map<String, dynamic>? body;
    final api = RpiApiService('http://hub', client: MockClient((req) async {
      body = jsonDecode(req.body) as Map<String, dynamic>;
      return http.Response.bytes(utf8.encode(jsonEncode(_serverItem())), 200,
          headers: {'content-type': 'application/json'});
    }));
    // 서버에서 받은 것을 기기에 저장했다가(toJson) 다시 읽은 것 — 동기화 대기열이 올리는 모양이다.
    final stored = ApplianceMap.fromJson(
        jsonDecode(jsonEncode(ApplianceMap.fromJson(_serverItem()).toJson())) as Map<String, dynamic>);
    await send(api, stored);
    return body!;
  }

  void expectKept(Map<String, dynamic> body) {
    final buttons = (body['buttons'] as List).cast<Map<String, dynamic>>();
    final dial = buttons.firstWhere((b) => b['id'] == 'D1');
    expect(dial['kind'], 'dial');
    expect(dial['detents'], 6);
    expect(dial['future_field'], 'keep');
    final start = buttons.firstWhere((b) => b['id'] == 'B1');
    expect(start['behavior'], 'toggle');
    expect(start['press_ms'], 300);
    expect(body['functions'], {
      '약불': ['불세기:+1', '시작'],
    });
    // mm 좌표는 본체가 같은 칸이면 스스로 이어받는다 — 실으면 옛 값이 새 보정을 이긴다.
    for (final b in buttons) {
      expect(b.containsKey('x_mm'), isFalse);
      expect(b.containsKey('y_mm'), isFalse);
    }
    // 정지·보관은 싣지 않는다(본체가 사진 매핑과 함께 이어받는다).
    expect(body.containsKey('stop_button'), isFalse);
    expect(body.containsKey('park_xy'), isFalse);
  }

  test('동기화 PUT(registerAppliance)이 폰이 고치지 않는 서버 필드를 그대로 다시 싣는다', () async {
    expectKept(await sentBody((api, a) => api.registerAppliance(a)));
  });

  test('등록 PUT(registerApplianceStrict)도 같은 모양이다', () async {
    expectKept(await sentBody((api, a) => api.registerApplianceStrict(a)));
  });

  test('목적을 모르는 정의(기기 저장분·옛 서버)는 functions를 싣지 않는다 — 빈 값으로 지우지 않는다', () async {
    final body = await sentBody((api, a) => api.registerAppliance(ApplianceMap.fromJson(
        {...a.toJson()}..remove('functions'))));
    expect(body.containsKey('functions'), isFalse);
  });
}
