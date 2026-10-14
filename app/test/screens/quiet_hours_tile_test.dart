// 조용한 시간(2026-10-14, 5번) — 설정 '알림' 구획 안(새 탭 없음). 서버 상태(/quiet-hours)를 그대로 보이고,
// 실제 범위만 말한다('모든 알림이 조용해진다'고 하지 않는다).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simplelay/models/quiet_hours.dart';
import 'package:simplelay/providers/ble_provider.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/settings_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';

import '../helpers/test_helpers.dart';

class _Server {
  Map<String, dynamic> state = {
    'enabled': true,
    'start': '22:00',
    'end': '07:00',
    'active': true,
    'reason': 'schedule',
    'pause_until': null,
    'scope': '새 제안과 일반 안내 소리만 쉬어요. 아직 시작하지 않은 자동 실행은 건너뛰고 나중에 다시 하지 않아요.',
  };
  final puts = <Map<String, dynamic>>[];

  /// PUT 응답의 저장 결과(2026-10-14 HIGH 재확인 M-R1) — false면 이번 세션만 적용.
  bool? persisted = true;

  RpiApiService api() => RpiApiService('http://rpi5.local:8000',
      client: MockClient((req) async {
        http.Response json(Object body, [int status = 200]) => http.Response.bytes(
            utf8.encode(jsonEncode(body)), status,
            headers: {'content-type': 'application/json'});
        if (req.url.path == '/quiet-hours') {
          if (req.method == 'PUT') {
            final body = jsonDecode(utf8.decode(req.bodyBytes)) as Map<String, dynamic>;
            puts.add(body);
            state = {...state, ...body, 'active': false, 'reason': null};
            return json({...state, 'persisted': persisted, 'session_only': persisted != true});
          }
          return json(state);
        }
        return json({'detail': 'not found'}, 404);
      }));
}

Widget _build(RpiApiService? api) => buildScreen(
      const SettingsScreen(),
      overrides: [
        scanResultsProvider.overrideWith((ref) => Stream.value(const <ScanResult>[])),
        ...installedOverrides([kTestAppliance]),
        rpiApiServiceProvider.overrideWithValue(api),
      ],
    );

void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(400, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets('알림 구획 안에 서버 상태 그대로 — 매일 시간대·지금 조용한 시간·실제 범위', (tester) async {
    _tall(tester);
    await tester.pumpWidget(_build(_Server().api()));
    await _settle(tester);
    expect(find.text('조용한 시간'), findsOneWidget);
    expect(find.text('매일 22:00~07:00 · 지금 조용한 시간이에요'), findsOneWidget);
    expect(find.textContaining('새 제안과 일반 안내 소리만 쉬어요'), findsOneWidget);
    expect(find.textContaining('직접 실행·정지는 그대로예요'), findsOneWidget);
    expect(find.textContaining('모든 알림'), findsNothing);
    // 잠시 쉬기도 같은 범위로 말한다(자동 실행도 건너뛴다).
    expect(find.text('몇 시간 동안 새 제안과 자동 실행을 쉬어요'), findsOneWidget);
  });

  testWidgets('켜기/끄기는 서버에 저장한다(PUT)', (tester) async {
    _tall(tester);
    final server = _Server();
    await tester.pumpWidget(_build(server.api()));
    await _settle(tester);
    final toggle = find.byKey(const Key('quiet-hours-switch'));
    expect(tester.getSize(toggle).height, greaterThanOrEqualTo(48));
    await tester.tap(toggle);
    await _settle(tester);
    expect(server.puts, [
      {'enabled': false},
    ]);
    expect(find.text('매일 22:00~07:00 · 꺼져 있어요'), findsOneWidget);
    expect(find.text(kSettingNotSavedNotice), findsNothing);
  });

  testWidgets('저장 실패(persisted=false)면 바뀐 값은 보이되 이번 세션만 적용이라고 알린다', (tester) async {
    _tall(tester);
    final server = _Server()..persisted = false;
    await tester.pumpWidget(_build(server.api()));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('quiet-hours-switch')));
    await _settle(tester);
    expect(server.puts, [
      {'enabled': false},
    ]);
    expect(find.text('매일 22:00~07:00 · 꺼져 있어요'), findsOneWidget);
    expect(find.text(kSettingNotSavedNotice), findsOneWidget);
  });

  testWidgets('허브가 없으면 설정할 수 없다고 말하고 스위치를 잠근다', (tester) async {
    _tall(tester);
    await tester.pumpWidget(_build(null));
    await _settle(tester);
    expect(find.text('허브와 연결되면 설정할 수 있어요.'), findsOneWidget);
    final sw = tester.widget<Switch>(find.descendant(
        of: find.byKey(const Key('quiet-hours-switch')), matching: find.byType(Switch)));
    expect(sw.onChanged, isNull);
  });
}
