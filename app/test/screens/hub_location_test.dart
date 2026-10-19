// 설정 → 허브 → "현재 위치로 설정"(2026-09-30).
//
// 폰 위치 권한 → PUT /hub/location. 거절하면 **보내지 않고** 무엇이 빠지는지
// (날씨 안내)와 다시 하는 길을 말한다. 날씨 출처 표시(공공누리 제1유형)도 본다.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/providers/ble_provider.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/app_info_screen.dart';
import 'package:simplelay/screens/settings_screen.dart';
import 'package:simplelay/services/location_service.dart';
import 'package:simplelay/services/rpi_api_service.dart';

import '../helpers/test_helpers.dart';

class _FakeLocation implements LocationService {
  _FakeLocation(this.outcome);
  final LocationOutcome outcome;
  int calls = 0;
  int settingsOpened = 0;

  @override
  Future<LocationOutcome> currentLocation() async {
    calls++;
    return outcome;
  }

  @override
  Future<bool> openSettings() async {
    settingsOpened++;
    return true;
  }
}

class _Server {
  Map<String, dynamic> location = {'source': 'none'};
  Map<String, dynamic>? putBody;

  http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
        utf8.encode(jsonEncode(body)),
        status,
        headers: {'content-type': 'application/json'},
      );

  RpiApiService api() => RpiApiService(
        'http://rpi5.local:8000',
        client: MockClient((req) async {
          if (req.url.path == '/hub/location') {
            if (req.method == 'PUT') {
              putBody = jsonDecode(utf8.decode(req.bodyBytes)) as Map<String, dynamic>;
              location = {
                'source': 'app',
                'lat': 37.57,
                'lon': 126.98,
                'nx': 60,
                'ny': 127,
              };
            }
            return _json(location);
          }
          return _json({'detail': 'not found'}, 404);
        }),
      );
}

Widget _build(_Server server, _FakeLocation location) => buildScreen(
      const HubSettingsScreen(),
      overrides: [
        ...connectedOverrides(),
        rpiApiServiceProvider.overrideWithValue(server.api()),
        locationServiceProvider.overrideWithValue(location),
        // 허브 화면 아래의 예비 연결 구획이 BLE 검색을 시작하지 않게 막는다.
        scanResultsProvider.overrideWith((ref) => Stream.value(const [])),
      ],
    );

void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(500, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('권한을 허용하면 폰 위치를 허브에 저장하고 저장된 위치를 다시 읽는다',
      (tester) async {
    final server = _Server();
    final location = _FakeLocation(const LocationFix(37.5665, 126.9780));
    _tall(tester);
    await tester.pumpWidget(_build(server, location));
    await _settle(tester);
    expect(find.text('아직 위치가 없어요. 날씨 안내를 하지 않아요'), findsOneWidget);

    await tester.tap(find.byKey(const Key('hub-location-set')));
    await _settle(tester);

    expect(location.calls, 1);
    expect(server.putBody, {'lat': 37.5665, 'lon': 126.9780});
    expect(find.text('본체 위치를 저장했어요. 약 1km 단위로만 저장해요.'), findsOneWidget);
    expect(find.text('폰에서 정한 위치예요'), findsOneWidget);
  });

  testWidgets('권한을 거절하면 보내지 않고, 빠지는 것과 다시 하는 길을 말한다',
      (tester) async {
    final server = _Server();
    final location = _FakeLocation(const LocationDenied());
    _tall(tester);
    await tester.pumpWidget(_build(server, location));
    await _settle(tester);

    await tester.tap(find.byKey(const Key('hub-location-set')));
    await _settle(tester);

    expect(server.putBody, isNull);
    expect(find.textContaining('위치 권한을 주지 않아서 정하지 않았어요'), findsOneWidget);
    expect(find.textContaining('날씨 안내만 빠지고'), findsOneWidget);
    // 다시 누를 수 있다.
    final button = tester.widget<FilledButton>(find.ancestor(
      of: find.text('지금 있는 곳으로 정하기'),
      matching: find.byWidgetPredicate((w) => w is FilledButton),
    ));
    expect(button.onPressed, isNotNull);
    expect(find.text('휴대폰 설정 열기'), findsNothing);
  });

  testWidgets('다시 묻지 않기로 거절했으면 폰 설정으로 가는 길을 준다', (tester) async {
    final server = _Server();
    final location = _FakeLocation(const LocationDeniedForever());
    _tall(tester);
    await tester.pumpWidget(_build(server, location));
    await _settle(tester);

    await tester.tap(find.byKey(const Key('hub-location-set')));
    await _settle(tester);

    expect(server.putBody, isNull);
    await tester.tap(find.text('휴대폰 설정 열기'));
    await tester.pump();
    expect(location.settingsOpened, 1);
  });

  testWidgets('앱 정보에 날씨 출처와 이용 허락 제1유형을 적는다', (tester) async {
    await tester.pumpWidget(buildScreen(const AppInfoScreen()));
    await tester.pump();
    expect(find.text('기상청 단기예보 조회서비스(공공데이터포털)'), findsOneWidget);
    expect(find.textContaining('이용허락 제1유형'), findsOneWidget);
  });

  testWidgets('설정의 "앱 정보"에서 날씨 출처 화면으로 간다', (tester) async {
    _tall(tester);
    final router = GoRouter(
      initialLocation: '/settings',
      routes: [
        GoRoute(path: '/settings', builder: (_, __) => const SettingsScreen()),
        GoRoute(path: '/settings/info', builder: (_, __) => const AppInfoScreen()),
      ],
    );
    await tester.pumpWidget(buildWithProviderState(
      overrides: [...connectedOverrides(), ...installedOverrides(const [])],
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.pump();
    await tester.tap(find.text('앱 정보'));
    await _settle(tester);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('기상청 단기예보 조회서비스(공공데이터포털)'), findsOneWidget);
  });
}
