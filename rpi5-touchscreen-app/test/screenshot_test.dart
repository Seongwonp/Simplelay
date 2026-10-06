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

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/theme/kiosk_colors.dart';
import 'package:simplelay_touchscreen/models/ambient.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
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
import 'package:simplelay_touchscreen/widgets/kiosk/suggestion_view.dart';

const _kioskSize = Size(800, 480);

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
  await expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile('goldens/$name.png'),
  );
}

/// 15.8형 패널 미리보기 — 제품 사양표 해상도 1920x1080
/// (docs/하드웨어-연결-설계.md §0-1). KioskCanvas가 가장자리 48px을 비우고
/// 800x480 설계 캔버스를 2.05배로 확대해 채운 모습 -- 글씨·버튼·터치타깃이 함께 커진다.
Future<void> _shoot15(WidgetTester tester, String name, Widget child) async {
  tester.view.physicalSize = const Size(1920, 1080);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(fontFamily: 'Malgun', brightness: Brightness.dark),
      home: KioskCanvas(
        child: Scaffold(backgroundColor: KioskColors.bg, body: child),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 300));
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

const _washer = ApplianceMap(
  id: 'washer',
  name: '세탁기',
  category: 'washing_machine',
  rows: 1,
  cols: 1,
  buttons: [],
);

const _fanAppliance = ApplianceMap(
  id: 'custom_fan',
  name: '거실 선풍기',
  category: 'other',
  rows: 1,
  cols: 1,
  buttons: [],
);

const _rice = ApplianceMap(
  id: 'rice',
  name: '밥솥',
  category: 'rice_cooker',
  rows: 1,
  cols: 1,
  buttons: [],
);

/// 평소 화면 — 가전 다섯(4개씩 넘기기), 세탁기 동작 중.
KioskIdleView _idle({
  List<ConnectionItem> connections = _okConnections,
  Set<String> attention = const {},
  AmbientInfo ambient = _ambient,
  DateTime? dndUntil,
}) =>
    KioskIdleView(
      now: DateTime(2026, 9, 30, 7, 8),
      connected: true,
      ambient: ambient,
      connections: connections,
      appliances: const [
        kMicrowaveAppliance,
        _washer,
        kInductionAppliance,
        _fanAppliance,
        _rice,
      ],
      running: const {'washer'},
      attention: attention,
      temperature: 23,
      humidity: 58,
      dndUntil: dndUntil,
      onSelectAppliance: (_) {},
      onOpenConnection: (_) {},
      onDndGesture: () {},
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
    );

KioskManualView _mine() => KioskManualView(
      appliance: kMicrowaveAppliance,
      onExecute: (_) {},
      onCancel: () {},
      routines: const [
        KioskRoutine(id: 'morning', name: '아침 데우기', stepCount: 3),
        KioskRoutine(id: 'evening', name: '저녁 데우기', stepCount: 4),
      ],
      onRoutine: (_) {},
    );

void main() {
  setUpAll(() async {
    final iconBytes = File(r'C:\flutter\flutter\bin\cache\artifacts\material_fonts\materialicons-regular.otf').readAsBytesSync();
    await (FontLoader('MaterialIcons')
          ..addFont(Future.value(ByteData.view(iconBytes.buffer))))
        .load();
    final bytes = File(r'C:\Windows\Fonts\malgun.ttf').readAsBytesSync();
    final loader = FontLoader('Malgun')
      ..addFont(Future.value(ByteData.view(bytes.buffer)));
    await loader.load();
  });

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

  testWidgets('평소 — 방해 금지 중(위 줄 칩)', (t) async {
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
        ambient: const AmbientInfo(
          greeting: '편안한 저녁 보내세요.',
          tip: AmbientTip(
              kind: 'appliance',
              text: '인덕션 확인이 필요해요. 마지막 작업이 끝까지 되지 않았어요.',
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

  testWidgets('평소 — 허브 연결 끊김', (t) async {
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
        Positioned.fill(child: _idle()),
        Positioned.fill(
          child: KioskConnectionModal(
            item: const ConnectionItem(
              id: 'plug',
              state: 'warn',
              title: '플러그 연결이 약해요',
              message:
                  '가전이 끝났는지 알려 주는 플러그와 연결이 약해요. 끝났다는 알림이 늦거나 오지 않을 수 있어요.',
              fixes: [
                '플러그가 콘센트에 끝까지 꽂혀 있는지 확인해 주세요.',
                '플러그를 허브와 가까운 콘센트로 옮겨 주세요.',
                '그래도 안 되면 플러그를 뽑았다가 10초 뒤 다시 꽂아 주세요.',
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
              detail: '콘센트 모듈의 비상정지 버튼이 눌렸어요', onRequest: () {}),
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
        cdRemaining: 20,
        cdTotal: 20,
        onApprove: () {},
        onReject: () {},
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
        cdRemaining: 20,
        cdTotal: 20,
        onApprove: () {},
        onReject: () {},
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
        cdRemaining: 20,
        cdTotal: 20,
        onApprove: () {},
        onReject: () {},
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
          readinessReasons: ['버튼 위치 보정이 아직 안 됐어요'],
        ),
        onExecute: (_) {},
        onCancel: () {},
      ),
    );
  });

  testWidgets('방해 금지 — 큰 글씨', (t) async {
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

  // 2026-10-06 실패널 결함 — 비상정지 띠 + 루틴 안내 + 예보 + 가전 줄이 함께 있어도
  // 예보가 가전 줄에 걸려 잘리지 않는다(남은 높이가 모자라면 예보를 접는다).
  testWidgets('15인치 미리보기 — 평소, 비상정지 띠와 안내', (t) async {
    await _shoot15(
        t,
        'kiosk15_idle_estop',
        KioskEstopLayout(
          banner: KioskEstopBanner(
              detail: '콘센트 모듈의 비상정지 버튼이 눌렸어요', onRequest: () {}),
          child: _idle(
            ambient: const AmbientInfo(
              greeting: '좋은 아침이에요.',
              tip: AmbientTip(
                  kind: 'routine',
                  text: '약 드실 시간이에요. 드셨으면 화면에서 확인을 눌러 주세요',
                  icon: 'notice'),
              hourly: [
                AmbientHour(label: '9시', icon: 'partly', temp: 16, precip: false),
                AmbientHour(label: '12시', icon: 'cloudy', temp: 18, precip: false),
                AmbientHour(label: '15시', icon: 'rain', pop: 70, precip: true),
                AmbientHour(label: '18시', icon: 'rain', pop: 60, precip: true),
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
        cdRemaining: 20,
        cdTotal: 20,
        onApprove: () {},
        onReject: () {},
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
        totalSteps: 2,
        verificationConfidence: 0.93,
        verificationDetail: '전류 +14mA · 소리 +9dB',
        onStop: () {},
      ),
    );
  });

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

  testWidgets('15인치 미리보기 — 방해 금지', (t) async {
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

  testWidgets('완료 — 확인 못 함', (t) async {
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
}
