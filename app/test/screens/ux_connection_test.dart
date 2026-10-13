import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/providers/ble_provider.dart';
import 'package:simplelay/screens/settings_screen.dart';
import 'package:simplelay/services/mdns_resolver.dart';
import '../helpers/test_helpers.dart';

class _Discovery extends MdnsResolver {
  int calls = 0;
  @override
  Future<String?> resolveIPv4(String host,
      {Duration timeout = const Duration(seconds: 3)}) async =>
      ++calls == 1 ? '192.0.2.1' : '192.0.2.2';
}

void main() {
  testWidgets('건강 응답이 있어도 인증 거절이면 키를 안내하고 키를 보여줘요', (tester) async {
    SharedPreferences.setMockInitialValues({'rpi_base_url': 'http://hub.test:8000'});
    tester.view.physicalSize = const Size(600, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late ProviderContainer container;
    await tester.pumpWidget(buildScreen(const HubSettingsScreen(), overrides: [
      rpiHttpClientProvider.overrideWithValue(MockClient((r) async =>
        http.Response('{}', r.url.path == '/health' ? 200 : 401))),
      scanResultsProvider.overrideWith((_) => Stream.value(const [])),
    ], onContainerReady: (c) => (container = c).read(rpiConnectionProvider)));
    await tester.pumpAndSettle();
    expect(container.read(rpiConnectionProvider), RpiConnectionState.keyRequired);
    expect(find.text('허브 키가 필요해요'), findsWidgets);
    expect(find.text('API 키 (선택)'), findsNothing);
    final field = find.byType(TextField).at(1);
    expect(tester.widget<TextField>(field).obscureText, isTrue);
    await tester.tap(find.byTooltip('키 보기'));
    await tester.pump();
    expect(tester.widget<TextField>(field).obscureText, isFalse);
  });

  test('발견 주소를 저장하지 않고 실패하면 다시 찾아요', () async {
    SharedPreferences.setMockInitialValues({'rpi_base_url': 'http://simplelay.local:8000'});
    final discovery = _Discovery();
    var firstAlive = true;
    final c = ProviderContainer(overrides: [
      mdnsResolverProvider.overrideWithValue(discovery),
      rpiHttpClientProvider.overrideWithValue(MockClient((r) async => http.Response('{}',
        r.url.host == '192.0.2.2' || (r.url.host == '192.0.2.1' && firstAlive) ? 200 : 503))),
    ]);
    addTearDown(c.dispose);
    await c.read(rpiUrlProvider.notifier).ensureLoaded();
    await c.read(rpiApiKeyProvider.notifier).ensureLoaded();
    // 주소가 이미 올라와 있으면 알림자가 만들어지자마자 스스로 확인한다.
    c.read(rpiConnectionProvider);
    for (var i = 0; i < 50 && c.read(rpiConnectionProvider) != RpiConnectionState.connected; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(c.read(rpiConnectionProvider), RpiConnectionState.connected);
    firstAlive = false;
    await c.read(rpiConnectionProvider.notifier).check();
    expect(discovery.calls, 2);
    expect(c.read(rpiConnectionProvider), RpiConnectionState.connected);
    expect((await SharedPreferences.getInstance()).getString('rpi_base_url'),
      'http://simplelay.local:8000');
  });
}
