// UI 평가 3차(2026-10-17)에서 큰 글씨(1.22배) 골든에 남은 잘림·어긋남을 맑은 고딕으로 잰다.
// - 실행 화면: 마지막 줄이 스크롤 영역 아래에서 잘렸다(k-large-executing).
// - 연결 창: 셋째 할 일이 스크롤해야 보였다(k-large-connection_modal).
// - 제안: '이번엔 안 할게요'가 두 줄로 접혀 옆 '지금 실행'과 높이가 달랐다(k-large-suggestion).
// - 결과: '작은 팔이 다 눌렀다고 알려 / 왔어요'처럼 한 덩어리 말이 끊겼다(k-large-done).
// 폰트가 없는 기기(윈도가 아닌 곳)에서는 건너뛴다.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/ambient.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/models/thinq.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/theme/kiosk_colors.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/connection_status.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/done_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/executing_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/kiosk_canvas.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/kiosk_text.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/suggestion_view.dart';

const kJoiner = '⁠';
const _fontPath = r'C:\Windows\Fonts\malgun.ttf';
final _hasFont = File(_fontPath).existsSync();

Future<void> _pump(WidgetTester tester, Widget child,
    {double scale = 1.22, bool panel15 = false}) async {
  tester.view.physicalSize = panel15 ? const Size(1920, 1080) : KioskCanvas.design;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final body = Scaffold(backgroundColor: KioskColors.bg, body: child);
  await tester.pumpWidget(MaterialApp(
    theme: ThemeData(fontFamily: 'Malgun', brightness: Brightness.dark),
    home: Builder(builder: (context) {
      final scaled = MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
        child: body,
      );
      return panel15 ? KioskCanvas(child: scaled) : scaled;
    }),
  ));
  await tester.pump(const Duration(milliseconds: 300));
}

/// 글자가 말줄임 없이, 화면 안·감싼 스크롤 영역의 보이는 부분 안에 다 그려졌나.
void _expectFullyVisible(WidgetTester tester, Finder text) {
  expect(text, findsOneWidget, reason: '$text');
  final para = tester.renderObject<RenderParagraph>(text);
  expect(para.didExceedMaxLines, isFalse, reason: '$text 말줄임');
  final rect = tester.getRect(text);
  final screen = Offset.zero & tester.view.physicalSize;
  expect(screen.contains(rect.topLeft) && screen.contains(rect.bottomRight - const Offset(0.01, 0.01)),
      isTrue,
      reason: '$text 화면 밖 $rect');
  for (final s in find.ancestor(of: text, matching: find.byType(Scrollable)).evaluate()) {
    final view = tester.getRect(find.byWidget(s.widget));
    expect(rect.top >= view.top - 0.5 && rect.bottom <= view.bottom + 0.5, isTrue,
        reason: '$text 가 스크롤해야 보인다 — 글자 $rect, 보이는 영역 $view');
  }
}

/// 보이는 글(단어 잇기 문자 포함)로 찾는다 — KioskText는 그리는 글자에만 잇기 문자를 넣는다.
Finder _drawn(String plain) => find.byWidgetPredicate((w) =>
    w is RichText && w.text.toPlainText().replaceAll('\u2060', '').replaceAll('\u00A0', ' ') == plain);

void main() {
  setUpAll(() async {
    if (!_hasFont) return;
    final bytes = File(_fontPath).readAsBytesSync();
    await (FontLoader('Malgun')..addFont(Future.value(ByteData.view(bytes.buffer)))).load();
  });

  for (final panel15 in [false, true]) {
    final where = panel15 ? '1920x1080' : '800x480';

    testWidgets('$where 큰 글씨 실행 화면 — 목적·이번 버튼·확인 문장이 스크롤 없이 다 보여요', (tester) async {
      if (!_hasFont) return markTestSkipped('맑은 고딕 없음');
      await _pump(
          tester,
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
          panel15: panel15);
      expect(tester.takeException(), isNull);
      _expectFullyVisible(tester, find.text("'냉동식품'"));
      _expectFullyVisible(tester, find.text('이번 버튼'));
      // 화면에 있는 글은 모두 스크롤 없이 보인다(잘린 마지막 줄이 없다).
      for (final e in find.byType(RichText).evaluate().toList()) {
        final w = e.widget as RichText;
        if (w.text.toPlainText().trim().isEmpty) continue;
        _expectFullyVisible(tester, find.byWidget(w));
      }
    });

    testWidgets('$where 큰 글씨 연결 창 — 할 일 세 줄이 스크롤 없이 다 보여요(본체 풀이 줄은 뺐다)', (tester) async {
      if (!_hasFont) return markTestSkipped('맑은 고딕 없음');
      const item = ConnectionItem(
        id: 'network',
        state: 'error',
        title: '와이파이 연결이 끊겼어요',
        message: 'SimpleLay 본체가 집 와이파이에 연결되지 않았어요. 휴대폰 앱에서 SimpleLay 본체를 찾지 못하고, '
            '날씨 안내도 볼 수 없어요.',
        fixes: [
          '공유기 전원이 켜져 있는지 확인해 주세요.',
          'SimpleLay 본체에 랜선을 쓰고 있다면 선이 끝까지 꽂혀 있는지 확인해 주세요.',
          '그래도 안 되면 SimpleLay 본체 전원을 껐다가 다시 켜 주세요.',
        ],
      );
      await _pump(
          tester,
          KioskConnectionModal(item: item, checking: false, onRecheck: () {}, onClose: () {}),
          panel15: panel15);
      expect(tester.takeException(), isNull);
      _expectFullyVisible(tester, find.text('와이파이 연결이 끊겼어요'));
      for (final fix in item.fixes) {
        _expectFullyVisible(tester, _drawn(fix));
      }
      expect(find.byKey(const ValueKey('hub-explain')), findsNothing);
      _expectFullyVisible(tester, find.text('새로 보기'));
    });

    testWidgets('$where 큰 글씨 제안 — 두 선택 단추의 높이가 같고 거절 말이 한 줄이에요', (tester) async {
      if (!_hasFont) return markTestSkipped('맑은 고딕 없음');
      await _pump(
          tester,
          KioskSuggestionView(
            suggestion: const KioskSuggestion(
              id: 's',
              purpose: '즉석밥 데워줘',
              occurrences: 3,
              timeBand: '아침',
              steps: ['즉석밥', '시작'],
            ),
            target: kMicrowaveAppliance,
            cdRemaining: 20,
            cdTotal: 20,
            onApprove: () {},
            onReject: () {},
          ),
          panel15: panel15);
      expect(tester.takeException(), isNull);
      final later = tester.getRect(find.byKey(const ValueKey('suggestion-later')));
      final approve = tester.getRect(find.byKey(const ValueKey('suggestion-approve')));
      expect((later.height - approve.height).abs(), lessThan(0.5),
          reason: '거절 $later · 실행 $approve');
      final rejectText = tester.renderObject<RenderParagraph>(_drawn('이번엔 안 할게요'));
      final plain = rejectText.text.toPlainText();
      final tops = rejectText
          .getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: plain.length))
          .map((b) => b.top.round())
          .toSet();
      expect(tops.length, 1, reason: '거절 말이 ${tops.length}줄로 접혔다');
    });
  }

  for (final scale in [1.0, 1.22]) {
    for (final panel15 in [false, true]) {
      testWidgets('위쪽 아이콘에 이름이 있어요(배율 $scale, ${panel15 ? '1920x1080' : '800x480'}) — 아이콘만으로는 뜻을 몰랐다',
          (tester) async {
        if (!_hasFont) return markTestSkipped('맑은 고딕 없음');
        await _pump(
            tester,
            KioskIdleView(
              now: DateTime(2026, 10, 17, 8, 38),
              connected: true,
              connections: const [
                ConnectionItem(id: 'network', state: 'ok', title: '', message: ''),
                ConnectionItem(id: 'press', state: 'ok', title: '', message: ''),
                ConnectionItem(id: 'plug', state: 'warn', title: '', message: ''),
              ],
              appliances: const [kMicrowaveAppliance],
              onSelectAppliance: (_) {},
              onOpenConnection: (_) {},
              onDndGesture: () {},
              onSettingsGesture: () {},
            ),
            scale: scale,
            panel15: panel15);
        expect(tester.takeException(), isNull);
        for (final label in ['설정', '쉬기', '와이파이', '작은 팔', '콘센트']) {
          _expectFullyVisible(tester, find.text(label));
        }
        // 이름은 제 아이콘 바로 아래에 있다.
        final wifi = tester.getRect(find.byKey(const ValueKey('conn-network')));
        expect(wifi.contains(tester.getCenter(find.text('와이파이'))), isTrue);
      });
    }
  }

  testWidgets('결과 제목 — 끝의 짧은 말 묶음(알려 왔어요·봐 주세요)은 줄이 갈라지지 않아요', (tester) async {
    expect(keepWords('작은 팔이 다 눌렀다고 알려 왔어요').replaceAll(kJoiner, ''), contains('알려\u00A0왔어요'));
    expect(keepWords('가전이 켜졌는지 봐 주세요').replaceAll(kJoiner, ''), contains('봐\u00A0주세요'));
    // 긴 낱말끼리는 묶지 않는다 — 줄바꿈 자리가 없어지면 안 된다.
    expect(keepWords('공유기 전원이 켜져 있는지 확인해야 합니다'), isNot(contains('\u00A0')));
    // 끝 두 낱말 합이 6자 이하면 묶는다 — 마지막 줄 외톨이 낱말 방지(UI 평가 4차).
    expect(keepWords('같은 버튼을 또 누르게 돼요.').replaceAll(kJoiner, ''), contains('누르게\u00A0돼요.'));
    expect(keepWords('정지 단추를 쓸 수 없어요').replaceAll(kJoiner, ''), contains('쓸\u00A0수\u00A0없어요'));
    expect(keepWords('그동안 새 제안을 쉬어요').replaceAll(kJoiner, ''), contains('제안을\u00A0쉬어요'));
  });

  testWidgets('800x480 큰 글씨 결과 — 제목이 스크롤 없이 보여요', (tester) async {
    if (!_hasFont) return markTestSkipped('맑은 고딕 없음');
    await _pump(
        tester,
        KioskDoneView(
          success: true,
          label: '냉동 만두 데워서 라면이랑 같이 먹을 준비',
          target: kMicrowaveAppliance,
          onDismiss: () {},
        ));
    expect(tester.takeException(), isNull);
    _expectFullyVisible(tester, _drawn('작은 팔이 다 눌렀다고 알려 왔어요'));
  });

  // UI 평가 4차 10/17: '쉬는 중' 칩이 켜지면 설정·연결 아이콘이 왼쪽으로 밀려 늘 누르던 자리가 바뀌었다.
  testWidgets('제안 쉬는 중이 켜져도 설정·연결 아이콘 자리는 그대로예요', (tester) async {
    if (!_hasFont) return markTestSkipped('맑은 고딕 없음');
    KioskIdleView idle({DateTime? dnd}) => KioskIdleView(
          now: DateTime(2026, 10, 17, 8, 38),
          connected: true,
          dndUntil: dnd,
          connections: const [
            ConnectionItem(id: 'network', state: 'ok', title: '', message: ''),
            ConnectionItem(id: 'press', state: 'ok', title: '', message: ''),
          ],
          appliances: const [kMicrowaveAppliance],
          onSelectAppliance: (_) {},
          onOpenConnection: (_) {},
          onDndGesture: () {},
          onSettingsGesture: () {},
        );
    await _pump(tester, idle(), scale: 1.0, panel15: true);
    final settingsOff = tester.getRect(find.byKey(const ValueKey('settings-entry')));
    final wifiOff = tester.getRect(find.byKey(const ValueKey('conn-network')));
    await _pump(tester, idle(dnd: DateTime(2026, 10, 17, 10, 8)), scale: 1.0, panel15: true);
    expect(find.text('쉬는 중'), findsOneWidget);
    expect(tester.getRect(find.byKey(const ValueKey('settings-entry'))), settingsOff);
    expect(tester.getRect(find.byKey(const ValueKey('conn-network'))), wifiOff);
  });

  // 실패널 10/17 09:33: 공기 줄이 넷이 되자 셋째 줄이 오른쪽에서 잘리고 넷째 줄('공기청정기 꺼짐')이 스크롤 아래로 숨었다.
  testWidgets('15인치 평소 화면 — 종합과 먼지 등급이 달라도 공기 줄이 잘리지 않아요', (tester) async {
    if (!_hasFont) return markTestSkipped('맑은 고딕 없음');
    final air = KioskAirReading.fromJson({
      'appliance_id': 'air_purifier', 'grade': 'NORMAL', 'grade_source': 'total',
      'pm25': 8, 'pm25_level': 'GOOD', 'pm10': 8, 'pm10_level': 'GOOD', 'power': 'off', 'age_s': 3.0,
    })!;
    await _pump(
        tester,
        KioskIdleView(
          now: DateTime(2026, 10, 17, 9, 33),
          connected: true,
          air: air,
          appliances: const [kMicrowaveAppliance],
          onSelectAppliance: (_) {},
          onOpenConnection: (_) {},
          onDndGesture: () {},
        ),
        scale: 1.0,
        panel15: true);
    expect(tester.takeException(), isNull);
    for (final d in air.details) {
      _expectFullyVisible(tester, find.text(d));
    }
  });

  // UI 평가 5차 10/17: 큰 글씨 결과 화면에 스크롤이 생겨 루틴 이름이 접힘 아래로 갔다.
  for (final panel15 in [false, true]) {
    testWidgets('큰 글씨 결과(${panel15 ? '1920x1080' : '800x480'}) — 제목·할 일·대상·이름이 스크롤 없이 다 보여요', (tester) async {
      if (!_hasFont) return markTestSkipped('맑은 고딕 없음');
      await _pump(
          tester,
          KioskDoneView(
            success: true,
            label: '냉동 만두 데워서 라면이랑 같이 먹을 준비',
            target: kMicrowaveAppliance,
            onDismiss: () {},
          ),
          panel15: panel15);
      expect(tester.takeException(), isNull);
      for (final e in find.byType(RichText).evaluate().toList()) {
        final w = e.widget as RichText;
        if (w.text.toPlainText().trim().isEmpty) continue;
        _expectFullyVisible(tester, find.byWidget(w));
      }
      expect(find.textContaining('냉동 만두'), findsOneWidget);
    });
  }
}
