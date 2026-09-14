// 키오스크 화면을 실제 이미지로 렌더한다 — 눈으로 확인하기 위한 도구다.
//
// 왜 필요한가: 이 앱은 라즈베리파이 7인치에서만 도는데 개발 PC에 웹 지원이 없다.
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
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/appliance_select_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/dnd_overlay.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/done_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/executing_view.dart';
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

/// 15인치 패널 미리보기 — 해상도는 1920x1080 **가정**(실제 사양 확인 필요,
/// docs/하드웨어-연결-설계.md §0-1). KioskCanvas가 800x480 설계
/// 캔버스를 2.25배로 확대해 채운 모습 -- 글씨·버튼·터치타깃이 함께 커진다.
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
    purpose: '우유 데워줘',
    occurrences: 3,
    timeBand: '아침',
    steps: ['해동', '시간 90초', '시작'],
  );

  testWidgets('대기', (t) async {
    await _shoot(
      t,
      'idle',
      KioskIdleView(
        now: DateTime(2026, 8, 30, 18, 56),
        connected: true,
        actuatorReady: true,
        appliance: kMicrowaveAppliance,
        temperature: 26.5,
        humidity: 58,
        onTap: () {},
        onLongPress: () {},
      ),
    );
  });

  testWidgets('대기 — 큰 글씨', (t) async {
    await _shoot(
      t,
      'idle_large',
      KioskIdleView(
        now: DateTime(2026, 8, 30, 18, 56),
        connected: true,
        actuatorReady: true,
        appliance: const ApplianceMap(
          id: 'custom_ac',
          name: '거실 창가 스탠드 에어컨',
          category: 'air_conditioner',
          rows: 1,
          cols: 1,
          buttons: [],
        ),
        temperature: 26.5,
        humidity: 58,
        onTap: () {},
        onLongPress: () {},
      ),
      textScale: 1.22,
    );
  });

  testWidgets('대기 — 준비 안 된 가전', (t) async {
    await _shoot(
      t,
      'idle_not_ready',
      KioskIdleView(
        now: DateTime(2026, 8, 30, 18, 56),
        connected: true,
        actuatorReady: true,
        appliance: const ApplianceMap(
          id: 'microwave',
          name: '전자레인지',
          category: 'microwave',
          rows: 1,
          cols: 1,
          buttons: [],
          canExecute: false,
          readiness: 'needs_setup',
          readinessReasons: ['버튼 위치 보정이 아직 안 됐어요'],
        ),
        onTap: () {},
        onLongPress: () {},
      ),
    );
  });

  testWidgets('대기 — 연결 끊김', (t) async {
    await _shoot(
      t,
      'idle_disconnected',
      KioskIdleView(
        now: DateTime(2026, 8, 30, 18, 56),
        connected: false,
        actuatorReady: false,
        onTap: () {},
        onLongPress: () {},
      ),
    );
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
        onRejectMute: () {},
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
        onRejectMute: () {},
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
        onRejectMute: () {},
      ),
      textScale: 1.22,
    );
  });

  testWidgets('실행', (t) async {
    await _shoot(
      t,
      'executing',
      KioskExecutingView(
        title: '우유 데워줘',
        target: kMicrowaveAppliance,
        lastButtons: null,
        currentButton: '시간 90초',
        currentAttempt: 1,
        completedSteps: 1,
        totalSteps: 3,
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
        title: '우유 데워줘',
        target: kMicrowaveAppliance,
        lastButtons: null,
        currentButton: '해동',
        currentAttempt: 2,
        completedSteps: 0,
        totalSteps: 3,
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

  testWidgets('15인치 미리보기 — 대기', (t) async {
    await _shoot15(
      t,
      'kiosk15_idle',
      KioskIdleView(
        now: DateTime(2026, 9, 10, 18, 56),
        connected: true,
        actuatorReady: true,
        appliance: kMicrowaveAppliance,
        temperature: 26.5,
        humidity: 58,
        onTap: () {},
        onLongPress: () {},
      ),
    );
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
        onRejectMute: () {},
      ),
    );
  });

  testWidgets('완료', (t) async {
    await _shoot(
      t,
      'done',
      KioskDoneView(
        success: true,
        label: '우유 데워줘',
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
        label: '우유 데워줘',
        target: kMicrowaveAppliance,
        onRetry: () {},
        onManual: () {},
        onDismiss: () {},
      ),
    );
  });
}
