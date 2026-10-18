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
// 정상이다(docs/archive/screenshots-2026-08의 실제 캡처 참고) — 여기서 볼 것은 레이아웃과 글자다.
// 다른 기기에서는 폰트 렌더가 달라 이미지가 어긋날 수 있다. 그때는
//   flutter test --exclude-tags screenshot
// 로 빼고 돌리면 된다.
@Tags(['screenshot'])
library;

import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/appliance.dart';
import 'package:simplelay/models/suggestion.dart';
import 'package:simplelay/models/execution_status.dart';
import 'package:simplelay/models/hub.dart';
import 'package:simplelay/models/routine.dart';
import 'package:simplelay/screens/appliance_detail_screen.dart';
import 'package:simplelay/screens/appliance_editor_screen.dart';
import 'package:simplelay/screens/routine_editor_screen.dart';
import 'package:simplelay/screens/history_screen.dart';
import 'package:simplelay/providers/estop_provider.dart';
import 'package:simplelay/providers/execution_status_provider.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/home_screen.dart';
import 'package:simplelay/screens/routines_screen.dart';
import 'package:simplelay/screens/manual_control_screen.dart';
import 'package:simplelay/screens/settings_screen.dart';
import 'package:simplelay/screens/splash_screen.dart';
import 'package:simplelay/screens/app_shell.dart';
import 'package:simplelay/screens/status_screen.dart';
import 'package:simplelay/screens/suggestion_screen.dart';
import 'package:simplelay/screens/voice_screen.dart';
import 'package:simplelay/providers/voice_provider.dart';
import 'package:simplelay/services/rpi_api_service.dart';
import 'package:simplelay/services/voice_service.dart';
import 'package:simplelay/theme/app_theme.dart';

import 'helpers/test_helpers.dart';
import 'support/golden_fonts.dart';

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
  ImageProvider? precache,
  // 실행 화면처럼 계속 도는 애니메이션(진행 표시·차트)이 있으면 pumpAndSettle이
  // 영영 안 끝난다. 그런 화면은 정해진 시간만 돌리고 찍는다.
  bool settle = true,
  // 이 골든이 가정하는 **설치된 가전**. 비우면 아직 아무것도 등록하지 않은
  // 사용자다 -- 그것도 찍어야 하는 정상 상태다.
  List<ApplianceMap>? installed,
  List<Override> extraOverrides = const [],
  // 찍기 전에 화면을 조작해야 하는 상태(예: 마이크를 눌러야 나오는 안내).
  Future<void> Function(WidgetTester tester)? before,
  // 연결된 본체(가짜)로 찍는다 — 홈의 '지금 우리 집'·루틴 타일, 루틴 탭은 본체가 있어야 보인다.
  RpiApiService? hub,
}) async {
  tester.view.physicalSize = _phoneSize;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    buildWithProviderState(
      suggestions: suggestions,
      executionStatus: executionStatus,
      overrides: [
        ...connected ? connectedOverrides() : disconnectedOverrides(),
        ...installedOverrides(installed ?? [kTestAppliance]),
        // 홈 골든은 닿지 않는다고 확인된 서버를 찍는다. 확인 중(기본)은 경고가
        // 없어 연결 경고 화면이 골든에서 사라진다.
        if (hub != null) ...[
          rpiServerOverride(RpiConnectionState.connected),
          rpiApiServiceProvider.overrideWithValue(hub),
        ] else if (screen is HomeScreen)
          rpiServerOverride(RpiConnectionState.unreachable),
        ...extraOverrides,
      ],
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
  if (before != null) {
    await before(tester);
    await tester.pump();
  }
  if (precache != null) {
    // 이미지는 **실제 디코딩**이 끝나야 그려진다. 가짜 시계 위에서는 그
    // 작업이 진행되지 않아, 미리 올려두지 않으면 사진 화면이 빈 프레임으로
    // 찍힌다 -- 사진을 덮는 척하면서 아무것도 검증하지 않는 골든이 된다.
    await tester.runAsync(() async {
      await precacheImage(precache, tester.element(find.byType(MaterialApp)));
    });
    await tester.pump();
  }
  await expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile('goldens/$name.png'),
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  setUpAll(loadGoldenFonts);

  // 서버에서 온 패턴 제안 — 실기기에서 실제로 오는 모양이다. 근거 문장과
  // '다시 받지 않기'가 이 경로에서만 나오므로, 골든도 이 경로를 찍어야
  // 화면 검토에 쓸모가 있다.
  const suggestions = [
    Suggestion(
      sequenceId: 'a',
      label: '즉석밥 데워줘',
      steps: ['BT-08', 'BT-05'],
      applianceId: 'microwave',
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

  // 2026-10-18 홈 개편 — 본체에 닿은 평소 홈(지금 우리 집·가전 상태·루틴 타일).
  for (final (name, light, scale) in [
    ('home_full_light', true, 1.0),
    ('home_full_dark', false, 1.0),
    ('home_full_large', true, 2.0),
  ]) {
    testWidgets('홈 — 본체 연결·평소 ($name)', (t) async {
      await _shoot(t, name, const HomeScreen(),
          light: light,
          textScale: scale,
          installed: _homeInstalled,
          hub: _demoHub(),
          suggestions: suggestions);
    });
  }

  // 2026-10-18 루틴 탭 — 본체가 준 루틴·자동으로 하기.
  for (final (name, light, scale) in [
    ('routines_light', true, 1.0),
    ('routines_large', true, 2.0),
  ]) {
    testWidgets('루틴 탭 ($name)', (t) async {
      await _shoot(t, name, const RoutinesScreen(),
          light: light, textScale: scale, installed: _homeInstalled, hub: _demoHub());
    });
  }

  testWidgets('루틴 탭 — 자동으로 하기 (라이트)', (t) async {
    await _shoot(t, 'routines_rules_light', const RoutinesScreen(),
        light: true, installed: _homeInstalled, hub: _demoHub(), before: (tester) async {
      await tester.tap(findPlainText('자동 규칙'));
      await tester.pumpAndSettle();
    });
  });

  // ── 제출용 장면(심사위원 시각 평가 10/18 §3-5) ─────────────────────────────────────────────
  // 다른 골든의 세탁기 등은 화면 시험용 예시다. 제출 서류·발표 그림에는 지금 실물 구성(누름 장치가 누르는 전자레인지 1대 +
  // LG 공기청정기)으로 만든 아래 장면만 쓴다. 실행 중은 눌림 센서 판정 없이, 결과는 누름 장치 보고(전력 판정 없음)까지만.
  // 2026-10-18 — 연습용 LG 세탁기: 실제 공기청정기 옆에 모의 세탁기 한 대. 세탁기 그림과 '연습' 표시가 보여야 한다.
  testWidgets('LG 세탁기(연습) 상세 (라이트)', (t) async {
    await _shoot(t, 'lt_thinq_washer_practice',
        const ApplianceDetailScreen(applianceId: 'thinq_washer'),
        light: true, installed: _practiceInstalled, hub: _demoHub(practiceWasher: true));
  });

  testWidgets('홈 — LG 세탁기(연습) 가전 칸 (라이트)', (t) async {
    await _shoot(t, 'lt_home_practice_washer', const HomeScreen(),
        light: true, installed: _practiceInstalled, hub: _demoHub(practiceWasher: true));
  });

  testWidgets('제출용 — 홈(전자레인지 + 공기청정기)', (t) async {
    await _shoot(t, 'submission_home', const HomeScreen(),
        light: true, installed: _submissionInstalled, hub: _demoHub(submission: true));
  });

  testWidgets('제출용 — 전자레인지 실행 중', (t) async {
    await _shoot(t, 'submission_status_running', const StatusScreen(),
        light: true,
        installed: _submissionInstalled,
        settle: false,
        executionStatus: const ExecutionStatus(
          phase: ExecutionPhase.running,
          label: '즉석밥 데워줘',
          sequenceId: 'sub-1',
          executionMode: 'real',
          route: 'physical',
          applianceId: 'mine_microwave',
          currentButton: '시작',
          totalSteps: 2,
          completedSteps: 1,
        ));
  });

  testWidgets('제출용 — 전자레인지 결과(누름 장치 보고)', (t) async {
    await _shoot(t, 'submission_status_done', const StatusScreen(),
        light: true,
        installed: _submissionInstalled,
        settle: false,
        executionStatus: const ExecutionStatus(
          phase: ExecutionPhase.completed,
          label: '즉석밥 데워줘',
          sequenceId: 'sub-2',
          executionMode: 'real',
          route: 'physical',
          receipt: 'accepted',
          confirmation: 'reported',
          applianceId: 'mine_microwave',
          totalSteps: 2,
          completedSteps: 2,
        ));
  });

  testWidgets('홈 — 큰 글씨 (200%)', (t) async {
    await _shoot(t, 'home_large', const HomeScreen(),
        suggestions: suggestions, textScale: 2.0);
  });

  // 홈에서 200% 확대가 무너졌던 원인(Row에 버튼이 끼어 텍스트가 압축되는 구조)이
  // 다른 화면에도 있는지 본다 -- 한 곳만 고치고 넘어가면 같은 결함이 남는다.
  testWidgets('할까요?', (t) async {
    await _shoot(t, 'suggestion', const SuggestionScreen(sequenceId: 'a'),
        suggestions: suggestions);
  });

  testWidgets('제안 확인 — 큰 글씨 (200%)', (t) async {
    await _shoot(t, 'suggestion_large', const SuggestionScreen(sequenceId: 'a'),
        suggestions: suggestions, textScale: 2.0);
  });

  // 6단계·긴 가전 이름·긴 말. 하단 고정 행동이 스크롤에 밀리지 않고,
  // 이름과 말이 잘리지 않는지 본다.
  const longSuggestion = [
    Suggestion(
      sequenceId: 'long',
      label: '냉동 만두 데워서 라면이랑 같이 먹을 준비',
      steps: ['AC-01', 'AC-04', 'AC-02', 'AC-02', 'AC-07', 'AC-08'],
      applianceId: 'mine_living_long',
      source: SuggestionSource.http,
      timeBand: '저녁',
      occurrences: 6,
    ),
  ];

  testWidgets('제안 확인 — 6단계·긴 이름 (라이트)', (t) async {
    await _shoot(t, 'suggestion_long', const SuggestionScreen(sequenceId: 'long'),
        suggestions: longSuggestion, installed: [_longNamed], light: true);
  });

  testWidgets('제안 확인 — 6단계·긴 이름·큰 글씨 (200%)', (t) async {
    await _shoot(t, 'suggestion_long_large',
        const SuggestionScreen(sequenceId: 'long'),
        suggestions: longSuggestion, installed: [_longNamed], textScale: 2.0);
  });

  const running = ExecutionStatus(
    phase: ExecutionPhase.running,
    label: '즉석밥 데워줘',
    sequenceId: 's1',
    steps: ['BT-08', 'BT-05'],
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
  // (10/18 §3-5) 눌림 센서(L1)를 단 구성을 가정한 장면이다 — 지금 실물 구성은 이 판정을 보내지 않으므로 제출 그림에 쓰지
  // 않는다(제출용은 아래 'submission_*').
  // 센서 차트 대신 "무슨 버튼을 누르고 어떻게 확인했는지"가 자리를 차지한다.
  const runningWithEvidence = ExecutionStatus(
    phase: ExecutionPhase.running,
    label: '즉석밥 데워줘',
    sequenceId: 's2',
    message: '하는 중이에요',
    currentButton: '시작',
    totalSteps: 2,
    completedSteps: 1,
    verificationConfidence: 0.93,
    verificationDetail: '센서로 눌림 확인',
  );

  testWidgets('실행 상태 — 폐루프 증거', (t) async {
    await _shoot(t, 'status_closed_loop', const StatusScreen(),
        executionStatus: runningWithEvidence, settle: false);
  });

  // 재시도·완료·실패·확인 불가 -- 색을 빼도 넷이 구분돼야 한다(흑백 변환본).
  const retrying = ExecutionStatus(
    phase: ExecutionPhase.retrying,
    label: '즉석밥 데워줘',
    sequenceId: 's3',
    steps: ['BT-08', 'BT-05'],
    completedSteps: 1,
    currentButton: '시작',
    currentAttempt: 2,
    applianceId: 'microwave',
    message: '답이 없어 다시 해 보는 중이에요.',
  );
  const completed = ExecutionStatus(
    phase: ExecutionPhase.completed,
    label: '즉석밥 데워줘',
    sequenceId: 's4',
    steps: ['BT-08', 'BT-05'],
    completedSteps: 2,
    applianceId: 'microwave',
    message: '버튼을 다 눌렀어요. 가전이 움직이는지 봐 주세요.',
  );
  const failed = ExecutionStatus(
    phase: ExecutionPhase.failed,
    label: '즉석밥 데워줘',
    sequenceId: 's5',
    steps: ['BT-08', 'BT-05'],
    completedSteps: 1,
    applianceId: 'microwave',
    message: '끝까지 하지 못했어요. 가전을 봐 주세요.',
  );
  const unknownState = ExecutionStatus(
    phase: ExecutionPhase.unknown,
    label: '즉석밥 데워줘',
    sequenceId: 's6',
    steps: ['BT-08', 'BT-05'],
    completedSteps: 1,
    applianceId: 'microwave',
    message: '연결이 끊겨 어떻게 됐는지 몰라요. 가전을 봐 주세요.',
  );
  for (final (name, st) in [
    ('status_retrying', retrying),
    ('status_completed', completed),
    ('status_failed', failed),
    ('status_unknown', unknownState),
  ]) {
    testWidgets('실행 상태 — $name (라이트)', (t) async {
      await _shoot(t, 'lt_$name', const StatusScreen(),
          executionStatus: st, light: true, settle: false);
    });
  }

  testWidgets('실행 상태 — 확인 불가·큰 글씨 (200%)', (t) async {
    await _shoot(t, 'status_unknown_large', const StatusScreen(),
        executionStatus: unknownState, textScale: 2.0, settle: false);
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

  // ── 팔레트 시안용 라이트 모드 ──────────────────────────────────────────
  testWidgets('시안 — 제안 확인 (라이트)', (t) async {
    await _shoot(t, 'lt_suggestion', const SuggestionScreen(sequenceId: 'a'),
        suggestions: suggestions, light: true);
  });

  testWidgets('시안 — 실행 상태 (라이트)', (t) async {
    await _shoot(t, 'lt_status', const StatusScreen(),
        executionStatus: running, light: true, settle: false);
  });

  testWidgets('시안 — 실행 상태·폐루프 증거 (라이트)', (t) async {
    await _shoot(t, 'lt_status_closed_loop', const StatusScreen(),
        executionStatus: runningWithEvidence, light: true, settle: false);
  });

  testWidgets('시안 — 설정 (라이트)', (t) async {
    await _shoot(t, 'lt_settings', const SettingsScreen(),
        light: true, settle: false);
  });

  testWidgets('시안 — 수동 조작 (라이트)', (t) async {
    await _shoot(t, 'lt_manual', const ManualControlScreen(),
        light: true, settle: false);
  });

  testWidgets('수동 조작 — 준비 안 된 가전 (라이트)', (t) async {
    // 눌러 보고 나서 실패로 알게 하지 않는다 -- 위에서 먼저 말한다.
    await _shoot(t, 'lt_manual_not_ready', const ManualControlScreen(),
        light: true, settle: false, installed: [_notReadyMicrowave]);
  });

  testWidgets('시안 — 홈·미연결 (라이트)', (t) async {
    await _shoot(t, 'lt_home_empty', const HomeScreen(),
        connected: false, light: true);
  });

  // ── 가전 상세: 사진 위 버튼 ──────────────────────────────────────────────
  //
  // 2026-09-30부터 사진은 홈이 아니라 가전 상세의 사진 패널에 나온다(UI 확정 §2).
  // 사진 비율과 버튼·정지(빨강)·쉬는 자리(점선) 표시 위치가 골든에 남아야 한다.
  // 파일 이미지는 위젯 테스트에서 디코딩되지 않으므로 `applianceImageOverride`에
  // **공개 가능한 테스트 이미지**를 끼운다. 사용자 사진은 저장소·테스트·로그
  // 어디에도 넣지 않는다.
  for (final (name, light) in [
    ('lt_detail_photo', true),
    ('detail_photo_dark', false),
  ]) {
    testWidgets('가전 상세 — 사진 패널 ($name)', (t) async {
      final image = await t.runAsync(_fixtureImage);
      applianceImageOverride = image;
      addTearDown(() => applianceImageOverride = null);
      await _shoot(t, name, ApplianceDetailScreen(applianceId: _mapped.id),
          installed: [_mapped], light: light, precache: image);
    });
  }

  testWidgets('루틴 편집 (라이트)', (t) async {
    await _shoot(
      t,
      'lt_routine_editor',
      RoutineEditorScreen(
        initial: Routine(
          id: 'rt-1',
          name: '아침 데우기',
          steps: const [
            RoutineStep.press('microwave', ['BT-07', 'BT-03', 'BT-05']),
            RoutineStep.wait('microwave'),
            RoutineStep.announce('약 드실 시간이에요'),
          ],
          trigger: const RoutineTrigger(
            kind: RoutineTriggerKind.time,
            days: [0, 1, 2, 3, 4],
            time: '07:30',
          ),
        ),
      ),
      light: true,
    );
  });

  // ── 시작 화면 ────────────────────────────────────────────────────────────
  //
  // 안드로이드 네이티브 스플래시(흰 배경 하나)와 이어져 보여야 한다. 여기서
  // 갑자기 카드나 그라데이션이 나오면 앱을 두 번 켠 것처럼 보인다.
  testWidgets('시작 화면 (다크)', (t) async {
    await _shoot(t, 'splash_dark', const Scaffold(body: Center(child: SplashWordmark())));
  });

  testWidgets('시작 화면 (라이트)', (t) async {
    await _shoot(t, 'splash_light',
        const Scaffold(body: Center(child: SplashWordmark())),
        light: true);
  });

  testWidgets('시작 화면 — 큰 글씨 (200%)', (t) async {
    await _shoot(t, 'splash_large',
        const Scaffold(body: Center(child: SplashWordmark())),
        light: true, textScale: 2.0);
  });

  // ── 설치 가전 0대 / 여러 대 / 데모 ───────────────────────────────────────
  //
  // 이 세 가지가 이번 작업의 핵심이다. 예전에는 세 경우가 화면에서 전부
  // 같아 보였다 -- 아무것도 등록하지 않은 사람에게도 전자레인지가 서 있었다.
  testWidgets('홈 — 설치 가전 0대', (t) async {
    await _shoot(t, 'home_no_appliance', const HomeScreen(), installed: const []);
  });

  testWidgets('시안 — 설치 가전 0대 (라이트)', (t) async {
    await _shoot(t, 'lt_home_no_appliance', const HomeScreen(),
        installed: const [], light: true);
  });

  testWidgets('홈 — 설치 가전 0대·큰 글씨 (200%)', (t) async {
    await _shoot(t, 'home_no_appliance_large', const HomeScreen(),
        installed: const [], textScale: 2.0);
  });

  testWidgets('홈 — 내 가전 두 대', (t) async {
    await _shoot(t, 'home_two_appliances', const HomeScreen(),
        installed: _twoOfMine, light: true);
  });

  testWidgets('홈 — 데모 표본', (t) async {
    // 표본에는 '연습'라고 적혀 있어야 한다. 심사 자리에서 우리가 실제로
    // 만든 것과 보여주기 위해 세운 것이 구분되지 않으면 안 된다.
    await _shoot(t, 'home_demo', const HomeScreen(),
        installed: kDemoAppliances, light: true);
  });

  testWidgets('홈 — 모르는 종류', (t) async {
    // 앞선 버전의 서버가 새 종류를 알고 있을 수 있다. 거절하지 않고
    // 일반 아이콘으로 떨어지는 것이 화면에서 어떻게 보이는지 남긴다.
    await _shoot(t, 'home_unknown_category', const HomeScreen(),
        installed: [_unknownKind], light: true);
  });

  // ── 가전 추가 ────────────────────────────────────────────────────────────
  //
  // 네 단계가 번호·제목·구분선으로 나뉘고, 저장이 아래 고정돼 있는지.
  testWidgets('가전 추가 (라이트)', (t) async {
    await _shoot(t, 'lt_editor', const ApplianceEditorScreen(), light: true);
  });

  testWidgets('가전 추가 — 큰 글씨 (200%)', (t) async {
    await _shoot(t, 'editor_large', const ApplianceEditorScreen(),
        textScale: 2.0);
  });

  // ── 실행 기록 ────────────────────────────────────────────────────────────
  //
  // 하루 안의 순서와 결과 네 가지(마침·재시도 후 마침·직접 멈춤·확인 못 함)가
  // 색을 빼도 구분되는지 본다. 시각은 harness가 09:00으로 고정한다.
  final history = [
    RpiHistoryEntry(
      jobId: 'h1',
      finishedAt: DateTime(2026, 9, 9, 8, 40),
      purpose: '즉석밥 데워줘',
      status: 'succeeded',
      retryCount: 0,
      applianceId: 'microwave',
      termination: 'completed',
      buttons: const [RpiHistoryButton(button: '즉석밥', success: true, attempts: 1)],
    ),
    RpiHistoryEntry(
      jobId: 'h2',
      finishedAt: DateTime(2026, 9, 9, 7, 55),
      purpose: '즉석밥 데워줘',
      status: 'succeeded',
      retryCount: 2,
      applianceId: 'microwave',
      termination: 'completed',
      buttons: const [RpiHistoryButton(button: '해동', success: true, attempts: 3)],
    ),
    RpiHistoryEntry(
      jobId: 'h3',
      finishedAt: DateTime(2026, 9, 8, 19, 20),
      purpose: null,
      status: 'safety_stopped',
      retryCount: 0,
      applianceId: 'microwave',
      termination: 'stopped_by_user',
      buttons: const [RpiHistoryButton(button: '냉동식품', success: false, attempts: 1)],
    ),
    RpiHistoryEntry(
      jobId: 'h4',
      finishedAt: DateTime(2026, 9, 6, 12, 5),
      purpose: '라면 끓여줘',
      status: 'failed',
      retryCount: 3,
      applianceId: 'microwave',
      termination: 'retries_exhausted',
      buttons: const [
        RpiHistoryButton(button: '라면', success: true, attempts: 2),
        RpiHistoryButton(button: '시작', success: false, attempts: 3),
      ],
    ),
  ];
  for (final (name, light, scale) in [
    ('lt_history', true, 1.0),
    ('history_dark', false, 1.0),
    ('history_large', false, 2.0),
  ]) {
    testWidgets('실행 기록 ($name)', (t) async {
      await _shoot(t, name, const HistoryScreen(),
          light: light,
          textScale: scale,
          extraOverrides: [
            historyProvider.overrideWith((ref) => Future.value(history)),
          ]);
    });
  }

  testWidgets('실행 기록 — 비어 있음 (라이트)', (t) async {
    await _shoot(t, 'lt_history_empty', const HistoryScreen(),
        light: true,
        extraOverrides: [
          historyProvider.overrideWith((ref) => Future.value(const [])),
        ]);
  });

  // ── 음성 명령 ────────────────────────────────────────────────────────────
  //
  // 대기 → 듣는 중 → 확인 → 쓸 수 없음. 파형은 실제 음량이 없으면 최소
  // 높이로 가만히 있는다(그럴듯하게 흔들지 않는다).
  testWidgets('음성 — 대기 (다크)', (t) async {
    await _shoot(t, 'voice_idle', const VoiceScreen(),
        extraOverrides: [voiceServiceProvider.overrideWithValue(_GoldenVoice())]);
  });

  testWidgets('음성 — 대기 (라이트)', (t) async {
    await _shoot(t, 'lt_voice_idle', const VoiceScreen(),
        light: true,
        extraOverrides: [voiceServiceProvider.overrideWithValue(_GoldenVoice())]);
  });

  testWidgets('음성 — 듣는 중 (라이트)', (t) async {
    await _shoot(t, 'lt_voice_listening', const VoiceScreen(),
        light: true,
        extraOverrides: [
          voiceServiceProvider.overrideWithValue(_GoldenVoice(listening: true)),
          voiceListeningProvider.overrideWith((ref) => true),
          voiceTextProvider.overrideWith((ref) => '즉석밥'),
        ]);
  });

  testWidgets('음성 — 확인 (라이트)', (t) async {
    await _shoot(t, 'lt_voice_confirm', const VoiceScreen(),
        light: true,
        extraOverrides: [
          voiceServiceProvider.overrideWithValue(_GoldenVoice()),
          voiceTextProvider.overrideWith((ref) => '즉석밥 데워줘'),
        ]);
  });

  testWidgets('음성 — 확인·큰 글씨 (200%)', (t) async {
    await _shoot(t, 'voice_confirm_large', const VoiceScreen(),
        textScale: 2.0,
        extraOverrides: [
          voiceServiceProvider.overrideWithValue(_GoldenVoice()),
          voiceTextProvider.overrideWith((ref) => '즉석밥 데워줘'),
        ]);
  });

  testWidgets('음성 — 쓸 수 없는 기기 (라이트)', (t) async {
    await _shoot(t, 'lt_voice_unavailable', const VoiceScreen(),
        light: true,
        extraOverrides: [
          voiceServiceProvider
              .overrideWithValue(_GoldenVoice(available: false)),
        ],
        before: (tester) async {
          await tester.tap(find.byIcon(Icons.mic_rounded));
          await tester.pumpAndSettle();
        });
  });

  // ── 하단 탭바 ────────────────────────────────────────────────────────────
  //
  // 다른 골든은 화면을 AppShell 없이 그린다. 탭바는 주 행동(말로 조작)을
  // 품고 있는데 어느 골든에도 안 잡히면, 여기가 무너져도 아무도 모른다.
  for (final (name, light) in [('shell_dark', false), ('shell_light', true)]) {
    testWidgets('하단 탭바 ($name)', (t) async {
      await _shootShell(t, name, light: light);
    });
  }

  // 비상정지 걸림(2026-10-05) — 탭바 위 배너. 실행 중이라 정지 줄도 함께 보인다.
  testWidgets('하단 탭바 — 비상정지 걸림 (라이트)', (t) async {
    await _shootShell(t, 'shell_estop', light: true, overrides: [
      rpiApiServiceProvider.overrideWithValue(_EstopApi()),
      estopPollIntervalProvider.overrideWithValue(null),
    ], status: const ExecutionStatus(phase: ExecutionPhase.running, label: '즉석밥'));
  });
}

class _EstopApi extends RpiApiService {
  _EstopApi() : super('http://hub.test');

  @override
  Future<HubStatus> hubStatus() async => const HubStatus(
      estopLatched: true, estopDetail: '콘센트 모듈의 비상정지 버튼이 눌렸어요');
}

/// 사진으로 등록한 전자레인지 — 버튼 자리는 테스트 이미지(320x200) 위 좌표다.
final _mapped = ApplianceMap(
  id: 'mine_microwave',
  name: '전자레인지',
  location: '주방',
  category: ApplianceCategory.microwave,
  rows: 2,
  cols: 3,
  buttons: const [
    ApplianceButton(id: 'B01', label: '해동', x: 0, y: 0),
    ApplianceButton(id: 'B02', label: '30초', x: 1, y: 0),
    ApplianceButton(id: 'B03', label: '1분', x: 2, y: 0),
    ApplianceButton(id: 'B04', label: '취소', x: 0, y: 1),
    ApplianceButton(id: 'B05', label: '시작', x: 1, y: 1),
  ],
  isCustom: true,
  stopButton: 'B04',
  panelMapping: const PanelMapping(
    photoWidth: 320,
    photoHeight: 200,
    buttons: {
      'B01': PhotoPoint(100, 80),
      'B02': PhotoPoint(160, 80),
      'B03': PhotoPoint(220, 80),
      'B04': PhotoPoint(120, 130),
      'B05': PhotoPoint(200, 130),
    },
    parkPoint: PhotoPoint(295, 180),
  ),
);

/// 같은 종류를 여러 대 등록한 사람. 위치가 이름 앞에 붙는다.
final _twoOfMine = <ApplianceMap>[
  ApplianceMap(
    id: 'mine_living',
    name: '에어컨',
    location: '거실',
    category: ApplianceCategory.airConditioner,
    rows: 3,
    cols: 3,
    buttons: kApplianceTemplates.firstWhere((t) => t.id == 'aircon').buttons,
    isCustom: true,
  ),
  ApplianceMap(
    id: 'mine_bed',
    name: '에어컨',
    location: '안방',
    category: ApplianceCategory.airConditioner,
    rows: 3,
    cols: 3,
    buttons: kApplianceTemplates.firstWhere((t) => t.id == 'aircon').buttons,
    isCustom: true,
  ),
];

/// 서버가 "아직 맡길 수 없다"고 한 전자레인지.
final _notReadyMicrowave = ApplianceMap(
  id: 'microwave',
  name: '전자레인지',
  category: ApplianceCategory.microwave,
  rows: kTestAppliance.rows,
  cols: kTestAppliance.cols,
  buttons: kTestAppliance.buttons,
  canExecute: false,
  readiness: 'needs_setup',
  readinessReasons: const ['버튼 위치 보정이 아직 안 됐어요'],
  readinessKnown: true,
);

/// 이름과 위치가 긴 가전. 제안 화면의 머리·확인 줄이 잘리지 않는지 본다.
final _longNamed = ApplianceMap(
  id: 'mine_living_long',
  name: '창가 쪽 스탠드형 에어컨',
  location: '거실',
  category: ApplianceCategory.airConditioner,
  rows: 3,
  cols: 3,
  buttons: kApplianceTemplates.firstWhere((t) => t.id == 'aircon').buttons,
  isCustom: true,
);

/// 종류를 모르는 가전. 서버가 새 값을 보냈거나, 사용자가 '기타'를 골랐다.
final _unknownKind = ApplianceMap(
  id: 'mine_unknown',
  name: '안마의자',
  location: '거실',
  category: ApplianceCategory.other,
  rows: 2,
  cols: 2,
  buttons: const [
    ApplianceButton(id: 'u1', label: '전원', x: 0, y: 0),
    ApplianceButton(id: 'u2', label: '세기', x: 1, y: 0),
    ApplianceButton(id: 'u3', label: '전신', x: 0, y: 1),
    ApplianceButton(id: 'u4', label: '정지', x: 1, y: 1),
  ],
  isCustom: true,
);

/// 플러그인 없이 화면만 찍기 위한 음성 서비스. 아무것도 듣지 않는다.
class _GoldenVoice extends VoiceService {
  _GoldenVoice({this.listening = false, this.available = true});

  final bool listening;
  final bool available;

  @override
  bool get isListening => listening;

  @override
  Future<bool> initialize() async => available;

  @override
  Future<void> listen({
    required void Function(String text) onText,
    required void Function(String finalText) onSilence,
    void Function(String errorId)? onError,
    void Function(double level)? onSoundLevel,
    void Function()? onInterrupted,
    void Function(String text)? onFinal,
    void Function()? onDone,
  }) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> cancel() async {}
}

/// 탭바를 포함한 shell 전체를 찍는다.
Future<void> _shootShell(
  WidgetTester tester,
  String name, {
  required bool light,
  List<Override> overrides = const [],
  ExecutionStatus? status,
}) async {
  tester.view.physicalSize = _phoneSize;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final router = GoRouter(
    initialLocation: '/',
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (_, __, shell) => AppShell(navigationShell: shell),
        // main.dart와 같은 다섯 브랜치(홈·루틴·기록·설정·개발자). 개발자 탭은
        // 서버 개발자 모드일 때만 보이므로 이 골든에는 네 탭이 찍힌다.
        branches: [
          StatefulShellBranch(routes: [
            GoRoute(path: '/', builder: (_, __) => const SizedBox.shrink()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
                path: '/routines', builder: (_, __) => const SizedBox.shrink()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
                path: '/history', builder: (_, __) => const SizedBox.shrink()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
                path: '/settings', builder: (_, __) => const SizedBox.shrink()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/dev', builder: (_, __) => const SizedBox.shrink()),
          ]),
        ],
      ),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: light
            ? AppTheme.light.copyWith(
                textTheme: AppTheme.light.textTheme.apply(fontFamily: 'Malgun'))
            : AppTheme.dark.copyWith(
                textTheme: AppTheme.dark.textTheme.apply(fontFamily: 'Malgun')),
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (status != null) {
    // Test-only seed of the real notifier.
    // ignore: invalid_use_of_protected_member
    ProviderScope.containerOf(tester.element(find.byType(AppShell)))
        .read(executionStatusProvider.notifier)
        .state = status;
    await tester.pumpAndSettle();
  }
  await expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile('goldens/$name.png'),
  );
}

/// 공개 가능한 테스트 이미지. 사용자 사진을 저장소·테스트에 들이지 않기 위한
/// 장치다(사진은 그 폰의 로컬 데이터로만 둔다).
///
/// 정사각이 아닌 **가로로 긴** 이미지를 쓴다 -- 정사각 프레임의 크롭이
/// 제대로 도는지 골든에 남기려면 비율이 달라야 한다.
Future<MemoryImage> _fixtureImage() async {
  const w = 320;
  const h = 200;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    Paint()..color = const Color(0xFF6F6A63),
  );
  // 가장자리 띠 — 크롭이 어디를 잘랐는지 골든에서 보이게 한다.
  canvas.drawRect(
    Rect.fromLTWH(0, 0, w.toDouble(), 16),
    Paint()..color = const Color(0xFFD9D2C7),
  );
  canvas.drawRRect(
    RRect.fromRectAndRadius(
      const Rect.fromLTWH(60, 50, 200, 110),
      const Radius.circular(12),
    ),
    Paint()..color = const Color(0xFF2E2A26),
  );
  final image = await recorder.endRecording().toImage(w, h);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  return MemoryImage(bytes!.buffer.asUint8List());
}

/// 골든용 집 — 전자레인지(사진 등록)·공기청정기(LG)·세탁기(설정 전).
final _homeInstalled = <ApplianceMap>[
  _mapped,
  ApplianceMap.fromJson(const {
    'id': 'air_purifier',
    'name': '공기청정기',
    'category': 'air_purifier',
    'rows': 1,
    'cols': 1,
    'buttons': [],
    'control_path': 'thinq',
    'can_execute': true,
    'readiness': 'operable',
    'readiness_reasons': [],
  }),
  ApplianceMap.fromJson(const {
    'id': 'washer',
    'name': '세탁기',
    'category': 'washing_machine',
    'rows': 1,
    'cols': 1,
    'is_custom': true,
    'buttons': [
      {'id': 'w1', 'label': '시작', 'x': 0, 'y': 0},
    ],
  }),
];

/// 연습용 LG 세탁기(2026-10-18) — 서버 `SIMPLELAY_THINQ_PRACTICE_DEVICES=washer`가 세우는 모의 세탁기(이름에 '(연습)').
final _practiceWasherJson = <String, dynamic>{
  'id': 'thinq_washer',
  'name': 'LG 세탁기(연습)',
  'category': 'washing_machine',
  'rows': 0,
  'cols': 0,
  'buttons': <dynamic>[],
  'control_path': 'thinq',
  'can_execute': true,
  'readiness': 'operable',
  'readiness_reasons': <dynamic>[],
};

/// 집 + 연습 LG 세탁기 — 전자레인지(사진 등록)·공기청정기(LG, 실제)·LG 세탁기(연습).
final _practiceInstalled = <ApplianceMap>[
  _homeInstalled[0],
  _homeInstalled[1],
  ApplianceMap.fromJson(_practiceWasherJson),
];

/// 제출용 집 — 지금 실물 구성 그대로: 전자레인지(사진 등록) + 공기청정기(LG).
final _submissionInstalled = <ApplianceMap>[_homeInstalled[0], _homeInstalled[1]];

/// 골든용 가짜 본체 — 실행 경로는 없다(찍기만 한다).
/// [submission]이면 지금 실물 구성(전자레인지 + LG 공기청정기)만 — 등록 안 된 세탁기 루틴·알림을 뺀다(10/18 §3-5).
RpiApiService _demoHub({bool submission = false, bool practiceWasher = false}) {
  http.Response json(Object body, [int status = 200]) => http.Response.bytes(
      utf8.encode(jsonEncode(body)), status,
      headers: {'content-type': 'application/json'});
  Map<String, dynamic> routine(String id, String name, String appliance, int steps,
          {Map<String, dynamic> trigger = const {'kind': 'manual'},
          String when = '직접 실행할 때'}) =>
      {
        'id': id,
        'name': name,
        'steps': [
          {
            'kind': 'press_sequence',
            'appliance_id': appliance,
            'buttons': List.filled(steps, '시작'),
          },
        ],
        'trigger': trigger,
        'when': when,
        'mode': 'approve',
        'enabled': true,
      };
  return RpiApiService('http://hub.test', client: MockClient((req) async {
    final path = req.url.path;
    // 제출용: 실물 캐리지 이동이 아직 검증되지 않아 실제 확인 주행 기록이 없다 — 있는 척하지 않는다(10/18 §3-5).
    if (submission && path.endsWith('/verify-pass')) {
      return json({'detail': VerifyPassLookup.noRecordDetail}, 404);
    }
    // 연습 LG 세탁기 상태 — 서버가 연습 기기에 주는 꼴(execution_mode mock, 모의 값).
    if (practiceWasher && path == '/thinq/status/thinq_washer') {
      return json({
        'appliance_id': 'thinq_washer',
        'execution_mode': 'mock',
        'state': {
          'runState': {'currentState': 'RUNNING'},
          'remoteControlEnable': {'remoteControlEnabled': true},
          'timer': {'remainHour': 0, 'remainMinute': 45},
        },
      });
    }
    switch (path) {
      case '/appliances':
        return json([
          if (practiceWasher) _practiceWasherJson,
          {
            ..._homeInstalled[0].toJson(),
            'can_execute': true,
            'readiness': 'operable',
            'readiness_reasons': [],
          },
          {
            'id': 'air_purifier',
            'name': '공기청정기',
            'category': 'air_purifier',
            'rows': 1,
            'cols': 1,
            'buttons': [],
            'control_path': 'thinq',
            'can_execute': true,
            'readiness': 'operable',
            'readiness_reasons': [],
          },
        ]);
      case '/routines':
        return json(<Map<String, dynamic>>[
          routine('r-1', '30초 데우기', 'mine_microwave', 2),
          routine('r-2', '아침 데우기', 'mine_microwave', 3),
          routine('r-3', '빨래 시작', 'washer', 1),
          // LG 가전 루틴은 누를 버튼이 아니라 LG 가전 단계(실화면과 같은 꼴, 평가 5차 10/18).
          {
            'id': 'r-4',
            'name': '저녁 공기청정기 켜기',
            'steps': [
              {
                'kind': 'thinq_command',
                'appliance_id': 'air_purifier',
                'action': 'set_power',
                'args': {'power': 'POWER_ON'},
              },
            ],
            'trigger': {
              'kind': 'time',
              'days': [0, 1, 2, 3, 4, 5, 6],
              'time': '22:00',
            },
            'when': '매일 22:00',
            'mode': 'approve',
            'enabled': true,
          },
          // 실화면과 같은 꼴(평가 4차 10/18) — 알림만 루틴, LG 가전 설정 단계.
          {
            'id': 'r-5',
            'name': '세탁 끝 알림',
            'steps': <dynamic>[],
            'trigger': {'kind': 'event', 'event': 'wash_complete'},
            'when': '세탁이 끝나면',
            'mode': 'notify',
            'enabled': true,
          },
          {
            'id': 'r-6',
            'name': '아침 공기청정기 끄기',
            'steps': [
              {
                'kind': 'thinq_command',
                'appliance_id': 'air_purifier',
                'action': 'set_power',
                'args': {'power': 'POWER_OFF'},
              },
            ],
            'trigger': {
              'kind': 'time',
              'days': [0, 1, 2, 3, 4, 5, 6],
              'time': '07:00',
            },
            'when': '매일 07:00',
            'mode': 'approve',
            'enabled': true,
          },
        ].where((r) => !submission || !const {'r-3', 'r-5'}.contains(r['id'])).toList());
      case '/routines/next':
        return json([
          {
            'routine_id': 'r-4',
            'name': '저녁 공기청정기 켜기',
            'at': '2026-09-09T22:00:00+09:00',
            'when': '매일 22:00',
            'mode': 'approve',
            'mode_label': '자동 실행',
            'auto': true,
            'day_label': '오늘',
            // 한 번 건너뛰기(2026-10-18) — 건너뛰지 않은 회차에는 '오늘은 건너뛰기' 단추.
            'skipped': false,
            'skip_label': null,
            'skip_action_label': '오늘은 건너뛰기',
          },
        ]);
      case '/routines/auto-rules':
        return json([
          {
            'id': 'ar-1',
            'name': '저녁 공기청정기 켜기',
            'condition_kind': 'time',
            'condition_time': '22:00',
            'condition_text': '매일 밤 10시에',
            'action_text': '공기청정기를 켜요',
            'enabled': true,
            'fingerprint': 'fp-1',
            'allowed_values': [],
          },
          {
            'id': 'ar-2',
            'name': '전자레인지가 멈추면 공기청정기 세게',
            'condition_text': '전자레인지가 데우기를 멈추면',
            'action_text': '공기청정기 바람을 세게 해요',
            'enabled': false,
            'disabled_reason': '자동으로 하기를 꺼 두셨어요.',
            'fingerprint': 'fp-2',
            'action': 'set_wind_strength',
            'value': 'HIGH',
            'allowed_values': [
              {'value': 'MID', 'label': '중'},
              {'value': 'HIGH', 'label': '강'},
            ],
          },
        ]);
      case '/thinq/power':
        return json({
          'execution_mode': 'real',
          'appliances': [
            {'appliance_id': 'air_purifier', 'power': 'on', 'age_s': 3},
          ],
        });
      case '/thinq/air':
        return json({
          'execution_mode': 'real',
          'appliances': [
            {'appliance_id': 'air_purifier', 'grade': 'NORMAL'},
          ],
        });
      case '/suggestions':
        return json(<dynamic>[]);
    }
    return json({'detail': 'not found'}, 404);
  }));
}
