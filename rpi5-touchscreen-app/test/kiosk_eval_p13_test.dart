// 사용자 요청·평가 13차(2026-10-18) — 키오스크 평소 화면·결과·연습 화면. 옛 코드에도 있는 공개 구성만 써서 옛 코드에서 실패하는 것을 확인한다.
//
// 1. '오늘은 건너뛰기'는 작은 글자 단추(테두리·면 없음, 머리말과 같은 작은 글씨), 누르는 자리는 48 이상. 건너뛴 상태도 같은 작은 꼴.
// 2. '자동으로 해요'는 없앤다 — 다음 루틴 묶음에 작은 머리말 '자동 루틴'(서버 auto일 때만, 아니면 '물어볼 루틴' 등 사실대로).
//    시각은 분까지 '오후 10:00'(폰과 같은 꼴).
// 3. 날짜 옆 날씨는 빼고 예보 줄 맨 앞 칸 '지금'으로(지금 + 3칸까지). 지금 칸이 없으면 예보 4칸.
// 4. 강수확률은 그 칸 안 기온 아래(칸 높이 같게), 날씨 안내는 어구 단위 줄바꿈('나갈 때'), 0시는 '밤 12시'.
// A. 결과 화면 '한 번 더 하기' — 작은 테두리 보조 단추(높이 48 이상, 흰 글자), 안내 문장과 떨어져 있다.
// B. 연습 말 통일 — 마친 뒤 대기 그림도 '연습으로 누르는 자리예요', 실행 중 위 띠 '전자레인지 · 즉석밥 데우기', 정지 안내는 짧게.
// C. 가전 줄 — 설정이 필요한 가전은 바로 쓸 수 있는 가전 뒤로.
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/ambient.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/models/kiosk_time.dart';
import 'package:simplelay_touchscreen/theme/kiosk_colors.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/appliance_strip.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/done_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/executing_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/hold_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/kiosk_canvas.dart';

const _at = '2026-10-18T22:00:00+09:00';
const _fontPath = r'C:\Windows\Fonts\malgun.ttf';
final _hasFont = File(_fontPath).existsSync();

void _noop() {}

KioskNextRun _next({bool skipped = false, bool auto = true, bool quiet = false}) => KioskNextRun.fromJson({
      'routine_id': 'rt-1',
      'name': '저녁 공기청정기 켜기',
      'at': _at,
      'day_label': '오늘',
      'auto': auto,
      'mode': 'approve',
      'mode_label': quiet ? '조용한 시간이라 건너뜀' : (auto ? '자동 실행' : '승인 후 실행'),
      if (quiet) 'quiet_skip': true,
      'skipped': skipped,
      'skip_label': skipped ? '오늘은 건너뛰어요' : null,
      'skip_action_label': '오늘은 건너뛰기',
    })!;

const _tipText = '지금 비 소식이 있어요. 나갈 때 우산 챙기세요.';

AmbientInfo _ambient({bool withNow = true}) => AmbientInfo(
      greeting: '좋은 오후예요.',
      weatherSource: 'mock',
      tip: const AmbientTip(kind: 'rain', text: _tipText, icon: 'rain'),
      now: withNow ? const AmbientHour(label: '지금', icon: 'rain', temp: 21, pop: 70, precip: true) : null,
      hourly: const [
        AmbientHour(label: '15시', hour: 15, icon: 'rain', temp: 21, pop: 70, precip: true),
        AmbientHour(label: '18시', hour: 18, icon: 'cloudy', temp: 19),
        AmbientHour(label: '21시', hour: 21, icon: 'cloudy', temp: 18),
        AmbientHour(label: '0시', hour: 0, icon: 'clear', temp: 16),
      ],
    );

/// 화면에 보이는 글 전부. 낱말 묶음 문자(U+2060·U+00A0)는 뗀다.
List<String> _texts(WidgetTester tester) => [
      for (final w in tester.widgetList<RichText>(find.byType(RichText)))
        w.text.toPlainText().replaceAll('\u2060', '').replaceAll('\u00A0', ' '),
    ];

Future<void> _pumpView(WidgetTester tester, Widget child,
    {double scale = 1.0, double letterSpacing = 0, Size size = const Size(800, 480)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(size: size, textScaler: TextScaler.linear(scale)),
      child: Scaffold(
          backgroundColor: KioskColors.bg,
          body: DefaultTextStyle.merge(style: TextStyle(letterSpacing: letterSpacing), child: child)),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 300));
}

KioskIdleView _idle({KioskNextRun? next, AmbientInfo? ambient, ValueChanged<KioskNextRun>? onToggle}) => KioskIdleView(
      now: DateTime(2026, 10, 18, 12, 43),
      connected: true,
      ambient: ambient ?? _ambient(),
      appliances: [kMicrowaveAppliance, kInductionAppliance],
      temperature: 23,
      humidity: 58,
      nextRun: next,
      onToggleNextRunSkip: onToggle,
      onSelectAppliance: (_) {},
      onOpenConnection: (_) {},
      onDndGesture: () {},
    );

double _fontOf(WidgetTester tester, Finder text) {
  final rich = tester.widget<RichText>(find.descendant(of: text, matching: find.byType(RichText)).first);
  var size = rich.text.style?.fontSize;
  rich.text.visitChildren((s) {
    size ??= s.style?.fontSize;
    return size == null;
  });
  return size!;
}

Color? _colorOf(WidgetTester tester, Finder text) {
  final rich = tester.widget<RichText>(find.descendant(of: text, matching: find.byType(RichText)).first);
  var color = rich.text.style?.color;
  rich.text.visitChildren((s) {
    color ??= s.style?.color;
    return color == null;
  });
  return color;
}

double _lum(Color c) {
  double ch(double v) => v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
}

double _contrast(Color a, Color b) {
  final la = _lum(a), lb = _lum(b);
  return ((la > lb ? la : lb) + 0.05) / ((la > lb ? lb : la) + 0.05);
}

final _skip = find.byKey(const ValueKey('idle-next-run-skip'));
final _unskip = find.byKey(const ValueKey('idle-next-run-unskip'));

void main() {
  setUpAll(() async {
    if (!_hasFont) return;
    final bytes = File(_fontPath).readAsBytesSync();
    await (FontLoader('Malgun')..addFont(Future.value(ByteData.view(bytes.buffer)))).load();
  });

  group('1·2. 다음 루틴 — 자동 루틴 머리말, 작은 글자 단추', () {
    testWidgets("'자동으로 해요' 대신 머리말 '자동 루틴', 시각은 '오후 10:00'", (tester) async {
      await _pumpView(tester, _idle(next: _next(), onToggle: (_) {}));
      final texts = _texts(tester);
      expect(texts, isNot(contains('자동으로 해요')));
      expect(texts, contains('자동 루틴'));
      // 좁으면 시각 뒤에서 줄을 바꾼다 — 어느 쪽이든 시각은 분까지.
      expect(texts.map((t) => t.replaceAll('\n', ' · ')), contains('오후 10:00 · 저녁 공기청정기 켜기'));
      expect(tester.takeException(), isNull);
    });

    testWidgets("카드로 물어보는 루틴은 '자동 루틴'이라 쓰지 않는다", (tester) async {
      await _pumpView(tester, _idle(next: _next(auto: false), onToggle: (_) {}));
      final texts = _texts(tester);
      expect(texts, isNot(contains('자동 루틴')));
      expect(texts, contains('물어볼 루틴'));
      expect(texts, isNot(contains('물어보고 해요')));
    });

    testWidgets('조용한 시간이라 건너뛰는 회차는 다음 루틴(자동으로 하지 않는다)', (tester) async {
      await _pumpView(tester, _idle(next: _next(quiet: true), onToggle: (_) {}));
      final texts = _texts(tester);
      expect(texts, contains('다음 루틴'));
      expect(texts, isNot(contains('자동 루틴')));
      expect(texts, contains('조용한 시간이라 건너뛰어요'));
      expect(_next().whenShort, '오후 10:00');
    });

    testWidgets("'오늘은 건너뛰기' — 테두리 없는 작은 글자, 머리말과 같은 크기, 누르는 자리 48 이상", (tester) async {
      final taps = <KioskNextRun>[];
      await _pumpView(tester, _idle(next: _next(), onToggle: taps.add));
      final label = find.descendant(of: _skip, matching: find.text('오늘은 건너뛰기'));
      expect(label, findsOneWidget);
      final bordered = find.descendant(
          of: _skip,
          matching: find.byWidgetPredicate((w) =>
              w is Container && w.decoration is BoxDecoration && (w.decoration as BoxDecoration).border != null));
      expect(bordered, findsNothing, reason: '테두리 단추가 아니다');
      expect(_fontOf(tester, label), _fontOf(tester, find.text('자동 루틴')), reason: '머리말과 같은 작은 글씨');
      expect(_colorOf(tester, label), KioskColors.muted, reason: '회색 계열');
      final r = tester.getRect(_skip);
      expect(r.height, greaterThanOrEqualTo(48));
      expect(r.width, greaterThanOrEqualTo(48));
      await tester.tap(_skip);
      expect(taps, hasLength(1));
    });

    testWidgets("건너뛴 상태 '오늘은 건너뛰어요 · 되돌리기' — 같은 작은 글씨", (tester) async {
      await _pumpView(tester, _idle(next: _next(skipped: true), onToggle: (_) {}));
      final head = _fontOf(tester, find.text('자동 루틴'));
      expect(_fontOf(tester, find.text('오늘은 건너뛰어요')), head);
      final undo = find.descendant(of: _unskip, matching: find.text('되돌리기'));
      expect(_fontOf(tester, undo), head);
      expect(tester.getRect(_unskip).height, greaterThanOrEqualTo(48));
      expect(_texts(tester), contains('·'));
    });

    for (final (scale, spacing) in [(1.0, 2.1), (1.22, 0.0), (1.22, 2.1)]) {
      for (final skipped in [false, true]) {
        testWidgets('배율 $scale 글자마다 +$spacing 건너뜀 $skipped — 머리말·단추가 가전 줄 위에서 눌린다', (tester) async {
          final taps = <KioskNextRun>[];
          await _pumpView(tester, _idle(next: _next(skipped: skipped), onToggle: taps.add),
              scale: scale, letterSpacing: spacing);
          expect(tester.takeException(), isNull);
          final tile = tester.getRect(find.byKey(const ValueKey('strip-microwave')));
          expect(tester.getRect(find.byKey(const ValueKey('idle-next-run'))).bottom, lessThanOrEqualTo(tile.top));
          expect(_texts(tester), contains('자동 루틴'));
          final b = skipped ? _unskip : _skip;
          expect(tester.getRect(b).height, greaterThanOrEqualTo(48));
          await tester.tap(b);
          expect(taps, hasLength(1));
        });
      }
    }
  });

  group('3·4. 날씨 — 지금 칸은 예보 줄 맨 앞, 칸 높이 같게, 어구 줄바꿈', () {
    testWidgets("날짜 옆 날씨는 없고 예보 첫 칸이 '지금'(지금 + 3칸)", (tester) async {
      await _pumpView(tester, _idle(), size: const Size(800, 480));
      expect(find.byKey(const ValueKey('idle-outside')), findsNothing);
      final hours = find.byKey(const ValueKey('ambient-hours'));
      expect(hours, findsOneWidget);
      final first = find.byKey(const ValueKey('ambient-hour-0'));
      expect(find.descendant(of: first, matching: find.text('지금')), findsOneWidget);
      expect(find.descendant(of: first, matching: find.text('21°')), findsOneWidget);
      expect(find.byKey(const ValueKey('ambient-hour-3')), findsOneWidget);
      expect(find.byKey(const ValueKey('ambient-hour-4')), findsNothing, reason: '4칸까지');
      expect(find.text('오후 3시'), findsOneWidget);
      expect(find.text('밤 12시'), findsNothing, reason: '지금 + 3칸');
      // 날짜 줄에는 기온이 없다.
      final date = tester.getRect(find.text('10월 18일 일요일'));
      for (final t in find.text('21°').evaluate()) {
        expect(tester.getRect(find.byWidget(t.widget)).top, greaterThan(date.bottom));
      }
    });

    testWidgets('지금 칸이 없으면 예보 4칸만', (tester) async {
      await _pumpView(tester, _idle(ambient: _ambient(withNow: false)));
      expect(find.text('지금'), findsNothing);
      expect(find.byKey(const ValueKey('ambient-hour-3')), findsOneWidget);
      expect(find.text('밤 12시'), findsOneWidget, reason: "자정은 '오전 12시'가 아니라 '밤 12시'");
      expect(find.text('오전 12시'), findsNothing);
    });

    testWidgets("'비 70%'는 그 칸 안 기온 아래, 칸 높이는 모두 같다", (tester) async {
      await _pumpView(tester, _idle(ambient: _ambient(withNow: false)));
      final cell0 = find.byKey(const ValueKey('ambient-hour-0'));
      expect(find.descendant(of: cell0, matching: find.text('비 70%')), findsOneWidget);
      final temp = tester.getRect(find.descendant(of: cell0, matching: find.text('21°')));
      final pop = tester.getRect(find.descendant(of: cell0, matching: find.text('비 70%')));
      expect(pop.top, greaterThanOrEqualTo(temp.bottom - 1));
      final h0 = tester.getRect(cell0);
      expect(pop.bottom, lessThanOrEqualTo(h0.bottom + 0.5), reason: '칸 안');
      for (var i = 1; i < 4; i++) {
        expect(tester.getRect(find.byKey(ValueKey('ambient-hour-$i'))).height, closeTo(h0.height, 0.5));
      }
    });

    testWidgets("날씨 안내는 '나갈 때'를 가르지 않는다(1920x1080·실제 글꼴)", (tester) async {
      if (!_hasFont) return markTestSkipped('맑은 고딕 없음');
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      for (final scale in [1.0, 1.22]) {
        await tester.pumpWidget(MaterialApp(
          theme: ThemeData(fontFamily: 'Malgun', brightness: Brightness.dark),
          home: Builder(builder: (context) => MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
                child: KioskCanvas(
                    child: Scaffold(backgroundColor: KioskColors.bg, body: _idle(next: _next(), onToggle: (_) {}))),
              )),
        ));
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);
        final para = _tipParagraph(tester);
        final drawn = para.text.toPlainText(includeSemanticsLabels: false);
        final a = drawn.indexOf('나');
        final b = drawn.indexOf('때');
        double dy(int i) => para.getOffsetForCaret(TextPosition(offset: i), Rect.zero).dy;
        expect(dy(a), closeTo(dy(b), 1), reason: '배율 $scale: $drawn');
        final tile = tester.getRect(find.byKey(const ValueKey('strip-microwave')));
        expect(tester.getRect(find.byKey(const ValueKey('idle-next-run'))).bottom, lessThanOrEqualTo(tile.top));
      }
    });

    for (final spacing in [0.0, 1.0, 2.1, 3.0]) {
      testWidgets("날씨 안내 '나갈 때'는 한 덩어리(글자마다 +$spacing)", (tester) async {
        await _pumpView(tester, _idle(next: _next(), onToggle: (_) {}), letterSpacing: spacing);
        final para = _tipParagraph(tester);
        final drawn = para.text.toPlainText(includeSemanticsLabels: false);
        // 줄 바꾸지 않는 띄어쓰기로 묶어 그린다 — 폭이 달라도 '나갈 / 때'로 갈라지지 않는다.
        expect(drawn.replaceAll('⁠', ''), contains('나갈 때'));
        final a = drawn.indexOf('나');
        final b = drawn.indexOf('때');
        double dy(int i) => para.getOffsetForCaret(TextPosition(offset: i), Rect.zero).dy;
        expect(dy(a), closeTo(dy(b), 1), reason: drawn);
      });
    }

    test('0시는 밤 12시 — 공통 시각 함수', () {
      expect(hourLabel12('0시'), '밤 12시');
      expect(spokenHhmm('00:30'), '밤 12시 30분');
      expect(ampmOf(0), '밤');
      expect(ampmOf(1), '오전');
      expect(ampmOf(12), '오후');
    });
  });

  group('A. 한 번 더 하기 — 작은 테두리 보조 단추', () {
    KioskDoneView failed({bool mock = false}) => KioskDoneView(
          success: false,
          executionMode: mock ? 'mock' : 'real',
          label: '즉석밥 데워줘',
          target: kMicrowaveAppliance,
          onRetry: _noop,
          onManual: _noop,
          onDismiss: _noop,
        );

    for (final mock in [false, true]) {
      testWidgets('연습 $mock — 테두리, 흰 글자 4.5:1 이상, 높이 48 이상, 주 출구보다 작은 글자', (tester) async {
        await _pumpView(tester, failed(mock: mock));
        final retry = find.byKey(const ValueKey('done-retry'));
        expect(tester.widget(retry), isA<OutlinedButton>());
        expect(tester.getRect(retry).height, greaterThanOrEqualTo(48));
        final label = find.descendant(of: retry, matching: find.text('한 번 더 하기'));
        final fg = _colorOf(tester, label) ?? DefaultTextStyle.of(tester.element(label)).style.color!;
        expect(_contrast(fg, KioskColors.bg), greaterThanOrEqualTo(4.5));
        final home = find.descendant(of: find.byKey(const ValueKey('done-home')), matching: find.text('처음 화면으로'));
        expect(_fontOf(tester, label), lessThan(_fontOf(tester, home)));
        // 평가 15차(10/18): 안내 문장 묶음은 없다 — 보조 한 줄 안(확인 창이 '가전을 보고 안 됐을 때만'을 말한다).
        expect(find.byKey(const ValueKey('done-retry-hint')), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('큰 글씨에서도 잘리지 않는다', (tester) async {
      await _pumpView(tester, failed(), scale: 1.22);
      expect(find.byKey(const ValueKey('done-retry')).hitTestable(), findsOneWidget);
      expect(tester.getRect(find.byKey(const ValueKey('done-retry'))).bottom, lessThanOrEqualTo(480));
      expect(tester.takeException(), isNull);
    });
  });

  group('B. 연습 말 통일', () {
    testWidgets("마친 뒤 연습 대기 그림도 '연습으로 누르는 자리예요', 정지 안내는 짧게", (tester) async {
      await _pumpView(
          tester,
          KioskHoldView(
            appliance: kMicrowaveAppliance,
            holdState: 'hovering_stop',
            stopButton: '취소',
            executionMode: 'mock',
            elapsed: const Duration(minutes: 1),
            buttonsPressed: 3,
            operationConfirmed: true,
            operationSource: 'mock',
            onStop: _noop,
          ));
      final texts = _texts(tester);
      expect(texts, contains('연습으로 누르는 자리예요. 화면은 누르지 않아도 돼요'));
      expect(texts, isNot(contains('작은 팔이 누르는 자리예요. 화면은 누르지 않아도 돼요')));
      // 평가 14차(10/18): 연습을 마친 대기에는 정지 안내 문장을 두지 않는다.
      expect(texts.any((t) => t.contains('눌러 볼 수')), isFalse);
    });

    testWidgets("실행 중 이름 줄 '전자레인지 · 즉석밥 데우기'", (tester) async {
      await _pumpView(
          tester,
          KioskExecutingView(
            executionMode: 'mock',
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
          ));
      final texts = _texts(tester);
      expect(texts.any((t) => t.contains('전자레인지 · 즉석밥 데우기')), isTrue, reason: '$texts');
      expect(texts.any((t) => t.contains('전자레인지   즉석밥')), isFalse);
    });
  });

  group('C. 가전 줄 순서', () {
    ApplianceMap a(String id, {bool setup = false, String readiness = 'operable'}) => ApplianceMap(
          id: id,
          name: id,
          category: 'other',
          rows: 1,
          cols: 1,
          buttons: const [ApplianceButton(id: 'B1', label: '전원', x: 0, y: 0)],
          readiness: readiness,
          isCustom: setup,
        );

    test('설정이 필요한 가전은 바로 쓸 수 있는 가전 뒤(같은 무리 안에서는 등록 순서)', () {
      final list = [
        a('washer', setup: true),
        a('intercom', readiness: 'needs_setup'),
        a('microwave'),
        a('purifier'),
        a('fan'),
      ];
      expect(orderForStrip(list, running: const {}, attention: const {}).map((x) => x.id).toList(),
          ['microwave', 'purifier', 'fan', 'washer', 'intercom']);
      // 확인 필요·동작 중은 여전히 맨 앞.
      expect(orderForStrip(list, running: {'intercom'}, attention: const {}).first.id, 'intercom');
    });
  });
}

/// 날씨 안내 문장의 문단(아이콘 글자 문단은 뺀다).
RenderParagraph _tipParagraph(WidgetTester tester) {
  final f = find.descendant(
      of: find.byKey(const ValueKey('ambient-tip')),
      matching: find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText().contains('우')));
  return tester.renderObject<RenderParagraph>(f.first);
}
