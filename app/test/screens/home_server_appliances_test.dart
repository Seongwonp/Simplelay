// 서버에만 등록된 사용자 가전도 홈에 보인다 (2026-10-07 에뮬레이터 결함).
//
// 실제 RPi5의 GET /appliances는 5대(시험용 전자레인지·Phone-MW·전자레인지·
// 세탁기·인터폰)를 돌려주는데, 홈에는 이 폰이 등록한 2대만 보였다. 나머지
// 3대는 PUT /appliances/<id>로 서버에 바로 올린 사용자 가전(is_custom=true)이라
// 내장 목록에서 걸러지고, 동기화 병합(저장·다시 보내기 때만 돈다)도 오지 않았다.
// 위치를 맞추지 않은 가전도 숨기지 않는다 -- 상태로 말할 뿐이다.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/appliance.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/home_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';

import '../helpers/test_helpers.dart';

Map<String, dynamic> _serverAppliance(
  String id,
  String name,
  String category, {
  bool canExecute = false,
}) =>
    {
      'id': id,
      'name': name,
      'category': category,
      'rows': 1,
      'cols': 2,
      'is_custom': true,
      'revision': 1,
      'can_execute': canExecute,
      'readiness': canExecute ? 'operable' : 'needs_setup',
      'readiness_reasons': canExecute ? <String>[] : ['좌표를 아직 맞추지 않았어요'],
      'buttons': [
        {'id': '$id-1', 'label': '전원', 'x': 0, 'y': 0},
        {'id': '$id-2', 'label': '시작', 'x': 1, 'y': 0},
      ],
    };

/// 2026-10-07 RPi5가 돌려준 목록과 같은 모양.
final kServerFive = [
  _serverAppliance('test_microwave', '시험용 전자레인지', 'microwave'),
  _serverAppliance('custom_1790777692424', 'Phone-MW', 'microwave'),
  _serverAppliance('home_mw', '전자레인지', 'microwave'),
  _serverAppliance('washer', '세탁기', 'washing_machine'),
  _serverAppliance('intercom', '인터폰', 'intercom'),
];

RpiApiService serverWithAppliances(List<Map<String, dynamic>> list) =>
    RpiApiService(
      'http://rpi5.local:8000',
      client: MockClient((req) async {
        if (req.method == 'GET' && req.url.path == '/appliances') {
          return http.Response.bytes(
            utf8.encode(jsonEncode(list)),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('{"detail":"not found"}', 404);
      }),
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('서버의 가전 5대가 홈에 모두 보인다 -- 이 폰이 등록한 2대만이 아니다',
      (tester) async {
    tester.view.physicalSize = const Size(400, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 이 폰에는 두 대만 저장돼 있다(예전에 병합으로 받았거나 직접 등록).
    final own = [
      ApplianceMap.fromJson(kServerFive[0]),
      ApplianceMap.fromJson(kServerFive[1]),
    ];
    await tester.pumpWidget(buildScreen(
      const HomeScreen(),
      overrides: [
        ...connectedOverrides(),
        ...installedOverrides(own),
        rpiServerOverride(RpiConnectionState.connected),
        rpiApiServiceProvider.overrideWithValue(
            serverWithAppliances(kServerFive)),
      ],
    ));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    for (final a in kServerFive) {
      expect(find.byKey(Key('appliance-card-${a['id']}')), findsOneWidget,
          reason: '${a['name']} 카드가 홈에 있어야 한다');
    }
    expect(find.byKey(const Key('appliance-add-card')), findsOneWidget);
    // 숨기지 않되, 준비가 안 됐다는 사실은 글자로 말한다.
    expect(find.text('준비 필요'), findsWidgets);
  });
}
