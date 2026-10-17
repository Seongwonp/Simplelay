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

  /// 자동 실행 규칙(GET /routines/auto-rules). 비면 404로 둔다(옛 시험과 같게).
  List<Map<String, dynamic>> rules = const [];

  /// PUT 응답의 저장 결과(2026-10-14 HIGH 재확인 M-R1) — false면 이번 세션만 적용.
  bool? persisted = true;

  RpiApiService api() => RpiApiService('http://rpi5.local:8000',
      client: MockClient((req) async {
        http.Response json(Object body, [int status = 200]) => http.Response.bytes(
            utf8.encode(jsonEncode(body)), status,
            headers: {'content-type': 'application/json'});
        if (req.url.path == '/routines/auto-rules' && rules.isNotEmpty) return json(rules);
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

Map<String, dynamic> _timeRule(String name, String time, {bool enabled = true}) => {
      'id': 'ar-$name', 'name': name, 'condition_kind': 'time', 'condition_time': time,
      'condition_text': '매일 $time이 되면', 'action_text': '공기청정기 전원', 'enabled': enabled,
      'status_label': enabled ? '자동 실행 켜짐' : '자동 실행 꺼짐',
    };

void main() {
  // UI 평가 6차 10/17: 조용한 시간 22:00~07:00을 켜면 22:00 자동 실행이 소리 없이 건너뛰어졌다 — 미리 말한다.
  // 서버 판정과 같게 시작은 포함, 끝은 제외(07:00 규칙은 그대로 돈다).
  testWidgets('조용한 시간과 겹치는 자동 실행을 이름·시각으로 미리 말한다(끝 시각은 포함하지 않는다)', (tester) async {
    _tall(tester);
    final server = _Server()
      ..state = {..._Server().state, 'enabled': false, 'active': false, 'reason': null}
      ..rules = [
        _timeRule('저녁 공기청정기 켜기', '22:00'),
        _timeRule('아침 공기청정기 끄기', '07:00'),
        _timeRule('새벽 끄기', '03:00', enabled: false),
      ];
    await tester.pumpWidget(_build(server.api()));
    await _settle(tester);
    expect(findPlainText('켜면 이 자동 실행은 건너뛰어요: 저녁 공기청정기 켜기(22:00)'), findsOneWidget);
    expect(findPlainText('아침 공기청정기 끄기', contains: true), findsNothing);
    expect(findPlainText('새벽 끄기', contains: true), findsNothing);
  });

  test('겹침 판정 — 자정을 넘는 시간대와 넘지 않는 시간대', () {
    expect(quietWindowContains('22:00', '07:00', '22:00'), isTrue);
    expect(quietWindowContains('22:00', '07:00', '03:30'), isTrue);
    expect(quietWindowContains('22:00', '07:00', '07:00'), isFalse);
    expect(quietWindowContains('13:00', '15:00', '14:59'), isTrue);
    expect(quietWindowContains('13:00', '15:00', '12:00'), isFalse);
  });

  testWidgets('알림 구획 안에 서버 상태 그대로 — 매일 시간대·지금 조용한 시간·실제 범위', (tester) async {
    _tall(tester);
    await tester.pumpWidget(_build(_Server().api()));
    await _settle(tester);
    expect(findPlainText('조용한 시간'), findsOneWidget);
    expect(findPlainText('매일 22:00~07:00 · 지금 조용한 시간이에요'), findsOneWidget);
    expect(findPlainText('새 제안과 일반 안내 소리만 쉬어요', contains: true), findsOneWidget);
    expect(findPlainText('직접 실행·정지는 그대로예요', contains: true), findsOneWidget);
    expect(findPlainText('모든 알림', contains: true), findsNothing);
    // 잠시 쉬기도 같은 범위로 말한다(자동 실행도 건너뛴다).
    expect(findPlainText('몇 시간 동안 새 제안과 자동 실행을 쉬어요'), findsOneWidget);
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
    expect(findPlainText('매일 22:00~07:00 · 꺼져 있어요'), findsOneWidget);
    expect(findPlainText(kSettingNotSavedNotice), findsNothing);
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
    expect(findPlainText('매일 22:00~07:00 · 꺼져 있어요'), findsOneWidget);
    expect(findPlainText(kSettingNotSavedNotice), findsOneWidget);
  });

  testWidgets('허브가 없으면 설정할 수 없다고 말하고 스위치를 잠근다', (tester) async {
    _tall(tester);
    await tester.pumpWidget(_build(null));
    await _settle(tester);
    expect(findPlainText('허브와 연결되면 설정할 수 있어요.'), findsOneWidget);
    final sw = tester.widget<Switch>(find.descendant(
        of: find.byKey(const Key('quiet-hours-switch')), matching: find.byType(Switch)));
    expect(sw.onChanged, isNull);
  });
}
