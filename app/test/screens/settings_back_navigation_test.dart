// 설정 하위 화면에서 안드로이드 시스템 뒤로 가기(2026-09-30 에뮬레이터 결함).
//
// 설정 → 앱 정보에서 뒤로 가기를 누르면 설정으로 돌아오지 않고 앱이 통째로
// 닫혔다. 앱은 targetSdk 36이라 안드로이드 16부터 **예측 뒤로 가기**가 기본으로
// 켜진다. 이때 운영체제는 뒤로 가기를 Flutter에 묻지 않고, 프레임워크가 미리
// 알려 둔 `SystemNavigator.setFrameworkHandlesBack(참/거짓)`만 보고 거짓이면
// 액티비티를 바로 닫는다. 그래서 두 가지를 본다.
//   1. 하위 화면이 열린 뒤 마지막으로 알린 값이 **참**인가(운영체제가 앱을 닫지 않는가).
//   2. `handlePopRoute()`(예전 뒤로 가기 길)로 설정이 다시 보이는가.
// main.dart의 **실제 경로표**(`buildAppRouter`)로 띄운다 -- 사본으로는 못 잡는다.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/main.dart';
import 'package:simplelay/providers/ble_provider.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';

import '../helpers/test_helpers.dart';

/// 프레임워크가 운영체제에 알린 "뒤로 가기를 내가 처리한다" 값들.
List<bool> _recordFrameworkHandlesBack(WidgetTester tester) {
  final calls = <bool>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'SystemNavigator.setFrameworkHandlesBack') {
        calls.add(call.arguments as bool);
      }
      return null;
    },
  );
  addTearDown(() => tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, null));
  return calls;
}

Future<void> _pumpSettings(WidgetTester tester) async {
  tester.view.physicalSize = const Size(500, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  // 알림은 앱이 살아 있는 상태에서만 운영체제로 간다(WidgetsApp 규칙).
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.pumpWidget(buildWithProviderState(
    overrides: [
      // 서버 없이 띄운다 -- 여기 관심사는 내비게이션이다.
      rpiApiServiceProvider.overrideWithValue(null),
      rpiServerOverride(RpiConnectionState.unconfigured),
      scanResultsProvider.overrideWith((ref) => Stream.value(const [])),
      ...installedOverrides([kTestAppliance]),
    ],
    child: MaterialApp.router(
      routerConfig: buildAppRouter(initialLocation: '/settings'),
    ),
  ));
  await tester.pumpAndSettle();
}

/// 설정 화면이 맨 앞에 보이는가 -- AppBar 제목 '설정'과 '앱 정보' 줄.
void _expectSettingsVisible() {
  expect(find.widgetWithText(AppBar, '설정'), findsOneWidget);
  expect(find.text('날씨 출처와 이용 허락'), findsOneWidget);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  // 줄 제목 → 열린 화면의 AppBar 제목.
  const subScreens = <String, String>{
    '앱 정보': '앱 정보',
    '허브': '허브',
    'LG ThinQ 연결': 'LG ThinQ 연결',
    '음성으로 멈추기': '음성으로 멈추기',
    '보호자 알림': '알림',
    '글자 크기': '글자 크기',
    '가전 추가': '가전 추가',
  };

  for (final MapEntry(key: row, value: appBarTitle) in subScreens.entries) {
    testWidgets('설정 → $row에서 시스템 뒤로 가기는 설정으로 돌아온다', (tester) async {
      final handlesBack = _recordFrameworkHandlesBack(tester);
      await _pumpSettings(tester);
      _expectSettingsVisible();

      await tester.tap(find.text(row).first);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, appBarTitle), findsWidgets,
          reason: '$row 화면이 열려야 한다');

      // 운영체제가 보는 마지막 값. 거짓이면 뒤로 가기에 앱이 닫힌다.
      expect(handlesBack, isNotEmpty);
      expect(handlesBack.last, isTrue,
          reason: '$row 화면에서 운영체제에 "뒤로 가기 처리 안 함"을 알리면 앱이 닫힌다');

      final handled = await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(handled, isTrue, reason: '뒤로 가기가 앱 종료로 새면 안 된다');
      expect(find.widgetWithText(AppBar, appBarTitle), findsNothing);
      _expectSettingsVisible();
      // 설정 탭 첫 화면으로 돌아오면 더 뒤로 갈 곳이 없다 -- 그때는 거짓이 맞다.
      expect(handlesBack.last, isFalse);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }
}
