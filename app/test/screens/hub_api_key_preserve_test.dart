// 설정 → 허브의 API 키가 지워지던 결함(2026-09-30 데스크톱 에이전트 발견, 10-01 수리).
//
// 허브 화면은 처음 그릴 때 provider 값으로 칸을 채웠다. 그런데 저장된 설정은
// 기기에서 비동기로 올라오므로, 그 순간 provider는 아직 null이다. 칸이 빈 채로
// 열리고, 사용자가 주소만 보고 '저장'을 누르면 빈 키가 저장돼 키가 지워졌다.
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

const _url = 'http://hub.test:8000';
const _key = 'saved-key';

http.Client _client() => MockClient((req) async => http.Response(
    '{"status":"ok"}', 200,
    headers: {'content-type': 'application/json'}));

Future<ProviderContainer> _open(WidgetTester tester) async {
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
    onContainerReady: (c) => container = c,
  ));
  await tester.pump();
  return container;
}

TextEditingController _field(WidgetTester tester, int index) =>
    tester.widgetList<TextField>(find.byType(TextField)).elementAt(index).controller!;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({
        'rpi_base_url': _url,
        'rpi_api_key': _key,
      }));

  testWidgets('설정이 늦게 올라와도 저장된 주소와 키가 칸에 채워진다', (tester) async {
    await _open(tester);
    expect(_field(tester, 0).text, _url);
    expect(_field(tester, 1).text, _key);
  });

  testWidgets('키 칸을 건드리지 않고 저장하면 저장된 키가 그대로 남는다', (tester) async {
    final container = await _open(tester);
    await tester.tap(find.widgetWithText(FilledButton, '저장'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('rpi_api_key'), _key);
    expect(container.read(rpiApiKeyProvider), _key);
  });

  testWidgets('사용자가 키 칸을 직접 비우고 저장하면 그때만 키를 지운다', (tester) async {
    final container = await _open(tester);
    await tester.enterText(find.byType(TextField).at(1), '');
    await tester.tap(find.widgetWithText(FilledButton, '저장'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('rpi_api_key'), isNull);
    expect(container.read(rpiApiKeyProvider), isNull);
  });
}
