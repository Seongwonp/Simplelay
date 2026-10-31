import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simplelay/models/appliance.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/services/rpi_api_service.dart';
import 'package:simplelay/widgets/kit_widgets.dart';

import '../helpers/test_helpers.dart';

const _fan = ApplianceMap(
    id: 'custom_fan', name: '선풍기', category: ApplianceCategory.other, rows: 1, cols: 1, isCustom: true, buttons: []);

void main() {
  Future<List<Map<String, dynamic>>> pump(WidgetTester tester, Map<String, dynamic> kit, {String? reject}) async {
    final binds = <Map<String, dynamic>>[];
    final api = RpiApiService('http://rpi5.local:8000', client: MockClient((req) async {
      http.Response json(Object body, [int status = 200]) => http.Response.bytes(utf8.encode(jsonEncode(body)), status,
          headers: {'content-type': 'application/json'});
      if (req.url.path == '/kit') return json(kit);
      if (req.url.path == '/kit/bind') {
        binds.add(jsonDecode(utf8.decode(req.bodyBytes)) as Map<String, dynamic>);
        return reject != null ? json({'detail': reject}, 409) : json(kit);
      }
      return json(<Object>[]);
    }));
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, __) => const Scaffold(body: KitReconnectButton(appliance: _fan))),
      GoRoute(path: '/appliance/setup', builder: (_, __) => const Scaffold(body: Text('자리 확인 화면'))),
    ]);
    await tester.pumpWidget(buildWithProviderState(
      overrides: [...connectedOverrides(), rpiServerOverride(RpiConnectionState.connected), rpiApiServiceProvider.overrideWithValue(api)],
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.pump();
    await tester.tap(find.byKey(const Key('kit-reconnect')));
    await tester.pumpAndSettle();
    return binds;
  }

  testWidgets('다른 가전이 맡았으면 확인을 거쳐 잇고 자리 확인으로 간다', (tester) async {
    final binds = await pump(tester, {'found': true, 'kit_id': 'k', 'bound_appliance': 'microwave', 'name': '전자레인지'});
    expect(find.textContaining('다시 연결할 때까지 쓸 수 없어요'), findsOneWidget);
    expect(binds, isEmpty);
    await tester.tap(find.byKey(const Key('kit-release-confirm')));
    await tester.pumpAndSettle();
    expect(binds.single, {'appliance_id': 'custom_fan', 'confirm_release': true});
    expect(find.text('자리 확인 화면'), findsOneWidget);
  });

  testWidgets('세트를 못 찾으면 잇지 않고 이유를 보인다', (tester) async {
    final binds = await pump(tester, {'found': false, 'reason': '세트를 찾지 못했어요.'});
    expect(binds, isEmpty);
    expect(find.text('세트를 찾지 못했어요.'), findsOneWidget);
  });

  testWidgets('본체가 거절하면 그 문장을 그대로 보인다', (tester) async {
    await pump(tester, {'found': true, 'kit_id': 'k'}, reject: '누름 장치가 일하는 중이에요.');
    expect(find.text('누름 장치가 일하는 중이에요.'), findsOneWidget);
    expect(find.text('자리 확인 화면'), findsNothing);
  });
}
