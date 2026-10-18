// 키오스크 화면을 실제 이미지로 렌더한다 — 눈으로 확인하기 위한 도구다.
//
// 왜 필요한가: 이 앱은 라즈베리파이 키오스크(15.8형 패널)에서만 도는데 개발 PC에 웹 지원이 없다.
// 디자인을 바꿔놓고 "테스트가 통과하니 괜찮겠지"로 넘기면, 이 프로젝트에서 반복해서
// 겪은 실패 모드("고쳤다"와 "실제로 그렇게 보인다"는 다르다)를 그대로 반복하게 된다.
//
// 실행: flutter test test/screenshot_test.dart --update-goldens
//   -> test/goldens/*.png 가 갱신된다. 통과/실패를 다투는 골든이 아니라 **보기 위한**
//      산출물이라, CI에서 깨지는 것이 목적이 아니다(폰트 렌더가 환경마다 다르다).
//
// 한글이 네모로 나오지 않게 시스템 폰트를 실어 준다.
// 다른 기기에서는 폰트 렌더가 달라 이미지가 어긋날 수 있다. 그때는
//   flutter test --exclude-tags screenshot
// 로 빼고 돌리면 된다.
@Tags(['screenshot'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/theme/kiosk_colors.dart';
import 'package:simplelay_touchscreen/models/ambient.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/models/thinq.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/appliance_select_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/danger_alert_overlay.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/dnd_overlay.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/estop_banner.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/done_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/connection_status.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/executing_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/hold_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/kiosk_canvas.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/manual_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/past_result_line.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/suggestion_view.dart';

import 'support/golden_fonts.dart';

const _kioskSize = Size(800, 480);

/// 비상 버튼 걸림의 서버 문장 — RPi4가 실제로 보내는 문장(서버 문구 정리 2bc87e5). 띠는 제목과 겹치는 머리를 뗀다.
const _estopDetail = "비상 버튼이 눌려 있어요 — 풀고 '해제하기'를 눌러야 다시 쓸 수 있어요";

/// 실기기 해상도 그대로. 큰 글씨 모드는 kiosk_screen이 textScaler로 얹으므로
/// 여기서도 같은 방식으로 흉내 낸다.
Future<void> _shoot(
  WidgetTester tester,
  String name,
  Widget child, {
  double textScale = 1.0,
}) async {
  tester.view.physicalSize = _kioskSize;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(fontFamily: 'Malgun', brightness: Brightness.dark),
      // Scaffold가 있어야 Text들이 테마의 기본 텍스트 스타일(=한글 폰트)을
      // 물려받는다. 없으면 fontFamily를 명시하지 않은 Text가 전부 네모로 나온다.
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: Scaffold(backgroundColor: KioskColors.bg, body: child),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 300));
  // 스크롤 막대(늘 보임)는 첫 그림 뒤에 나타난다 — 한 번 더 그려 막대까지 찍는다(2026-10-15).
  await tester.pump(const Duration(milliseconds: 400));
  await expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile('goldens/$name.png'),
  );
}

/// 15.8형 패널 미리보기 — 제품 사양표 해상도 1920x1080
/// (docs/하드웨어-연결-설계.md §0-1). KioskCanvas가 가장자리 48px을 비우고
/// 800x480 설계 캔버스를 2.05배로 확대해 채운 모습 -- 글씨·버튼·터치타깃이 함께 커진다.
Future<void> _shoot15(WidgetTester tester, String name, Widget child,
    {Future<void> Function(WidgetTester)? before, bool dim = false}) async {
  tester.view.physicalSize = const Size(1920, 1080);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(fontFamily: 'Malgun', brightness: Brightness.dark),
      home: KioskCanvas(
        dim: dim,
        child: Scaffold(backgroundColor: KioskColors.bg, body: child),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 300));
  if (before != null) await before(tester);
  // 스크롤 막대(늘 보임)는 첫 그림 뒤에 나타난다 — 한 번 더 그려 막대까지 찍는다(2026-10-15).
  await tester.pump(const Duration(milliseconds: 400));
  await expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile('goldens/$name.png'),
  );
}

void _noop() {}

const _okConnections = [
  ConnectionItem(id: 'network', state: 'ok', title: '', message: ''),
  ConnectionItem(id: 'press', state: 'ok', title: '', message: ''),
  ConnectionItem(id: 'plug', state: 'ok', title: '', message: ''),
];

const _ambient = AmbientInfo(
  greeting: '좋은 아침이에요.',
  tip: AmbientTip(
      kind: 'rain', text: '오후 3시부터 비 예보가 있어요. 우산 챙기세요.', icon: 'rain'),
  hourly: [
    // 서버(services/weather/ambient.py)가 실제로 보내는 칸 이름 꼴 — "15시".
    AmbientHour(label: '9시', icon: 'partly', temp: 16),
    AmbientHour(label: '12시', icon: 'cloudy', temp: 18),
    AmbientHour(label: '15시', icon: 'rain', temp: 17, pop: 70, precip: true),
    AmbientHour(label: '18시', icon: 'rain', temp: 15, pop: 60, precip: true),
  ],
  weatherSource: 'mock',
);

/// 서버 `/appliances` 꼴 — 평가 6차(10/18): 상태 띠는 서버 판정(readiness·is_custom·panel_mapping)을 따르므로 골든도
/// 서버가 실제로 주는 값으로 그린다(판정 없는 하드코딩 가전은 '확인 전이에요').
ApplianceMap _served(String id, String name, String category,
        {bool custom = false,
        List<ApplianceButton> buttons = const [],
        String control = 'physical',
        String readiness = 'operable',
        List<String> reasons = const []}) =>
    ApplianceMap(
      id: id,
      name: name,
      category: category,
      rows: 1,
      cols: 1,
      buttons: buttons,
      readiness: readiness,
      readinessReasons: reasons,
      controlPath: control,
      isCustom: custom,
    );

final _mw = _served('microwave', '전자레인지', 'microwave', buttons: kMicrowaveAppliance.buttons);
/// 인덕션 — 누름 장치가 전자레인지 위에만 있어(갠트리 1대) 서버가 '설정이 필요해요'로 준다(2026-10-18,
/// `SIMPLELAY_GANTRY_APPLIANCES` 기본 microwave).
final _ind = _served('induction', '인덕션', 'induction',
    buttons: kInductionAppliance.buttons,
    readiness: 'needs_setup',
    reasons: const ['누름 장치가 이 가전 위에 없어서 누를 수 없어요']);
final _washer = _served('washer', '세탁기', 'washing_machine');

/// 휴대폰 앱에서 등록하고 사진 위 버튼 자리를 아직 맞추지 않은 가전 — 폰과 같이 '설정이 필요해요'.
final _washerSetup = _served('washer', '세탁기', 'washing_machine', custom: true);
final _intercom = _served('intercom', '인터폰', 'intercom', custom: true);

/// 서버가 세우는 모의 선풍기(id 'fan', 종류 other) — 바람 계열 그림.
final _fanAppliance = _served('fan', '선풍기', 'other');

/// 평소 화면 — 가전 다섯(4개씩 넘기기), 세탁기 동작 중.
KioskIdleView _idle({
  List<ConnectionItem> connections = _okConnections,
  Set<String> attention = const {},
  AmbientInfo ambient = _ambient,
  DateTime? dndUntil,
  KioskAirReading? air,
  KioskNextRun? nextRun,
  List<ApplianceMap>? appliances,
  Set<String> running = const {'washer'},
  Set<String> on = const {},
  Set<String> off = const {},
  DateTime? now,
  String? quietUntil,
  bool quietDim = false,
}) =>
    KioskIdleView(
      // 7:38 — 예보 첫 칸(9시)이 지금 ±90분 안이라 날짜 옆에 바깥 날씨가 붙는다(사용자 요청 10/18).
      now: now ?? DateTime(2026, 9, 30, 7, 38),
      quietUntil: quietUntil,
      quietDim: quietDim,
      connected: true,
      ambient: ambient,
      connections: connections,
      // 다섯(4개씩 넘기기): 세탁기 작동 중 · 전자레인지 준비 · 인터폰 설정 필요 · 선풍기 준비 · 인덕션.
      appliances: appliances ?? [_mw, _washer, _intercom, _fanAppliance, _ind],
      running: running,
      on: on,
      off: off,
      attention: attention,
      temperature: 23,
      humidity: 58,
      dndUntil: dndUntil,
      air: air,
      nextRun: nextRun,
      // 다음 루틴 '오늘은 건너뛰기'(2026-10-18) — 서버가 회차를 알려 주면 단추가 보인다.
      onToggleNextRunSkip: (_) {},
      onSelectAppliance: (_) {},
      onOpenConnection: (_) {},
      onDndGesture: () {},
    );

/// ThinQ 공기청정기 상세(2026-10-16) — 상태는 모의 값(연습 표시).
/// 다음 루틴 — 서버 /routines/next 항목 꼴(건너뛰기 필드 포함, 2026-10-18).
KioskNextRun _nextRun({bool skipped = false}) => KioskNextRun(
      name: '저녁 공기청정기 켜기',
      dayLabel: '오늘',
      hhmm: '22:00',
      modeLabel: '자동 실행',
      routineId: 'rt-evening',
      at: '2026-09-30T22:00:00+09:00',
      skipped: skipped,
      skipLabel: skipped ? '오늘은 건너뛰어요' : null,
      skipActionLabel: '오늘은 건너뛰기',
    );

/// 연습용 LG 세탁기(2026-10-18) — 서버 `SIMPLELAY_THINQ_PRACTICE_DEVICES=washer`가 세우는 모의 세탁기.
final _practiceWasher = applianceFromServerJson({
  'id': 'thinq_washer',
  'name': 'LG 세탁기(연습)',
  'category': 'washing_machine',
  'rows': 0,
  'cols': 0,
  'buttons': <dynamic>[],
  'control_path': 'thinq',
  'can_execute': true,
  'readiness': 'operable',
});

KioskManualView _washerDetail() => KioskManualView(
      appliance: _practiceWasher,
      onExecute: (_) {},
      onCancel: () {},
      thinqRead: () async => KioskThinqStatus(
        executionMode: 'mock',
        readAt: DateTime(2026, 10, 18, 9, 7),
        state: const {
          'runState': {'currentState': 'RUNNING'},
          'remoteControlEnable': {'remoteControlEnabled': true},
          'timer': {'remainHour': 0, 'remainMinute': 45},
        },
      ),
      thinqSend: (_, __) async => const KioskJobAccepted(jobId: 'j'),
      onThinqAccepted: (_, __) {},
    );

final _purifierAppliance = applianceFromServerJson({
  'id': 'air_purifier',
  'name': '공기청정기',
  'category': 'air_purifier',
  'rows': 0,
  'cols': 0,
  'buttons': <dynamic>[],
  'control_path': 'thinq',
  'can_execute': true,
  'readiness': 'operable',
});

/// 실제 공기청정기 상세 — 가전별 실행 환경이 real이라 연습 문구가 없다(2차 독립 평가 A, 10/18: 예전 골든은 연습 표시가
/// 없는 실제 가전에 모의 값(mock)을 넣어 '연습이에요'가 보였다). 연습 가전 상세는 `kiosk15_thinq_washer_practice`.
KioskManualView _thinqDetail({String power = 'POWER_ON', bool sensor = true}) => KioskManualView(
      appliance: _purifierAppliance,
      onExecute: (_) {},
      onCancel: () {},
      thinqRead: () async => KioskThinqStatus(
        executionMode: 'real',
        readAt: DateTime(2026, 10, 16, 9, 7),
        state: {
          'operation': {'airPurifierOperationMode': power},
          'airPurifierJobMode': {'currentJobMode': 'CLEAN'},
          'airFlow': {'windStrength': 'LOW'},
          if (sensor)
            'airQualitySensor': {'PM2': 42, 'PM10': 90, 'PM2Level': 'BAD', 'PM10Level': 'NORMAL'},
          'filterInfo': {'filterRemainPercent': 87},
        },
      ),
      thinqSend: (_, __) async => const KioskJobAccepted(jobId: 'j'),
      onThinqAccepted: (_, __) {},
    );

KioskHoldView _hold({bool stopRequested = false}) => KioskHoldView(
      appliance: kMicrowaveAppliance,
      holdState: 'hovering_stop',
      stopButton: '취소',
      executionMode: 'mock',
      elapsed: const Duration(minutes: 1, seconds: 2),
      buttonsPressed: 3,
      operationConfirmed: true,
      operationSource: 'mock',
      stopRequested: stopRequested,
      onStop: _noop,
      // 연습 대기는 '처음 화면으로'로 나갈 수 있다(평가 12차 10/18, kiosk_screen과 같은 조건).
      onClose: _noop,
    );

KioskManualView _mine() => KioskManualView(
      appliance: kMicrowaveAppliance,
      onExecute: (_) {},
      onCancel: () {},
      routines: const [
        KioskRoutine(id: 'morning', name: '아침 데우기', pressCount: 3),
        KioskRoutine(id: 'evening', name: '저녁 데우기', pressCount: 4),
      ],
      onRoutine: (_) {},
    );

void main() {
  setUpAll(loadGoldenFonts);

  // 서버가 실제로 주는 모양 -- 시간대가 있어야 '왜 지금'을 문장으로 만든다.
  const suggestion = KioskSuggestion(
    id: 'suggestion-1',
    purpose: '즉석밥 데워줘',
    occurrences: 3,
    timeBand: '아침',
    steps: ['즉석밥', '시작'],
  );

  testWidgets('평소', (t) async {
    await _shoot(t, 'idle', _idle());
  });

  testWidgets('평소 — 제안 쉬는 중(위 줄 칩)', (t) async {
    await _shoot(t, 'idle_dnd', _idle(dndUntil: DateTime(2026, 9, 30, 8, 38)));
  });

  testWidgets('평소 — 큰 글씨·연결 문제·확인 필요', (t) async {
    await _shoot(
      t,
      'idle_large',
      _idle(
        connections: const [
          ConnectionItem(id: 'network', state: 'ok', title: '', message: ''),
          ConnectionItem(id: 'press', state: 'ok', title: '', message: ''),
          ConnectionItem(id: 'plug', state: 'warn', title: '', message: ''),
        ],
        attention: const {'induction'},
        // 큰 글씨에서도 다음 루틴 줄과 '오늘은 건너뛰기'가 시계 아래에 잘리지 않는다(2026-10-18).
        nextRun: _nextRun(),
        ambient: const AmbientInfo(
          greeting: '편안한 저녁 보내세요.',
          tip: AmbientTip(
              kind: 'appliance',
              text: '인덕션 버튼 누르기가 중간에 멈췄어요. 가전을 봐 주세요.',
              icon: 'attention'),
        ),
      ),
      textScale: 1.22,
    );
  });

  testWidgets('평소 — 등록된 가전 없음·예보 없음', (t) async {
    await _shoot(
      t,
      'idle_empty',
      KioskIdleView(
        now: DateTime(2026, 9, 30, 18, 56),
        connected: true,
        connections: _okConnections,
        appliances: const [],
        onSelectAppliance: (_) {},
        onOpenConnection: (_) {},
        onDndGesture: () {},
      ),
    );
  });

  testWidgets('평소 — 본체 연결 끊김', (t) async {
    await _shoot(
      t,
      'idle_disconnected',
      KioskIdleView(
        now: DateTime(2026, 9, 30, 18, 56),
        connected: false,
        connections: const [
          ConnectionItem.hubUnreachable,
          ConnectionItem(id: 'press', state: 'unreachable', title: '', message: ''),
          ConnectionItem(id: 'plug', state: 'unreachable', title: '', message: ''),
        ],
        onSelectAppliance: (_) {},
        onOpenConnection: (_) {},
        onDndGesture: () {},
      ),
    );
  });

  testWidgets('평소 — 연결 문제 모달', (t) async {
    await _shoot(
      t,
      'connection_modal',
      Stack(children: [
        // 배경 칩도 같은 문제를 말한다(평가 7차 10/18 — 창은 문제인데 뒤 칩이 '모두 정상'이었다).
        Positioned.fill(child: _idle(connections: const [
          ConnectionItem(id: 'network', state: 'ok', title: '', message: ''),
          ConnectionItem(id: 'press', state: 'ok', title: '', message: ''),
          ConnectionItem(id: 'plug', state: 'warn', title: '전기 플러그 연결이 약해요', message: ''),
        ])),
        Positioned.fill(
          child: KioskConnectionModal(
            item: const ConnectionItem(
              id: 'plug',
              state: 'warn',
              // 서버가 실제로 보내는 문장(rpi/services/connections.py, 쉬운 말 4차 b039967 — 콘센트 → 전기 플러그).
              title: '전기 플러그 연결이 약해요',
              message: '가전이 끝났다는 알림이 늦거나 오지 않을 수 있어요.',
              fixes: [
                '전기 플러그가 벽에 끝까지 꽂혀 있는지 봐 주세요.',
                '전기 플러그와 누름 장치를 잇는 선이 끝까지 꽂혀 있는지 봐 주세요.',
                '그래도 안 되면 전기 플러그를 뽑았다가 10초 뒤 다시 꽂아 주세요.',
              ],
            ),
            checking: false,
            onRecheck: () {},
            onClose: () {},
          ),
        ),
      ]),
    );
  });

  testWidgets('동작 중 — 정지 버튼 위 대기', (t) async {
    await _shoot(t, 'hold', _hold());
  });

  // 비상정지 걸림(2026-10-05) — 위쪽 전폭 경고, 아래 화면의 정지 버튼은 그대로.
  testWidgets('동작 중 — 비상정지 걸림 경고', (t) async {
    await _shoot(
        t,
        'hold_estop',
        KioskEstopLayout(
          banner: KioskEstopBanner(
              detail: _estopDetail, onRequest: () {}),
          child: _hold(),
        ));
  });

  testWidgets('동작 중 — 큰 글씨·정지 요청 보냄', (t) async {
    await _shoot(t, 'hold_large', _hold(stopRequested: true), textScale: 1.22);
  });

  testWidgets('동작 중 — 정지 요청함·미확인', (t) async {
    await _shoot(
      t,
      'hold_unconfirmed',
      const KioskHoldView(
        appliance: kMicrowaveAppliance,
        holdState: 'parked',
        stopOutcome: 'requested_unconfirmed',
        stopButton: '취소',
        executionMode: 'real',
        elapsed: Duration(minutes: 1, seconds: 40),
        onStop: _noop,
        onClose: _noop,
      ),
    );
  });

  testWidgets('내 가전 — 버튼판과 내 루틴', (t) async {
    await _shoot(t, 'my_appliance', _mine());
  });

  testWidgets('가전 선택', (t) async {
    // 수동 조작 진입 첫 화면 — 폰에서 등록한 커스텀 가전까지 카드로 나온다
    await _shoot(
      t,
      'appliance_select',
      KioskApplianceSelectView(
        appliances: const [
          kMicrowaveAppliance,
          kInductionAppliance,
          ApplianceMap(
            id: 'custom_fan',
            name: '거실 선풍기',
            category: 'other',
            rows: 1,
            cols: 2,
            buttons: [
              ApplianceButton(id: 'F-01', label: '전원', x: 0, y: 0),
              ApplianceButton(id: 'F-02', label: '약풍', x: 1, y: 0),
            ],
          ),
        ],
        lastUsedId: 'microwave',
        onSelect: (_) {},
        onCancel: () {},
      ),
    );
  });

  testWidgets('제안', (t) async {
    await _shoot(
      t,
      'suggestion',
      KioskSuggestionView(
        suggestion: suggestion,
        target: kMicrowaveAppliance,
        cdRemaining: 37,
        cdTotal: 40,
        onApprove: () {},
        onReject: () {},
        // 화면 타이머 '시간 더 주기'(접근성 감사 10/18) — kiosk_screen이 늘 넘긴다.
        onExtend: () {},
      ),
    );
  });

  testWidgets('제안 — 큰 글씨', (t) async {
    await _shoot(
      t,
      'suggestion_large',
      KioskSuggestionView(
        suggestion: suggestion,
        target: kMicrowaveAppliance,
        cdRemaining: 37,
        cdTotal: 40,
        onApprove: () {},
        onReject: () {},
        // 화면 타이머 '시간 더 주기'(접근성 감사 10/18) — kiosk_screen이 늘 넘긴다.
        onExtend: () {},
      ),
      textScale: 1.22,
    );
  });

  testWidgets('제안 — 6단계·긴 이름·큰 글씨', (t) async {
    // 순서 목록이 길고 이름이 길어도 행동 버튼이 밀려나지 않는지 본다.
    await _shoot(
      t,
      'suggestion_long_large',
      KioskSuggestionView(
        suggestion: const KioskSuggestion(
          id: 'long',
          purpose: '냉동 만두 데워서 라면이랑 같이 먹을 준비',
          occurrences: 6,
          timeBand: '저녁',
          steps: ['해동', '냉동식품', '1분', '1분', '30초', '시작'],
        ),
        target: const ApplianceMap(
          id: 'custom_mw',
          name: '주방 창가 쪽 큰 전자레인지',
          category: 'microwave',
          rows: 1,
          cols: 1,
          buttons: [],
        ),
        cdRemaining: 37,
        cdTotal: 40,
        onApprove: () {},
        onReject: () {},
        // 화면 타이머 '시간 더 주기'(접근성 감사 10/18) — kiosk_screen이 늘 넘긴다.
        onExtend: () {},
      ),
      textScale: 1.22,
    );
  });

  testWidgets('실행', (t) async {
    await _shoot(
      t,
      'executing',
      KioskExecutingView(
        title: '즉석밥 데워줘',
        target: kMicrowaveAppliance,
        lastButtons: null,
        currentButton: '시작',
        currentAttempt: 1,
        completedSteps: 1,
        totalSteps: 2,
        verificationConfidence: 0.93,
        verificationDetail: '전류 +14mA · 소리 +9dB',
        onStop: () {},
      ),
    );
  });

  testWidgets('실행 — 보정 후 다시 시도', (t) async {
    await _shoot(
      t,
      'executing_retry',
      KioskExecutingView(
        title: '즉석밥 데워줘',
        target: kMicrowaveAppliance,
        lastButtons: null,
        currentButton: '즉석밥',
        currentAttempt: 2,
        completedSteps: 0,
        totalSteps: 2,
        verificationConfidence: null,
        verificationDetail: null,
        onStop: () {},
      ),
    );
  });

  testWidgets('실행 — 큰 글씨', (t) async {
    await _shoot(
      t,
      'executing_large',
      KioskExecutingView(
        title: '냉동 만두 데워서 라면이랑 같이 먹을 준비',
        target: kMicrowaveAppliance,
        lastButtons: null,
        currentButton: '냉동식품',
        currentAttempt: 1,
        completedSteps: 2,
        totalSteps: 6,
        verificationConfidence: 0.93,
        verificationDetail: '전류 +14mA · 소리 +9dB',
        onStop: () {},
      ),
      textScale: 1.22,
    );
  });

  testWidgets('수동 조작', (t) async {
    await _shoot(
      t,
      'manual',
      KioskManualView(
        appliance: kMicrowaveAppliance,
        onExecute: (_) {},
        onCancel: () {},
      ),
    );
  });

  testWidgets('수동 조작 — 큰 글씨·4열', (t) async {
    await _shoot(
      t,
      'manual_large',
      KioskManualView(
        appliance: kInductionAppliance,
        onExecute: (_) {},
        onCancel: () {},
      ),
      textScale: 1.22,
    );
  });

  testWidgets('수동 조작 — 준비 안 됨', (t) async {
    await _shoot(
      t,
      'manual_not_ready',
      KioskManualView(
        appliance: const ApplianceMap(
          id: 'microwave',
          name: '전자레인지',
          category: 'microwave',
          rows: 4,
          cols: 3,
          buttons: [
            ApplianceButton(id: 'BT-01', label: '10초', x: 0, y: 0),
            ApplianceButton(id: 'BT-03', label: '1분', x: 2, y: 0),
            ApplianceButton(id: 'BT-08', label: '즉석밥', x: 1, y: 2),
            ApplianceButton(id: 'BT-05', label: '시작', x: 2, y: 3),
          ],
          canExecute: false,
          readiness: 'needs_setup',
          readinessReasons: ['버튼 자리를 아직 맞추지 않았어요'],
        ),
        onExecute: (_) {},
        onCancel: () {},
      ),
    );
  });

  testWidgets('제안 잠시 쉬기 — 큰 글씨', (t) async {
    await _shoot(
      t,
      'dnd_large',
      DndOverlay(
        dndUntil: null,
        onSet: (_) {},
        onClear: () {},
        onDismiss: () {},
      ),
      textScale: 1.22,
    );
  });

  testWidgets('15인치 미리보기 — 평소', (t) async {
    await _shoot15(t, 'kiosk15_idle', _idle());
  });

  // 화면 구조 개편(10/18) — 위쪽 메뉴 창(잠시 쉬기·설정)과 문제가 있을 때의 앰버 상태 칩.
  testWidgets('15인치 미리보기 — 평소, 메뉴 창', (t) async {
    await _shoot15(t, 'kiosk15_idle_menu', _idle(), before: (t) async {
      await t.tap(find.byKey(const ValueKey('idle-menu')));
      await t.pump();
    });
  });

  // 휴리스틱 평가(10/18) — 메뉴의 '사용 방법' 첫 장.
  testWidgets('15인치 미리보기 — 평소, 사용 방법', (tester) async {
    await _shoot15(tester, 'kiosk15_idle_help', _idle(), before: (t) async {
      await t.tap(find.byKey(const ValueKey('idle-menu')));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('help-entry')));
      await t.pump();
    });
  });

  testWidgets('15인치 미리보기 — 평소, 누름 장치 연결 끊김 칩', (t) async {
    await _shoot15(
        t,
        'kiosk15_idle_problem',
        _idle(connections: const [
          ConnectionItem(id: 'network', state: 'ok', title: '', message: ''),
          ConnectionItem(id: 'press', state: 'error', title: '누름 장치와 연결이 끊겼어요', message: ''),
        ]));
  });

  // 2026-10-16 — 실내 공기 한 줄(시계 아래 빈 자리), ThinQ 공기청정기 상세(지금 상태 + 큰 조작 단추).
  // 사용자 결정(10/18): 공기 줄은 나쁠 때만, 공기청정기 전원 말은 뺀다(가전 타일이 말한다). 다음 루틴은 그 아래.
  testWidgets('15인치 미리보기 — 평소, 실내 공기 나쁨 한 줄', (t) async {
    await _shoot15(
        t,
        'kiosk15_idle_air',
        _idle(
            // 평가 14차(10/18) — 공기청정기가 가전 줄에 있으면 공기 줄 아래 할 일 작은 글자 단추('공기청정기를 켜 보세요').
            appliances: [_purifierAppliance, _mw, _ind, _washerSetup],
            running: const {},
            off: const {'air_purifier'},
            air: const KioskAirReading(
                applianceId: 'air_purifier', grade: 'BAD', pm25: 42, pm10: 90, power: 'off'),
            nextRun: _nextRun()));
  });

  // 사용자 결정(10/18) — 다음 루틴은 시계 아래 담담한 줄 + '오늘은 건너뛰기'(오른쪽 큰 카드는 없앴다). 실패널 k01과 같은
  // 조건(예보·보통 공기 — 공기 줄은 없다). 평가 4차(10/18) — 가전 4개(LG 공기청정기 포함)면 장 넘김 없이 한 줄에 4개.
  testWidgets('15인치 미리보기 — 평소, 다음 루틴 줄', (t) async {
    await _shoot15(
        t,
        'kiosk15_idle_next',
        _idle(
            // 실패널 k01과 같은 넷 — 공기청정기 켜짐(읽은 값) · 전자레인지 · 인덕션 · 세탁기(사진 자리 미설정).
            appliances: [_purifierAppliance, _mw, _ind, _washerSetup],
            running: const {},
            on: const {'air_purifier'},
            air: const KioskAirReading(
                applianceId: 'air_purifier', grade: 'NORMAL', pm25: 20, power: 'on'),
            nextRun: _nextRun()));
  });

  // 2026-10-18 — '오늘은 건너뛰기'를 누른 뒤: 서버 말 '오늘은 건너뛰어요' + '되돌리기'.
  testWidgets('15인치 미리보기 — 평소, 다음 루틴 오늘은 건너뜀', (t) async {
    await _shoot15(
        t,
        'kiosk15_idle_next_skipped',
        _idle(
            appliances: [_purifierAppliance, _mw, _ind, _washerSetup],
            running: const {},
            on: const {'air_purifier'},
            nextRun: _nextRun(skipped: true)));
  });

  // 평가 10차(10/18) — 지금 비면 날짜 옆에 비 오는 구름(물방울은 습도로 읽혔다), 꺼진 LG 가전은 '꺼져 있어요'.
  testWidgets('15인치 미리보기 — 평소, 지금 비·꺼진 공기청정기', (t) async {
    await _shoot15(
        t,
        'kiosk15_idle_rain_off',
        _idle(
            appliances: [_purifierAppliance, _mw, _ind, _washerSetup],
            running: const {},
            off: const {'air_purifier'},
            ambient: const AmbientInfo(
              greeting: '좋은 아침이에요.',
              weatherSource: 'kma',
              now: AmbientHour(label: '지금', hour: 7, icon: 'rain', temp: 14, pop: 80, precip: true),
              hourly: [
                AmbientHour(label: '9시', hour: 9, icon: 'rain', temp: 14),
                AmbientHour(label: '12시', hour: 12, icon: 'cloudy', temp: 16),
                AmbientHour(label: '15시', hour: 15, icon: 'rain', temp: 15),
                AmbientHour(label: '18시', hour: 18, icon: 'partly', temp: 13),
              ],
            )));
  });

  testWidgets('평소 — 큰 글씨, 실내 공기 매우 나쁨', (t) async {
    await _shoot(
        t,
        'idle_air_large',
        _idle(
            air: const KioskAirReading(
                applianceId: 'air_purifier', grade: 'VERY_BAD', pm25: 120, power: 'on')),
        textScale: 1.22);
  });

  // 2026-10-18 — 실제 공기청정기 옆 연습 LG 세탁기 타일(세탁기 그림·이름의 '(연습)'), 인덕션은 '설정이 필요해요'.
  testWidgets('15인치 미리보기 — 평소, LG 세탁기(연습)·인덕션 설정 필요', (t) async {
    await _shoot15(
        t,
        'kiosk15_idle_practice_washer',
        _idle(
            appliances: [_purifierAppliance, _mw, _practiceWasher, _ind],
            running: const {},
            on: const {'air_purifier'},
            nextRun: _nextRun()));
  });

  testWidgets('15인치 미리보기 — LG 세탁기(연습) 상세', (t) async {
    await _shoot15(t, 'kiosk15_thinq_washer_practice', _washerDetail());
  });

  testWidgets('15인치 미리보기 — ThinQ 공기청정기 상세(실제)', (t) async {
    await _shoot15(t, 'kiosk15_thinq_detail', _thinqDetail());
  });

  testWidgets('ThinQ 공기청정기 상세 — 큰 글씨, 전원 꺼짐', (t) async {
    await _shoot(t, 'thinq_detail_large', _thinqDetail(power: 'POWER_OFF', sensor: false),
        textScale: 1.22);
  });

  // 2026-10-06 실패널 결함 — 비상정지 띠 + 루틴 안내 + 예보 + 가전 줄이 함께 있어도
  // 예보가 가전 줄에 걸려 잘리지 않는다(남은 높이가 모자라면 예보를 접는다).
  testWidgets('15인치 미리보기 — 평소, 비상정지 띠와 안내', (t) async {
    await _shoot15(
        t,
        'kiosk15_idle_estop',
        KioskEstopLayout(
          banner: KioskEstopBanner(
              detail: _estopDetail, onRequest: () {}),
          child: _idle(
            ambient: const AmbientInfo(
              greeting: '좋은 아침이에요.',
              tip: AmbientTip(
                  kind: 'routine',
                  text: '약 드실 시간이에요. 아직 안 드셨으면 지금 챙겨 드세요',
                  icon: 'notice'),
              hourly: [
                AmbientHour(label: '9시', icon: 'partly', temp: 16, precip: false),
                AmbientHour(label: '12시', icon: 'cloudy', temp: 18, precip: false),
                // 서버는 비 칸에도 기온을 준다(services/weather/ambient.py) — 모든 칸 아이콘 + 기온, 강수확률은 둘째 줄(평가 11차 10/18).
                AmbientHour(label: '15시', icon: 'rain', temp: 17, pop: 70, precip: true),
                AmbientHour(label: '18시', icon: 'rain', temp: 15, pop: 60, precip: true),
              ],
            ),
          ),
        ));
  });

  testWidgets('15인치 미리보기 — 동작 중', (t) async {
    await _shoot15(t, 'kiosk15_hold', _hold());
  });

  testWidgets('15인치 미리보기 — 내 가전', (t) async {
    await _shoot15(t, 'kiosk15_my_appliance', _mine());
  });

  testWidgets('15인치 미리보기 — 제안', (t) async {
    await _shoot15(
      t,
      'kiosk15_suggestion',
      KioskSuggestionView(
        suggestion: suggestion,
        target: kMicrowaveAppliance,
        cdRemaining: 37,
        cdTotal: 40,
        onApprove: () {},
        onReject: () {},
        // 화면 타이머 '시간 더 주기'(접근성 감사 10/18) — kiosk_screen이 늘 넘긴다.
        onExtend: () {},
      ),
    );
  });

  // 사양 해상도 확인(9/14) 뒤 넓힌 15인치 미리보기 — 나머지 상태와 오버레이.
  testWidgets('15인치 미리보기 — 가전 선택', (t) async {
    await _shoot15(
      t,
      'kiosk15_appliance_select',
      KioskApplianceSelectView(
        appliances: const [kMicrowaveAppliance, kInductionAppliance],
        lastUsedId: 'microwave',
        onSelect: (_) {},
        onCancel: () {},
      ),
    );
  });

  testWidgets('15인치 미리보기 — 실행', (t) async {
    await _shoot15(
      t,
      'kiosk15_executing',
      KioskExecutingView(
        title: '즉석밥 데워줘',
        target: kMicrowaveAppliance,
        lastButtons: null,
        currentButton: '시작',
        currentAttempt: 1,
        completedSteps: 1,
        doneButtons: const ['즉석밥'],
        totalSteps: 2,
        verificationConfidence: 0.93,
        verificationDetail: '전류 +14mA · 소리 +9dB',
        onStop: () {},
      ),
    );
  });

  for (final verified in [false, true]) {
    testWidgets('15인치 완료 — ${verified ? '전력 확인' : '누름 보고만'}', (t) async {
      await _shoot15(t, verified ? 'kiosk15_done_verified' : 'kiosk15_done_reported',
        KioskDoneView(success: true, label: '즉석밥 데워줘', target: kMicrowaveAppliance,
          executionMode: 'real', resultConfirmation: 'reported',
          operationConfirmed: verified ? true : null, operationSource: verified ? 'real' : null,
          pressed: const [KioskButtonResult(button: '즉석밥', success: true), KioskButtonResult(button: '시작', success: true)],
          onDismiss: _noop));
    });
  }

  testWidgets('15인치 미리보기 — 완료', (t) async {
    await _shoot15(
      t,
      'kiosk15_done',
      KioskDoneView(
        success: true,
        label: '즉석밥 데워줘',
        target: kMicrowaveAppliance,
        onDismiss: () {},
      ),
    );
  });

  testWidgets('15인치 미리보기 — 수동 조작', (t) async {
    await _shoot15(
      t,
      'kiosk15_manual',
      KioskManualView(
        appliance: kMicrowaveAppliance,
        onExecute: (_) {},
        onCancel: () {},
      ),
    );
  });

  testWidgets('15인치 미리보기 — 제안 잠시 쉬기', (t) async {
    await _shoot15(
      t,
      'kiosk15_dnd',
      DndOverlay(
        dndUntil: null,
        onSet: (_) {},
        onClear: () {},
        onDismiss: () {},
      ),
    );
  });

  testWidgets('15인치 미리보기 — 위험 신호음 경보', (t) async {
    await _shoot15(
      t,
      'kiosk15_danger',
      DangerAlertOverlay(onAcknowledge: () {}),
    );
  });

  testWidgets('완료', (t) async {
    await _shoot(
      t,
      'done',
      KioskDoneView(
        success: true,
        label: '즉석밥 데워줘',
        target: kMicrowaveAppliance,
        onDismiss: () {},
      ),
    );
  });

  testWidgets('완료 — 큰 글씨', (t) async {
    await _shoot(
      t,
      'done_large',
      KioskDoneView(
        success: true,
        label: '냉동 만두 데워서 라면이랑 같이 먹을 준비',
        target: kMicrowaveAppliance,
        onDismiss: () {},
      ),
      textScale: 1.22,
    );
  });

  testWidgets('완료 — 몰라요', (t) async {
    await _shoot(
      t,
      'done_failed',
      KioskDoneView(
        success: false,
        label: '즉석밥 데워줘',
        target: kMicrowaveAppliance,
        onRetry: () {},
        onManual: () {},
        onDismiss: () {},
      ),
    );
  });

  // 2026-10-14 문구 정리: 사용자가 멈춘 실행은 실패가 아니다 — 손 아이콘·차분한 색, 닫기가 먼저.
  testWidgets('완료 — 사용자 정지', (t) async {
    await _shoot(
      t,
      'done_user_stop',
      KioskDoneView(
        success: false,
        label: '즉석밥 데워줘',
        target: kMicrowaveAppliance,
        reason: KioskFailureReason.stopped,
        stopLevel: 'verified',
        stopAckMs: 9,
        onRetry: () {},
        onManual: () {},
        onDismiss: () {},
      ),
    );
  });

  testWidgets('완료 — 사용자 정지, 큰 글씨', (t) async {
    await _shoot(
      t,
      'done_user_stop_large',
      KioskDoneView(
        success: false,
        label: '즉석밥 데워줘',
        target: kMicrowaveAppliance,
        reason: KioskFailureReason.stopped,
        stopLevel: 'sent',
        executionMode: 'real',
        // 평가 16차(10/18) — 실제 화면처럼 '다시 멈추기'를 넘긴다(큰 글씨에서도 정지 자리에 보인다).
        onStopAgain: () {},
        onRetry: () {},
        onManual: () {},
        onDismiss: () {},
      ),
      textScale: 1.22,
    );
  });

  // ── 2026-10-15 문구 개선 1단계 — 처음 쓰는 사람 검토용으로 늘린 장면 ──────────────
  testWidgets('완료 — 버튼을 다 눌렀어요·전력 사용이 늘었어요', (t) async {
    await _shoot(
      t,
      'done_power',
      KioskDoneView(
        success: true,
        label: '즉석밥 데워줘',
        executionMode: 'real',
        target: kMicrowaveAppliance,
        operationConfirmed: true,
        operationSource: 'real',
        onDismiss: () {},
      ),
    );
  });

  testWidgets('동작 중 — 비상 버튼 풀기 안내', (t) async {
    await _shoot(
        t,
        'hold_estop_confirm',
        KioskEstopLayout(
          banner: KioskEstopBanner(
              detail: _estopDetail, confirming: true, onRequest: () {}),
          child: _hold(),
        ));
  });

  testWidgets('15인치 미리보기 — 실패(가전을 먼저 봐 주세요)', (t) async {
    await _shoot15(
      t,
      'kiosk15_done_failed',
      KioskDoneView(
        success: false,
        label: '즉석밥 데워줘',
        target: kMicrowaveAppliance,
        // 서버는 실패에도 누른 단계(last_buttons)를 준다 — 성공과 같은 자리에 누른 순서·버튼판(출시 검토 10/18).
        pressed: const [KioskButtonResult(button: '즉석밥', success: true), KioskButtonResult(button: '시작', success: false)],
        onRetry: () {},
        onManual: () {},
        onDismiss: () {},
      ),
    );
  });

  // 휴리스틱 평가(10/18) — '안 움직였어요'라고 답한 뒤: '손으로 할게요'(앞) · '한 번 더 하기'(확인 창).
  testWidgets('15인치 미리보기 — 눌렸는지 모름, 안 움직였어요 뒤', (tester) async {
    await _shoot15(
      tester,
      'kiosk15_done_check_no',
      KioskDoneView(
        success: false,
        executionMode: 'real',
        label: '즉석밥 데워줘',
        target: kMicrowaveAppliance,
        pressed: const [KioskButtonResult(button: '즉석밥', success: true), KioskButtonResult(button: '시작', success: false)],
        onRetry: () {},
        onManual: () {},
        onDismiss: () {},
      ),
      before: (t) async {
        await t.tap(find.byKey(const ValueKey('done-check-no')));
        await t.pump();
      },
    );
  });

  testWidgets('15인치 미리보기 — 정지 몰라요', (t) async {
    await _shoot15(
      t,
      'kiosk15_hold_unconfirmed',
      const KioskHoldView(
        appliance: kMicrowaveAppliance,
        holdState: 'parked',
        stopOutcome: 'requested_unconfirmed',
        stopButton: '취소',
        executionMode: 'real',
        elapsed: Duration(minutes: 1, seconds: 40),
        onStop: _noop,
        onClose: _noop,
      ),
    );
  });

  testWidgets('15인치 미리보기 — 사용자 정지(멈추라고 보냄)', (t) async {
    await _shoot15(
      t,
      'kiosk15_done_user_stop',
      KioskDoneView(
        success: false,
        executionMode: 'real',
        label: '즉석밥 데워줘',
        target: kMicrowaveAppliance,
        reason: KioskFailureReason.stopped,
        stopLevel: 'sent',
        onRetry: () {},
        onManual: () {},
        // 평가 15차(10/18) — 멈췄는지 모르면 골라 누르기 대신 정지 자리의 '다시 멈추기'.
        onStopAgain: () {},
        onDismiss: () {},
      ),
    );
  });

  // 평가 8차(10/18) — 정지 확인 보고를 기다리는 동안은 끝난 결과가 아니다: 진행 말·처음 화면 단추 없음.
  testWidgets('15인치 미리보기 — 사용자 정지, 확인 기다리는 중', (t) async {
    await _shoot15(
      t,
      'kiosk15_done_stop_pending',
      KioskDoneView(
        success: false,
        label: '즉석밥 데워줘',
        target: kMicrowaveAppliance,
        executionMode: 'real',
        reason: KioskFailureReason.stopped,
        stopPending: true,
        onRetry: () {},
        onManual: () {},
        onDismiss: () {},
      ),
    );
  });

  // ── 2026-10-15 문구 개선 3단계 — 연결 창(B4)·본체 풀이 ─────────────
  const networkDown = ConnectionItem(
    id: 'network',
    state: 'error',
    title: '와이파이 연결이 끊겼어요',
    message: '본체가 집 와이파이에 연결되지 않았어요. 휴대폰 앱에서 찾지 못하고, '
        '날씨 안내도 볼 수 없어요.',
    fixes: [
      '공유기 전원이 켜져 있는지 확인해 주세요.',
      '그래도 안 되면 본체 전원을 껐다가 다시 켜 주세요.',
    ],
  );

  testWidgets('연결 창 — 큰 글씨·본체 풀이', (t) async {
    await _shoot(
      t,
      'connection_modal_large',
      Stack(children: [
        // 배경 칩도 같은 문제를 말한다(평가 7차 10/18).
        Positioned.fill(child: _idle(connections: const [networkDown, ConnectionItem(id: 'press', state: 'ok', title: '', message: '')])),
        Positioned.fill(
          child: KioskConnectionModal(
              item: networkDown, checking: false, onRecheck: () {}, onClose: () {}),
        ),
      ]),
      textScale: 1.22,
    );
  });

  testWidgets('15인치 미리보기 — 연결 창', (t) async {
    await _shoot15(
      t,
      'kiosk15_connection_modal',
      Stack(children: [
        // 배경 칩도 같은 문제를 말한다(평가 7차 10/18).
        Positioned.fill(child: _idle(connections: const [networkDown, ConnectionItem(id: 'press', state: 'ok', title: '', message: '')])),
        Positioned.fill(
          child: KioskConnectionModal(
              item: networkDown, checking: false, onRecheck: () {}, onClose: () {}),
        ),
      ]),
    );
  });

  testWidgets('15인치 미리보기 — 평소, 제안 쉬는 중', (t) async {
    await _shoot15(t, 'kiosk15_idle_dnd', _idle(dndUntil: DateTime(2026, 9, 30, 8, 38)));
  });

  // 사용자 결정(10/18) — 조용한 시간에는 처음 화면만 어둡게: 시계·다음 루틴·문제 표시만, 예보·인사말·가전 줄은 접는다.
  // 막 짙기는 추측이다(실패널에서 밤에 1~2 m로 보고 고친다).
  testWidgets('15인치 미리보기 — 평소, 조용한 시간 어둡게', (t) async {
    await _shoot15(
        t,
        'kiosk15_idle_quiet',
        _idle(
            now: DateTime(2026, 9, 30, 23, 12),
            quietUntil: '07:00',
            quietDim: true,
            nextRun: const KioskNextRun(
              name: '아침 공기청정기 끄기',
              dayLabel: '내일',
              hhmm: '07:00',
              modeLabel: '자동 실행',
              routineId: 'rt-morning',
              at: '2026-10-01T07:00:00+09:00',
              skipActionLabel: '내일은 건너뛰기',
            )),
        // 평가 15차(10/18) — 어두운 막은 패널 전체(가장자리 여백까지). kiosk_screen이 캔버스에 같은 판정을 넘긴다.
        dim: true);
  });

  // 사용자 결정(10/18) — 설정의 고대비: 회색 보조 글자 → 흰색, 옅은 면 → 검정 + 흰 테두리, 상태색은 더 또렷하게.
  testWidgets('15인치 미리보기 — 평소, 고대비', (t) async {
    KioskColors.setHighContrast(true);
    addTearDown(() => KioskColors.setHighContrast(false));
    await _shoot15(
        t,
        'kiosk15_idle_contrast',
        _idle(
            appliances: [_purifierAppliance, _mw, _ind, _washerSetup],
            running: const {},
            on: const {'air_purifier'},
            nextRun: _nextRun(),
            connections: const [
              ConnectionItem(id: 'network', state: 'ok', title: '', message: ''),
              ConnectionItem(id: 'press', state: 'error', title: '누름 장치와 연결이 끊겼어요', message: ''),
            ]));
  });

  // 사용자 결정(10/18) — 결과 화면을 닫은 뒤에도 실패·'확인 못 함'은 처음 화면 위에 한 줄로, '확인'을 누를 때까지.
  testWidgets('15인치 미리보기 — 평소, 지난 일 한 줄', (t) async {
    await _shoot15(
        t,
        'kiosk15_idle_past',
        KioskEstopLayout(
          banner: KioskPastResultLine(
            result: KioskPastResult(at: DateTime(2026, 9, 30, 15, 12), label: '즉석밥 데우기', headline: '눌렸는지 몰라요'),
            onAcknowledge: _noop,
          ),
          child: _idle(
              appliances: [_purifierAppliance, _mw, _ind, _washerSetup],
              running: const {},
              on: const {'air_purifier'},
              nextRun: _nextRun()),
        ));
  });

  // ── 2026-10-16 디자인 규격 — 연습(청록 띠)·비상 버튼 띠 + 정지 영역 ────────────────────
  testWidgets('15인치 미리보기 — 연습 실행(청록 띠)', (t) async {
    await _shoot15(
      t,
      'kiosk15_executing_practice',
      KioskExecutingView(
        executionMode: 'mock',
        title: '즉석밥 데워줘',
        target: kMicrowaveAppliance,
        lastButtons: null,
        currentButton: '시작',
        currentAttempt: 1,
        completedSteps: 1,
        // 화면이 본 끝낸 버튼(실제 흐름은 kiosk_screen이 모은다) — 누를 순서 첫 칸 이름(평가 8차 10/18).
        doneButtons: const ['즉석밥'],
        totalSteps: 2,
        verificationConfidence: null,
        verificationDetail: null,
        onStop: () {},
      ),
    );
  });

  testWidgets('15인치 미리보기 — 정지 대기, 비상 버튼 띠', (t) async {
    await _shoot15(
        t,
        'kiosk15_hold_estop',
        KioskEstopLayout(
          banner: KioskEstopBanner(detail: _estopDetail, onRequest: () {}),
          child: const KioskHoldView(
            appliance: kMicrowaveAppliance,
            holdState: 'hovering_stop',
            stopButton: '취소',
            executionMode: 'real',
            elapsed: Duration(minutes: 1, seconds: 2),
            buttonsPressed: 2,
            operationConfirmed: true,
            operationSource: 'real',
            onStop: _noop,
            estopTitle: '비상 버튼이 눌려 있어요',
          ),
        ));
  });

  testWidgets('15인치 미리보기 — 연습 결과 실패(청록 연습 칸 + 빨강 띠)', (t) async {
    await _shoot15(
      t,
      'kiosk15_done_failed_practice',
      KioskDoneView(
        success: false,
        executionMode: 'mock',
        label: '즉석밥 데워줘',
        target: kMicrowaveAppliance,
        onRetry: () {},
        onManual: () {},
        onDismiss: () {},
      ),
    );
  });

  // 사용자 요청(10/18) — LG 가전 실행은 버튼판·누를 순서 없이 기다림 + 한 줄, 끝나면 결과 창 하나.
  KioskExecutingView thinqSending() => KioskExecutingView(
        executionMode: 'real',
        title: '공기청정기를 켤까요?',
        target: _purifierAppliance,
        thinqOnly: true,
        lastButtons: null,
        currentButton: null,
        currentAttempt: null,
        completedSteps: null,
        totalSteps: 1,
        verificationConfidence: null,
        verificationDetail: null,
        onStop: () {},
      );
  KioskDoneView thinqDone({bool confirmed = true, String? detail}) => KioskDoneView(
        success: confirmed,
        reason: confirmed ? null : KioskFailureReason.unconfirmed,
        executionMode: 'real',
        label: '공기청정기를 켤까요?',
        target: _purifierAppliance,
        thinqOnly: true,
        route: 'thinq',
        resultConfirmation: confirmed ? 'state_confirmed' : 'none',
        detail: detail ?? (confirmed ? '전원 켜기로 바꿨어요.' : '가전에 전했지만 설정이 바뀌었는지 몰라요. 가전을 봐 주세요.'),
        onDismiss: () {},
      );

  testWidgets('15인치 미리보기 — LG 가전 보내는 중', (t) async {
    await _shoot15(t, 'kiosk15_thinq_sending', thinqSending());
  });

  testWidgets('15인치 미리보기 — LG 가전 결과(확인됨)', (t) async {
    await _shoot15(t, 'kiosk15_thinq_result', thinqDone());
  });

  testWidgets('15인치 미리보기 — LG 가전 결과(바람 세기, 확인됨)', (t) async {
    await _shoot15(t, 'kiosk15_thinq_result_wind', thinqDone(detail: '바람 세기 강으로 바꿨어요.'));
  });

  testWidgets('15인치 미리보기 — LG 가전 결과(확인 못 함)', (t) async {
    await _shoot15(t, 'kiosk15_thinq_result_unconfirmed', thinqDone(confirmed: false));
  });

  testWidgets('LG 가전 보내는 중 — 큰 글씨', (t) async {
    await _shoot(t, 'thinq_sending_large', thinqSending(), textScale: 1.22);
  });

  testWidgets('LG 가전 결과 — 큰 글씨', (t) async {
    await _shoot(t, 'thinq_result_large', thinqDone(), textScale: 1.22);
  });
  // ── 제출용 장면(심사위원 시각 평가 10/18 §3-5) ─────────────────────────────────────────────
  // 위 골든의 가전 다섯(세탁기·선풍기·인덕션 등)은 화면 시험용 예시다. 제출 서류·발표 그림에는 지금 실물 구성
  // — 누름 장치가 누르는 전자레인지 1대 + LG 공기청정기 — 으로 만든 아래 장면만 쓴다. 결과는 지금 실물로 낼 수 있는
  // 확인 수준(누름 장치 보고, 전력 판정 없음)이라 '버튼은 다 눌렀어요'까지만 말한다(콘센트 모듈 CT 미측정).
  final submissionPurifier = _served('air_purifier', '공기청정기', 'air_purifier', control: 'thinq');
  const submissionAmbient = AmbientInfo(
    greeting: '좋은 저녁이에요.',
    hourly: [
      AmbientHour(label: '18시', icon: 'partly', temp: 17),
      AmbientHour(label: '21시', icon: 'cloudy', temp: 15),
      AmbientHour(label: '0시', icon: 'cloudy', temp: 13),
      AmbientHour(label: '3시', icon: 'cloudy', temp: 12),
    ],
    weatherSource: 'kma',
  );

  testWidgets('제출용 — 처음 화면(전자레인지 + 공기청정기)', (t) async {
    await _shoot15(
      t,
      'kiosk15_submission_idle',
      _idle(
        now: DateTime(2026, 10, 18, 18, 20),
        ambient: submissionAmbient,
        appliances: [_mw, submissionPurifier],
        running: const {},
        on: const {'air_purifier'},
        nextRun: _nextRun(),
      ),
    );
  });

  testWidgets('제출용 — 전자레인지 실행 중(누름 장치)', (t) async {
    await _shoot15(
      t,
      'kiosk15_submission_executing',
      KioskExecutingView(
        title: '즉석밥 데워줘',
        target: kMicrowaveAppliance,
        executionMode: 'real',
        lastButtons: null,
        currentButton: '시작',
        currentAttempt: 1,
        completedSteps: 1,
        doneButtons: const ['즉석밥'],
        totalSteps: 2,
        // 지금 실물 구성은 버튼별 눌림 센서 판정을 보내지 않는다.
        verificationConfidence: null,
        verificationDetail: null,
        onStop: () {},
      ),
    );
  });

  testWidgets('제출용 — 전자레인지 결과(누름 장치 보고)', (t) async {
    await _shoot15(
      t,
      'kiosk15_submission_done',
      KioskDoneView(
        success: true,
        label: '즉석밥 데워줘',
        target: kMicrowaveAppliance,
        executionMode: 'real',
        resultConfirmation: 'reported',
        pressed: const [
          KioskButtonResult(button: '즉석밥', success: true),
          KioskButtonResult(button: '시작', success: true),
        ],
        onDismiss: _noop,
      ),
    );
  });
}
