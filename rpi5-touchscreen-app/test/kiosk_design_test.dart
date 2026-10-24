// 키오스크 시각 디자인 규격(2026-10-16, docs/키오스크-디자인-규격-계획-2026-10-15.md §4 결정) — 회귀 시험.
//
// 결정:
// - 정지 버튼은 실행·정지 대기·정지 미확인 화면에만, 세 화면에서 위치·크기·아이콘·테두리가 같다.
//   대기·제안·결과·설정에는 없다.
// - 연습 표시 = 청록 띠 + 연습 아이콘 + '연습 중'. 앰버를 연습에 쓰지 않는다.
// - 상태 띠는 제안 → 실행 → 정지 대기 → 결과에 같은 위치·같은 높이. 일반 = 중립, 연습 = 청록,
//   확인 필요 = 앰버, 실패·비상 = 빨강. 주의(앰버)는 채운 단추처럼 보이지 않게 옅은 면. 대기·설정에는 없다.
// - 비상 버튼 띠는 모든 화면에서 보인다.
//
// 수정 전 코드에서 실패하는 것을 확인한 뒤 넣었다(CLAUDE.md 게이트) — 그래서 새 상수 대신 키(ValueKey 글자)와
// 색의 색상(hue)으로 판정한다. 골든·위젯 시험 수준이다(실패널·실거리 확인이 아니다).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/idle_menu.dart';
import 'package:simplelay_touchscreen/models/ambient.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/screens/kiosk_screen.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/theme/kiosk_colors.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/appliance_select_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/done_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/executing_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/hold_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/kiosk_canvas.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/manual_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/suggestion_view.dart';

import 'kiosk_phase_test.dart' show FakeEventStream, FakeKioskApi, FakeTts;

const _stopArea = ValueKey('kiosk-stop-area');
const _band = ValueKey('status-band');
const _bandIcon = ValueKey('status-band-icon');
const _practice = ValueKey('practice-band');
const _header = ValueKey('status-header');
const _estop = ValueKey('estop-banner');

const _panel = Size(1920, 1080);

void _noop() {}

/// 15.8형 패널(1920x1080) — KioskCanvas가 가장자리를 비우고 800x480 캔버스를 확대한 실제 좌표로 잰다.
Future<void> _pump15(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = _panel;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: KioskCanvas(
      child: Scaffold(backgroundColor: KioskColors.bg, body: child),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 300));
}

// ── 화면들 ────────────────────────────────────────────────────────────────

KioskExecutingView _exec({String mode = 'real', int attempt = 1}) => KioskExecutingView(
      executionMode: mode,
      title: '즉석밥 데워줘',
      target: kMicrowaveAppliance,
      lastButtons: null,
      currentButton: '시작',
      currentAttempt: attempt,
      completedSteps: 1,
      totalSteps: 2,
      verificationConfidence: null,
      verificationDetail: null,
      onStop: _noop,
    );

KioskHoldView _hold({
  String holdState = 'hovering_stop',
  String? outcome,
  String mode = 'real',
  String? estopTitle,
}) =>
    KioskHoldView(
      appliance: kMicrowaveAppliance,
      holdState: holdState,
      stopOutcome: outcome,
      stopButton: '취소',
      executionMode: mode,
      elapsed: const Duration(minutes: 1),
      onStop: _noop,
      onClose: outcome == 'requested_unconfirmed' || holdState == 'fault' ? _noop : null,
      estopTitle: estopTitle,
    );

KioskHoldView _holdUnconfirmed({String mode = 'real'}) =>
    _hold(holdState: 'hovering_stop', outcome: 'requested_unconfirmed', mode: mode);

KioskSuggestionView _suggestion() => KioskSuggestionView(
      suggestion: const KioskSuggestion(
        id: 's1',
        purpose: '즉석밥 데워줘',
        occurrences: 3,
        timeBand: '아침',
        applianceId: 'microwave',
        steps: ['즉석밥', '시작'],
      ),
      target: kMicrowaveAppliance,
      cdRemaining: 20,
      cdTotal: 20,
      onApprove: _noop,
      onReject: _noop,
    );

KioskDoneView _done({
  bool success = true,
  String mode = 'real',
  KioskFailureReason? reason,
  String? stopLevel,
}) =>
    KioskDoneView(
      success: success,
      executionMode: mode,
      label: '즉석밥 데워줘',
      target: kMicrowaveAppliance,
      reason: reason,
      stopLevel: stopLevel,
      onRetry: success ? null : _noop,
      onManual: success ? null : _noop,
      onDismiss: _noop,
    );

KioskIdleView _idle() => KioskIdleView(
      now: DateTime(2026, 10, 16, 7, 8),
      connected: true,
      ambient: const AmbientInfo(greeting: '좋은 아침이에요.'),
      appliances: const [kMicrowaveAppliance],
      onSelectAppliance: (_) {},
      onOpenConnection: (_) {},
      onDndGesture: _noop,
    );

KioskManualView _manual() => KioskManualView(
      appliance: kMicrowaveAppliance,
      onExecute: (_) {},
      onCancel: _noop,
    );

KioskApplianceSelectView _select() => KioskApplianceSelectView(
      appliances: const [kMicrowaveAppliance, kInductionAppliance],
      lastUsedId: 'microwave',
      onSelect: (_) {},
      onCancel: _noop,
    );

// ── 색 판정(색상 hue) ─────────────────────────────────────────────────────

enum _Tone { neutral, practice, attention, danger, running }

/// 띠 아이콘 색으로 띠의 뜻을 가른다 — 새 상수가 아니라 색상으로 잰다(수정 전 코드에서도 컴파일된다).
_Tone _toneOf(Color c) {
  final hsv = HSVColor.fromColor(c);
  if (hsv.saturation < 0.2) return _Tone.neutral;
  final h = hsv.hue;
  // 10/24 시각 QA: 진행 중은 primary 청록 계열, 연습은 폰과 같은 파랑으로 바꿨다.
  if (h >= 160 && h <= 200) return _Tone.running; // 청록
  if (h >= 201 && h <= 255) return _Tone.practice; // 파랑
  if (h >= 25 && h <= 55) return _Tone.attention; // 앰버
  if (h <= 15 || h >= 345) return _Tone.danger; // 빨강
  return _Tone.neutral;
}

Color _iconColor(WidgetTester tester, Finder f) {
  final w = tester.widget(f);
  if (w is Icon) return w.color!;
  final icon = find.descendant(of: f, matching: find.byType(Icon)).first;
  return tester.widget<Icon>(icon).color!;
}

_Tone _bandTone(WidgetTester tester) {
  expect(find.byKey(_band), findsOneWidget, reason: '상태 띠가 있어야 한다');
  expect(find.byKey(_bandIcon), findsOneWidget, reason: '띠에는 아이콘이 함께 간다(색 없이도 구분)');
  return _toneOf(_iconColor(tester, find.byKey(_bandIcon)));
}

/// 띠 면은 옅게 — 채운 단추(앰버 채움 = 주요 행동)처럼 보이지 않는다.
void _expectBandNotFilled(WidgetTester tester) {
  final boxes = find.descendant(
      of: find.byKey(_band), matching: find.byType(DecoratedBox), matchRoot: true);
  for (final e in boxes.evaluate()) {
    final d = (e.widget as DecoratedBox).decoration;
    if (d is BoxDecoration && d.color != null) {
      expect(d.color!.a, lessThanOrEqualTo(0.4), reason: '띠 면이 채운 단추처럼 진하다');
    }
  }
}

const _fontPath = r'C:\Windows\Fonts\malgun.ttf';
final _hasFont = File(_fontPath).existsSync();

/// 실제 글꼴(맑은 고딕)로 그린다 — 줄바꿈 자리는 글자 폭에 달려 있어 시험 글꼴로는 잴 수 없다.
Future<void> _pumpMalgun(WidgetTester tester, Widget child,
    {required bool panel15, double scale = 1.0}) async {
  tester.view.physicalSize = panel15 ? _panel : const Size(800, 480);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: ThemeData(fontFamily: 'Malgun', brightness: Brightness.dark),
    home: Builder(builder: (context) {
      final scaled = MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
        child: Scaffold(backgroundColor: KioskColors.bg, body: child),
      );
      return panel15 ? KioskCanvas(child: scaled) : scaled;
    }),
  ));
  await tester.pump(const Duration(milliseconds: 300));
}

/// 여러 줄로 그려진 한글 문장마다, 둘째 줄부터 각 줄의 첫 글자 바로 앞이 띄어쓰기인지 본다
/// ("멈/췄는지"처럼 낱말 가운데서 끊기지 않는다). 낱말 안 단어 잇기 문자(U+2060)는 건너뛰고 본다.
List<String> _midWordBreaks(WidgetTester tester) {
  final bad = <String>[];
  final hangul = RegExp(r'[가-힣]');
  for (final e in find.byType(RichText).evaluate()) {
    final p = e.renderObject! as RenderParagraph;
    // 그린 글자 그대로(화면 읽기용 원문 말고) — 줄 위치는 그린 글자 기준이다.
    final text = p.text.toPlainText(includeSemanticsLabels: false);
    if (!hangul.hasMatch(text) || !text.contains(' ')) continue;
    final width = p.constraints.maxWidth;
    if (!width.isFinite) continue;
    // 같은 글·같은 폭으로 다시 배치해 줄 정보를 얻는다(RenderParagraph는 줄 정보를 내주지 않는다).
    final painter = TextPainter(
      text: p.text,
      textAlign: p.textAlign,
      textDirection: p.textDirection,
      textScaler: p.textScaler,
      maxLines: p.maxLines,
      textWidthBasis: p.textWidthBasis,
    )..layout(maxWidth: width);
    final lines = painter.computeLineMetrics();
    for (final line in lines.skip(1)) {
      final y = line.baseline - line.ascent + line.height / 2;
      var at = painter.getPositionForOffset(Offset(0, y)).offset;
      // 줄 머리에서 보이지 않는 잇기 문자를 건너뛴다.
      while (at > 0 && text.codeUnitAt(at - 1) == 0x2060) {
        at--;
      }
      if (at <= 0 || at > text.length) continue;
      final before = text[at - 1];
      if (before != ' ' && before != '\n') {
        final clean = text.replaceAll('\u2060', '');
        bad.add('"$clean" — 줄 머리 "${text.substring(at).replaceAll('\u2060', '').split(' ').first}"');
      }
    }
  }
  return bad;
}

void main() {
  setUpAll(() async {
    if (!_hasFont) return;
    final bytes = File(_fontPath).readAsBytesSync();
    await (FontLoader('Malgun')..addFont(Future.value(ByteData.view(bytes.buffer))))
        .load();
  });

  group('어절 단위 줄바꿈 — 낱말 가운데서 줄이 바뀌지 않는다(§1-3)', () {
    final views = <(String, Widget)>[
      ('정지 미확인', _holdUnconfirmed()),
      ('정지 대기', _hold()),
      ('실행 — 확인하는 중', KioskExecutingView(
          title: '즉석밥 데워줘',
          target: kMicrowaveAppliance,
          lastButtons: null,
          currentButton: '시작',
          currentAttempt: 1,
          completedSteps: 1,
          totalSteps: 2,
          verificationConfidence: 0.9,
          verificationDetail: 'x',
          onStop: _noop)),
      ('결과 실패', _done(success: false)),
      ('사용자 정지 — 보냄', _done(success: false, reason: KioskFailureReason.stopped, stopLevel: 'sent')),
      ('결과 성공', _done()),
      ('제안', _suggestion()),
    ];
    for (final panel15 in [true, false]) {
      for (final scale in [1.0, 1.22]) {
        for (final (name, view) in views) {
          testWidgets('$name · ${panel15 ? '1920x1080' : '800x480'} · $scale배', (tester) async {
            if (!_hasFont) return markTestSkipped('맑은 고딕 없음');
            await _pumpMalgun(tester, view, panel15: panel15, scale: scale);
            expect(tester.takeException(), isNull);
            final bad = _midWordBreaks(tester);
            expect(bad, isEmpty, reason: bad.join('\n'));
          });
        }
      }
    }
  });

  group('정지 버튼 — 실행·정지 대기·정지 미확인에만, 세 화면에서 같은 자리·크기·아이콘·테두리', () {
    testWidgets('세 화면의 정지 영역이 같은 자리·같은 크기이고 같은 아이콘·테두리다', (tester) async {
      final rects = <String, Rect>{};
      final borders = <String, double>{};
      for (final (name, view) in [
        ('실행', _exec()),
        ('정지 대기', _hold()),
        ('정지 미확인', _holdUnconfirmed()),
        ('연습 실행', _exec(mode: 'mock')),
        ('연습 정지 대기', _hold(mode: 'mock')),
      ]) {
        await _pump15(tester, view);
        expect(tester.takeException(), isNull, reason: name);
        expect(find.byKey(_stopArea), findsOneWidget, reason: name);
        rects[name] = tester.getRect(find.byKey(_stopArea));
        // 같은 아이콘 하나(■)
        expect(find.descendant(of: find.byKey(_stopArea), matching: find.byIcon(Icons.stop)),
            findsOneWidget,
            reason: name);
        expect(find.byIcon(Icons.stop_circle_outlined), findsNothing, reason: name);
        final button = tester.widget<ElevatedButton>(find.descendant(
            of: find.byKey(_stopArea), matching: find.byType(ElevatedButton)));
        expect(button.style!.backgroundColor!.resolve({}), KioskColors.stop, reason: name);
        final shape = button.style!.shape!.resolve({})! as RoundedRectangleBorder;
        borders[name] = shape.side.width;
      }
      final first = rects.values.first;
      for (final MapEntry(:key, :value) in rects.entries) {
        expect(value, first, reason: '$key 정지 영역 $value ≠ $first');
      }
      expect(borders.values.toSet().length, 1, reason: '테두리 두께가 화면마다 다르다 $borders');
      expect(borders.values.first, greaterThanOrEqualTo(3));
      // 규격 1-1(1920x1080 출발값): 폭 약 560·높이 약 200, 오른쪽·아래 여백 64 이상.
      expect(first.width, inInclusiveRange(520, 600));
      expect(first.height, inInclusiveRange(180, 220));
      expect(_panel.width - first.right, greaterThanOrEqualTo(64));
      expect(_panel.height - first.bottom, greaterThanOrEqualTo(64));
    });

    testWidgets('이름만 상황별 — 정지 미확인은 다시 멈추기(한 줄), 글자 크기는 같다', (tester) async {
      await _pump15(tester, _hold());
      final normal = tester.widget<Text>(find.descendant(
          of: find.byKey(_stopArea), matching: find.text('정지')));
      await _pump15(tester, _holdUnconfirmed());
      final retry = tester.widget<Text>(find.descendant(
          of: find.byKey(_stopArea), matching: find.text('다시 멈추기')));
      expect(retry.style!.fontSize, normal.style!.fontSize);
    });

    for (final (name, view) in [
      ('평소', _idle()),
      ('제안', _suggestion()),
      ('결과 성공', _done()),
      ('결과 실패', _done(success: false)),
      ('수동 조작', _manual()),
      ('가전 선택', _select()),
    ]) {
      testWidgets('$name 화면에는 정지 버튼이 없다', (tester) async {
        await _pump15(tester, view);
        expect(find.byKey(_stopArea), findsNothing);
        expect(find.byIcon(Icons.stop), findsNothing);
        expect(find.text('정지'), findsNothing);
      });
    }
  });

  group('연습 표시 — 청록 띠 + 연습 아이콘 + 연습 중', () {
    for (final (name, view) in [
      ('실행', _exec(mode: 'mock')),
      ('정지 대기', _hold(mode: 'mock')),
      ('결과', _done(mode: 'mock')),
      // 확인 필요(앰버)·실패(빨강)와 겹쳐도 연습 표시는 청록으로 남는다.
      ('정지 미확인', _holdUnconfirmed(mode: 'mock')),
      ('결과 실패', _done(success: false, mode: 'mock')),
    ]) {
      testWidgets('$name — 청록 아이콘·연습 아이콘·연습 중 글자, 앰버가 아니다', (tester) async {
        await _pump15(tester, view);
        expect(find.byKey(_practice), findsOneWidget);
        final icon = find.descendant(
            of: find.byKey(_practice), matching: find.byIcon(Icons.school_outlined));
        expect(icon, findsOneWidget);
        expect(_toneOf(_iconColor(tester, icon)), _Tone.practice);
        final texts = tester
            .widgetList<Text>(find.descendant(of: find.byKey(_practice), matching: find.byType(Text)))
            .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '');
        // 연습 띠 한 문장(평가 4차 10/18) — '연습이에요. 실제 가전은 그대로예요'.
        // 가전 줄이 함께 있는 결과 띠에서는 짧게 '연습'(결선 모의 평가 10/18).
        expect(texts.any((t) => t.contains('연습')), isTrue);
        for (final t in tester.widgetList<Text>(
            find.descendant(of: find.byKey(_practice), matching: find.byType(Text)))) {
          if (t.style?.color case final c?) {
            expect(_toneOf(c), isNot(_Tone.attention), reason: '연습 글자가 앰버');
          }
        }
      });
    }

    testWidgets('실제 실행에는 연습 띠가 없다', (tester) async {
      for (final view in [_exec(), _hold(), _done()]) {
        await _pump15(tester, view);
        expect(find.byKey(_practice), findsNothing);
      }
    });
  });

  group('상태 띠 — 제안 → 실행 → 정지 대기 → 결과에 같은 위치·높이, 상태별 색', () {
    final cases = <(String, Widget, _Tone)>[
      ('제안', _suggestion(), _Tone.neutral),
      ('실행', _exec(), _Tone.running),
      ('실행 — 다시 누르는 중', _exec(attempt: 2), _Tone.running),
      ('정지 대기', _hold(), _Tone.neutral),
      ('결과 성공', _done(), _Tone.attention),
      ('연습 실행', _exec(mode: 'mock'), _Tone.practice),
      ('연습 정지 대기', _hold(mode: 'mock'), _Tone.practice),
      ('연습 결과', _done(mode: 'mock'), _Tone.practice),
      ('정지 미확인', _holdUnconfirmed(), _Tone.attention),
      ('사용자 정지 — 보냄(멈췄는지 모름)', _done(success: false, reason: KioskFailureReason.stopped, stopLevel: 'sent'),
          _Tone.attention),
      ('ThinQ 확인하지 못했어요', _done(success: false, reason: KioskFailureReason.unconfirmed), _Tone.attention),
      // 눌렸는지 모름(execution)은 실패가 아니라 확인 필요(외부 평가 10/16 4차). 실행되지 않음은 실패(빨강).
      ('결과 — 눌렸는지 모름', _done(success: false), _Tone.attention),
      ('결과 실패 — 실행되지 않음', _done(success: false, reason: KioskFailureReason.notExecuted), _Tone.danger),
      ('정지 대기 — 장치 문제', _hold(holdState: 'fault'), _Tone.danger),
      ('정지 대기 — 비상 버튼', _hold(estopTitle: '비상 버튼이 눌려 있어요'), _Tone.danger),
    ];
    for (final (name, view, tone) in cases) {
      testWidgets('$name → $tone', (tester) async {
        await _pump15(tester, view);
        expect(tester.takeException(), isNull);
        expect(_bandTone(tester), tone);
        _expectBandNotFilled(tester);
      });
    }

    testWidgets('네 화면에서 띠의 위치·높이가 같다', (tester) async {
      Rect? first;
      for (final view in [_suggestion(), _exec(), _hold(), _holdUnconfirmed(), _done(), _done(success: false)]) {
        await _pump15(tester, view);
        final r = tester.getRect(find.byKey(_band));
        first ??= r;
        expect(r, first);
      }
      // 규격 1-2: 48~88px(1920x1080).
      expect(first!.height, inInclusiveRange(48, 88));
    });

    testWidgets('실행·정지 대기·정지 미확인 — 상태 아이콘+제목이 같은 자리(왼쪽 위 같은 기준선)', (tester) async {
      Offset? first;
      for (final view in [_exec(), _hold(), _holdUnconfirmed(), _exec(mode: 'mock')]) {
        await _pump15(tester, view);
        expect(find.byKey(_header), findsOneWidget);
        final at = tester.getTopLeft(find.byKey(_header));
        first ??= at;
        expect(at, first);
      }
    });

    for (final (name, view) in [
      ('평소', _idle()),
      ('수동 조작', _manual()),
      ('가전 선택', _select()),
    ]) {
      testWidgets('$name 화면에는 일반 상태 띠가 없다', (tester) async {
        await _pump15(tester, view);
        expect(find.byKey(_band), findsNothing);
      });
    }
  });

  // 2차 평가(10/18): 주 하나 · 보조 하나 · 글자 하나. 확인 필요·실패(앰버·빨강 띠)에서는 주 단추가 골드가 아닌 중립 채움.
  group('결과 화면 버튼 — 처음 화면으로는 한 모양(채움), 확인 필요·실패는 중립색', () {
    Finder inButton<T>(String text) => find.ancestor(
        of: find.text(text), matching: find.byWidgetPredicate((w) => w is T));

    // 휴리스틱 평가(10/18): 누름 보고만·눌렸는지 모름은 '가전을 보고 알려 주세요' 두 답 단추(아래 시험) — 채움 단추가 없다.
    for (final (name, view, fill) in [
      // 멈춤을 확인해도 가전은 사람이 봐야 한다 — 띠 '확인 필요'라 중립 채움(평가 3차 10/18).
      ('사용자 정지(멈춤 확인)', _done(success: false, reason: KioskFailureReason.stopped, stopLevel: 'verified'),
          KioskColors.primary), // 10/24 시각 QA — 주 행동은 모두 primary 한 색
    ]) {
      testWidgets('$name — 처음 화면으로는 채움 단추 하나', (tester) async {
        await _pump15(tester, view);
        final home = inButton<ElevatedButton>('처음 화면으로');
        expect(home, findsOneWidget);
        final b = tester.widget<ElevatedButton>(home);
        expect(b.style!.backgroundColor!.resolve({}), fill);
        expect(find.byType(ElevatedButton), findsOneWidget, reason: '화면당 채움 단추는 하나');
      });
    }

    for (final (name, view) in [('누름 보고만(확인 필요)', _done()), ('눌렸는지 모름', _done(success: false))]) {
      testWidgets('$name — 채움 단추 없이 대등한 두 답 단추, 처음 화면으로는 테두리', (tester) async {
        await _pump15(tester, view);
        expect(find.byType(ElevatedButton), findsNothing);
        expect(inButton<OutlinedButton>('처음 화면으로'), findsOneWidget);
        expect(tester.getSize(find.byKey(const ValueKey('done-check-yes'))),
            tester.getSize(find.byKey(const ValueKey('done-check-no'))));
      });
    }

    // 평가 5차(10/18): 밑줄 글자 단추는 링크로 읽혔다 — 테두리 버튼(아이콘 + 글). 휴리스틱 평가(10/18): 눌렸는지 모르면
    // '한 번 더 하기'는 '안 움직였어요' 뒤에만, 누름 장치로 골라 누르기는 확실히 못 한 결과(연습)에만.
    testWidgets('실패 — 한 번 더 하기는 답한 뒤 테두리(48 이상), 누름 장치로 골라 누르기는 연습 실패의 테두리 버튼', (tester) async {
      await _pump15(tester, _done(success: false));
      await tester.tap(find.byKey(const ValueKey('done-check-no')));
      await tester.pump();
      expect(inButton<OutlinedButton>('한 번 더 하기'), findsOneWidget);
      expect(tester.getSize(inButton<OutlinedButton>('한 번 더 하기')).height, greaterThanOrEqualTo(48));
      await _pump15(tester, _done(success: false, mode: 'mock'));
      final manual = inButton<OutlinedButton>('누름 장치로 골라 누르기');
      expect(manual, findsOneWidget);
      expect(tester.getSize(manual).height, greaterThanOrEqualTo(48));
    });
  });

  group('비상 버튼 띠는 모든 화면에서 보인다', () {
    const detail = "비상 버튼이 눌려 있어요 — 풀고 '해제하기'를 눌러야 다시 쓸 수 있어요";

    Future<void> pumpKiosk(WidgetTester tester, FakeKioskApi api) async {
      tester.view.physicalSize = _panel;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: KioskScreen(api: api, tts: FakeTts(), events: FakeEventStream()),
      ));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    Future<void> nextPoll(WidgetTester tester) async {
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    void expectBanner(WidgetTester tester, String where) {
      expect(find.byKey(_estop), findsOneWidget, reason: where);
      expect(find.byKey(_estop).hitTestable(), findsOneWidget, reason: '$where — 가려졌다');
    }

    testWidgets('평소·설정·제안·실행·결과·수동 조작·정지 대기', (tester) async {
      final api = FakeKioskApi()
        ..applianceList = const [kMicrowaveAppliance]
        ..statusResult =
            const KioskStatus(running: false, estopLatched: true, estopDetail: detail);
      await pumpKiosk(tester, api);
      await nextPoll(tester);
      expect(find.byType(KioskIdleView), findsOneWidget);
      expectBanner(tester, '평소');

      // 설정 창을 열어도
      await tapIdleMenuItem(tester, 'settings-entry');
      await nextPoll(tester);
      expectBanner(tester, '설정');
      await tester.pumpWidget(const SizedBox.shrink());

      // 제안 → 실행 → 결과
      final api2 = FakeKioskApi()
        ..applianceList = const [kMicrowaveAppliance]
        ..suggestionList = [
          const KioskSuggestion(id: 's1', purpose: '즉석밥 데워줘', occurrences: 3, applianceId: 'microwave')
        ]
        ..statusResult =
            const KioskStatus(running: false, estopLatched: true, estopDetail: detail);
      await pumpKiosk(tester, api2);
      await nextPoll(tester);
      expect(find.byType(KioskSuggestionView), findsOneWidget);
      expectBanner(tester, '제안');
      api2.suggestionList = [];
      await tester.tap(find.byKey(const ValueKey('suggestion-approve')));
      await tester.pump();
      api2.statusResult = const KioskStatus(
          running: true,
          jobId: 'job-1',
          applianceId: 'microwave',
          totalSteps: 2,
          completedSteps: 0,
          estopLatched: true,
          estopDetail: detail);
      await nextPoll(tester);
      expect(find.byType(KioskExecutingView), findsOneWidget);
      expectBanner(tester, '실행');
      api2.statusResult = const KioskStatus(
          running: false,
          lastJobId: 'job-1',
          lastStatus: 'failed',
          lastOutcome: 'failed',
          estopLatched: true,
          estopDetail: detail);
      await nextPoll(tester);
      await tester.pump(const Duration(milliseconds: 900));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(KioskDoneView), findsOneWidget);
      expectBanner(tester, '결과');
      await tester.pumpWidget(const SizedBox.shrink());

      // 수동 조작
      // 비상 버튼 동안 누름 장치 가전은 '지금 못 써요'(평가 4차 10/18) — 수동 조작 화면은 LG 가전으로 연다.
      final api3 = FakeKioskApi()
        ..applianceList = const [
          kMicrowaveAppliance,
          ApplianceMap(
              id: 'air_purifier',
              name: '공기청정기',
              category: 'air_purifier',
              rows: 0,
              cols: 0,
              buttons: [],
              controlPath: 'thinq'),
        ]
        ..statusResult =
            const KioskStatus(running: false, estopLatched: true, estopDetail: detail);
      await pumpKiosk(tester, api3);
      await nextPoll(tester);
      await tester.tap(find.byKey(const ValueKey('strip-air_purifier')));
      await nextPoll(tester);
      expect(find.byType(KioskManualView), findsOneWidget);
      expectBanner(tester, '수동 조작');
      await tester.pumpWidget(const SizedBox.shrink());

      // 정지 대기
      final api4 = FakeKioskApi()
        ..statusResult = const KioskStatus(
            running: false,
            holdState: 'hovering_stop',
            holdApplianceId: 'microwave',
            holdStopButton: '취소',
            holdExecutionMode: 'real',
            estopLatched: true,
            estopDetail: detail);
      await pumpKiosk(tester, api4);
      await nextPoll(tester);
      expect(find.byType(KioskHoldView), findsOneWidget);
      expectBanner(tester, '정지 대기');
      // 띠가 정지 버튼을 가리지 않는다.
      expect(find.descendant(of: find.byType(KioskHoldView), matching: find.text('정지')).hitTestable(),
          findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
