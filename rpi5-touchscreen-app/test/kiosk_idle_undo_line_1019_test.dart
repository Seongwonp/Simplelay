// 결선 모의 평가(2026-10-19, 실패널 처음 화면): 건너뛴 다음 루틴의 '되돌리기'가 '오후 10:00 · 저녁 공기청정기 켜기'
// 줄 아래 혼자 떨어져 무엇을 되돌리는지 몰랐다. '되돌리기'는 그 묶음의 머리말 '물어볼 루틴 · 오늘은 안 해요' 끝(같은
// 높이, 오른쪽)에 붙는다 — 되돌리는 바로 그 말 옆. 시각·이름 줄은 잘리지 않는다. 작은 회색 굵은 글자 그대로(사용자
// 결정 10/19). 낭독은 묶음 한 덩이 + 따로 누르는 '되돌리기'.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/ambient.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/theme/kiosk_colors.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_view.dart';

KioskNextRun _next({bool skipped = true}) => KioskNextRun.fromJson({
      'routine_id': 'rt-1',
      'name': '저녁 공기청정기 켜기',
      'at': '2026-10-19T22:00:00+09:00',
      'day_label': '오늘',
      'auto': false,
      'mode': 'approve',
      'mode_label': '승인 후 실행',
      'skipped': skipped,
      'skip_label': skipped ? '오늘은 건너뛰어요' : null,
      'skip_action_label': '오늘은 건너뛰기',
    })!;

Future<void> _pump(WidgetTester tester, KioskNextRun next, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(size: size),
      child: Scaffold(
        backgroundColor: KioskColors.bg,
        body: KioskIdleView(
          now: DateTime(2026, 10, 19, 13, 14),
          connected: true,
          appliances: [kMicrowaveAppliance],
          connections: const [],
          nextRun: next,
          onToggleNextRunSkip: (_) {},
          onSelectAppliance: (_) {},
          onOpenConnection: (_) {},
          onDndGesture: () {},
        ),
      ),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 300));
}

final _undo = find.byKey(const ValueKey('idle-next-run-unskip'));
final _line = find.byKey(const ValueKey('idle-next-run-text'));
final _head = find.byKey(const ValueKey('idle-next-run-skipped-head'));

void main() {
  for (final size in const [Size(1920, 1080), Size(1280, 720)]) {
    testWidgets("건너뛴 회차의 '되돌리기'는 '오늘은 안 해요' 옆 — ${size.width.toInt()}", (tester) async {
      await _pump(tester, _next(), size);
      expect(tester.takeException(), isNull);
      expect(_undo, findsOneWidget);
      expect(_head, findsOneWidget);
      // 시안 B(10/24): 다음 루틴은 오른쪽 좁은 줄 칸 — 머리말 옆 자리가 있으면 그 옆(같은 줄, 그 말 오른쪽),
      // 모자라면 종전 규칙대로 시각·이름 줄 바로 아래. 어느 쪽이든 머리말과 줄 사이에 혼자 떨어지지 않는다.
      final onHead = (tester.getCenter(_undo).dy - tester.getCenter(_head).dy).abs() < 4;
      if (onHead) {
        expect(tester.getTopLeft(_undo).dx, greaterThan(tester.getTopRight(_head).dx));
        expect(tester.getBottomLeft(_undo).dy, lessThanOrEqualTo(tester.getTopLeft(_line).dy + 1));
      } else {
        expect(tester.getTopLeft(_undo).dy, greaterThanOrEqualTo(tester.getBottomLeft(_line).dy - 1));
      }
      final para = tester.renderObject<RenderParagraph>(find.descendant(of: _line, matching: find.byType(RichText)));
      expect(para.didExceedMaxLines, isFalse);
      // 작은 회색 굵은 글자 그대로.
      final text = tester.widget<Text>(find.descendant(of: _undo, matching: find.text('되돌리기')));
      expect(text.style?.color, KioskColors.muted);
      expect(text.style?.fontWeight, FontWeight.w700);
    });
  }

  // 머리말 옆 폭이 모자라면(작은 화면) 종전대로 끝 줄 — 넘치지 않고 시각·이름 줄 아래.
  testWidgets("좁으면 '되돌리기'는 종전대로 끝 줄 — 800", (tester) async {
    await _pump(tester, _next(), const Size(800, 480));
    expect(tester.takeException(), isNull);
    expect(_undo, findsOneWidget);
    expect(tester.getTopLeft(_undo).dy, greaterThanOrEqualTo(tester.getBottomLeft(_line).dy - 1));
  });

  testWidgets('낭독 — 줄은 한 덩이, 되돌리기는 따로 누르는 단추', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pump(tester, _next(), const Size(1920, 1080));
    expect(find.bySemanticsLabel(RegExp('오늘은 안 해요.*저녁 공기청정기 켜기')), findsOneWidget);
    expect(tester.getSemantics(_undo), isSemantics(label: '되돌리기', isButton: true));
    semantics.dispose();
  });

  testWidgets("건너뛰지 않은 회차의 '오늘은 건너뛰기'는 종전대로 줄 아래", (tester) async {
    await _pump(tester, _next(skipped: false), const Size(1920, 1080));
    final skip = find.byKey(const ValueKey('idle-next-run-skip'));
    expect(skip, findsOneWidget);
    expect(tester.getTopLeft(skip).dy, greaterThanOrEqualTo(tester.getBottomLeft(_line).dy - 1));
  });
}
