// 10/19 사용성·정직 손질 — 단정 시험.
//
// 3. LG 가전 보내는 중 정지 안내 — '정지를 누르면 더 보내지 않아요. 이미 보낸 것은 되돌리지 못할 수 있어요'(이미 보낸 명령을
//    되돌린다고 약속하지 않는다). 실행 화면 칸 안에서 잘리지 않는다.
// 4. 실행 중 '눌렀어요, 확인 중이에요'는 버튼을 **다 누른 뒤**에만 — 두 번째 버튼을 누르러 가는 동안(앞 버튼 확인 결과만
//    남아 있을 때)은 '누르고 있어요'.
// 5. 건너뛴 다음 루틴 — 머리말 '자동 루틴 · 오늘은 안 해요' 하나로 말하고, 끝 줄은 '되돌리기'만(같은 말 두 번 금지).
// 6. 누름 장치 끊김 칩의 가전 수는 누름 장치가 누르는 가전만 — LG 가전·연습 가전·누름 장치가 위에 없는 가전은 세지 않는다.
//    실내 온습도는 실측일 때만(모의·모름은 줄 없음).
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/ambient.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/models/thinq_run.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/theme/kiosk_colors.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/executing_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_view.dart';

final _purifier = applianceFromServerJson({
  'id': 'air_purifier',
  'name': '공기청정기',
  'category': 'air_purifier',
  'rows': 0,
  'cols': 0,
  'buttons': <dynamic>[],
  'control_path': 'thinq',
  'can_execute': true,
  'readiness': 'operable',
});

Future<void> _pump(WidgetTester tester, Widget child, {Size size = const Size(800, 480)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(size: size),
      child: Scaffold(backgroundColor: KioskColors.bg, body: child),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 300));
}

List<String> _texts(WidgetTester tester) => [
      for (final w in tester.widgetList<RichText>(find.byType(RichText)))
        w.text.toPlainText().replaceAll('⁠', '').replaceAll(' ', ' '),
    ];

KioskIdleView _idle({
  KioskNextRun? next,
  List<ApplianceMap>? appliances,
  List<ConnectionItem> connections = const [
    ConnectionItem(id: 'network', state: 'ok', title: '', message: ''),
    ConnectionItem(id: 'press', state: 'ok', title: '', message: ''),
  ],
  double? temperature,
  double? humidity,
}) =>
    KioskIdleView(
      now: DateTime(2026, 10, 19, 19, 30),
      connected: true,
      appliances: appliances ?? [_purifier, kMicrowaveAppliance],
      connections: connections,
      temperature: temperature,
      humidity: humidity,
      nextRun: next,
      onToggleNextRunSkip: (_) {},
      onSelectAppliance: (_) {},
      onOpenConnection: (_) {},
      onDndGesture: () {},
    );

void main() {
  group('3. LG 가전 보내는 중 — 정지 안내', () {
    test('더 보내지 않는다 + 이미 보낸 것은 되돌리지 못할 수 있다', () {
      expect(kThinqStopNote, '정지를 누르면 더 보내지 않아요. 이미 보낸 것은 되돌리지 못할 수 있어요');
    });

    testWidgets('실행 화면에서 잘리지 않는다', (tester) async {
      await _pump(
          tester,
          KioskExecutingView(
            executionMode: 'real',
            title: '공기청정기를 켤까요?',
            target: _purifier,
            thinqOnly: true,
            lastButtons: null,
            currentButton: null,
            currentAttempt: null,
            completedSteps: null,
            totalSteps: 1,
            verificationConfidence: null,
            verificationDetail: null,
            onStop: () {},
          ));
      expect(_texts(tester), contains(kThinqStopNote));
      final note = tester.renderObject<RenderParagraph>(find.descendant(
          of: find.byKey(const ValueKey('thinq-stop-note')), matching: find.byType(RichText)));
      expect(note.didExceedMaxLines, isFalse);
      expect(tester.takeException(), isNull);
    });
  });

  group("4. '눌렀어요, 확인 중이에요'는 다 누른 뒤에만", () {
    Widget exec({required String current, required int completed, double? confidence}) => KioskExecutingView(
          executionMode: 'real',
          title: '즉석밥 데워줘',
          target: kMicrowaveAppliance,
          lastButtons: null,
          currentButton: current,
          currentAttempt: 1,
          completedSteps: completed,
          doneButtons: completed > 0 ? const ['즉석밥'] : const [],
          totalSteps: 2,
          verificationConfidence: confidence,
          verificationDetail: null,
          onStop: () {},
        );

    testWidgets('첫 버튼 확인 결과만 있고 두 번째를 아직 누르는 중이면 누르는 머리말', (tester) async {
      await _pump(tester, exec(current: '즉석밥', completed: 0, confidence: 0.9));
      expect(find.text(kExecPressing), findsOneWidget);
      expect(find.text(kExecPressedChecking), findsNothing);
    });

    testWidgets('마지막 버튼을 누르고 확인 결과가 오면 확인 중', (tester) async {
      await _pump(tester, exec(current: '시작', completed: 1, confidence: 0.9));
      expect(find.text(kExecPressedChecking), findsOneWidget);
      expect(find.text(kExecPressing), findsNothing);
    });
  });

  group('5. 건너뛴 다음 루틴 — 한 번만 말한다', () {
    KioskNextRun next({bool skipped = true}) => KioskNextRun.fromJson({
          'routine_id': 'rt-1',
          'name': '저녁 공기청정기 켜기',
          'at': '2026-10-19T22:00:00+09:00',
          'day_label': '오늘',
          'auto': true,
          'mode': 'approve',
          'mode_label': '자동 실행',
          'skipped': skipped,
          'skip_label': skipped ? '오늘은 건너뛰어요' : null,
          'skip_action_label': '오늘은 건너뛰기',
        })!;

    testWidgets("머리말 '자동 루틴 · 오늘은 안 해요', 끝 줄은 '되돌리기'만", (tester) async {
      await _pump(tester, _idle(next: next()));
      final texts = _texts(tester);
      expect(texts, contains('자동 루틴'));
      expect(texts, contains('오늘은 안 해요'));
      expect(texts.where((t) => t.contains('건너뛰어요')), isEmpty);
      expect(find.descendant(
              of: find.byKey(const ValueKey('idle-next-run-unskip')), matching: find.text('되돌리기')),
          findsOneWidget);
    });

    testWidgets("건너뛰지 않았으면 '오늘은 건너뛰기' 그대로", (tester) async {
      await _pump(tester, _idle(next: next(skipped: false)));
      expect(find.descendant(
              of: find.byKey(const ValueKey('idle-next-run-skip')), matching: find.text('오늘은 건너뛰기')),
          findsOneWidget);
      expect(_texts(tester).where((t) => t.contains('안 해요')), isEmpty);
    });

    test('건너뛴 회차의 끝 줄 말은 없다(머리말이 말한다), 조용한 시간은 그대로', () {
      expect(next().statusWord, '');
      expect(next().skippedHead, '오늘은 안 해요');
      final quiet = KioskNextRun.fromJson({
        'routine_id': 'rt-1',
        'name': '저녁 공기청정기 켜기',
        'at': '2026-10-19T22:00:00+09:00',
        'day_label': '오늘',
        'mode_label': '조용한 시간이라 건너뜀',
        'quiet_skip': true,
      })!;
      expect(quiet.statusWord, '조용한 시간이라 건너뛰어요');
    });
  });

  group('6. 누름 장치 끊김 칩 · 실내 온습도', () {
    const pressDown = [
      ConnectionItem(id: 'network', state: 'ok', title: '', message: ''),
      ConnectionItem(id: 'press', state: 'error', title: '누름 장치와 연결이 끊겼어요', message: ''),
    ];
    final notUnderGantry = applianceFromServerJson({
      'id': 'induction',
      'name': '인덕션',
      'category': 'induction',
      'rows': 1,
      'cols': 1,
      'buttons': [
        {'id': 'p', 'label': '전원', 'x': 0, 'y': 0},
      ],
      'control_path': 'physical',
      'can_execute': false,
      'readiness': 'needs_setup',
      'readiness_reasons': ['누름 장치가 이 가전 위에 없어서 누를 수 없어요'],
    });
    final practiceWasher = applianceFromServerJson({
      'id': 'washer',
      'name': 'LG 세탁기(연습)',
      'category': 'washer',
      'rows': 0,
      'cols': 0,
      'buttons': <dynamic>[],
      'control_path': 'physical',
      'can_execute': true,
      'readiness': 'operable',
    });

    testWidgets('누름 장치가 누르는 가전만 센다', (tester) async {
      await _pump(
          tester,
          _idle(
            appliances: [_purifier, kMicrowaveAppliance, notUnderGantry, practiceWasher],
            connections: pressDown,
          ));
      expect(_texts(tester), contains('누름 장치가 끊겨 가전 1대를 쓸 수 없어요'));
    });

    testWidgets('실내 값이 없으면(모의·모름) 실내 줄이 없다', (tester) async {
      await _pump(tester, _idle());
      expect(_texts(tester).where((t) => t.startsWith('실내 ') && t.endsWith('°')), isEmpty);
      expect(_texts(tester).where((t) => t.startsWith('습도 ')), isEmpty);
    });

    test('본체가 실측인지 말하지 않으면 모의로 본다', () {
      expect(SensorData.fromJson({'temperature': 26.5, 'humidity': 55}).mocked, isTrue);
      expect(SensorData.fromJson({'temperature': 23, 'humidity': 50, 'mocked': true}).mocked, isTrue);
      expect(SensorData.fromJson({'temperature': 23, 'humidity': 50, 'mocked': false}).mocked, isFalse);
    });
  });
}
