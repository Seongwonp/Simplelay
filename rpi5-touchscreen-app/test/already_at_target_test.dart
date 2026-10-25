// ThinQ 결과를 확인한 사실만큼(2026-10-14 보드 날 발견 3, 폰과 같은 규칙) — 네 경우:
// - 이미 목표값(보내지 않음, already_at_target): "이미 강풍으로 설정돼 있어요. 변경 명령을 보내지 않았어요."
// - 바꿈(state_confirmed): "강풍으로 바꿨어요."
// - 보낸 뒤 목표값·전 값 모름(state_confirmed_unknown_before): "강풍으로 설정된 것을 확인했어요." ('바꿨어요' 금지)
// - 미확인(unconfirmed): "설정이 바뀌었는지 확인하지 못했어요"
//
// 자동 실행 한 줄·완료 화면·확인 칩·단계 줄이 이미 목표값을 실패·미확인으로도, 바꿨다고도 말하지 않고, 연습은 연습이라고 밝힌다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/auto_run.dart';
import 'package:simplelay_touchscreen/models/command_result.dart';
import 'package:simplelay_touchscreen/models/scenario_run.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/done_view.dart';

const _already = '이미 강풍으로 설정돼 있어요. 변경 명령을 보내지 않았어요.';
const _seen = '강풍으로 설정된 것을 확인했어요.';

void _notChangedOrFailed(String text) {
  expect(text, isNot(contains('바꿨')));
  expect(text, isNot(contains('보냈')));
  expect(text, isNot(contains('확인하지 못했')));
  expect(text, isNot(contains('보내지 못했')));
  expect(text, isNot(contains('끝까지')));
}

KioskAutoRun _run(String confirmation,
        {String status = 'succeeded', String mode = 'real', String target = '공기청정기',
        String? phrase = '강풍'}) =>
    KioskAutoRun(
        jobId: 'a',
        outcome: 'sent',
        status: status,
        receipt: confirmation == 'already_at_target' ? 'not_dispatched' : 'accepted',
        confirmation: confirmation,
        executionMode: mode,
        targetName: target,
        settingLabel: '풍량',
        valueLabel: '강',
        valuePhrase: phrase);

void main() {
  test('자동 실행 한 줄 네 경우(실행 당시 설정 이름)', () {
    final already = autoRunNotice(_run('already_at_target'));
    expect(already, '공기청정기는 이미 강풍으로 돼 있어 보내지 않았어요');
    _notChangedOrFailed(already);
    expect(autoRunNotice(_run('state_confirmed')), '공기청정기를 강풍으로 바꿨어요');
    final seen = autoRunNotice(_run('state_confirmed_unknown_before'));
    expect(seen, '공기청정기가 강풍으로 된 것을 확인했어요');
    expect(seen, isNot(contains('바꿨')));
    expect(autoRunNotice(_run('none', status: 'unconfirmed')), '공기청정기 설정이 바뀌었는지 확인하지 못했어요');
    // 옛 서버(설정 이름 없음)는 속성 이름을 붙인다.
    expect(autoRunNotice(_run('already_at_target', phrase: null)),
        '공기청정기는 이미 풍량 강으로 돼 있어 보내지 않았어요');
  });

  test('자동 실행 한 줄: 연습은 연습 표시 유지', () {
    expect(autoRunNotice(_run('already_at_target', mode: 'mock', target: '공기청정기(모의)')),
        '공기청정기(모의)는 이미 강풍으로 돼 있어 보내지 않았어요. 연습이에요');
    expect(autoRunNotice(_run('state_confirmed_unknown_before', mode: 'mock', target: '공기청정기(모의)')),
        endsWith('. 연습이에요'));
  });

  test('확인 칩·결과 문장·단계 줄', () {
    String? label(String c, String mode) => confirmationLabel(
        route: 'thinq',
        receipt: c == 'already_at_target' ? 'not_dispatched' : 'accepted',
        confirmation: c,
        kind: ResultKind.success,
        executionMode: mode);
    expect(label('already_at_target', 'real'), '이미 그 설정이라 보내지 않았어요');
    expect(label('already_at_target', 'mock'), '이미 그 설정이라 보내지 않았어요');
    expect(label('state_confirmed_unknown_before', 'real'), '현재 설정을 확인했어요');
    final spoken = finishedMessage(
        kind: ResultKind.success,
        executionMode: 'real',
        route: 'thinq',
        receipt: 'not_dispatched',
        confirmation: 'already_at_target',
        detail: _already);
    expect(spoken, _already);
    _notChangedOrFailed(spoken);
    expect(
        finishedMessage(
            kind: ResultKind.success,
            executionMode: 'mock',
            route: 'thinq',
            receipt: 'not_dispatched',
            confirmation: 'already_at_target',
            detail: _already),
        '연습이에요. $_already');
    final facts = runStepFacts(const ScenarioRunStep(
        targetId: 'air_purifier',
        route: 'thinq',
        status: 'succeeded',
        receipt: 'not_dispatched',
        confirmation: 'already_at_target',
        executionMode: 'real'));
    expect(facts, 'LG 가전 · 이미 그 설정이라 보내지 않았어요 · 완료');
  });

  Future<void> pump(WidgetTester tester, KioskDoneView view) async {
    tester.view.physicalSize = const Size(800, 480);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: view)));
  }

  testWidgets('완료 화면: 이미 그 설정이에요 + 서버 문장, 보낸 뒤 확인했다고 하지 않는다', (tester) async {
    await pump(
        tester,
        const KioskDoneView(
          success: true,
          label: '공기청정기 강풍',
          executionMode: 'real',
          route: 'thinq',
          confirmation: '이미 그 설정이라 보내지 않았어요',
          resultConfirmation: 'already_at_target',
          detail: _already,
        ));
    expect(find.text('이미 그 설정이에요'), findsOneWidget);
    expect(find.text(_already), findsOneWidget);
    expect(find.textContaining('ThinQ로 보낸 뒤'), findsNothing);
    expect(find.text('가전 상태를 확인했어요'), findsNothing);
    expect(find.textContaining('바꿨'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  // 2026-10-14 추가 확인 3: 체크를 써도 낭독 제목이 '바꿨어요'로 읽히지 않는다.
  testWidgets('완료 화면 낭독: 이미 그 설정이라고, 바꿨다고 하지 않는다', (tester) async {
    final handle = tester.ensureSemantics();
    await pump(
        tester,
        const KioskDoneView(
          success: true,
          label: '공기청정기 강풍',
          executionMode: 'real',
          route: 'thinq',
          confirmation: '이미 그 설정이라 보내지 않았어요',
          resultConfirmation: 'already_at_target',
          detail: _already,
        ));
    final live = find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.liveRegion == true);
    final label = tester.widget<Semantics>(live.first).properties.label!;
    expect(label, contains('이미 그 설정이에요'));
    expect(label, contains('이미 그 설정이라 보내지 않았어요'));
    expect(label, isNot(contains('바꿨')));
    expect(label, isNot(contains('상태를 확인했어요')));
    handle.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('완료 화면: 전 값 모름은 설정된 것을 확인했다고만', (tester) async {
    await pump(
        tester,
        const KioskDoneView(
          success: true,
          label: '공기청정기 강풍',
          executionMode: 'real',
          route: 'thinq',
          confirmation: '설정된 것 확인됨',
          resultConfirmation: 'state_confirmed_unknown_before',
          detail: _seen,
        ));
    expect(find.text(_seen), findsOneWidget);
    expect(find.textContaining('바꿨'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('완료 화면: 연습의 이미 목표값은 연습이라고', (tester) async {
    await pump(
        tester,
        const KioskDoneView(
          success: true,
          label: '공기청정기 강풍',
          executionMode: 'mock',
          route: 'thinq',
          confirmation: '연습 · 이미 그 설정이라 보내지 않았어요',
          resultConfirmation: 'already_at_target',
          detail: _already,
        ));
    expect(find.text('이미 그 설정이에요'), findsOneWidget);
    expect(find.text(_already), findsOneWidget);
    expect(find.textContaining('바꿨'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
