// LG 가전 실행 화면(사용자 요청 10/18) — 작은 팔이 누르지 않는 실행에 버튼판·'누를 버튼'·누를 순서를 보이지 않는다.
//
// - 보내는 중: 가운데 큰 기다림 표시 + 하려는 일('공기청정기를 켜고 있어요', 평가 10차 10/18). 정지 단추는 그대로.
// - 끝: 결과 창 — 서버가 상태를 다시 읽어 확인했을 때만 초록 체크 + 바뀐 결과('공기청정기가 켜졌어요').
//   확인 못 함은 체크 없이 '켜 달라고 했어요 / 켜졌는지는 아직 몰라요', 이미 그 설정이면 '이미 켜져 있어요'.
//   몇 초 뒤 또는 '닫기'로 처음 화면.
// - 판정 근거: 승인에 묶인 명령(`commands[].route`)이 LG 가전 명령 하나일 때(또는 LG 가전 상세에서 바꾼 것)만.
//   작은 팔 단계가 섞인 루틴은 기존 화면.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/models/command_result.dart';
import 'package:simplelay_touchscreen/models/thinq_run.dart';
import 'package:simplelay_touchscreen/screens/kiosk_screen.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/theme/kiosk_colors.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/done_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/executing_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/kiosk_timings.dart';

import 'kiosk_phase_test.dart' show FakeEventStream, FakeKioskApi, FakeTts;

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

const _powerOn = KioskSuggestion(
  id: 'sc-on',
  purpose: '공기청정기를 켤까요?',
  occurrences: 0,
  timeBand: '환경',
  reason: '공기청정기 센서: 초미세먼지 42 · 나쁨',
  applianceId: 'air_purifier',
  scenarioId: 'air_quality_power_on',
  commands: [
    KioskSuggestionCommand(
        targetId: 'air_purifier', route: 'thinq', action: 'set_power', summary: '공기청정기 전원 켜기'),
  ],
);

/// 루틴 — LG 가전 단계와 작은 팔 단계가 섞였다.
const _mixed = KioskSuggestion(
  id: 'sc-mixed',
  purpose: '저녁 휴식 — 공기청정기를 켜고 선풍기를 약풍으로 켤까요?',
  occurrences: 0,
  timeBand: '시나리오',
  applianceId: 'air_purifier',
  scenarioId: 'evening_rest',
  commands: [
    KioskSuggestionCommand(targetId: 'air_purifier', route: 'thinq', action: 'set_power', summary: '공기청정기 전원 켜기'),
    KioskSuggestionCommand(targetId: 'microwave', route: 'physical', buttons: ['즉석밥'], summary: '전자레인지 즉석밥'),
  ],
);

const _approveKey = ValueKey('suggestion-approve');
final _sending = find.byKey(const ValueKey('thinq-sending'));
final _result = find.byKey(const ValueKey('thinq-result'));

Future<FakeKioskApi> _start(WidgetTester tester, KioskSuggestion card, {FakeTts? tts}) async {
  tester.view.physicalSize = const Size(800, 480);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final api = FakeKioskApi()
    ..applianceList = [kMicrowaveAppliance, _purifier]
    ..suggestionList = [card];
  await tester.pumpWidget(MaterialApp(
      home: KioskScreen(api: api, tts: tts ?? FakeTts(), events: FakeEventStream())));
  await tester.pump();
  await tester.pump();
  return api;
}

Future<void> _approveAndRun(WidgetTester tester, FakeKioskApi api) async {
  api.suggestionList = [];
  await tester.tap(find.byKey(_approveKey));
  await tester.pump();
  api.statusResult = const KioskStatus(
      running: true, jobId: 'job-1', applianceId: 'air_purifier', executionMode: 'real', totalSteps: 1);
  await tester.pump(const Duration(seconds: 2));
  await tester.pump();
}

Future<void> _finish(WidgetTester tester, FakeKioskApi api, KioskStatus status) async {
  api.statusResult = status;
  await tester.pump(const Duration(seconds: 2));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 900));
  await tester.pump();
}

KioskStatus _done({
  String outcome = 'success',
  String receipt = 'accepted',
  String confirmation = 'state_confirmed',
  String detail = '전원 켜기로 바꿨어요.',
  String mode = 'real',
}) =>
    KioskStatus(
      running: false,
      lastJobId: 'job-1',
      lastStatus: outcome == 'success' ? 'succeeded' : outcome,
      lastOutcome: outcome,
      lastRoute: 'thinq',
      lastReceipt: receipt,
      lastConfirmation: confirmation,
      lastDetail: detail,
      lastExecutionMode: mode,
      lastApplianceId: 'air_purifier',
    );

void main() {
  group('결과 말 — 서버 확인 수준만큼', () {
    ThinqResultCopy? copy(String conf, String detail,
            {ResultKind kind = ResultKind.success, String receipt = 'accepted', String mode = 'real'}) =>
        thinqResultCopy(
            applianceName: '공기청정기',
            kind: kind,
            receipt: receipt,
            confirmation: conf,
            detail: detail,
            executionMode: mode);

    test('상태 확인(바뀜) — 켜졌어요·꺼졌어요·바람 세기', () {
      expect(copy('state_confirmed', '전원 켜기로 바꿨어요.')!.headline, '공기청정기가 켜졌어요');
      expect(copy('state_confirmed', '전원 끄기로 바꿨어요.')!.headline, '공기청정기가 꺼졌어요');
      expect(copy('state_confirmed', '바람 세기 강으로 바꿨어요.')!.headline, '바람 세기 강으로 바꿨어요');
      expect(copy('state_confirmed', '전원 켜기로 바꿨어요.')!.tone, ThinqResultTone.confirmed);
    });

    test('전 값을 모름 — 바꿨다고 하지 않고 본 상태만', () {
      final c = copy('state_confirmed_unknown_before', '전원 켜기로 설정된 것을 확인했어요.')!;
      expect(c.headline, '공기청정기가 켜져 있어요');
      expect(c.headline, isNot(contains('켜졌어요')));
      expect(copy('state_confirmed_unknown_before', '바람 세기 강으로 설정된 것을 확인했어요.')!.headline,
          '바람 세기 강으로 설정된 것을 확인했어요');
    });

    test('이미 그 설정 — 이미 켜져 있어요, 그대로 두었어요', () {
      final c = copy('already_at_target', '이미 전원 켜기로 설정돼 있어요. 그래서 보내지 않았어요.')!;
      expect(c.headline, '이미 켜져 있어요');
      expect(c.sub, '그대로 두었어요');
    });

    test('확인 못 함 — 체크 없이 정직하게, 받았는지 모르면 다시 보내기 전에 보라고', () {
      final c = copy('none', '가전에 전했지만 설정이 바뀌었는지 몰라요. 가전을 봐 주세요.',
          kind: ResultKind.unconfirmed)!;
      // 무엇을 부탁했는지 모르면(서버 문장에 설정이 없으면) 일반 문장 — 지어내지 않는다.
      // 제목에 가전 이름(평가 11차 10/18 — '…달라고 했어요'는 누가 누구에게인지 몰랐다).
      expect(c.headline, '공기청정기에 설정 바꾸기를 보냈어요');
      expect(c.sub, '바뀌었는지는 아직 몰라요\n가전을 봐 주세요');
      expect(c.tone, ThinqResultTone.attention);
      final on = thinqResultCopy(
          applianceName: '공기청정기',
          kind: ResultKind.unconfirmed,
          receipt: 'accepted',
          confirmation: 'none',
          executionMode: 'real',
          action: thinqActionOf('공기청정기', ['공기청정기 전원 켜기']))!;
      expect(on.headline, '공기청정기에 켜기를 보냈어요');
      expect(on.sub, '켜졌는지는 아직 몰라요\n가전을 봐 주세요');
      expect(copy('none', '', kind: ResultKind.unconfirmed, receipt: 'unknown')!.headline, '공기청정기에 전해졌는지 몰라요');
    });

    test('실행 환경을 모르면 확인으로 올리지 않는다 · 연습은 연습 · 실패는 기존 화면(null)', () {
      expect(copy('state_confirmed', '전원 켜기로 바꿨어요.', mode: 'unknown')!.tone, ThinqResultTone.attention);
      expect(copy('state_confirmed', '전원 켜기로 바꿨어요.', mode: 'mock')!.tone, ThinqResultTone.practice);
      expect(copy('none', '', kind: ResultKind.failed), isNull);
      expect(copy('none', '', kind: ResultKind.stopped), isNull);
    });

    test('판정 — LG 가전 명령 하나만', () {
      expect(isSingleThinqCommand(['thinq']), isTrue);
      expect(isSingleThinqCommand(['thinq', 'physical']), isFalse);
      expect(isSingleThinqCommand(['physical']), isFalse);
      expect(isSingleThinqCommand(const <String>[]), isFalse);
    });
  });

  group('키오스크 화면', () {
    testWidgets('보내는 중 — 버튼판·누를 순서·작은 팔 문구 없이 기다림 + 한 줄, 정지 단추는 그대로', (tester) async {
      final api = await _start(tester, _powerOn);
      await _approveAndRun(tester, api);
      expect(find.byType(KioskExecutingView), findsOneWidget);
      expect(_sending, findsOneWidget);
      expect(find.text('공기청정기를 켜고 있어요'), findsOneWidget);
      expect(find.descendant(of: _sending, matching: find.byType(CircularProgressIndicator)), findsOneWidget);
      expect(find.textContaining('누를'), findsNothing);
      expect(find.textContaining('작은 팔'), findsNothing);
      expect(find.textContaining('버튼'), findsNothing);
      expect(find.text('준비 중'), findsNothing);
      expect(find.byKey(const ValueKey('exec-step-trail')), findsNothing);
      expect(find.byKey(const ValueKey('exec-panel-caption')), findsNothing);
      // 정지는 실행 화면과 같은 단추.
      expect(find.byKey(const ValueKey('kiosk-stop-area')), findsOneWidget);
      await tester.tap(find.text('정지'));
      await tester.pump();
      expect(api.stopCalls, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('끝: 상태 확인 → 초록 체크 + 공기청정기가 켜졌어요, 몇 초 뒤 처음 화면', (tester) async {
      final tts = FakeTts();
      final api = await _start(tester, _powerOn, tts: tts);
      await _approveAndRun(tester, api);
      await _finish(tester, api, _done());
      expect(find.byType(KioskDoneView), findsOneWidget);
      expect(_result, findsOneWidget);
      expect(find.text('공기청정기가 켜졌어요'), findsOneWidget);
      expect(find.text('공기청정기에서 확인했어요'), findsOneWidget);
      final ring = find.byKey(const ValueKey('thinq-result-ring'));
      final icon = tester.widget<Icon>(find.descendant(of: ring, matching: find.byType(Icon)));
      expect(icon.icon, Icons.check);
      expect(icon.color, KioskColors.confirmed);
      // 결과 창에 작은 팔 문구·버튼판이 없다.
      expect(find.textContaining('작은 팔'), findsNothing);
      expect(find.textContaining('눌렀'), findsNothing);
      expect(tts.utterances.last, contains('공기청정기가 켜졌어요'));
      await tester.pump(KioskTimings.doneReturn);
      await tester.pump();
      expect(find.byType(KioskIdleView), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('끝: 확인 못 함 → 체크 없이 공기청정기에 켜기를 보냈어요 / 켜졌는지는 아직 몰라요, 처음 화면으로', (tester) async {
      final api = await _start(tester, _powerOn);
      await _approveAndRun(tester, api);
      await _finish(
          tester,
          api,
          _done(
              outcome: 'unconfirmed',
              confirmation: 'none',
              detail: '가전에 전했지만 설정이 바뀌었는지 몰라요. 가전을 봐 주세요.'));
      expect(_result, findsOneWidget);
      expect(find.text('공기청정기에 켜기를 보냈어요'), findsOneWidget);
      expect(find.text('켜졌는지는 아직 몰라요\n가전을 봐 주세요'), findsOneWidget);
      expect(find.descendant(of: _result, matching: find.byIcon(Icons.check)), findsNothing);
      expect(find.text('한 번 더 하기'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('thinq-result-close')));
      await tester.pump();
      expect(find.byType(KioskIdleView), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('끝: 이미 그 설정 → 이미 켜져 있어요', (tester) async {
      final api = await _start(tester, _powerOn);
      await _approveAndRun(tester, api);
      await _finish(
          tester,
          api,
          _done(
              receipt: 'not_dispatched',
              confirmation: 'already_at_target',
              detail: '이미 전원 켜기로 설정돼 있어요. 그래서 보내지 않았어요.'));
      expect(_result, findsOneWidget);
      expect(find.text('이미 켜져 있어요'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('실패는 기존 실패 화면', (tester) async {
      final api = await _start(tester, _powerOn);
      await _approveAndRun(tester, api);
      await _finish(tester, api,
          _done(outcome: 'failed', receipt: 'not_dispatched', confirmation: 'none', detail: '가전에 연결되지 않았어요.'));
      expect(find.byType(KioskDoneView), findsOneWidget);
      expect(_result, findsNothing);
      expect(find.text('처음 화면으로'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('LG 가전 단계와 작은 팔 단계가 섞인 루틴은 기존 실행 화면', (tester) async {
      final api = await _start(tester, _mixed);
      await _approveAndRun(tester, api);
      expect(find.byType(KioskExecutingView), findsOneWidget);
      expect(_sending, findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('보내는 중·결과 — 큰 글씨에서도 잘리지 않는다', (tester) async {
      for (final scale in [1.0, 1.22]) {
        tester.view.physicalSize = const Size(800, 480);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        Widget wrap(Widget child) => MaterialApp(
            home: MediaQuery(
                data: MediaQueryData(size: const Size(800, 480), textScaler: TextScaler.linear(scale)),
                child: Scaffold(body: child)));
        await tester.pumpWidget(wrap(KioskExecutingView(
            title: '공기청정기를 켤까요?',
            target: _purifier,
            thinqOnly: true,
            executionMode: 'real',
            lastButtons: null,
            currentButton: null,
            currentAttempt: null,
            completedSteps: null,
            verificationConfidence: null,
            verificationDetail: null,
            onStop: () {})));
        await tester.pump();
        expect(tester.takeException(), isNull, reason: 'x$scale 보내는 중');
        expect(find.text('공기청정기를 켜고 있어요'), findsOneWidget);
        await tester.pumpWidget(wrap(KioskDoneView(
            success: true,
            label: '공기청정기를 켤까요?',
            target: _purifier,
            thinqOnly: true,
            route: 'thinq',
            executionMode: 'real',
            resultConfirmation: 'state_confirmed',
            detail: '전원 켜기로 바꿨어요.',
            onDismiss: () {})));
        await tester.pump();
        expect(tester.takeException(), isNull, reason: 'x$scale 결과');
        expect(find.byKey(const ValueKey('thinq-result-close')).hitTestable(), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    });
  });
}
