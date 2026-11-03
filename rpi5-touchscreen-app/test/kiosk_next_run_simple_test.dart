// 처음 화면 '다음 루틴'을 짧게(사용자 요청 2026-11-03) — 옛 코드에도 있는 공개 구성만 써서 옛 코드에서 실패하는 것을 확인한다.
//
// 실패널에서 '물어볼 루틴'(머리말) / '오후 6:30' / '귀가 준비 — 공기청정기 강풍'(루틴 이름) / '오늘은 건너뛰기'로 보였다.
// 1. 머리말('자동 실행'·'물어볼 루틴'·'알림 루틴'·'다음 루틴')은 없다 — 시계 아이콘 옆 시각, 그 아래 할 일만.
// 2. 이름이 '○○ — 할 일'로 묶였으면 할 일만 보인다(루틴 이름은 처음 화면에서 뺀다).
// 3. 자동 실행은 꼬리표 없이, 묻는 회차만 회색 꼬리표 '물어보고', 알림만이면 '알림'. 조용한 시간 건너뜀은 그 사정만.
// 4. 낭독에는 루틴 이름 전체와 '하기 전에 물어봐요'·'자동으로 해요'가 남는다. '오늘은 건너뛰기' 단추는 그대로.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/ambient.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/theme/kiosk_colors.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_view.dart';

const _name = '귀가 준비 — 공기청정기 강풍';

KioskNextRun _next({String mode = 'approve', bool auto = false, bool quiet = false, String name = _name}) =>
    KioskNextRun.fromJson({
      'routine_id': 'rt-home',
      'name': name,
      'at': '2026-11-03T18:30:00+09:00',
      'day_label': '오늘',
      'auto': auto,
      'mode': mode,
      'mode_label': quiet
          ? '조용한 시간이라 건너뜀'
          : auto
              ? '자동 실행'
              : (mode == 'notify' ? '알림만' : '승인 후 실행'),
      if (quiet) 'quiet_skip': true,
      'skipped': false,
      'skip_label': null,
      'skip_action_label': '오늘은 건너뛰기',
    })!;

KioskIdleView _idle(KioskNextRun next) => KioskIdleView(
      now: DateTime(2026, 11, 3, 14, 3),
      connected: true,
      ambient: const AmbientInfo(greeting: '좋은 오후예요.', weatherSource: 'mock'),
      appliances: const [kMicrowaveAppliance, kInductionAppliance],
      temperature: 23,
      humidity: 38,
      nextRun: next,
      onToggleNextRunSkip: (_) {},
      onSelectAppliance: (_) {},
      onOpenConnection: (_) {},
      onDndGesture: () {},
    );

Future<void> _pump(WidgetTester tester, KioskNextRun next) async {
  tester.view.physicalSize = const Size(800, 480);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: Scaffold(backgroundColor: KioskColors.bg, body: _idle(next))));
  await tester.pump(const Duration(milliseconds: 300));
}

/// 다음 루틴 묶음 안에 보이는 글. 낱말 묶음 문자(U+2060·U+00A0)는 뗀다.
List<String> _texts(WidgetTester tester) => [
      for (final w in tester.widgetList<RichText>(
          find.descendant(of: find.byKey(const ValueKey('idle-next-run')), matching: find.byType(RichText))))
        w.text.toPlainText().replaceAll('⁠', '').replaceAll(' ', ' '),
    ];

void main() {
  testWidgets("묻는 회차 — '오후 6:30' / '공기청정기 강풍 물어보고', 머리말·루틴 이름 없음, 단추는 그대로", (tester) async {
    await _pump(tester, _next());
    final texts = _texts(tester);
    expect(texts, contains('오후 6:30'));
    expect(texts, contains('공기청정기 강풍 물어보고'), reason: '$texts');
    for (final gone in ['물어볼 루틴', '다음 루틴', '자동 실행', '알림 루틴']) {
      expect(texts, isNot(contains(gone)), reason: gone);
    }
    expect(texts.any((t) => t.contains('귀가 준비')), isFalse, reason: '루틴 이름은 처음 화면에서 뺀다');
    expect(find.descendant(of: find.byKey(const ValueKey('idle-next-run-skip')), matching: find.text('오늘은 건너뛰기')),
        findsOneWidget);
    // 시계 아이콘과 시각은 한 줄, 할 일은 그 아래.
    final when = find.byKey(const ValueKey('idle-next-run-when'));
    expect(find.descendant(of: when, matching: find.byIcon(Icons.schedule)), findsOneWidget);
    expect(tester.getRect(find.byKey(const ValueKey('idle-next-run-text'))).top,
        greaterThanOrEqualTo(tester.getRect(when).bottom - 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets("자동 실행 — 꼬리표 없이 '공기청정기 강풍'", (tester) async {
    await _pump(tester, _next(auto: true));
    final texts = _texts(tester);
    expect(texts, contains('공기청정기 강풍'), reason: '$texts');
    expect(texts.any((t) => t.contains('물어보고') || t.contains('자동')), isFalse, reason: '$texts');
  });

  testWidgets("알림 루틴 — '공기청정기 강풍 알림'", (tester) async {
    await _pump(tester, _next(mode: 'notify'));
    expect(_texts(tester), contains('공기청정기 강풍 알림'));
  });

  testWidgets('조용한 시간이라 건너뛰는 회차 — 꼬리표 없이 할 일 + 그 사정', (tester) async {
    await _pump(tester, _next(auto: true, quiet: true));
    final texts = _texts(tester);
    expect(texts, contains('공기청정기 강풍'));
    expect(texts, contains('조용한 시간이라 건너뛰어요'));
    expect(texts, isNot(contains('다음 루틴')));
  });

  testWidgets('줄표가 없는 이름은 이름 그대로가 할 일', (tester) async {
    await _pump(tester, _next(name: '저녁 공기청정기 켜기'));
    expect(_texts(tester), contains('저녁 공기청정기 켜기 물어보고'));
  });

  testWidgets('낭독 — 루틴 이름 전체와 실행 방식을 온전히', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pump(tester, _next());
    expect(find.bySemanticsLabel(RegExp('오후 6:30.*귀가 준비 — 공기청정기 강풍.*하기 전에 물어봐요')), findsOneWidget);
    await _pump(tester, _next(auto: true));
    expect(find.bySemanticsLabel(RegExp('귀가 준비 — 공기청정기 강풍.*자동으로 해요')), findsOneWidget);
    semantics.dispose();
  });
}
