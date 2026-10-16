import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/providers/ble_provider.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/models/execution_status.dart';
import 'package:simplelay/providers/demo_provider.dart';
import 'package:simplelay/providers/hub_provider.dart';
import 'package:simplelay/providers/wellness_pause_provider.dart';
import 'package:simplelay/models/appliance.dart';
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
  void Function(ProviderContainer)? onContainerReady,
  ExecutionStatus? executionStatus,
}) {
  return buildScreen(
    const SettingsScreen(),
    overrides: [
      ..._scanOverrides(value: scanValue),
      // 가전 선택 칩을 보려면 고를 가전이 있어야 한다.
      ...installedOverrides([kTestAppliance]),
      ...extra,
    ],
    executionStatus: executionStatus,
    onContainerReady: onContainerReady,
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

// 2026-09-30 개편: 예전 '고급 설정'의 서버 주소·API 키·예비 연결(BLE)은 설정 →
// 허브 화면으로, 데모·개발자 도구는 개발자 탭으로 옮겼다. 같은 테스트를 새 자리에서
// 다시 본다.
Widget _buildHub({
  AsyncValue<List<ScanResult>>? scanValue,
  void Function(ProviderContainer)? onContainerReady,
}) =>
    buildScreen(
      const HubSettingsScreen(),
      overrides: [..._scanOverrides(value: scanValue)],
      onContainerReady: onContainerReady,
    );

Widget _buildDev({
  void Function(ProviderContainer)? onContainerReady,
  ExecutionStatus? executionStatus,
  bool developerMode = true,
}) =>
    buildScreen(
      const DeveloperTabScreen(),
      overrides: [
        ..._scanOverrides(),
        developerModeProvider.overrideWithValue(developerMode),
      ],
      executionStatus: executionStatus,
      onContainerReady: onContainerReady,
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('SettingsScreen — 기본 레이아웃', () {
    testWidgets('"설정" AppBar 표시', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildSettings());
      await tester.pump();
      expect(findPlainText('설정'), findsOneWidget);
    });

    testWidgets('UI 확정 §2의 여섯 항목이 그 순서로 맨 위에 있다', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildSettings());
      await tester.pump();
      const rows = [
        '허브',
        'LG ThinQ 연결',
        '보호자 알림',
        '글자 크기',
      ];
      double? last;
      for (final label in rows) {
        final f = find.widgetWithText(ListTile, label);
        expect(f, findsOneWidget, reason: label);
        final y = tester.getTopLeft(f).dy;
        if (last != null) expect(y, greaterThan(last), reason: label);
        last = y;
      }
    });

    testWidgets('가전 목록은 상세로 이어지고 옛 선택 칩을 숨겨요', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildSettings());
      await tester.pump();
      expect(findPlainText('제어 가전'), findsNothing);
      expect(findPlainText('새 가전'), findsNothing);
      expect(findPlainText('음성으로 멈추기'), findsNothing);
      expect(findPlainText('가전 추가'), findsNothing);
      expect(find.widgetWithText(ListTile, '전자레인지'), findsWidgets);
    });

    // UI 평가 10/17: 홈은 5대인데 설정 '내 가전'은 ThinQ 가전을 빼 4대였고, 지우기가 없는 줄은 이유도 화살표도 없었다.
    testWidgets('내 가전: ThinQ 가전도 보이고, 지울 수 없는 줄은 이유와 화살표', (tester) async {
      _useTallViewport(tester);
      final purifier = ApplianceMap.fromJson({
        'id': 'air_purifier',
        'name': '공기청정기',
        'rows': 1,
        'cols': 1,
        'buttons': const [],
        'control_path': 'thinq',
      });
      await tester.pumpWidget(buildScreen(
        const SettingsScreen(),
        overrides: [
          ..._scanOverrides(),
          ...installedOverrides([kTestAppliance, purifier]),
        ],
      ));
      await tester.pump();
      expect(find.widgetWithText(ListTile, '공기청정기'), findsOneWidget);
      expect(findPlainText('ThinQ 가전 · 빼기는 LG ThinQ 연결에서'), findsOneWidget);
      expect(findPlainText('기본 가전'), findsOneWidget);
      expect(find.descendant(of: find.widgetWithText(ListTile, '공기청정기'), matching: find.byIcon(Icons.chevron_right)),
          findsOneWidget);
    });

    testWidgets('허브 화면에 RPi 서버 URL 입력 필드가 보인다', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildHub());
      await tester.pump();
      expect(
        find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.hintText == 'http://simplelay.local:8000',
        ),
        findsOneWidget,
      );
    });

    testWidgets('허브 화면에 주소 저장 버튼이 보인다', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildHub());
      await tester.pump();
      expect(find.widgetWithText(FilledButton, '저장'), findsOneWidget);
    });

    testWidgets('허브 화면에 주변 BLE 기기 섹션 타이틀이 보인다', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildHub());
      await tester.pump();
      expect(findPlainText('주변 BLE 기기'), findsOneWidget);
    });

    testWidgets('허브 화면에 검색된 기기 없음 문구가 보인다 (빈 목록)', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildHub());
      await tester.pump();
      // 스트림의 첫 데이터 이벤트가 반영되려면 pump 한 번 더 필요.
      await tester.pump();
      expect(findPlainText('찾은 기기가 없어요.'), findsOneWidget);
    });
  });

  group('SettingsScreen — 스캔 로딩', () {
    // 이 로딩 표시는 '가전마다 버튼을 눌러 줄 장치'(노드 목록) 구획의 것이었다. 그 구획을 개발자 탭으로
    // 옮겨(2026-10-14 UX) 설정 첫 화면에는 로딩 표시가 남지 않는다.
    testWidgets('누름 장치 구획을 옮겨 설정 첫 화면엔 로딩 표시가 없다', (tester) async {
      _useTallViewport(tester);
      // scanResultsProvider가 loading 상태를 내보내도록 절대 완료되지 않는 스트림을 사용
      final w = buildScreen(
        const SettingsScreen(),
        overrides: [
          scanResultsProvider.overrideWith(
            (ref) => Stream<List<ScanResult>>.empty(),
          ),
          ...installedOverrides([kTestAppliance]),
        ],
      );
      await tester.pumpWidget(w);
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });

  group('안부 확인 쉬기 (F5)', () {
    testWidgets('평소에는 쉬고 있지 않다고 말한다', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildSettings());
      await tester.pump();

      expect(findPlainText('안부 확인 쉬기'), findsOneWidget);
      expect(findPlainText('쉬기'), findsOneWidget);
      expect(findPlainText('여행처럼 집을 비우는 날', contains: true), findsOneWidget);
      // 부제는 어절 단위로만 줄바꿈('정상 / 인' 방지)·14pt 이상, 화면 읽기는 원문(UI 평가 3차 10/17).
      final sub = tester.widget<Text>(findPlainText('여행처럼 집을 비우는 날', contains: true));
      expect(sub.data, contains(kWordJoiner));
      expect(sub.style?.fontSize, greaterThanOrEqualTo(14));
      expect(sub.semanticsLabel, '여행처럼 집을 비우는 날 켜세요. 조용한 게 정상인 날 알림이 오지 않아요.');
    });

    testWidgets('쉬는 동안에도 실패·위험 알림은 간다고 말한다', (tester) async {
      // 이 약속이 화면에 없으면, 안부를 쉬는 것이 알림을 전부 끄는 것으로
      // 읽힌다 — 그러면 여행 갈 때 아무도 안 켠다.
      _useTallViewport(tester);
      await tester.pumpWidget(
        _buildSettings(
          extra: [
            wellnessPauseProvider.overrideWith(
              (ref) => _PausedNotifier(ref, DateTime(2026, 7, 30)),
            ),
          ],
        ),
      );
      await tester.pump();

      expect(findPlainText('7월 30일까지 쉬어요', contains: true), findsOneWidget);
      expect(findPlainText('실행 실패·위험 신호음은 그대로', contains: true), findsOneWidget);
      expect(findPlainText('지금 켜기'), findsOneWidget);
    });

    testWidgets('버튼이 48px 이상이다', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildSettings());
      await tester.pump();

      final size = tester.getSize(find.widgetWithText(OutlinedButton, '쉬기'));
      expect(size.height, greaterThanOrEqualTo(48));
    });
  });

  group('SettingsScreen — 데모 섹션', () {
    // 데모는 디버그 빌드가 아니라 개발자 탭에 있다(UI 확정 §1-6: 데모 흔적은
    // 개발자 모드에서만). 결선 리허설은 릴리즈 APK로 하므로 빌드로 가르지 않는다.
    testWidgets('설정 탭에는 데모·개발자 도구가 보이지 않는다', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildSettings());
      await tester.pump();
      expect(findPlainText('데모 모드'), findsNothing);
      expect(findPlainText('제안 시뮬레이션'), findsNothing);
      expect(findPlainText('개발자 도구'), findsNothing);
      expect(findPlainText('고급 설정'), findsNothing);
    });

    testWidgets('개발자 탭에 데모 모드 토글과 시뮬레이션이 보인다', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildDev());
      await tester.pump();
      expect(findPlainText('데모 모드'), findsOneWidget);
      expect(findPlainText('제안 시뮬레이션'), findsOneWidget);
      expect(findPlainText('연결 해제'), findsOneWidget);
    });

    testWidgets('데모 모드는 기본이 꺼짐이다', (tester) async {
      // 디버그 빌드라는 이유만으로 켜지면 안 된다 -- 실기기에 물린 디버그
      // 빌드에서 가짜 센서가 섞이면 안 눌린 실행이 성공으로 보인다.
      _useTallViewport(tester);
      late ProviderContainer container;
      await tester.pumpWidget(
        _buildSettings(onContainerReady: (c) => container = c),
      );
      await tester.pump();
      expect(container.read(demoModeProvider), isFalse);
    });

    testWidgets('토글을 켜면 데모 모드가 켜진다', (tester) async {
      _useTallViewport(tester);
      late ProviderContainer container;
      await tester.pumpWidget(
        _buildDev(onContainerReady: (c) => container = c),
      );
      await tester.pump();
      await tester.tap(
        find.descendant(
          of: find.widgetWithText(SwitchListTile, '데모 모드'),
          matching: find.byType(Switch),
        ),
      );
      await tester.pump();
      expect(container.read(demoModeProvider), isTrue);
    });

    testWidgets('실행 중에는 데모 토글이 잠긴다', (tester) async {
      // 모드를 갈아타면 실행 경로(실제 서버 / 모의)가 통째로 바뀌는데,
      // 그 순간 진행 중이던 작업은 추적을 잃는다.
      _useTallViewport(tester);
      await tester.pumpWidget(
        _buildDev(
          executionStatus: const ExecutionStatus(
            phase: ExecutionPhase.running,
            label: '즉석밥 데워줘',
          ),
        ),
      );
      await tester.pump();

      final toggle = tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, '데모 모드'),
      );
      expect(toggle.onChanged, isNull);
      expect(findPlainText('실행이 끝난 뒤에 바꿀 수 있어요'), findsOneWidget);
    });

    testWidgets('개발자 도구 진입은 개발자 탭에만 있고 모의·실제 장치를 단정하지 않는다',
        (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildDev());
      await tester.pump();
      expect(findPlainText('개발자 도구'), findsOneWidget);
      // 서버가 실제 장치일 수 있어 '실제로 움직이지 않는다'고 단정하지 않는다(10/12).
      expect(findPlainText('실제로 움직이지 않', contains: true), findsNothing);
      expect(findPlainText('들어가면 어느 쪽인지 표시돼요', contains: true), findsOneWidget);
    });

    testWidgets('제안 시뮬레이션 탭 시 SnackBar 표시', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildDev());
      await tester.pump();
      await tester.tap(findPlainText('제안 시뮬레이션'));
      await tester.pump();
      expect(findPlainText('데모 제안 주입 완료'), findsOneWidget);
    });

    testWidgets('연결 해제 탭 시 SnackBar 표시', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildDev());
      await tester.pump();
      await tester.tap(findPlainText('연결 해제'));
      await tester.pump();
      expect(findPlainText('연결 해제 시뮬레이션'), findsOneWidget);
    });
  });

  group('개발자 탭 — 개발자 모드가 꺼지면', () {
    testWidgets('데모도 꺼져 있으면 도구 대신 꺼졌다고만 말한다', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildDev(developerMode: false));
      await tester.pump();
      expect(findPlainText('허브의 개발자 모드가 꺼져 있어요.'), findsOneWidget);
      expect(findPlainText('개발자 도구'), findsNothing);
      expect(findPlainText('데모 모드'), findsNothing);
    });
  });

  group('SettingsScreen — 저장 기능', () {
    testWidgets('저장 버튼 탭 시 rpiUrlProvider가 기본값으로 반영된다', (tester) async {
      _useTallViewport(tester);
      late ProviderContainer container;
      await tester.pumpWidget(_buildHub(
        onContainerReady: (c) => container = c,
      ));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, '저장'));
      await tester.pump();
      expect(container.read(rpiUrlProvider), 'http://simplelay.local:8000');
    });

    testWidgets('TextField에 값 입력 후 저장 탭 시 그 값이 rpiUrlProvider에 반영된다',
        (tester) async {
      _useTallViewport(tester);
      late ProviderContainer container;
      await tester.pumpWidget(_buildHub(
        onContainerReady: (c) => container = c,
      ));
      await tester.pump();
      final urlField = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.hintText == 'http://simplelay.local:8000',
      );
      await tester.enterText(urlField, 'http://192.168.0.42:8000');
      await tester.tap(find.widgetWithText(FilledButton, '저장'));
      await tester.pump();
      expect(container.read(rpiUrlProvider), 'http://192.168.0.42:8000');
    });
  });
}

/// 이미 쉬는 중인 상태를 그대로 주입한다 — 서버 왕복 없이 화면만 본다.
class _PausedNotifier extends WellnessPauseNotifier {
  _PausedNotifier(super.ref, DateTime until) {
    state = until;
  }

  @override
  Future<void> refresh() async {}
}
