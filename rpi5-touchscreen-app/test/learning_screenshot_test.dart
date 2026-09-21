@Tags(['screenshot'])
library;

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/widgets/learning_status_dialog.dart';
import 'package:simplelay_touchscreen/theme/kiosk_colors.dart';
import 'learning_status_dialog_test.dart' as fixtures;

void main() {
  setUpAll(() async {
    final sdk = Platform.environment['FLUTTER_ROOT'] ?? '../.venv/flutter';
    final icons = File(
            '$sdk/bin/cache/artifacts/material_fonts/materialicons-regular.otf')
        .readAsBytesSync();
    await (FontLoader('MaterialIcons')
          ..addFont(Future.value(ByteData.view(icons.buffer))))
        .load();
    final bytes = File(r'C:\Windows\Fonts\malgun.ttf').readAsBytesSync();
    await (FontLoader('Malgun')
          ..addFont(Future.value(ByteData.view(bytes.buffer))))
        .load();
  });
  for (final scale in [1.0, 1.6]) {
    testWidgets('learning preview $scale', (tester) async {
      tester.view.physicalSize = const Size(800, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
            brightness: Brightness.dark,
            fontFamily: 'Malgun',
            colorScheme: ColorScheme.fromSeed(
                seedColor: KioskColors.primary, brightness: Brightness.dark)),
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
