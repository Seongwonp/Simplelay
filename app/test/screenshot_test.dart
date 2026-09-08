// 폰 화면을 실제 이미지로 렌더한다 — 눈으로 확인하기 위한 도구다.
//
// 위젯 테스트는 "그 문구가 있다"까지만 확인한다. 큰 글씨에서 버튼 안 글자가 잘리거나,
// 근거 줄이 말줄임으로 사라지는 것은 테스트가 통과하면서도 벌어진다 — 실제로 키오스크
// 쪽에서 그 두 가지가 이 방식으로만 드러났다.
//
// 실행: flutter test test/screenshot_test.dart --update-goldens
//   -> test/goldens/*.png. 통과/실패를 다투는 골든이 아니라 **보기 위한** 산출물이다
//      (폰트 렌더가 환경마다 다르므로 CI에서 깨지는 것이 목적이 아니다).
//
// 참고: 테스트 환경에는 MaterialIcons 폰트가 없어 아이콘이 네모로 나온다. 실기기에는
// 정상이다(docs/screenshots의 실제 캡처 참고) — 여기서 볼 것은 레이아웃과 글자다.
// 다른 기기에서는 폰트 렌더가 달라 이미지가 어긋날 수 있다. 그때는
//   flutter test --exclude-tags screenshot
// 로 빼고 돌리면 된다.
@Tags(['screenshot'])
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/suggestion.dart';
import 'package:simplelay/models/execution_status.dart';
import 'package:simplelay/screens/home_screen.dart';
import 'package:simplelay/screens/manual_control_screen.dart';
import 'package:simplelay/screens/settings_screen.dart';
import 'package:simplelay/screens/status_screen.dart';
import 'package:simplelay/screens/suggestion_screen.dart';
import 'package:simplelay/theme/app_theme.dart';

import 'helpers/test_helpers.dart';

const _phoneSize = Size(390, 844);

Future<void> _shoot(
  WidgetTester tester,
  String name,
  Widget screen, {
  List<Suggestion> suggestions = const [],
  ExecutionStatus? executionStatus,
  bool connected = true,
  bool light = false,
  double textScale = 1.0,
  // 실행 화면처럼 계속 도는 애니메이션(진행 표시·차트)이 있으면 pumpAndSettle이
  // 영영 안 끝난다. 그런 화면은 정해진 시간만 돌리고 찍는다.
  bool settle = true,
}) async {
  tester.view.physicalSize = _phoneSize;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    buildWithProviderState(
      suggestions: suggestions,
      executionStatus: executionStatus,
      overrides: connected ? connectedOverrides() : disconnectedOverrides(),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        // 실제 테마를 쓴다 -- 기존 테스트 헬퍼는 ThemeData.dark()를 쓰고 있어서
        // 우리 팔레트가 화면에 어떻게 나오는지는 확인되지 않는다.
        theme: light
            ? AppTheme.light.copyWith(
                textTheme: AppTheme.light.textTheme.apply(fontFamily: 'Malgun'))
            : AppTheme.dark.copyWith(
                textTheme: AppTheme.dark.textTheme.apply(fontFamily: 'Malgun')),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: screen,
      ),
    ),
  );
  // 제안 카드는 등장 애니메이션(_SlidingCard)을 거치므로 정착까지 기다린다.
  // pump 한 번으로는 화면에 아직 안 그려져 있어 빈 화면을 찍게 된다.
  if (settle) {
    await tester.pumpAndSettle(const Duration(milliseconds: 50));
  } else {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
  }
  await expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile('goldens/$name.png'),
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  setUpAll(() async {
    final bytes = File(r'C:\Windows\Fonts\malgun.ttf').readAsBytesSync();
    final loader = FontLoader('Malgun')
      ..addFont(Future.value(ByteData.view(bytes.buffer)));
    await loader.load();
  });

  // 서버에서 온 패턴 제안 — 실기기에서 실제로 오는 모양이다. 근거 문장과
  // '다시 받지 않기'가 이 경로에서만 나오므로, 골든도 이 경로를 찍어야
  // 화면 검토에 쓸모가 있다.
  const suggestions = [
    Suggestion(
      sequenceId: 'a',
      label: '우유 데워줘',
      steps: ['BT-08', 'BT-03', 'BT-05'],
      source: SuggestionSource.http,
      timeBand: '아침',
      occurrences: 4,
    ),
  ];

  testWidgets('홈 — 제안 있음 (다크)', (t) async {
    await _shoot(t, 'home_dark', const HomeScreen(), suggestions: suggestions);
  });

  testWidgets('홈 — 제안 있음 (라이트)', (t) async {
    await _shoot(t, 'home_light', const HomeScreen(),
        suggestions: suggestions, light: true);
  });

  testWidgets('홈 — 제안 없음·미연결', (t) async {
    await _shoot(t, 'home_empty', const HomeScreen(), connected: false);
  });

  testWidgets('홈 — 큰 글씨 (200%)', (t) async {
    await _shoot(t, 'home_large', const HomeScreen(),
        suggestions: suggestions, textScale: 2.0);
  });

  // 홈에서 200% 확대가 무너졌던 원인(Row에 버튼이 끼어 텍스트가 압축되는 구조)이
  // 다른 화면에도 있는지 본다 -- 한 곳만 고치고 넘어가면 같은 결함이 남는다.
  testWidgets('제안 확인', (t) async {
    await _shoot(t, 'suggestion', const SuggestionScreen(sequenceId: 'a'),
        suggestions: suggestions);
  });

  testWidgets('제안 확인 — 큰 글씨 (200%)', (t) async {
    await _shoot(t, 'suggestion_large', const SuggestionScreen(sequenceId: 'a'),
        suggestions: suggestions, textScale: 2.0);
  });

  const running = ExecutionStatus(
    phase: ExecutionPhase.running,
    label: '우유 데워줘',
    sequenceId: 's1',
    steps: ['BT-08', 'BT-03', 'BT-05'],
    completedSteps: 1,
    currentMa: 320,
    soundDb: 42,
  );

  testWidgets('실행 상태', (t) async {
    await _shoot(t, 'status', const StatusScreen(),
        executionStatus: running, settle: false);
  });

  testWidgets('실행 상태 — 큰 글씨 (200%)', (t) async {
    await _shoot(t, 'status_large', const StatusScreen(),
        executionStatus: running, textScale: 2.0, settle: false);
  });

  // 폐루프 증거가 표시되는 실행 화면 -- HTTP 경로(원시 mA/dB 없음)라
  // 센서 차트 대신 "무슨 버튼을 누르고 어떻게 확인했는지"가 자리를 차지한다.
  const runningWithEvidence = ExecutionStatus(
    phase: ExecutionPhase.running,
    label: '즉석밥 데워줘',
    sequenceId: 's2',
    message: '실행 중',
    currentButton: '1분 추가',
    totalSteps: 3,
    completedSteps: 1,
    verificationConfidence: 0.93,
    verificationDetail: '센서로 눌림 확인',
  );

  testWidgets('실행 상태 — 폐루프 증거', (t) async {
    await _shoot(t, 'status_closed_loop', const StatusScreen(),
        executionStatus: runningWithEvidence, settle: false);
  });

  // 설정·수동 조작도 행 끝에 컨트롤이 붙는 구조라 홈과 같은 압축이 일어날 수 있다
  testWidgets('설정', (t) async {
    await _shoot(t, 'settings', const SettingsScreen(), settle: false);
  });

  testWidgets('설정 — 큰 글씨 (200%)', (t) async {
    await _shoot(t, 'settings_large', const SettingsScreen(),
        textScale: 2.0, settle: false);
  });

  testWidgets('수동 조작 — 큰 글씨 (200%)', (t) async {
    await _shoot(t, 'manual_large', const ManualControlScreen(),
        textScale: 2.0, settle: false);
  });
}
