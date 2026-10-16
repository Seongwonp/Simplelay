// 키오스크 디자인 규격 §1-8 큰 글자 배치(2026-10-16, docs/키오스크-디자인-규격-계획-2026-10-15.md §4 결정) — 회귀 시험.
//
// 결정: 큰 글씨(1.22배)에서는 가로 2열 배치를 세로 1열로 바꾼다(문장을 한 줄에 억지로 넣지 않는다).
// 정지 단추는 큰 글씨에서도 같은 자리·같은 크기. 함께 고친 것:
// - 비상 버튼 띠가 위에 있으면 상태 띠를 얇게(두 뜻은 그대로 보이고 비상 띠는 가리지 않는다).
// - '다시 정지 시도'가 정지 단추 안에서 줄어들어 테두리에 붙지 않게(단추 크기·아이콘 크기 그대로).
//
// 글자 폭이 판정에 들어가므로 맑은 고딕으로 잰다(없으면 건너뜀 — kiosk_large_text_layout_test와 같은 방식).
// 수정 전 코드에서 실패하는 것을 확인한 뒤 넣었다(CLAUDE.md 게이트). 골든·위젯 시험 수준이다.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/theme/kiosk_colors.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/done_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/estop_banner.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/executing_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/hold_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/kiosk_canvas.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/run_frame.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/suggestion_view.dart';

const _fontPath = r'C:\Windows\Fonts\malgun.ttf';
final _hasFont = File(_fontPath).existsSync();

const _stopArea = ValueKey('kiosk-stop-area');
const _header = ValueKey('status-header');
const _band = ValueKey('status-band');
const _estopDetail = "비상 버튼이 눌려 있어요 — 풀고 '해제하기'를 눌러야 다시 쓸 수 있어요";

void _noop() {}

KioskExecutingView _exec() => KioskExecutingView(
      executionMode: 'real',
      title: '즉석밥 데워줘',
      target: kMicrowaveAppliance,
      lastButtons: null,
      currentButton: '시작',
      currentAttempt: 1,
      completedSteps: 1,
      totalSteps: 2,
      verificationConfidence: null,
      verificationDetail: null,
      onStop: _noop,
    );

KioskHoldView _hold({String mode = 'real', String? estopTitle}) => KioskHoldView(
      appliance: kMicrowaveAppliance,
      holdState: 'hovering_stop',
      stopButton: '취소',
      executionMode: mode,
      elapsed: const Duration(minutes: 1, seconds: 2),
      buttonsPressed: 3,
      operationConfirmed: true,
      operationSource: mode == 'mock' ? 'mock' : 'real',
      onStop: _noop,
      estopTitle: estopTitle,
    );

KioskHoldView _holdUnconfirmed() => KioskHoldView(
      appliance: kMicrowaveAppliance,
      holdState: 'parked',
      stopOutcome: 'requested_unconfirmed',
      stopButton: '취소',
      elapsed: const Duration(minutes: 1),
      onStop: _noop,
      onClose: _noop,
    );

/// 골든 `suggestion_long_large`와 같은 제안 — 순서가 길고 가전 이름도 길다.
KioskSuggestionView _longSuggestion() => KioskSuggestionView(
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
      onApprove: _noop,
      onReject: _noop,
    );

/// 골든 `done_user_stop_large`와 같은 결과 — 사용자 정지, 멈췄는지 아직 모름.
KioskDoneView _userStopSent() => KioskDoneView(
      success: false,
      label: '즉석밥 데워줘',
      target: kMicrowaveAppliance,
      reason: KioskFailureReason.stopped,
      stopLevel: 'sent',
      onRetry: _noop,
      onManual: _noop,
      onDismiss: _noop,
    );

Future<void> _pump(WidgetTester tester, Widget child,
    {double scale = 1.0, bool panel15 = false}) async {
  tester.view.physicalSize = panel15 ? const Size(1920, 1080) : KioskCanvas.design;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final body = Scaffold(backgroundColor: KioskColors.bg, body: child);
  await tester.pumpWidget(MaterialApp(
    theme: ThemeData(fontFamily: 'Malgun', brightness: Brightness.dark),
    // 실제 앱(kiosk_screen)처럼 캔버스 안에서 글자 배율을 얹는다.
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

/// 화면 안이고, 감싼 스크롤 영역이 있으면 스크롤하지 않고 보이는 영역 안인가.
void _expectVisible(WidgetTester tester, Finder f, String why) {
  expect(f, findsOneWidget, reason: why);
  final rect = tester.getRect(f);
  final screen = Offset.zero & tester.view.physicalSize;
  expect(screen.contains(rect.topLeft) && screen.contains(rect.bottomRight - const Offset(0.01, 0.01)),
      isTrue,
      reason: '$why — 화면 밖 $rect');
  for (final s in find.ancestor(of: f, matching: find.byType(Scrollable)).evaluate()) {
    final view = tester.getRect(find.byWidget(s.widget));
    expect(rect.top >= view.top - 0.5 && rect.bottom <= view.bottom + 0.5, isTrue,
        reason: '$why — 스크롤해야 보인다(글 $rect, 보이는 영역 $view)');
  }
}

void main() {
  setUpAll(() async {
    if (!_hasFont) return;
    final bytes = File(_fontPath).readAsBytesSync();
    await (FontLoader('Malgun')..addFont(Future.value(ByteData.view(bytes.buffer)))).load();
  });

  final runScreens = <(String, Widget Function())>[
    ('실행', _exec),
    ('정지 대기', _hold),
    ('정지 미확인', _holdUnconfirmed),
  ];

  group('큰 글자 — 실행 계열 세 화면은 세로 1열, 정지 단추는 그대로', () {
    for (final panel15 in [false, true]) {
      final where = panel15 ? '1920x1080' : '800x480';
      for (final (name, view) in runScreens) {
        testWidgets('$where $name — 큰 글씨면 상태 영역이 화면 폭을 다 쓰고 버튼판은 정지 단추 옆 한 줄', (tester) async {
          if (!_hasFont) return markTestSkipped('맑은 고딕 없음');
          await _pump(tester, view(), scale: 1.22, panel15: panel15);
          expect(tester.takeException(), isNull);
          final stop = tester.getRect(find.byKey(_stopArea));
          final header = tester.getRect(find.byKey(_header));
          // 1열: 상태 영역이 정지 단추 왼쪽 끝을 넘어 오른쪽까지 이어진다(2열이면 정지 칸 왼쪽에서 끝난다).
          expect(header.right, greaterThan(stop.left + 1),
              reason: '상태 영역 $header 가 정지 칸 $stop 왼쪽에서 끝난다 — 아직 2열');
          expect(header.bottom, lessThan(stop.top), reason: '상태 영역이 정지 단추 위에 있어야');
          // 버튼판 그림은 정지 단추와 같은 줄(위·아래가 정지 단추 안), 정지 단추 왼쪽.
          final picture = tester.getRect(find.byType(KioskPanelPicture));
          expect(picture.top, greaterThanOrEqualTo(stop.top - 0.5), reason: '그림 $picture · 정지 $stop');
          expect(picture.bottom, lessThanOrEqualTo(stop.bottom + 0.5), reason: '그림 $picture · 정지 $stop');
          expect(picture.right, lessThan(stop.left), reason: '그림이 정지 단추 왼쪽');
        });

        testWidgets('$where $name — 보통 글씨는 지금처럼 2열', (tester) async {
          if (!_hasFont) return markTestSkipped('맑은 고딕 없음');
          await _pump(tester, view(), panel15: panel15);
          expect(tester.takeException(), isNull);
          final stop = tester.getRect(find.byKey(_stopArea));
          final header = tester.getRect(find.byKey(_header));
          expect(header.right, lessThan(stop.left));
          expect(tester.getRect(find.byType(KioskPanelPicture)).bottom, lessThan(stop.top));
        });
      }
    }

    testWidgets('정지 단추는 큰 글씨에서도 세 화면 모두 같은 자리·같은 크기(1920x1080)', (tester) async {
      if (!_hasFont) return markTestSkipped('맑은 고딕 없음');
      final rects = <String, Rect>{};
      for (final scale in [1.0, 1.22]) {
        for (final (name, view) in runScreens) {
          await _pump(tester, view(), scale: scale, panel15: true);
          expect(tester.takeException(), isNull, reason: '$name $scale');
          rects['$name $scale배'] = tester.getRect(find.byKey(_stopArea));
        }
      }
      final first = rects.values.first;
      for (final MapEntry(:key, :value) in rects.entries) {
        expect(value, first, reason: '$key 정지 영역 $value ≠ $first');
      }
    });
  });

  group('큰 글자 — 제안·결과 화면', () {
    for (final panel15 in [false, true]) {
      final where = panel15 ? '1920x1080' : '800x480';

      testWidgets('$where 긴 제안 — 질문이 스크롤 없이 다 보이고 순서도 화면에 남는다', (tester) async {
        if (!_hasFont) return markTestSkipped('맑은 고딕 없음');
        await _pump(tester, _longSuggestion(), scale: 1.22, panel15: panel15);
        expect(tester.takeException(), isNull);
        _expectVisible(tester, find.textContaining('지금 할까요?'), '질문');
        _expectVisible(tester, find.byKey(const ValueKey('suggestion-approve')), '시작');
        _expectVisible(tester, find.byKey(const ValueKey('suggestion-later')), '이번엔 안 할게요');
        // 순서는 같은 화면 안(스크롤해서라도) 그대로 있다.
        for (final step in ['해동', '냉동식품', '30초']) {
          expect(find.text(step), findsOneWidget, reason: step);
        }
      });

      testWidgets('$where 사용자 정지(멈췄는지 모름) — 할 일 줄이 스크롤 없이 보이고 처음 화면으로는 아래 고정', (tester) async {
        if (!_hasFont) return markTestSkipped('맑은 고딕 없음');
        await _pump(tester, _userStopSent(), scale: 1.22, panel15: panel15);
        expect(tester.takeException(), isNull);
        _expectVisible(tester, find.byKey(const ValueKey('done-next-step')), '할 일 줄');
        _expectVisible(tester, find.byKey(const ValueKey('done-home')), '처음 화면으로');
        expect(find.byKey(const ValueKey('done-retry')), findsOneWidget);
        expect(find.byKey(const ValueKey('done-manual')), findsOneWidget);
      });
    }
  });

  group('비상 버튼 띠가 있으면 상태 띠는 얇게 — 두 뜻은 그대로', () {
    for (final panel15 in [false, true]) {
      final where = panel15 ? '1920x1080' : '800x480';
      testWidgets('$where 정지 대기 + 비상 버튼 띠', (tester) async {
        if (!_hasFont) return markTestSkipped('맑은 고딕 없음');
        await _pump(tester, _hold(estopTitle: '비상 버튼이 눌려 있어요'), panel15: panel15);
        final normal = tester.getRect(find.byKey(_band)).height;
        await _pump(
            tester,
            KioskEstopLayout(
              banner: KioskEstopBanner(detail: _estopDetail, onRequest: _noop),
              child: _hold(estopTitle: '비상 버튼이 눌려 있어요'),
            ),
            panel15: panel15);
        expect(tester.takeException(), isNull);
        final estop = tester.getRect(find.byKey(const ValueKey('estop-banner')));
        final band = tester.getRect(find.byKey(_band));
        expect(band.height, lessThan(normal * 0.8), reason: '띠 $band (보통 $normal)');
        // 비상 띠 바로 아래, 비상 띠는 그대로 보이고 닿는다.
        expect(band.top, closeTo(estop.bottom, 0.5));
        expect(find.byKey(const ValueKey('estop-banner')).hitTestable(), findsOneWidget);
        // 상태 띠의 뜻(아이콘·글자)은 남는다.
        expect(find.descendant(of: find.byKey(_band), matching: find.text('정지 대기')), findsOneWidget);
        expect(find.descendant(
                of: find.byKey(_band), matching: find.byKey(const ValueKey('status-band-icon'))),
            findsOneWidget);
      });
    }

    testWidgets('800x480 풀기 안내 중 — 버튼판 칸이 너무 작아지지 않는다', (tester) async {
      if (!_hasFont) return markTestSkipped('맑은 고딕 없음');
      await _pump(
          tester,
          KioskEstopLayout(
            banner: KioskEstopBanner(detail: _estopDetail, confirming: true, onRequest: _noop),
            child: _hold(mode: 'mock'),
          ));
      expect(tester.takeException(), isNull);
      final cell = tester.getRect(find.byKey(const ValueKey('panel-current')));
      // 골든 hold_estop_confirm에서 칸 높이가 약 20이었다 — 글자(17) 하나 들어갈 자리도 빠듯했다.
      expect(cell.height, greaterThanOrEqualTo(28), reason: '지금 칸 $cell');
    });
  });

  group("'다시 정지 시도' — 정지 단추 안에서 줄지 않고 테두리에서 떨어진다", () {
    for (final scale in [1.0, 1.22]) {
      testWidgets('1920x1080 $scale배', (tester) async {
        if (!_hasFont) return markTestSkipped('맑은 고딕 없음');
        final stopIcon = find.descendant(of: find.byKey(_stopArea), matching: find.byIcon(Icons.stop));
        await _pump(tester, _hold(), scale: scale, panel15: true);
        final normalIcon = tester.getRect(stopIcon).size;
        await _pump(tester, _holdUnconfirmed(), scale: scale, panel15: true);
        expect(tester.takeException(), isNull);
        final area = tester.getRect(find.byKey(_stopArea));
        final retryIcon = tester.getRect(stopIcon).size;
        // 같은 아이콘 크기 — 예전에는 한 줄로 줄여 넣어 '다시 정지 시도' 쪽만 아이콘·글자가 작아졌다.
        expect(retryIcon.width, closeTo(normalIcon.width, 0.5), reason: '정지 $normalIcon · 다시 $retryIcon');
        final label = tester.getRect(find.descendant(
            of: find.byKey(_stopArea), matching: find.text('다시 정지 시도')));
        // 흰 테두리(3)에서 떨어져 있다 — 1920x1080에서 좌우 32px 이상.
        expect(label.left - area.left, greaterThanOrEqualTo(32), reason: '글 $label · 단추 $area');
        expect(area.right - label.right, greaterThanOrEqualTo(32), reason: '글 $label · 단추 $area');
        expect(label.top, greaterThanOrEqualTo(area.top));
        expect(label.bottom, lessThanOrEqualTo(area.bottom));
      });
    }
  });
}
