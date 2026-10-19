import 'package:flutter/material.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/settings_overlay.dart';
import 'kiosk_phase_test.dart' show FakeKioskApi;
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/learning_status.dart';
import 'package:simplelay_touchscreen/widgets/learning_status_dialog.dart';

LearningStatus status({bool empty = false}) => LearningStatus.fromJson({
      'window_days': 28,
      'minimum_days': 3,
      'minimum_occurrences': 3,
      'paused': true,
      'routines': empty
          ? []
          : [
              {
                'purpose': '즉석밥 데워줘',
                'appliance_id': 'mw',
                'time_band': '아침',
                'occurrences': 5,
                'distinct_days': 2,
                'established': false,
                'muted': true,
              }
            ],
    });

void main() {
  testWidgets('settings opens learning inside kiosk scaling and returns safely',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: MediaQuery(
      data: const MediaQueryData(textScaler: TextScaler.linear(1.6)),
      child: KioskSettingsOverlay(
        currentAppliance: kMicrowaveAppliance,
        api: FakeKioskApi(),
        onDismiss: () {},
      ),
    ))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('생활 습관 알아가기'));
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(LearningStatusDialog));
    expect(MediaQuery.textScalerOf(context).scale(10), 16);
    expect(find.textContaining('불러오지 못했어요'), findsOneWidget);
    await tester.tap(find.text('닫기'));
    await tester.pumpAndSettle();
    expect(find.byType(KioskSettingsOverlay), findsOneWidget);
    expect(find.text('생활 습관 알아가기'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows server evidence, hidden recommendation, and pause',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: LearningStatusDialog(
      load: () async => status(),
      applianceNames: const {'mw': '주방 전자레인지'},
    ))));
    await tester.pumpAndSettle();
    // 기간을 같이 말한다(2026-10-15) — '2일 사용 · 5회'는 어느 기간인지 몰랐다.
    expect(find.text('최근 28일 중 2일, 모두 5번'), findsOneWidget);
    expect(find.text('주방 전자레인지 · 아침'), findsOneWidget);
    expect(find.text('이 제안은 보이지 않게 해 뒀어요'), findsOneWidget);
    expect(find.textContaining('방해 금지가 켜져 있어'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('error never becomes empty history and refresh recovers',
      (tester) async {
    var calls = 0;
    await tester
        .pumpWidget(MaterialApp(home: Scaffold(body: LearningStatusDialog(
      load: () async {
        if (calls++ == 0) throw StateError('offline');
        return status(empty: true);
      },
    ))));
    await tester.pumpAndSettle();
    expect(find.textContaining('불러오지 못했어요'), findsOneWidget);
    expect(find.textContaining('아직 학습할'), findsNothing);
    await tester.tap(find.text('새로 보기'));
    await tester.pumpAndSettle();
    expect(find.textContaining('아직 습관으로 기억할'), findsOneWidget);
    expect(calls, 2);
  });

  testWidgets('large text on compact screen scrolls without overflow',
      (tester) async {
    tester.view.physicalSize = const Size(800, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
        data:
            MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(1.6)),
        child: child!,
      ),
      home: Scaffold(body: LearningStatusDialog(load: () async => status())),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('닫기').hitTestable(), findsOneWidget);
  });

  testWidgets('no connection is distinct from no history', (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
      body: LearningStatusDialog(load: null),
    )));
    expect(find.textContaining('연결하면'), findsOneWidget);
    expect(find.textContaining('아직 학습할'), findsNothing);
  });
}
