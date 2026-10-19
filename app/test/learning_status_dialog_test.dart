import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay/models/learning_status.dart';
import 'package:simplelay/widgets/learning_status_dialog.dart';

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
  testWidgets('shows server evidence, hidden recommendation, and pause',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: LearningStatusDialog(
      load: () async => status(),
      applianceNames: const {'mw': '주방 전자레인지'},
    ))));
    await tester.pumpAndSettle();
    expect(find.text('2일 동안 5번 썼어요'), findsOneWidget);
    expect(find.text('주방 전자레인지, 아침'), findsOneWidget);
    expect(find.text('묻지 않기로 했어요'), findsOneWidget);
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
    await tester.tap(find.text('새로고침'));
    await tester.pumpAndSettle();
    expect(find.textContaining('아직 학습할'), findsOneWidget);
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
