@Tags(['screenshot'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay/widgets/learning_status_dialog.dart';
import 'package:simplelay/theme/app_theme.dart';
import 'learning_status_dialog_test.dart' as fixtures;
import 'support/golden_fonts.dart';

void main() {
  setUpAll(loadGoldenFonts);
  for (final scale in [1.0, 1.6]) {
    testWidgets('learning preview $scale', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.dark.copyWith(
            textTheme: AppTheme.dark.textTheme.apply(fontFamily: 'Malgun')),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
            body: LearningStatusDialog(
          load: () async => fixtures.status(),
          applianceNames: const {'mw': '주방 전자레인지'},
        )),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await expectLater(find.byType(MaterialApp),
          matchesGoldenFile('goldens/learning_$scale.png'));
    });
  }
}
