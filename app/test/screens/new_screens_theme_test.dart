// 2026-09-30 개편 화면들을 **앱의 실제 테마**로 그려 본다(보통 크기·200%).
//
// 다른 위젯 테스트는 ThemeData.dark()를 쓴다. 그런데 앱 테마의 Filled/Outlined
// 버튼은 화면 폭을 채운다(Size.fromHeight) -- 줄(Row)이나 앱바 안에 두면 무한 폭
// 제약으로 레이아웃이 무너진다. 골든을 찍기 전까지 이 결함이 가전 상세에 숨어
// 있었다. 골든이 없는 새 화면도 여기서 한 번씩 그려서 예외가 없는지 본다.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/appliance.dart';
import 'package:simplelay/models/hub.dart';
import 'package:simplelay/models/routine.dart';
import 'package:simplelay/providers/ble_provider.dart';
import 'package:simplelay/providers/hub_provider.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/add_appliance_wizard_screen.dart';
import 'package:simplelay/screens/app_info_screen.dart';
import 'package:simplelay/screens/appliance_detail_screen.dart';
import 'package:simplelay/screens/home_screen.dart';
import 'package:simplelay/screens/routine_editor_screen.dart';
import 'package:simplelay/screens/routine_record_screen.dart';
import 'package:simplelay/screens/routines_screen.dart';
import 'package:simplelay/screens/settings_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';
import 'package:simplelay/theme/app_theme.dart';

import '../helpers/test_helpers.dart';

final _mapped = ApplianceMap(
  id: 'custom_1',
  name: '전자레인지',
  location: '주방',
  category: ApplianceCategory.microwave,
  rows: 1,
  cols: 2,
  buttons: const [
    ApplianceButton(id: 'B01', label: '시작', x: 0, y: 0),
    ApplianceButton(id: 'B02', label: '취소', x: 1, y: 0),
  ],
  isCustom: true,
  stopButton: 'B02',
  panelMapping: const PanelMapping(
    photoWidth: 1000,
    photoHeight: 800,
    buttons: {'B01': PhotoPoint(300, 400), 'B02': PhotoPoint(700, 400)},
    parkPoint: PhotoPoint(950, 750),
  ),
);

RpiApiService _api() => RpiApiService(
      'http://rpi5.local:8000',
      client: MockClient((req) async {
        final body = switch (req.url.path) {
          '/routines' => [
              {
                'id': 'rt-1',
                'name': '아침 데우기',
                'steps': [
                  {'kind': 'press_sequence', 'appliance_id': 'custom_1', 'buttons': ['B01']},
                ],
                'trigger': {'kind': 'time', 'days': [0, 1, 2, 3, 4], 'time': '07:30'},
                'mode': 'approve',
                'enabled': true,
                'when': '평일 07:30',
              },
            ],
          '/routines/next' || '/routines/templates' || '/history' => <dynamic>[],
          '/hub/location' => {'source': 'none'},
          _ => {'detail': 'not found'},
        };
        return http.Response.bytes(utf8.encode(jsonEncode(body)), 200,
            headers: {'content-type': 'application/json'});
      }),
    );

Future<void> _render(WidgetTester tester, Widget screen, double scale) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(buildWithProviderState(
    overrides: [
      ...connectedOverrides(),
      ...installedOverrides([_mapped]),
      rpiApiServiceProvider.overrideWithValue(_api()),
      scanResultsProvider.overrideWith((ref) => Stream.value(const [])),
      developerModeProvider.overrideWithValue(true),
    ],
    child: MaterialApp(
      theme: AppTheme.light,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: screen,
    ),
  ));
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(tester.takeException(), isNull);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  final screens = <String, Widget>{
    '홈': const HomeScreen(),
    '루틴 탭': const RoutinesScreen(),
    '루틴 편집': RoutineEditorScreen(
      initial: Routine(
        id: 'rt-1',
        name: '아침 데우기',
        steps: const [
          RoutineStep.press('custom_1', ['B01']),
          RoutineStep.announce('약 드실 시간이에요'),
        ],
      ),
    ),
    '누르는 순서 저장': const RoutineRecordScreen(applianceId: 'custom_1'),
    '가전 상세': const ApplianceDetailScreen(applianceId: 'custom_1'),
    '가전 추가': const AddApplianceWizardScreen(),
    '설정': const SettingsScreen(),
    '본체': const HubSettingsScreen(),
    '개발자 탭': const DeveloperTabScreen(),
    '앱 정보': const AppInfoScreen(),
  };

  for (final entry in screens.entries) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('${entry.key} — 앱 테마·${(scale * 100).round()}%에서 예외 없이 그린다',
          (tester) async {
        await _render(tester, entry.value, scale);
      });
    }
  }
}
