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

const summaryText = '평일 오후 10시쯤 즉석밥을 자주 데우셨어요. 최근 28일 중 5일이에요.';

LearningStatus learned(
        {String source = 'llm', bool onlyFirst = false, bool firstHidden = false}) =>
    LearningStatus.fromJson({
      'window_days': 28,
      'minimum_days': 3,
      'minimum_occurrences': 3,
      'paused': false,
      'summary': {
        'text': summaryText,
        'generated_at': '2026-10-26T03:00:00+09:00',
        'source': source,
      },
      'routines': [
        {
          'purpose': '즉석밥 데워줘',
          'appliance_id': 'mw',
          'time_band': '야간',
          'occurrences': 6,
          'distinct_days': 5,
          'established': true,
          'muted': firstHidden,
          'when_text': '평일 오후 10시쯤',
          'state': firstHidden ? 'hidden' : 'asking',
        },
        if (!onlyFirst) ...[
          {
            'purpose': '공기청정기 켜기',
            'appliance_id': 'air',
            'time_band': '저녁',
            'occurrences': 4,
            'distinct_days': 4,
            'established': true,
            'muted': false,
            'when_text': '저녁 이맘때',
            'state': 'auto',
            'routine_name': '저녁 공기청정기 켜기',
          },
          {
            'purpose': '해동하기',
            'appliance_id': 'mw',
            'time_band': '아침',
            'occurrences': 3,
            'distinct_days': 3,
            'established': true,
            'muted': false,
            'when_text': '오전 8시쯤',
            'state': 'paused',
            // 현지 시각으로 적어 시험 기계의 시간대와 무관하게.
            'paused_until': '2026-10-27T22:00:00',
          },
          {
            'purpose': '라면 끓이기',
            'appliance_id': 'mw',
            'time_band': '점심',
            'occurrences': 2,
            'distinct_days': 2,
            'established': false,
            'muted': false,
            'state': 'learning',
          },
        ],
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
    await tester.tap(find.text('생활 습관 보기'));
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(LearningStatusDialog));
    expect(MediaQuery.textScalerOf(context).scale(10), 16);
    expect(find.textContaining('불러오지 못했어요'), findsOneWidget);
    await tester.tap(find.text('닫기'));
    await tester.pumpAndSettle();
    expect(find.byType(KioskSettingsOverlay), findsOneWidget);
    expect(find.text('생활 습관 보기'), findsOneWidget);
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
    // 옛 서버(state 없음) — 숨김 여부로 상태를 정한다.
    expect(find.text('숨김'), findsOneWidget);
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

  testWidgets('learned view shows summary, when, evidence and every state',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: LearningStatusDialog(
      load: () async => learned(),
      applianceNames: const {'mw': '주방 전자레인지', 'air': '거실 공기청정기'},
      onHide: (_) async {},
      onUnhide: (_) async {},
    ))));
    await tester.pumpAndSettle();
    expect(find.text('알게 된 것'), findsOneWidget);
    expect(find.text(summaryText), findsOneWidget);
    expect(find.text('본체 안 AI가 정리했어요'), findsOneWidget);
    expect(find.text('주방 전자레인지 · 평일 오후 10시쯤'), findsOneWidget);
    expect(find.text('거실 공기청정기 · 저녁 이맘때'), findsOneWidget);
    expect(find.text('최근 28일 중 5일, 모두 6번'), findsOneWidget);
    expect(find.text('물어보는 중'), findsOneWidget);
    expect(find.text('자동 실행 중'), findsOneWidget);
    expect(find.text('루틴: 저녁 공기청정기 켜기'), findsOneWidget);
    expect(find.text('잠시 묻지 않음 (10월 27일 오후 10시까지)'), findsOneWidget);
    expect(find.text('알아 가는 중'), findsOneWidget);
    expect(find.text('숨기기'), findsNWidgets(4));
    expect(tester.takeException(), isNull);
  });

  testWidgets('template summary carries no AI label', (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: LearningStatusDialog(
                load: () async => learned(source: 'template')))));
    await tester.pumpAndSettle();
    expect(find.text(summaryText), findsOneWidget);
    expect(find.text('본체 안 AI가 정리했어요'), findsNothing);
    expect(find.text('숨기기'), findsNothing); // 고칠 길이 없으면 단추도 없다
  });

  testWidgets('hide and unhide call the server and reload', (tester) async {
    final calls = <String>[];
    var hidden = false;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: LearningStatusDialog(
      load: () async => learned(onlyFirst: true, firstHidden: hidden),
      onHide: (p) async {
        calls.add('hide $p');
        hidden = true;
      },
      onUnhide: (p) async {
        calls.add('unhide $p');
        hidden = false;
      },
    ))));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('숨기기'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('숨기기'));
    await tester.pumpAndSettle();
    expect(calls, ['hide 즉석밥 데워줘']);
    expect(find.text('숨김'), findsOneWidget);
    await tester.ensureVisible(find.text('다시 보이기'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('다시 보이기'));
    await tester.pumpAndSettle();
    expect(calls, ['hide 즉석밥 데워줘', 'unhide 즉석밥 데워줘']);
    expect(find.text('물어보는 중'), findsOneWidget);
  });

  testWidgets('failed hide says so and keeps the habit', (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: LearningStatusDialog(
      load: () async => learned(onlyFirst: true),
      onHide: (_) async => throw StateError('offline'),
    ))));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('숨기기'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('숨기기'));
    await tester.pumpAndSettle();
    expect(find.text('바꾸지 못했어요. 잠시 뒤 다시 눌러 주세요.'), findsOneWidget);
    expect(find.text('물어보는 중'), findsOneWidget);
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
