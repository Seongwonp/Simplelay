// D5 — 오버레이·보조 화면의 접근성 감사: 터치 크기, 스크린리더, 큰 글씨.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/appliance_select_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/danger_alert_overlay.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/dnd_overlay.dart';

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  double textScale = 1.0,
}) async {
  tester.view.physicalSize = const Size(800, 480);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
      child: Scaffold(body: child),
    ),
  ));
}

void main() {
  group('방해 금지', () {
    testWidgets('선택지와 취소가 모두 48px 이상의 버튼이다', (tester) async {
      final minutes = <int>[];
      var dismissed = 0;
      await _pump(
        tester,
        DndOverlay(
          dndUntil: null,
          onSet: minutes.add,
          onClear: () {},
          onDismiss: () => dismissed++,
        ),
      );

      for (final label in ['30분', '1시간', '2시간', '취소']) {
        final button = find.ancestor(
          of: find.text(label),
          matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
        );
        expect(button, findsOneWidget, reason: label);
        expect(tester.getSize(button).height, greaterThanOrEqualTo(48),
            reason: label);
      }

      await tester.tap(find.text('1시간'));
      await tester.tap(find.text('취소'));
      expect(minutes, [60]);
      expect(dismissed, 1);
    });

    testWidgets('큰 글씨에서도 넘치지 않는다', (tester) async {
      await _pump(
        tester,
        DndOverlay(
          dndUntil: null,
          onSet: (_) {},
          onClear: () {},
          onDismiss: () {},
        ),
        textScale: 1.22,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('위험 신호음 경보', () {
    testWidgets('떠오르면 스크린리더가 바로 읽는 영역이다', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, DangerAlertOverlay(onAcknowledge: () {}));

      // 경보 화면 전체를 감싸는 의미 노드가 liveRegion이어야 한다.
      final region = tester.getSemantics(find
          .descendant(
            of: find.byType(DangerAlertOverlay),
            matching: find.byType(ColoredBox),
          )
          .first);
      expect(region, isSemantics(isLiveRegion: true));
      handle.dispose();
    });

    testWidgets('큰 글씨에서도 넘치지 않는다', (tester) async {
      await _pump(
        tester,
        DangerAlertOverlay(onAcknowledge: () {}),
        textScale: 1.22,
      );
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('가전 선택 — 가전이 많고 큰 글씨여도 넘치지 않는다', (tester) async {
    await _pump(
      tester,
      KioskApplianceSelectView(
        appliances: [
          kMicrowaveAppliance,
          kInductionAppliance,
          for (var i = 0; i < 4; i++)
            ApplianceMap(
              id: 'custom_$i',
              name: '거실 창가 쪽 가전 $i',
              category: 'other',
              rows: 1,
              cols: 1,
              buttons: const [],
            ),
        ],
        lastUsedId: 'microwave',
        onSelect: (_) {},
        onCancel: () {},
      ),
      textScale: 1.22,
    );
    expect(tester.takeException(), isNull);
  });
}
