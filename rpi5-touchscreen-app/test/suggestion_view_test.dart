// 제안 화면 — 어느 가전을 → 무엇을 → 어떤 순서로 → 할까 말까.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/suggestion_view.dart';

const _sug = KioskSuggestion(
  id: 's1',
  purpose: '즉석밥 데워줘',
  occurrences: 3,
  timeBand: '아침',
  steps: ['즉석밥', '시작'],
  applianceId: 'microwave',
);

const _approve = ValueKey('suggestion-approve');
const _later = ValueKey('suggestion-later');

Future<void> _pump(WidgetTester tester,
    {ApplianceMap? target, KioskSuggestion suggestion = _sug}) async {
  tester.view.physicalSize = const Size(800, 480);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: KioskSuggestionView(
        suggestion: suggestion,
        target: target,
        cdRemaining: 20,
        cdTotal: 20,
        onApprove: () {},
        onReject: () {},
      ),
    ),
  ));
}

void main() {
  testWidgets('버튼은 시작과 다음에 두 개뿐 — 억제·미루기·바꾸기는 폰에 둔다', (tester) async {
    await _pump(tester, target: kMicrowaveAppliance);
    expect(tester.takeException(), isNull);
    expect(find.byType(ElevatedButton), findsOneWidget);
    expect(find.byType(OutlinedButton), findsOneWidget);
    expect(find.byType(TextButton), findsNothing);
    expect(find.text('이번엔 안 할게요'), findsOneWidget);
    expect(find.descendant(of: find.byKey(_approve), matching: find.text('시작')),
        findsOneWidget);
  });

  testWidgets('루틴 카드는 사용자가 붙인 루틴 이름을 보인다', (tester) async {
    await _pump(tester,
        target: kMicrowaveAppliance,
        suggestion: const KioskSuggestion(
          id: 'r1',
          purpose: '아침 데우기',
          occurrences: 0,
          applianceId: 'microwave',
          routineId: 'morning',
          routineName: '아침 데우기',
        ));
    expect(find.text('내 루틴 "아침 데우기"'), findsOneWidget);
  });

  testWidgets('대상 가전·질문·번호 붙은 순서·두 행동을 보여준다', (tester) async {
    await _pump(tester, target: kMicrowaveAppliance);

    expect(find.text('전자레인지'), findsOneWidget);
    expect(find.text('즉석밥 데워줘,\n지금 할까요?'), findsOneWidget);
    expect(find.text('작은 팔이 누를 순서'), findsOneWidget);
    for (final (i, label) in [(1, '즉석밥'), (2, '시작')]) {
      expect(find.text('$i'), findsOneWidget);
      expect(
          find.descendant(
              of: find.byType(ListView), matching: find.text(label)),
          findsOneWidget);
    }
    expect(find.byKey(_approve), findsOneWidget);
    expect(find.byKey(_later), findsOneWidget);
    expect(find.textContaining('AI'), findsNothing);
  });

  testWidgets('대상을 모르면 대상 줄을 그리지 않는다', (tester) async {
    await _pump(tester);

    expect(find.text('전자레인지'), findsNothing);
    expect(find.byKey(_approve), findsOneWidget);
  });

  testWidgets('대상을 모르는 제안은 실행 버튼을 잠그고 이유를 말한다', (tester) async {
    // 백로그 B10 — 서버도 대상 없는 승인을 409로 거절하므로, 눌리는
    // 버튼을 세워 두면 "눌렀는데 아무 일도 없는" 화면이 된다.
    await _pump(tester);

    final button = tester.widget<ElevatedButton>(find.byKey(_approve));
    expect(button.onPressed, isNull);
    expect(
      find.textContaining('가전을 찾을 수 없어 실행할 수 없어요'),
      findsOneWidget,
    );
    // 넘기기는 그대로 된다 — 카드에서 벗어날 길은 항상 있어야 한다.
    final reject = tester.widget<OutlinedButton>(find.byKey(_later));
    expect(reject.onPressed, isNotNull);
  });

  testWidgets('대상이 있으면 실행 버튼이 살아 있다', (tester) async {
    await _pump(tester, target: kMicrowaveAppliance);

    final button = tester.widget<ElevatedButton>(find.byKey(_approve));
    expect(button.onPressed, isNotNull);
    expect(find.textContaining('누르지 않으면 실행하지 않아요'), findsOneWidget);
  });

  testWidgets('두 버튼 모두 최소 터치 크기를 지킨다', (tester) async {
    await _pump(tester, target: kMicrowaveAppliance);
    expect(tester.getSize(find.byKey(_approve)).height,
        greaterThanOrEqualTo(48));
    expect(tester.getSize(find.byKey(_later)).height, greaterThanOrEqualTo(48));
  });

  // 2026-10-14 UI 정리: '무엇을 할까요?'와 선택 버튼이 가장 크고, 근거는 짧게, 버튼 순서는 보조.
  group('글자 위계', () {
    double sizeOf(WidgetTester tester, Finder f) =>
        tester.widget<Text>(f).style!.fontSize!;

    testWidgets('질문이 가장 크고, 선택 버튼 글자가 순서·근거보다 크다', (tester) async {
      await _pump(tester, target: kMicrowaveAppliance);
      final question = sizeOf(tester, find.text('즉석밥 데워줘,\n지금 할까요?'));
      final approve = sizeOf(tester,
          find.descendant(of: find.byKey(_approve), matching: find.byType(Text)));
      final later = sizeOf(tester,
          find.descendant(of: find.byKey(_later), matching: find.byType(Text)));
      final step = sizeOf(tester,
          find.descendant(of: find.byType(ListView), matching: find.text('즉석밥')));
      final why = sizeOf(tester, find.text('아침에 자주 하셔서 여쭤봐요 · 3번 하신 기록이 있어요'));
      final all = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.style?.fontSize ?? 0)
          .toList();
      expect(all.reduce((a, b) => a > b ? a : b), question);
      for (final button in [approve, later]) {
        expect(button, greaterThan(step));
        expect(button, greaterThan(why));
      }
      expect(tester.getSize(find.byKey(_approve)).height, greaterThanOrEqualTo(72));
    });

    testWidgets('근거는 두 줄까지만', (tester) async {
      await _pump(tester,
          target: kMicrowaveAppliance,
          suggestion: const KioskSuggestion(
            id: 'sc',
            purpose: '공기청정기 강풍으로 바꿀까요?',
            occurrences: 0,
            reason: '전자레인지 가열 종료를 콘센트 전력으로 감지했어요 — 조리 완료가 아닐 수 있어요. '
                '냄새가 남을 수 있어 공기청정기를 강풍으로 바꾸면 좋아요. 실내 미세먼지도 조금 높아요.',
            scenarioId: 'cook_done_air',
            commands: [
              KioskSuggestionCommand(
                  targetId: 'air_purifier', route: 'thinq', summary: '공기청정기 풍량 강'),
            ],
          ));
      final why = tester.widget<Text>(find.textContaining('근거:'));
      expect(why.maxLines, 2);
      expect(why.overflow, TextOverflow.ellipsis);
      // 할 일(대상·동작)과 경로는 그대로 보인다.
      expect(find.text('공기청정기 풍량 강'), findsOneWidget);
    });
  });

  // 2026-10-14 추가 확인 1: 근거를 두 줄로 잘라도 중요한 제한·모의 여부는 늘 보이는 줄에 있고,
  // 긴 근거는 펼쳐 읽을 수 있으며, 낭독은 잘리지 않은 전체 근거다.
  group('근거 두 줄 제한의 안전', () {
    const longReason = '전자레인지 가열 종료를 콘센트 전력(CT)으로 감지했어요(조리 완료가 아닐 수 있어요) '
        '(모의 입력) · 최근 기록에서 이 제안을 3번 승인했어요. 냄새가 남을 수 있어 공기청정기를 '
        '강풍으로 바꾸면 좋아요. 실내 미세먼지도 조금 높아요. 문을 연 채 두었다면 닫아 주세요.';
    const longCard = KioskSuggestion(
      id: 'sc',
      purpose: '공기청정기 강풍으로 바꿀까요?',
      occurrences: 0,
      isDemo: true,
      reason: longReason,
      scenarioId: 'cook_done_air',
      commands: [
        KioskSuggestionCommand(
            targetId: 'air_purifier', route: 'thinq', summary: '공기청정기 풍량 강'),
      ],
    );

    testWidgets('모의 여부는 질문 줄, 조리 완료 단서는 근거 밖 줄에 늘 보인다', (tester) async {
      await _pump(tester, suggestion: longCard);
      expect(find.text('[시연 데이터] 공기청정기 강풍으로 바꿀까요?'), findsOneWidget);
      final caveat = tester.widget<Text>(find.byKey(const ValueKey('suggestion-caveat')));
      expect(caveat.data, '조리 완료가 아닐 수 있어요');
      expect(caveat.maxLines, isNull);
    });

    testWidgets('낭독은 잘리지 않은 전체 근거', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, suggestion: longCard);
      expect(find.bySemanticsLabel('근거: $longReason'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('긴 근거는 펼쳐 읽을 수 있다(48 이상 버튼), 짧은 근거에는 펼치기가 없다', (tester) async {
      await _pump(tester, suggestion: longCard);
      final more = find.byKey(const ValueKey('suggestion-why-more'));
      expect(more, findsOneWidget);
      expect(tester.getSize(more).height, greaterThanOrEqualTo(48));
      expect(tester.widget<Text>(find.textContaining('근거:')).maxLines, 2);
      // 위 상태 띠가 생긴 뒤(2026-10-16) 800x480·시험 글꼴에서는 펼치기 단추가 왼쪽 칸 스크롤 아래에 있다 — 스크롤해 누른다.
      await tester.ensureVisible(more);
      await tester.pump();
      await tester.tap(more);
      await tester.pump();
      expect(tester.widget<Text>(find.textContaining('근거:')).maxLines, isNull);
      expect(tester.takeException(), isNull);

      await _pump(tester, target: kMicrowaveAppliance);
      expect(find.byKey(const ValueKey('suggestion-why-more')), findsNothing);
    });
  });

  test('서버가 준 appliance_id를 받는다', () {
    final parsed = KioskSuggestion.fromJson({
      'id': 's1',
      'purpose': '즉석밥 데워줘',
      'appliance_id': 'custom_fan',
    });
    expect(parsed.applianceId, 'custom_fan');
    expect(
      KioskSuggestion.fromJson({'id': 's2', 'purpose': 'x'}).applianceId,
      isNull,
    );
  });
}
