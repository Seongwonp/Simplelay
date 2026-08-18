import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/appliance.dart';
import 'package:simplelay/providers/appliance_provider.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/manual_control_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';

const _testAppliance = ApplianceMap(
  id: 'custom_test',
  name: '테스트가전',
  icon: Icons.widgets_outlined,
  rows: 1,
  cols: 2,
  isCustom: true,
  buttons: [
    ApplianceButton(id: 'b1', label: '켜기', x: 0, y: 0),
    ApplianceButton(id: 'b2', label: '끄기', x: 1, y: 0),
  ],
);

Widget _buildScreen(ProviderContainer container) => UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: ManualControlScreen()),
    );

Future<ProviderContainer> _makeContainerWithAppliance(
  WidgetTester tester, {
  List<Override> extra = const [],
}) async {
  final container = ProviderContainer(overrides: extra);
  addTearDown(container.dispose);
  await container.read(customAppliancesProvider.notifier).ensureLoaded();
  await container.read(customAppliancesProvider.notifier).add(_testAppliance);
  await container.read(selectedApplianceProvider.notifier).select(_testAppliance);
  return container;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('RPi 서버가 연결 안 되어 있으면 설정 안내 화면을 보여준다', (tester) async {
    final container = await _makeContainerWithAppliance(
      tester,
      extra: [rpiApiServiceProvider.overrideWithValue(null)],
    );
    await tester.pumpWidget(_buildScreen(container));
    await tester.pump();

    expect(find.text('RPi 서버 URL을 먼저 설정해야 버튼을 직접 실행할 수 있어요.'), findsOneWidget);
  });

  testWidgets('RPi URL이 있으면 선택된 가전의 버튼 그리드를 보여준다', (tester) async {
    final client = MockClient((_) async => http.Response('{}', 200));
    final api = RpiApiService('http://rpi5.local:8000', client: client);
    final container = await _makeContainerWithAppliance(
      tester,
      extra: [rpiApiServiceProvider.overrideWithValue(api)],
    );

    await tester.pumpWidget(_buildScreen(container));
    await tester.pump();

    expect(find.text('테스트가전 버튼 조작'), findsOneWidget);
    expect(find.text('켜기'), findsOneWidget);
    expect(find.text('끄기'), findsOneWidget);
  });

  testWidgets('버튼을 탭하면 /execute-buttons를 호출하고 성공 표시 후 원상복구된다', (tester) async {
    http.Request? captured;
    final client = MockClient((request) async {
      captured = request;
      return http.Response.bytes(
        utf8.encode(jsonEncode({
          'status': 'succeeded',
          'buttons': [
            {'button': '켜기', 'success': true},
          ],
        })),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });
    final api = RpiApiService('http://rpi5.local:8000', client: client);
    final container = await _makeContainerWithAppliance(
      tester,
      extra: [rpiApiServiceProvider.overrideWithValue(api)],
    );

    await tester.pumpWidget(_buildScreen(container));
    await tester.pump();

    await tester.tap(find.text('켜기'));
    await tester.pump(); // 요청 발송 + 응답 처리
    await tester.pump();

    expect(jsonDecode(captured!.body), {
      'buttons': ['켜기'],
      'appliance_id': 'custom_test',
    });
    expect(find.byIcon(Icons.check), findsOneWidget);

    // 2초 뒤 결과 표시가 사라진다.
    await tester.pump(const Duration(seconds: 3));
    expect(find.byIcon(Icons.check), findsNothing);
  });

  testWidgets('실행 중에는 다른 버튼 탭이 무시된다', (tester) async {
    var callCount = 0;
    final client = MockClient((request) async {
      callCount++;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      return http.Response.bytes(
        utf8.encode(jsonEncode({
          'status': 'succeeded',
          'buttons': [
            {'button': '켜기', 'success': true},
          ],
        })),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });
    final api = RpiApiService('http://rpi5.local:8000', client: client);
    final container = await _makeContainerWithAppliance(
      tester,
      extra: [rpiApiServiceProvider.overrideWithValue(api)],
    );

    await tester.pumpWidget(_buildScreen(container));
    await tester.pump();

    await tester.tap(find.text('켜기'));
    await tester.pump(const Duration(milliseconds: 10));
    // 첫 요청이 아직 진행 중일 때 다른 버튼을 탭 — 무시되어야 함.
    await tester.tap(find.text('끄기'));
    await tester.pump(const Duration(milliseconds: 200));

    expect(callCount, 1);
  });
}
