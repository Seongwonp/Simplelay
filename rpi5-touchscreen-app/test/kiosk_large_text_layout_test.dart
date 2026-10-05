// 큰 글씨(1.22배)와 보통 글씨에서 평소·동작 중 화면의 핵심 글자가 **잘리지 않고
// 스크롤 없이** 다 보이는지 확인한다(2026-10-05 골든에서 잘림 발견).
//
// 왜 시스템 폰트를 싣는가: 기본 테스트 폰트는 모든 글자가 1em 네모라 한글 폭을
// 실제보다 훨씬 넓게 잰다. 실제 패널과 같은 판정을 하려면 맑은 고딕으로 잰다.
// 폰트가 없는 기기(윈도가 아닌 곳)에서는 건너뛴다.
//
// 판정 규칙:
// - 레이아웃 예외(RenderFlex 넘침 등)가 없다.
// - 글자가 말줄임(…)으로 줄지 않았다(didExceedMaxLines == false).
// - 글자 사각형이 화면 안이고, 감싼 스크롤 영역이 있으면 그 보이는 영역 안이다
//   (스크롤해야 보이는 글자는 '잘린' 것으로 본다).
// 1920x1080은 KioskCanvas가 800x480 캔버스를 확대하므로 같은 판정을 그 위에서 한다.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/ambient.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/theme/kiosk_colors.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/hold_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/kiosk_canvas.dart';

const _fontPath = r'C:\Windows\Fonts\malgun.ttf';
final _hasFont = File(_fontPath).existsSync();

const _washer = ApplianceMap(
    id: 'washer', name: '세탁기', category: 'washing_machine', rows: 1, cols: 1, buttons: []);
const _fan = ApplianceMap(
    id: 'custom_fan', name: '거실 선풍기', category: 'other', rows: 1, cols: 1, buttons: []);
const _rice = ApplianceMap(
    id: 'rice', name: '밥솥', category: 'rice_cooker', rows: 1, cols: 1, buttons: []);

const _tipText = '인덕션 확인이 필요해요. 마지막 작업이 끝까지 되지 않았어요.';

KioskIdleView _idle({Set<String> attention = const {}, String tip = _tipText}) =>
    KioskIdleView(
      now: DateTime(2026, 9, 30, 7, 8),
      connected: true,
      ambient: AmbientInfo(
        greeting: '편안한 저녁 보내세요.',
        tip: AmbientTip(kind: 'appliance', text: tip, icon: 'attention'),
      ),
      connections: const [
        ConnectionItem(id: 'network', state: 'ok', title: '', message: ''),
        ConnectionItem(id: 'press', state: 'ok', title: '', message: ''),
        ConnectionItem(id: 'plug', state: 'warn', title: '', message: ''),
      ],
      appliances: const [
        kMicrowaveAppliance,
        _washer,
        kInductionAppliance,
        _fan,
        _rice,
      ],
      running: const {'washer'},
      attention: attention,
      temperature: 23,
      humidity: 58,
      onSelectAppliance: (_) {},
      onOpenConnection: (_) {},
      onDndGesture: () {},
    );

KioskHoldView _hold() => KioskHoldView(
      appliance: kMicrowaveAppliance,
      holdState: 'hovering_stop',
      stopButton: '취소',
      executionMode: 'mock',
      elapsed: const Duration(minutes: 1, seconds: 2),
      buttonsPressed: 3,
      operationConfirmed: true,
      operationSource: 'mock',
      stopRequested: true,
      onStop: () {},
    );

Future<void> _pump(WidgetTester tester, Widget child,
    {required double scale, required bool panel15}) async {
  tester.view.physicalSize =
      panel15 ? const Size(1920, 1080) : KioskCanvas.design;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final body = Scaffold(backgroundColor: KioskColors.bg, body: child);
  await tester.pumpWidget(MaterialApp(
    theme: ThemeData(fontFamily: 'Malgun', brightness: Brightness.dark),
    // 실제 앱(kiosk_screen)처럼 캔버스 안에서 글자 배율을 얹는다.
    home: Builder(builder: (context) {
      final scaled = MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: body,
      );
      return panel15 ? KioskCanvas(child: scaled) : scaled;
    }),
  ));
  await tester.pump(const Duration(milliseconds: 300));
}

/// 글자가 말줄임 없이, 화면 안·스크롤 없이 보이는 영역 안에 다 그려졌나.
void _expectFullyVisible(WidgetTester tester, Finder text) {
  expect(text, findsOneWidget, reason: '$text');
  final para = tester.renderObject<RenderParagraph>(text);
  expect(para.didExceedMaxLines, isFalse, reason: '$text 말줄임');
  final rect = tester.getRect(text);
  final screen = Offset.zero & tester.view.physicalSize;
  expect(screen.contains(rect.topLeft) && screen.contains(rect.bottomRight - const Offset(0.01, 0.01)),
      isTrue,
      reason: '$text 화면 밖 $rect');
  final scrollables =
      find.ancestor(of: text, matching: find.byType(Scrollable));
  for (final s in scrollables.evaluate()) {
    final view = tester.getRect(find.byWidget(s.widget));
    expect(rect.top >= view.top - 0.5 && rect.bottom <= view.bottom + 0.5,
        isTrue,
        reason: '$text 가 스크롤해야 보인다 — 글자 $rect, 보이는 영역 $view');
  }
}

void main() {
  setUpAll(() async {
    if (!_hasFont) return;
    final bytes = File(_fontPath).readAsBytesSync();
    await (FontLoader('Malgun')..addFont(Future.value(ByteData.view(bytes.buffer))))
        .load();
  });

  for (final panel15 in [false, true]) {
    final where = panel15 ? '1920x1080' : '800x480';

    testWidgets('$where 큰 글씨 평소 화면 — 안내·습도·가전 이름·상태가 잘리지 않아요',
        (tester) async {
      if (!_hasFont) return markTestSkipped('맑은 고딕 없음');
      await _pump(tester, _idle(attention: const {'induction'}),
          scale: 1.22, panel15: panel15);
      expect(tester.takeException(), isNull);
      _expectFullyVisible(tester, find.text(_tipText));
      _expectFullyVisible(tester, find.textContaining('습도 58%'));
      _expectFullyVisible(tester, find.text('7:08'));
      _expectFullyVisible(tester, find.text('방해 금지'));
      // 첫 장 맨 앞: 확인 필요(인덕션) → 동작 중(세탁기)
      _expectFullyVisible(tester, find.text('인덕션'));
      _expectFullyVisible(tester, find.text('확인 필요'));
      _expectFullyVisible(tester, find.text('세탁기'));
      _expectFullyVisible(tester, find.text('동작 중'));
      // 다음 장으로 넘기는 수단은 남는다.
      expect(find.byKey(const ValueKey('strip-next')), findsOneWidget);
    });

    testWidgets('$where 보통 글씨 평소 화면 — 가전 이름을 줄이지 않아요',
        (tester) async {
      if (!_hasFont) return markTestSkipped('맑은 고딕 없음');
      await _pump(tester, _idle(), scale: 1.0, panel15: panel15);
      expect(tester.takeException(), isNull);
      _expectFullyVisible(tester, find.text('세탁기'));
      _expectFullyVisible(tester, find.text('동작 중'));
      _expectFullyVisible(tester, find.text('전자레인지'));
      _expectFullyVisible(tester, find.text(_tipText));
      _expectFullyVisible(tester, find.textContaining('습도 58%'));
      // 거실 선풍기는 첫 장이든 다음 장이든 줄지 않고 보여야 한다.
      if (find.text('거실 선풍기').evaluate().isEmpty) {
        await tester.tap(find.byKey(const ValueKey('strip-next')));
        await tester.pump();
      }
      _expectFullyVisible(tester, find.text('거실 선풍기'));
    });

    testWidgets('$where 큰 글씨 동작 중 — 연습용 표시는 스크롤 없이 보여요',
        (tester) async {
      if (!_hasFont) return markTestSkipped('맑은 고딕 없음');
      await _pump(tester, _hold(), scale: 1.22, panel15: panel15);
      expect(tester.takeException(), isNull);
      _expectFullyVisible(tester, find.text('연습 모드 · 실제 가전 아님'));
      _expectFullyVisible(tester, find.text('연습용 전력 값이에요 · 실제 동작 확인 아님'));
      _expectFullyVisible(tester, find.text('정지'));
    });
  }
}
