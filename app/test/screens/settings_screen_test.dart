import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/providers/ble_provider.dart';
import 'package:simplelay/screens/settings_screen.dart';

import '../helpers/test_helpers.dart';

List<Override> _scanOverrides({
  AsyncValue<List<ScanResult>>? value,
}) =>
    [
      scanResultsProvider.overrideWith(
        (ref) => Stream.value((value ?? const AsyncValue.data([])).value ?? []),
      ),
    ];

Widget _buildSettings({
  AsyncValue<List<ScanResult>>? scanValue,
  List<Override> extra = const [],
}) {
  return buildScreen(
    const SettingsScreen(),
    overrides: [
      ..._scanOverrides(value: scanValue),
      ...extra,
    ],
  );
}

// SettingsScreen 본문은 ListView고 섹션이 많이 늘어나서(기기이름/RPi URL/가전종류/
// 저장된 기기/BLE 스캔/데모) 기본 테스트 뷰포트(800x600)로는 하단 섹션의 Element가
// 아예 안 만들어진다 — status/suggestion_screen_test.dart와 동일한 문제.
void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(400, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('SettingsScreen — 기본 레이아웃', () {
    testWidgets('"설정" AppBar 표시', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildSettings());
      await tester.pump();
      expect(find.text('설정'), findsOneWidget);
    });

    testWidgets('기기 이름 입력 필드 표시', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildSettings());
      await tester.pump();
      // RPi 서버 URL 섹션에도 TextField가 있어서(둘 다 표시됨) hintText로 특정한다.
      expect(
        find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.hintText == 'SimpleLay',
        ),
        findsOneWidget,
      );
    });

    testWidgets('저장 버튼 표시', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildSettings());
      await tester.pump();
      // RPi URL 섹션의 저장 버튼은 FilledButton이라 TextButton으로 좁히면 구분된다.
      expect(find.widgetWithText(TextButton, '저장'), findsOneWidget);
    });

    testWidgets('주변 BLE 기기 섹션 타이틀 표시', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildSettings());
      await tester.pump();
      expect(find.text('주변 BLE 기기'), findsOneWidget);
    });

    testWidgets('검색된 기기 없음 문구 (빈 목록)', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildSettings());
      await tester.pump();
      expect(find.text('검색된 기기가 없습니다.'), findsOneWidget);
    });
  });

  group('SettingsScreen — 스캔 로딩', () {
    testWidgets('로딩 중일 때 CircularProgressIndicator 표시', (tester) async {
      _useTallViewport(tester);
      // scanResultsProvider가 loading 상태를 내보내도록 절대 완료되지 않는 스트림을 사용
      final w = buildScreen(
        const SettingsScreen(),
        overrides: [
          scanResultsProvider.overrideWith(
            (ref) => Stream<List<ScanResult>>.empty(),
          ),
        ],
      );
      await tester.pumpWidget(w);
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });
  });

  group('SettingsScreen — 데모 섹션', () {
    testWidgets('debug 빌드에서 제안 시뮬레이션 버튼 표시', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildSettings());
      await tester.pump();
      if (kDebugMode) {
        expect(find.text('제안 시뮬레이션'), findsOneWidget);
        expect(find.text('연결 해제'), findsOneWidget);
      }
    });

    testWidgets('제안 시뮬레이션 탭 시 SnackBar 표시', (tester) async {
      if (!kDebugMode) return;
      _useTallViewport(tester);
      await tester.pumpWidget(_buildSettings());
      await tester.pump();
      await tester.tap(find.text('제안 시뮬레이션'));
      await tester.pump();
      expect(
        find.text('데모 제안을 주입했습니다. 홈 화면을 확인하세요.'),
        findsOneWidget,
      );
    });

    testWidgets('연결 해제 탭 시 SnackBar 표시', (tester) async {
      if (!kDebugMode) return;
      _useTallViewport(tester);
      await tester.pumpWidget(_buildSettings());
      await tester.pump();
      await tester.tap(find.text('연결 해제'));
      await tester.pump();
      expect(find.text('연결 해제 시뮬레이션'), findsOneWidget);
    });
  });

  group('SettingsScreen — 저장 기능', () {
    testWidgets('저장 버튼 탭 시 SnackBar 표시', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildSettings());
      await tester.pump();
      await tester.tap(find.widgetWithText(TextButton, '저장'));
      await tester.pump();
      expect(find.text('기기 이름을 저장했습니다.'), findsOneWidget);
    });

    testWidgets('TextField에 값 입력 후 저장 탭 시 SnackBar 표시', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildSettings());
      await tester.pump();
      final nameField = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.hintText == 'SimpleLay',
      );
      await tester.enterText(nameField, 'MyDevice');
      await tester.tap(find.widgetWithText(TextButton, '저장'));
      await tester.pump();
      expect(find.text('기기 이름을 저장했습니다.'), findsOneWidget);
    });
  });
}
