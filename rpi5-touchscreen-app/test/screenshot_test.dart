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
import 'package:simplelay_touchscreen/widgets/kiosk/done_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/executing_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/kiosk_canvas.dart';
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

/// 새로 지급받은 15인치 패널(1920x1080) 미리보기. KioskCanvas가 800x480 설계
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
    final bytes = File(r'C:\Windows\Fonts\malgun.ttf').readAsBytesSync();
    final loader = FontLoader('Malgun')
      ..addFont(Future.value(ByteData.view(bytes.buffer)));
    await loader.load();
  });

  const suggestion = KioskSuggestion(
    id: 'suggestion-1',
    purpose: '우유 데워줘',
    occurrences: 3,
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
        temperature: 26.5,
        humidity: 58,
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
            icon: Icons.widgets_outlined,
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
        lastButtons: null,
        currentButton: '시간 90초',
        currentAttempt: 1,
        completedSteps: 1,
        verificationConfidence: 0.93,
        verificationDetail: '전류 +14mA · 소리 +9dB',
        onStop: () {},
      ),
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
      const KioskDoneView(success: true, label: '우유 데워줘'),
    );
  });
}
