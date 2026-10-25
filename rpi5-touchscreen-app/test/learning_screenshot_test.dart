@Tags(['screenshot'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/widgets/learning_status_dialog.dart';
import 'package:simplelay_touchscreen/theme/kiosk_colors.dart';
import 'learning_status_dialog_test.dart' as fixtures;
import 'support/golden_fonts.dart';

void main() {
  setUpAll(loadGoldenFonts);
  for (final scale in [1.0, 1.6]) {
    testWidgets('learning preview $scale', (tester) async {
      tester.view.physicalSize = const Size(800, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
            brightness: KioskColors.brightness,
            fontFamily: 'Malgun',
            colorScheme: ColorScheme.fromSeed(
                seedColor: KioskColors.primary, brightness: KioskColors.brightness)),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
            body: LearningStatusDialog(
          load: () async => fixtures.learned(),
          applianceNames: const {'mw': '주방 전자레인지', 'air': '거실 공기청정기'},
          onHide: (_) async {},
          onUnhide: (_) async {},
        )),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await expectLater(find.byType(MaterialApp),
          matchesGoldenFile('goldens/learning_$scale.png'));
    });
  }
}
