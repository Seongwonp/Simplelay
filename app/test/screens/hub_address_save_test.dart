// 설정 → 허브에서 서버 주소를 저장한 뒤 연결 표시(2026-09-30 에뮬레이터 결함).
//
// 새 주소를 저장하면 이후 요청(/suggestions·/appliances·/status)은 200으로
// 성공하는데, 홈 머리와 허브 화면은 계속 "허브에 닿지 않아요"였다. '재시도'를
// 눌러야만 "허브 연결됨"으로 바뀌었다.
//
// 원인: 주소가 바뀌면 연결 알림자의 listen이 곧바로 확인을 시작하는데, Riverpod는
// listen을 **의존 provider를 무효화하기 전에** 부른다. 그래서 그 확인은 아직 캐시된
// **옛 주소**의 서비스로 ping을 보낸다. 저장 버튼이 이어서 새 주소로 한 번 더
// 확인해 '연결됨'이 되지만, 늦게 끝난 옛 주소의 실패가 그 위를 덮어 '닿지 않음'으로
// 굳었다. 여기서는 옛 주소가 늦게 실패하고 새 주소가 곧바로 성공하게 만든다.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/providers/ble_provider.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/settings_screen.dart';

import '../helpers/test_helpers.dart';

const _oldUrl = 'http://old-hub.test:8000';
const _newHost = '10.0.2.2';

/// 옛 주소는 2초 뒤에 실패하고(이름 풀이·연결 대기), 새 주소는 바로 답한다.
http.Client _client() => MockClient((req) async {
      if (req.url.host == 'old-hub.test') {
        await Future<void>.delayed(const Duration(seconds: 2));
        throw http.ClientException('host lookup failed', req.url);
      }
      if (req.url.host == _newHost && req.url.path == '/health') {
        return http.Response('{"status":"ok"}', 200,
            headers: {'content-type': 'application/json'});
      }
      return http.Response('{"detail":"not found"}', 404,
          headers: {'content-type': 'application/json'});
    });

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({
        'rpi_base_url': _oldUrl,
        'rpi_api_key': 'test-key',
      }));

  testWidgets('새 주소를 저장하면 재시도 없이 연결됨으로 바뀐다(옛 주소의 늦은 실패가 덮지 않는다)',
      (tester) async {
    tester.view.physicalSize = const Size(500, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late ProviderContainer container;
    await tester.pumpWidget(buildScreen(
      const HubSettingsScreen(),
      overrides: [
        rpiHttpClientProvider.overrideWithValue(_client()),
        scanResultsProvider.overrideWith((ref) => Stream.value(const [])),
      ],
      // 앱처럼 시작부터 연결 알림자를 살려 둔다(홈 머리가 지켜본다).
      onContainerReady: (c) => (container = c).read(rpiConnectionProvider),
    ));
    // 앱을 연 직후의 확인 -- 옛 주소라 닿지 않는다.
    await tester.pump(const Duration(seconds: 3));
    expect(container.read(rpiConnectionProvider),
        RpiConnectionState.unreachable);

    // 사용자가 새 주소를 넣고 저장한다(API 키는 그대로).
    await tester.enterText(
        find.byType(TextField).first, 'http://$_newHost:8000');
    await tester.tap(find.widgetWithText(FilledButton, '저장'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();

    expect(container.read(rpiUrlProvider), 'http://$_newHost:8000');
    expect(container.read(rpiConnectionProvider),
        RpiConnectionState.connected,
        reason: '저장한 새 주소는 닿는다 -- 재시도 없이 연결됨이어야 한다');
    expect(find.text('연결됐어요 — 버튼을 대신 눌러 줄 수 있어요'), findsOneWidget);
  });
}

