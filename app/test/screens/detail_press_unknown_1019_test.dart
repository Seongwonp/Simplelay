// 검토 10/19(core5 5): 가전 상세의 누르기도 수동 조작 화면처럼 — 보냈는데 답이 없으면 본체가 이미 눌렀을 수 있다.
// '보내지 못했어요'라고 하지 않고 모름으로 두어 정지를 남기며, 같은 버튼은 다시 누를지부터 묻는다(켜기·끄기 버튼이 도로 꺼짐).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/appliance.dart';
import 'package:simplelay/models/execution_status.dart';
import 'package:simplelay/models/hub.dart';
import 'package:simplelay/providers/execution_status_provider.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/appliance_detail_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';

import '../helpers/test_helpers.dart';

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
    utf8.encode(jsonEncode(body)), status,
    headers: {'content-type': 'application/json; charset=utf-8'});

Future<void> _pumps(WidgetTester tester, [int n = 6]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('가전 상세 누르기', () {
    final mapped = ApplianceMap(
      id: 'custom_1',
      name: '전자레인지',
      location: '주방',
      category: ApplianceCategory.microwave,
      rows: 1,
      cols: 3,
      buttons: const [
        ApplianceButton(id: 'B01', label: '해동', x: 0, y: 0),
        ApplianceButton(id: 'B02', label: '시작', x: 1, y: 0),
        ApplianceButton(id: 'B03', label: '취소', x: 2, y: 0),
      ],
      isCustom: true,
      stopButton: 'B03',
      panelMapping: const PanelMapping(
        photoWidth: 1000,
        photoHeight: 800,
        buttons: {
          'B01': PhotoPoint(200, 400),
          'B02': PhotoPoint(500, 400),
          'B03': PhotoPoint(800, 400),
        },
        parkPoint: PhotoPoint(950, 750),
      ),
    );

    testWidgets('답이 없으면 못 보냈다고 하지 않고 모름으로 정지를 남기며, 같은 버튼은 다시 누를지부터 묻는다', (tester) async {
      tester.view.physicalSize = const Size(500, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      var presses = 0;
      final api = RpiApiService('http://rpi5.local:8000', client: MockClient((req) async {
        if (req.url.path == '/execute-buttons') {
          presses++;
          throw http.ClientException('응답 유실');
        }
        if (req.url.path == '/routines' || req.url.path == '/history') return _json(<dynamic>[]);
        if (req.url.path == '/status') return _json({'running': false});
        return _json({'detail': 'not found'}, 404);
      }));
      late ProviderContainer container;
      final router = GoRouter(
        initialLocation: '/detail',
        routes: [
          GoRoute(
              path: '/detail',
              builder: (_, __) => const ApplianceDetailScreen(applianceId: 'custom_1')),
          GoRoute(path: '/status', builder: (_, __) => const Scaffold(body: Text('상태 화면'))),
        ],
      );
      await tester.pumpWidget(buildWithProviderState(
        overrides: [
          ...connectedOverrides(),
          ...installedOverrides([mapped]),
          rpiApiServiceProvider.overrideWithValue(api),
        ],
        onContainerReady: (c) => container = c,
        child: MaterialApp.router(theme: ThemeData.dark(), routerConfig: router),
      ));
      await _pumps(tester, 12);

      await tester.tap(find.byKey(const Key('mark-B02')));
      await _pumps(tester);
      await tester.tap(find.text('누르기'));
      await _pumps(tester);
      expect(presses, 1);
      expect(find.textContaining('누르라고 보내지 못했어요'), findsNothing);
      final status = container.read(executionStatusProvider);
      expect(status.phase, ExecutionPhase.unknown);
      expect(status.label, '시작');
      expect(find.text('상태 화면'), findsOneWidget);

      router.go('/detail');
      await _pumps(tester, 12);
      await tester.tap(find.byKey(const Key('mark-B02')));
      await _pumps(tester);
      expect(find.text('다시 누를까요?'), findsOneWidget, reason: '눌렸는지 모르는 버튼은 확인 없이 다시 보내지 않는다');
      await tester.tap(find.text('그만두기'));
      await _pumps(tester);
      expect(presses, 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 20));
    });
  });
}
