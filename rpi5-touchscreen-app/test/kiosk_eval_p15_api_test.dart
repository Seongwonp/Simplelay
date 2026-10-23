// 평가 15차(2026-10-18) — 새로 생긴 구성을 쓰는 단정 시험(옛 코드에는 이 구성이 없어 컴파일부터 실패한다).
//
// 3. 안전: 누름 장치가 멈췄는지 모르는 정지 결과의 '다시 멈추기' — 정지 자리(오른쪽 아래)의 빨간 정지 단추, 누르면 정지 경로를
//    다시 부르고(kiosk_screen이 /stop), 결과(받음·닿지 않음)를 한 줄로 말한다. 연습·확인한 정지에는 없다.
// 10. 조용한 시간 어둡게는 패널 전체(가장자리 여백까지) — 캔버스 안쪽 사각형 테두리가 드러나지 않는다.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/ambient.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/screens/kiosk_screen.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/theme/kiosk_colors.dart';
import 'package:simplelay_touchscreen/theme/kiosk_tokens.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/done_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/kiosk_canvas.dart';

import 'kiosk_phase_test.dart' show FakeEventStream, FakeKioskApi, FakeTts;

const _fontPath = r'C:\Windows\Fonts\malgun.ttf';
final _hasFont = File(_fontPath).existsSync();

Future<void> _pump15(WidgetTester tester, Widget child, {bool dim = false}) async {
  tester.view.physicalSize = const Size(1920, 1080);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(fontFamily: 'Malgun', brightness: Brightness.dark),
    home: KioskCanvas(dim: dim, child: Scaffold(backgroundColor: KioskColors.bg, body: child)),
  ));
  await tester.pump(const Duration(milliseconds: 300));
}

KioskDoneView _userStop({String? level = 'sent', String mode = 'real', VoidCallback? onStopAgain, String? stopAgain}) =>
    KioskDoneView(
      success: false,
      executionMode: mode,
      label: '즉석밥 데워줘',
      target: kMicrowaveAppliance,
      reason: KioskFailureReason.stopped,
      stopLevel: level,
      onManual: () {},
      onDismiss: () {},
      onStopAgain: onStopAgain,
      stopAgain: stopAgain,
    );

void main() {
  setUpAll(() async {
    if (!_hasFont) return;
    final bytes = File(_fontPath).readAsBytesSync();
    await (FontLoader('Malgun')..addFont(Future.value(ByteData.view(bytes.buffer)))).load();
  });

  group('3. 정지 미확인 결과 — 다시 멈추기', () {
    testWidgets('정지 자리(오른쪽 아래)에 빨간 다시 멈추기, 누르면 부른다, 처음 화면으로는 같은 모양 보조 크기', (tester) async {
      var calls = 0;
      await _pump15(tester, _userStop(onStopAgain: () => calls++));
      final stop = find.byKey(const ValueKey('done-stop-again'));
      expect(stop, findsOneWidget);
      expect(find.descendant(of: stop, matching: find.text('다시 멈추기')), findsOneWidget);
      final r = tester.getRect(stop);
      // 실행·정지 대기 화면의 정지 단추와 같은 자리·크기(오른쪽 끝).
      expect(r.width, closeTo(KioskSizes.stopWidth * 2.05, 4));
      expect(r.right, closeTo(1920 - 140 - KioskSizes.stopRight * 2.05, 4));
      expect(find.text(kManualEntryLabel), findsNothing);
      final home = find.byKey(const ValueKey('done-home'));
      // 휴리스틱 평가(10/18): 정지가 주인공이면 처음 화면으로는 보조 모양(테두리) — 이름·집 아이콘은 같다.
      expect(tester.widget(home), isA<OutlinedButton>());
      expect(find.descendant(of: home, matching: find.byIcon(Icons.home_outlined)), findsOneWidget);
      expect(tester.getRect(home).height, lessThan(r.height), reason: '정지가 주인공 — 처음 화면은 보조 크기');
      await tester.tap(stop);
      await tester.pump();
      expect(calls, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('누른 뒤 결과 한 줄 — 받음·닿지 않음', (tester) async {
      await _pump15(tester, _userStop(onStopAgain: () {}, stopAgain: 'sent'));
      expect(find.byKey(const ValueKey('done-stop-again-note')), findsOneWidget);
      expect(find.text('한 번 더 멈추라고 했어요. 누름 장치를 봐 주세요'), findsOneWidget);
      await _pump15(tester, _userStop(onStopAgain: () {}, stopAgain: 'failed'));
      expect(find.text('정지 요청 결과를 확인하지 못했어요. 가전 전원을 직접 꺼 주세요'), findsOneWidget);
    });

    testWidgets('확인한 정지·연습 정지에는 다시 멈추기가 없다', (tester) async {
      await _pump15(tester, _userStop(level: 'verified', onStopAgain: () {}));
      expect(find.byKey(const ValueKey('done-stop-again')), findsNothing);
      await _pump15(tester, _userStop(mode: 'mock', onStopAgain: () {}));
      expect(find.byKey(const ValueKey('done-stop-again')), findsNothing);
    });

    testWidgets('키오스크 화면 — 정지 미확인 결과의 다시 멈추기는 정지(/stop)를 한 번 더 보낸다', (tester) async {
      tester.view.physicalSize = const Size(800, 480);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final api = FakeKioskApi()
        ..statusResult = const KioskStatus(
            running: false, lastJobId: 'job-0', lastStatus: 'succeeded', lastOutcome: 'success');
      await tester.pumpWidget(MaterialApp(
        home: KioskScreen(api: api, tts: FakeTts(), events: FakeEventStream()),
      ));
      await tester.pump();
      await tester.pump();
      api.statusResult = const KioskStatus(
          running: false,
          lastJobId: 'job-2',
          lastApplianceId: 'microwave',
          lastStatus: 'safety_stopped',
          lastOutcome: 'stopped',
          lastRoute: 'physical',
          lastExecutionMode: 'real',
          lastStopLevel: 'mcu_ack',
          lastStopAckMs: 14,
          lastStopJobId: 'job-2',
          reportsStopJobId: true);
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 900));
      expect(find.text('누름 장치가 멈췄는지 확인하지 못했어요'), findsOneWidget);
      expect(find.byKey(const ValueKey('done-manual')), findsNothing);
      final before = api.stopCalls;
      await tester.tap(find.byKey(const ValueKey('done-stop-again')));
      await tester.pump();
      await tester.pump();
      expect(api.stopCalls, before + 1);
      expect(find.byKey(const ValueKey('done-stop-again-note')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('번호 안내는 정지가 먼저', (tester) async {
      await _pump15(tester, _userStop(onStopAgain: () {}));
      expect(kStopUnknownSteps.first, contains('다시 멈추기'));
      expect(find.byKey(const ValueKey('done-recovery-step-0')), findsOneWidget);
    });
  });

  group('10. 조용한 시간 — 패널 전체 어둡게', () {
    testWidgets('어두운 바탕은 가장자리 여백까지, 처음 화면 안쪽에 막을 겹쳐 얹지 않는다', (tester) async {
      await _pump15(
          tester,
          KioskIdleView(
            now: DateTime(2026, 9, 30, 23, 12),
            connected: true,
            ambient: const AmbientInfo(greeting: '편안한 밤 보내세요.'),
            appliances: const [],
            quietUntil: '07:00',
            quietDim: true,
            onSelectAppliance: (_) {},
            onOpenConnection: (_) {},
            onDndGesture: () {},
          ),
          dim: true);
      final panel = find.byKey(const ValueKey('kiosk-panel-dim'));
      expect(panel, findsOneWidget);
      expect(tester.getRect(panel), const Rect.fromLTWH(0, 0, 1920, 1080));
      // 접근성 감사(10/18): 막을 글자 위에 덮지 않고 바탕만 어둡게 — 패널 바탕(불투명)이 평소 바탕에 검정을 섞은 색.
      expect(tester.widget<ColoredBox>(panel).color, KioskCanvas.quietBg);
      expect(tester.widget<ColoredBox>(panel).color.a, 1.0);
      // 안쪽 깨우는 자리는 그대로(누름을 받는다) — 색은 겹치지 않는다.
      final inner = tester.widget<ColoredBox>(find.descendant(
          of: find.byKey(const ValueKey('idle-quiet-dim')), matching: find.byType(ColoredBox)));
      expect(inner.color.a, 0);
    });

    testWidgets('어둡지 않으면 어두운 바탕이 없다', (tester) async {
      await _pump15(tester, const SizedBox.expand());
      expect(find.byKey(const ValueKey('kiosk-panel-dim')), findsNothing);
    });
  });
}
