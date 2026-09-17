import 'package:flutter/semantics.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/providers/ble_provider.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/models/execution_status.dart';
import 'package:simplelay/providers/demo_provider.dart';
import 'package:simplelay/providers/wellness_pause_provider.dart';
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

// RPi URL 수동 입력·BLE 스캔 섹션은 "고급 설정" 토글 뒤에 숨어있다 — 열어야 보인다.
Future<void> _expandAdvanced(WidgetTester tester) async {
  await tester.tap(find.text('고급 설정'));
  await tester.pump();
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

    testWidgets('가전 선택 칩이 선택 상태와 터치 목표를 만족한다', (tester) async {
      // 체크 아이콘은 눈으로만 보이는 신호다 -- 스크린리더 사용자도 무엇이
      // 선택됐는지 알아야 하고, 칩 자체가 누르기 충분해야 한다.
      final handle = tester.ensureSemantics();
      _useTallViewport(tester);
      await tester.pumpWidget(_buildSettings());
      await tester.pump();

      final chip = find
          .ancestor(
            of: find.text('전자레인지'),
            matching: find.byType(AnimatedContainer),
          )
          .first;

      // 제품 터치 목표 48 (WCAG 2.2 AA 최소치 24보다 높게 잡은 값)
      expect(tester.getSize(chip).height, greaterThanOrEqualTo(48.0));
      expect(
        tester.getSemantics(chip).hasFlag(SemanticsFlag.isSelected),
        isTrue,
      );
      handle.dispose();
    });

    testWidgets('고급 설정을 열면 RPi 서버 URL 입력 필드가 보인다', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildSettings());
      await tester.pump();
      await _expandAdvanced(tester);
      expect(
        find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.hintText == 'http://simplelay.local:8000',
        ),
        findsOneWidget,
      );
    });

    testWidgets('고급 설정을 열면 저장 버튼이 보인다', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildSettings());
      await tester.pump();
      await _expandAdvanced(tester);
      expect(find.widgetWithText(FilledButton, '저장'), findsOneWidget);
    });

    testWidgets('고급 설정을 열면 주변 BLE 기기 섹션 타이틀이 보인다', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildSettings());
      await tester.pump();
      await _expandAdvanced(tester);
      expect(find.text('주변 BLE 기기'), findsOneWidget);
    });

    testWidgets('고급 설정을 열면 검색된 기기 없음 문구가 보인다 (빈 목록)', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildSettings());
      await tester.pump();
      await _expandAdvanced(tester);
      // _BleSection이 확장 시점에 처음 mount되면서 scanResultsProvider를 그제서야
      // watch하기 시작 — 스트림의 첫 데이터 이벤트가 반영되려면 pump 한 번 더 필요.
      await tester.pump();
      expect(find.text('찾은 기기가 없어요.'), findsOneWidget);
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
          ...installedOverrides([kTestAppliance]),
        ],
      );
      await tester.pumpWidget(w);
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });
  });

  group('안부 확인 쉬기 (F5)', () {
    testWidgets('평소에는 쉬고 있지 않다고 말한다', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildSettings());
      await tester.pump();

      expect(find.text('안부 확인 쉬기'), findsOneWidget);
      expect(find.text('쉬기'), findsOneWidget);
      expect(find.textContaining('여행처럼 집을 비우는 날'), findsOneWidget);
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

      expect(find.textContaining('7월 30일까지 쉬어요'), findsOneWidget);
      expect(find.textContaining('실행 실패·위험 신호음은 그대로'), findsOneWidget);
      expect(find.text('지금 켜기'), findsOneWidget);
    });

    testWidgets('버튼이 48px 이상이다', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildSettings());
      await tester.pump();

      final size = tester.getSize(find.widgetWithText(TextButton, '쉬기'));
      expect(size.height, greaterThanOrEqualTo(48));
    });
  });

  group('SettingsScreen — 데모 섹션', () {
    // 데모는 디버그 빌드가 아니라 '고급'에 있다. 결선 리허설은 릴리즈 APK로
    // 하는데 디버그에만 있으면 정작 필요한 곳에서 못 켠다.
    testWidgets('평소에는 데모가 보이지 않는다', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildSettings());
      await tester.pump();
      expect(find.text('데모 모드'), findsNothing);
      expect(find.text('제안 시뮬레이션'), findsNothing);
    });

    testWidgets('고급 설정을 펴면 데모 모드 토글과 시뮬레이션이 보인다', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildSettings());
      await tester.pump();
      await _expandAdvanced(tester);
      expect(find.text('데모 모드'), findsOneWidget);
      expect(find.text('제안 시뮬레이션'), findsOneWidget);
      expect(find.text('연결 해제'), findsOneWidget);
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
        _buildSettings(onContainerReady: (c) => container = c),
      );
      await tester.pump();
      await _expandAdvanced(tester);
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
        _buildSettings(
          executionStatus: const ExecutionStatus(
            phase: ExecutionPhase.running,
            label: '즉석밥 데워줘',
          ),
        ),
      );
      await tester.pump();
      await _expandAdvanced(tester);

      final toggle = tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, '데모 모드'),
      );
      expect(toggle.onChanged, isNull);
      expect(find.text('실행이 끝난 뒤에 바꿀 수 있어요'), findsOneWidget);
    });

    testWidgets('개발자 도구 진입은 고급 설정 안에만 있고 모의 제어라고 말한다',
        (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildSettings());
      await tester.pump();
      expect(find.text('개발자 도구'), findsNothing);

      await _expandAdvanced(tester);
      expect(find.text('개발자 도구'), findsOneWidget);
      expect(find.textContaining('모의 제어 — 실제로 움직이지 않습니다'), findsOneWidget);
    });

    testWidgets('제안 시뮬레이션 탭 시 SnackBar 표시', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildSettings());
      await tester.pump();
      await _expandAdvanced(tester);
      await tester.tap(find.text('제안 시뮬레이션'));
      await tester.pump();
      expect(find.text('데모 제안 주입 완료'), findsOneWidget);
    });

    testWidgets('연결 해제 탭 시 SnackBar 표시', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildSettings());
      await tester.pump();
      await _expandAdvanced(tester);
      await tester.tap(find.text('연결 해제'));
      await tester.pump();
      expect(find.text('연결 해제 시뮬레이션'), findsOneWidget);
    });
  });

  group('SettingsScreen — 저장 기능', () {
    testWidgets('저장 버튼 탭 시 rpiUrlProvider가 기본값으로 반영된다', (tester) async {
      _useTallViewport(tester);
      late ProviderContainer container;
      await tester.pumpWidget(_buildSettings(
        onContainerReady: (c) => container = c,
      ));
      await tester.pump();
      await _expandAdvanced(tester);
      await tester.tap(find.widgetWithText(FilledButton, '저장'));
      await tester.pump();
      expect(container.read(rpiUrlProvider), 'http://simplelay.local:8000');
    });

    testWidgets('TextField에 값 입력 후 저장 탭 시 그 값이 rpiUrlProvider에 반영된다',
        (tester) async {
      _useTallViewport(tester);
      late ProviderContainer container;
      await tester.pumpWidget(_buildSettings(
        onContainerReady: (c) => container = c,
      ));
      await tester.pump();
      await _expandAdvanced(tester);
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
