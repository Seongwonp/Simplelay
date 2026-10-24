// 평가 16차(2026-10-18, 키오스크 92.5 → 목표 97) — 감점 항목 단정 시험. 옛 코드에서 실패하는 것을 확인했다.
//
// 1. 안전: 누름 장치가 멈췄는지 모르는 정지 결과 — 모든 크기(보통·큰 글씨, 800x480·실패널)·정지 단계·다시 멈추기 결과에서
//    '다시 멈추기'가 화면 안에 다 보이고 눌린다.
// 2. '자동 루틴' 본 줄은 한 줄('오후 10:00 · 이름') — 넘치면 이름만 말줄임.
// 3. 정지 미확인 대기: 누름 장치가 제자리로 돌아간 것을 서버가 알려 왔으면(hold_state=parked) '다시 멈추기' 대신 '정지'(같은 자리)와
//    손으로 누를 안내가 주 안내. 아직 정지 버튼 위면 '다시 멈추기' 유지. '전자레인지의' 번역투 없음.
// 4. 연습을 마친 대기: '연습이 끝났어요', 버튼판 칸 강조 없음, 정지 단추는 같은 자리·이름 그대로.
// 5. 성공 자동 복귀 말은 큰 글씨에서도 같은 말.
// 6. 결과 띠는 짧은 명사 '살펴볼 게 있어요'.
// 7. 비상 버튼 띠: '풀기 안내' 순환 대신 '푸는 방법 보기'.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/ambient.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/theme/kiosk_colors.dart';
import 'package:simplelay_touchscreen/theme/kiosk_tokens.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/done_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/kiosk_timings.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/estop_banner.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/hold_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/kiosk_canvas.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/kiosk_text.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/panel_picture.dart';

const _fontPath = r'C:\Windows\Fonts\malgun.ttf';
final _hasFont = File(_fontPath).existsSync();

Future<void> _pump(WidgetTester tester, Widget child,
    {bool panel = false, double textScale = 1.0}) async {
  final size = panel ? const Size(1920, 1080) : const Size(800, 480);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  Widget body = Scaffold(backgroundColor: KioskColors.bg, body: child);
  if (panel) body = KioskCanvas(child: body);
  await tester.pumpWidget(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(fontFamily: 'Malgun', brightness: Brightness.dark),
    home: MediaQuery(
      data: MediaQueryData(size: size, textScaler: TextScaler.linear(textScale)),
      child: body,
    ),
  ));
  await tester.pump(const Duration(milliseconds: 300));
}

List<String> _texts(WidgetTester tester) => [
      for (final w in tester.widgetList<RichText>(find.byType(RichText)))
        w.text.toPlainText().replaceAll('\u2060', '').replaceAll('\u00A0', ' '),
    ];

bool _has(WidgetTester tester, String needle) => _texts(tester).any((t) => t.contains(needle));

KioskDoneView _userStop({String? level, String? again}) => KioskDoneView(
      success: false,
      executionMode: 'real',
      label: '즉석밥 데워줘',
      target: kMicrowaveAppliance,
      reason: KioskFailureReason.stopped,
      stopLevel: level,
      stopAgain: again,
      onRetry: () {},
      onManual: () {},
      onStopAgain: () {},
      onDismiss: () {},
    );

KioskNextRun _next(String name) => KioskNextRun(
      name: name,
      dayLabel: '오늘',
      hhmm: '22:00',
      modeLabel: '자동 실행',
      routineId: 'rt-evening',
      at: '2026-09-30T22:00:00+09:00',
      skipActionLabel: '오늘은 건너뛰기',
    );

KioskIdleView _idle(KioskNextRun next) => KioskIdleView(
      now: DateTime(2026, 9, 30, 7, 38),
      connected: true,
      ambient: const AmbientInfo(
        greeting: '좋은 아침이에요.',
        tip: AmbientTip(kind: 'rain', text: '오후 3시부터 비 예보가 있어요. 우산 챙기세요.', icon: 'rain'),
        hourly: [
          AmbientHour(label: '9시', icon: 'partly', temp: 16),
          AmbientHour(label: '12시', icon: 'cloudy', temp: 18),
          AmbientHour(label: '15시', icon: 'rain', temp: 17, pop: 70, precip: true),
          AmbientHour(label: '18시', icon: 'rain', temp: 15, pop: 60, precip: true),
        ],
        weatherSource: 'mock',
      ),
      connections: const [
        ConnectionItem(id: 'network', state: 'ok', title: '', message: ''),
        ConnectionItem(id: 'press', state: 'ok', title: '', message: ''),
      ],
      appliances: const [kMicrowaveAppliance, kInductionAppliance],
      temperature: 23,
      humidity: 58,
      nextRun: next,
      onToggleNextRunSkip: (_) {},
      onSelectAppliance: (_) {},
      onOpenConnection: (_) {},
      onDndGesture: () {},
    );

KioskHoldView _hold({String state = 'hovering_stop', String? outcome, String mode = 'real', bool stopRequested = false}) =>
    KioskHoldView(
      appliance: kMicrowaveAppliance,
      holdState: state,
      stopOutcome: outcome,
      stopButton: '취소',
      executionMode: mode,
      elapsed: const Duration(minutes: 1),
      stopRequested: stopRequested,
      onStop: () {},
      onClose: () {},
    );

void main() {
  setUpAll(() async {
    if (!_hasFont) return;
    final bytes = File(_fontPath).readAsBytesSync();
    await (FontLoader('Malgun')..addFont(Future.value(ByteData.view(bytes.buffer)))).load();
  });

  group('1. 정지 미확인 결과 — 다시 멈추기는 늘 화면 안', () {
    for (final panel in [false, true]) {
      for (final scale in [1.0, 1.22]) {
        for (final level in <String?>['sent', 'mcu_ack', null]) {
          for (final again in <String?>[null, 'sent', 'failed']) {
            testWidgets('panel=$panel scale=$scale level=$level again=$again', (t) async {
              await _pump(t, _userStop(level: level, again: again), panel: panel, textScale: scale);
              final stop = find.byKey(const ValueKey('done-stop-again'));
              expect(stop, findsOneWidget);
              final r = t.getRect(stop);
              final screen = Offset.zero & t.view.physicalSize;
              expect(screen.contains(r.topLeft) && screen.contains(r.bottomRight - const Offset(0.1, 0.1)), isTrue,
                  reason: '다시 멈추기 $r 가 화면 $screen 밖');
              expect(find.text('다시 멈추기').hitTestable(), findsOneWidget);
              expect(t.takeException(), isNull);
            });
          }
        }
      }
    }
  });

  // 시안 B(10/24): 다음 루틴은 오른쪽 좁은 줄 칸 — 첫 줄은 늘 시각 하나('오후 10:00'), 이름은 그 아래(시각 뒤에서만 줄을 바꾼다).
  // 16차의 뜻(실패널과 골든이 서로 다른 자리에서 꺾이지 않게)은 '줄바꿈 자리가 늘 시각 뒤'로 지킨다.
  group('2. 자동 루틴 줄 — 첫 줄은 시각 하나', () {
    for (final (panel, scale) in [(true, 1.0), (false, 1.0), (false, 1.22)]) {
      for (final name in ['저녁 공기청정기 켜기', '저녁마다 거실 공기청정기를 강풍으로 켜고 인덕션 확인하기']) {
        testWidgets('panel=$panel scale=$scale $name', (t) async {
          await _pump(t, _idle(_next(name)), panel: panel, textScale: scale);
          final f = find.byKey(const ValueKey('idle-next-run-text'));
          expect(f, findsOneWidget);
          final rt = t.widget<RichText>(find.descendant(of: f, matching: find.byType(RichText)));
          final plain = rt.text.toPlainText();
          expect(plain.split('\n').first, '오후 10:00');
          expect(plain.split('\n'), hasLength(2), reason: '시각 뒤에서 한 번만 줄을 바꾼다');
          final h = t.getSize(f).height;
          final line = KioskType.body * 1.25 * scale * (panel ? 2.05 : 1.0);
          expect(h, lessThan(line * 3.2), reason: '높이 $h — 시각 한 줄 + 이름 두 줄까지');
        });
      }
    }
  });

  group('3. 정지 미확인 대기', () {
    testWidgets('누름 장치가 제자리로 돌아갔으면 다시 멈추기 대신 손으로 누를 안내', (t) async {
      await _pump(t, _hold(state: 'parked', outcome: 'requested_unconfirmed'), panel: true);
      expect(find.text('다시 멈추기'), findsNothing);
      expect(find.byKey(const ValueKey('hold-stop')), findsOneWidget);
      expect(_has(t, '전자레인지 취소 버튼을 손으로 눌러 주세요'), isTrue, reason: _texts(t).join(' | '));
      expect(_texts(t).any((s) => s.contains('누름 장치도')), isFalse);
      expect(_texts(t).any((s) => s.contains('전자레인지의')), isFalse);
    });

    testWidgets('아직 정지 버튼 위면 다시 멈추기 유지', (t) async {
      await _pump(t, _hold(outcome: 'requested_unconfirmed'), panel: true);
      expect(find.text('다시 멈추기'), findsOneWidget);
      expect(_texts(t).any((s) => s.contains('전자레인지의')), isFalse);
    });
  });

  group('4. 연습을 마친 대기', () {
    // 2차 독립 평가 D(10/18): 연습이 끝나 움직일 것이 없으면 정지는 흐리게(못 누름) + '이미 끝났어요' — 자리·이름은 그대로.
    testWidgets('연습이 끝났어요 · 칸 강조 없음 · 정지는 자리·이름 그대로 흐리게', (t) async {
      await _pump(t, _hold(mode: 'mock'), panel: true);
      expect(_has(t, '연습이 끝났어요'), isTrue, reason: _texts(t).join(' | '));
      expect(_has(t, '마쳤어요'), isFalse);
      final pic = t.widget<KioskPanelPicture>(find.byType(KioskPanelPicture));
      expect(pic.current, isNull);
      final stop = find.byKey(const ValueKey('hold-stop'));
      expect(stop, findsOneWidget);
      expect(find.text('정지'), findsOneWidget);
      expect(t.widget<ElevatedButton>(stop).onPressed, isNull);
      expect(_has(t, '이미 끝났어요'), isTrue);
    });

    testWidgets('연습에서 정지를 누른 뒤', (t) async {
      await _pump(t, _hold(mode: 'mock', stopRequested: true), textScale: 1.22);
      expect(_has(t, '연습으로 멈추는 중이에요'), isFalse);
      expect(_has(t, '실제 가전은 그대로예요'), isTrue);
    });
  });

  // 접근성 감사(10/18): 말은 같은 꼴('N초 뒤 처음 화면으로 돌아가요'), 숫자는 실제 남은 초 — 큰 글씨는 실제 전환이 두 배라 20초.
  testWidgets('5. 자동 복귀 말은 큰 글씨에서도 같은 꼴, 숫자는 실제 시간', (t) async {
    String backLine() => _texts(t).firstWhere((s) => s.contains('처음 화면으로 돌아가요'));
    // 자동 복귀는 확인한 성공만(2차 독립 평가 C, 10/18) — 실측 동작 확인 결과로 본다.
    final done = KioskDoneView(
        success: true,
        executionMode: 'real',
        operationConfirmed: true,
        operationSource: 'real',
        label: '즉석밥 데워줘',
        target: kMicrowaveAppliance,
        onDismiss: () {});
    await _pump(t, done);
    final normal = backLine();
    await t.pumpWidget(const SizedBox());
    await _pump(t, done, textScale: 1.22);
    expect(normal, '${KioskTimings.doneReturn.inSeconds}초 뒤 처음 화면으로 돌아가요');
    expect(backLine(), '${KioskTimings.doneReturnLarge.inSeconds}초 뒤 처음 화면으로 돌아가요');
  });

  testWidgets('6. 결과 띠는 짧은 명사', (t) async {
    await _pump(
        t,
        KioskDoneView(
            success: false,
            executionMode: 'real',
            label: '즉석밥 데워줘',
            target: kMicrowaveAppliance,
            onRetry: () {},
            onManual: () {},
            onDismiss: () {}),
        panel: true);
    expect(_texts(t), contains('살펴볼 게 있어요'));
    expect(_has(t, '확인해 주세요'), isFalse);
  });

  testWidgets('7. 비상 버튼 띠 — 푸는 방법 보기', (t) async {
    await _pump(
        t,
        KioskEstopLayout(
          banner: KioskEstopBanner(
              detail: "비상 버튼이 눌려 있어요 — 풀고 '해제하기'를 눌러야 다시 쓸 수 있어요", onRequest: () {}),
          child: const SizedBox.expand(),
        ),
        panel: true);
    expect(_has(t, '풀기 안내'), isFalse);
    expect(_has(t, '푸는 방법 보기'), isTrue);
  });

  test('8. 날씨 안내 — 목적어와 서술어는 한 덩어리', () {
    expect(keepPhrases('비가 와요. 나갈 때 우산 챙기세요.'), contains('우산 챙기세요.'));
  });
}
