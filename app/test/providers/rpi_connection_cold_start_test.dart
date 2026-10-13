// 앱을 다시 열 때 저장된 주소가 연결 알림자보다 먼저 올라와 있으면
// 연결 확인이 한 번도 돌지 않아 '미설정'에 머물렀다(2026-10-13 에뮬레이터).
// 요청은 200으로 오가는데 홈 머리는 '허브 확인 중', 타일은 '허브 설정이 필요해요'.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';

http.Client _client() => MockClient((req) async {
      if (req.url.path == '/status') {
        return http.Response('{"status":"ok"}', 200,
            headers: {'content-type': 'application/json'});
      }
      return http.Response('{"detail":"not found"}', 404,
          headers: {'content-type': 'application/json'});
    });

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({
        'rpi_base_url': 'http://10.0.2.2:8000',
        'rpi_api_key': 'test-key',
      }));

  test('주소가 먼저 올라온 뒤에 연결 알림자를 만들어도 스스로 확인해 연결됨이 된다', () async {
    final container = ProviderContainer(overrides: [
      rpiHttpClientProvider.overrideWithValue(_client()),
    ]);
    addTearDown(container.dispose);

    // 다른 화면이 먼저 주소를 읽어 올려 둔다.
    container.read(rpiUrlProvider);
    container.read(rpiApiKeyProvider);
    await container.read(rpiUrlProvider.notifier).ensureLoaded();
    await Future<void>.delayed(Duration.zero);
    expect(container.read(rpiUrlProvider), 'http://10.0.2.2:8000');

    // 그 뒤에 홈 머리가 연결 상태를 지켜보기 시작한다.
    final sub = container.listen(rpiConnectionProvider, (_, __) {});
    addTearDown(sub.close);
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      if (container.read(rpiConnectionProvider) ==
          RpiConnectionState.connected) {
        break;
      }
    }
    expect(container.read(rpiConnectionProvider), RpiConnectionState.connected,
        reason: '재시도를 누르지 않아도 저장된 주소로 확인해야 한다');
  });
}
