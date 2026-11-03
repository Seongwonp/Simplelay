// 제안 화면 — 어느 가전을 → 무엇을 → 어떤 순서로 → 할까 말까.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/kiosk_canvas.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/kiosk_scroll_area.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/panel_picture.dart';
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
    {ApplianceMap? target,
    KioskSuggestion suggestion = _sug,
    Size size = const Size(800, 480),
    double? textScale,
    VoidCallback? onMarkDone}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final view = KioskSuggestionView(
    suggestion: suggestion,
    target: target,
    cdRemaining: 20,
    cdTotal: 20,
    onApprove: () {},
    onReject: () {},
    onMarkDone: onMarkDone,
  );
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: textScale == null
          ? view
          : Builder(
              builder: (context) => MediaQuery(
                    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
                    child: view,
                  )),
    ),
  ));
}

final _chips = find.byWidgetPredicate((w) =>
    w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith('suggestion-signal-chip-'));

const _signals = [
  KioskSuggestionSignal(label: '집에 계심'),
  KioskSuggestionSignal(label: '평소 오후 10시쯤'),
  KioskSuggestionSignal(label: '최근 7일 중 5일'),
  KioskSuggestionSignal(label: '불을 끄심'),
  KioskSuggestionSignal(label: '다섯째 신호'),
];

const _habit = KioskSuggestion(
  id: 'h1',
  purpose: '즉석밥 데워줘',
  occurrences: 5,
  timeBand: '저녁',
  reason: '최근 7일 중 5일, 오후 10시쯤 하셨어요',
  steps: ['즉석밥', '시작'],
  applianceId: 'microwave',
  signals: _signals,
  canMarkDone: true,
);

const _malgunPath = r'C:\Windows\Fonts\malgun.ttf';
final _hasMalgun = File(_malgunPath).existsSync();

void main() {
  setUpAll(() async {
    if (!_hasMalgun) return;
    final bytes = File(_malgunPath).readAsBytesSync();
    await (FontLoader('Malgun')..addFont(Future.value(ByteData.view(bytes.buffer)))).load();
  });

  testWidgets('버튼은 시작과 다음에 두 개뿐 — 억제·미루기·바꾸기는 폰에 둔다', (tester) async {
    await _pump(tester, target: kMicrowaveAppliance);
    expect(tester.takeException(), isNull);
    expect(find.byType(ElevatedButton), findsOneWidget);
    expect(find.byType(OutlinedButton), findsOneWidget);
    expect(find.byType(TextButton), findsNothing);
    expect(find.text('아니요'), findsOneWidget);
    // 승인 버튼은 폰과 같은 '네'(2차 평가 10/18) — 가전 버튼 이름 '시작'과 겹치지 않게(UI 평가 10/17).
    expect(find.descendant(of: find.byKey(_approve), matching: find.text('네')),
        findsOneWidget);
    expect(find.descendant(of: find.byKey(_approve), matching: find.text('시작')), findsNothing);
  });

  testWidgets('루틴 카드는 사용자가 붙인 루틴 이름을 보인다', (tester) async {
    await _pump(tester,
        target: kMicrowaveAppliance,
        suggestion: const KioskSuggestion(
          id: 'r1',
          purpose: '즉석밥 데워줘',
          occurrences: 0,
          applianceId: 'microwave',
          routineId: 'morning',
          routineName: '아침 데우기',
        ));
    expect(find.text('내 루틴 "아침 데우기"'), findsOneWidget);
  });

  // 실패널(10/17): 질문이 이미 루틴 이름을 말하면("'30초 데우기' 루틴을 실행할까요?") 위 줄에서 되풀이하지 않는다.
  testWidgets('질문에 루틴 이름이 있으면 위 루틴 이름 줄을 되풀이하지 않는다', (tester) async {
    await _pump(tester,
        target: kMicrowaveAppliance,
        suggestion: const KioskSuggestion(
          id: 'r2',
          purpose: "'30초 데우기' 루틴을 실행할까요?",
          occurrences: 0,
          applianceId: 'microwave',
          routineId: 'warm30',
          routineName: '30초 데우기',
        ));
    expect(find.text('내 루틴 "30초 데우기"'), findsNothing);
  });

  testWidgets('대상 가전·질문·번호 붙은 순서·두 행동을 보여준다', (tester) async {
    await _pump(tester, target: kMicrowaveAppliance);

    expect(find.text('전자레인지'), findsOneWidget);
    expect(find.text('즉석밥 데우기를\n지금 할까요?'), findsOneWidget);
    // 버튼판 안내는 실행 화면과 같이 '화면은 누르지 않아도 돼요'까지(접근성 감사 10/18).
    expect(find.text('누름 장치가 누를 순서예요. 화면은 누르지 않아도 돼요'), findsOneWidget);
    for (final (i, label) in [(1, '즉석밥'), (2, '시작')]) {
      expect(find.text('$i'), findsOneWidget);
      expect(
          find.descendant(
              of: find.byType(KioskPanelPicture), matching: find.text(label)),
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
      find.textContaining('이 가전을 찾지 못해 할 수 없어요'),
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
    expect(find.textContaining('누르기 전에는 아무것도 하지 않아요'), findsOneWidget);
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
      final question = sizeOf(tester, find.text('즉석밥 데우기를\n지금 할까요?'));
      final approve = sizeOf(tester,
          find.descendant(of: find.byKey(_approve), matching: find.byType(Text)));
      final later = sizeOf(tester,
          find.descendant(of: find.byKey(_later), matching: find.byType(Text)));
      final step = sizeOf(tester,
          find.descendant(of: find.byType(KioskPanelPicture), matching: find.text('즉석밥')));
      final why = sizeOf(tester, find.text('아침에 3번 하셨어요'));
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
      final why = tester.widget<Text>(find.textContaining('이유:'));
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
        '(모의 입력) · 최근 기록: 이 제안 승인 3번. 냄새가 남을 수 있어 공기청정기를 '
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
            targetId: 'air_purifier', route: 'thinq', summary: '공기청정기(모의) 풍량 강'),
      ],
    );

    testWidgets('시연 데이터 카드의 할 일에는 "(모의)"를 되풀이하지 않는다(위 띠가 말한다)', (tester) async {
      await _pump(tester, suggestion: longCard, size: const Size(1920, 1080));
      expect(find.text('공기청정기 풍량 강'), findsOneWidget);
      expect(find.textContaining('(모의)'), findsNothing);
    });

    testWidgets('시연 데이터 여부는 위 띠, 조리 완료 단서는 근거 밖 줄에 늘 보인다', (tester) async {
      await _pump(tester, suggestion: longCard);
      // 외부 평가 10/16 2차: 가장 큰 글자(질문)에 '[시연 데이터]'가 박혀 있었다 — 위 상태 띠로 옮긴다.
      expect(find.text('공기청정기 강풍으로 바꿀까요?'), findsOneWidget);
      expect(find.textContaining('[시연 데이터]'), findsNothing);
      expect(find.text('제안 연습'), findsOneWidget);
      final caveat = tester.widget<Text>(find.byKey(const ValueKey('suggestion-caveat')));
      expect(caveat.data, '조리 완료가 아닐 수 있어요');
      expect(caveat.maxLines, isNull);
    });

    // 2026-10-16 결함 ③(15.8형 실패널): 왼쪽 칸이 질문·단서로 차서 근거 둘째 줄이 칸 아래에서 잘렸다.
    // 시나리오 카드의 근거는 비어 있는 오른쪽 칸('할 일' 아래)에 둔다.
    for (final size in const [Size(1920, 1080), Size(800, 480)]) {
      testWidgets('시나리오 근거는 오른쪽 칸에 잘리지 않고 보인다(${size.width.toInt()}×${size.height.toInt()})',
          (tester) async {
        await _pump(tester, suggestion: longCard, size: size);
        final why = find.textContaining('이유:');
        expect(why, findsOneWidget);
        final rect = tester.getRect(why);
        expect(rect.left, greaterThan(size.width / 2), reason: '오른쪽 칸');
        final buttonsTop = tester.getRect(find.byType(ElevatedButton)).top;
        expect(rect.bottom, lessThanOrEqualTo(buttonsTop), reason: '버튼 위에서 다 보인다');
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('낭독은 잘리지 않은 전체 근거', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, suggestion: longCard);
      expect(find.bySemanticsLabel('이유: $longReason'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('긴 근거는 펼쳐 읽을 수 있다(48 이상 버튼), 짧은 근거에는 펼치기가 없다', (tester) async {
      await _pump(tester, suggestion: longCard);
      final more = find.byKey(const ValueKey('suggestion-why-more'));
      expect(more, findsOneWidget);
      expect(tester.getSize(more).height, greaterThanOrEqualTo(48));
      expect(tester.widget<Text>(find.textContaining('이유:')).maxLines, 2);
      // 위 상태 띠가 생긴 뒤(2026-10-16) 800x480·시험 글꼴에서는 펼치기 단추가 왼쪽 칸 스크롤 아래에 있다 — 스크롤해 누른다.
      await tester.ensureVisible(more);
      await tester.pump();
      await tester.tap(more);
      await tester.pump();
      expect(tester.widget<Text>(find.textContaining('이유:')).maxLines, isNull);
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

  // 2026-10-26 '왜 지금' 신호 칩·'이미 했어요'.
  group('신호 칩·이미 했어요', () {
    testWidgets('서버가 준 신호를 칩으로 4개까지만 보인다', (tester) async {
      await _pump(tester, target: kMicrowaveAppliance, suggestion: _habit, onMarkDone: () {});
      expect(tester.takeException(), isNull);
      expect(_chips, findsNWidgets(4));
      expect(find.text('집에 계심'), findsOneWidget);
      expect(find.text('다섯째 신호'), findsNothing);
    });

    testWidgets('신호가 없으면 칩 줄이 없다(화면에서 만들지 않음)', (tester) async {
      await _pump(tester, target: kMicrowaveAppliance, onMarkDone: () {});
      expect(find.byKey(const ValueKey('suggestion-signals')), findsNothing);
    });

    testWidgets("'이미 했어요'는 습관 카드(can_mark_done)에만 있고 누르면 알린다", (tester) async {
      var done = 0;
      await _pump(tester, target: kMicrowaveAppliance, suggestion: _habit, onMarkDone: () => done++);
      await tester.tap(find.byKey(const ValueKey('suggestion-already-done')));
      expect(done, 1);
      await _pump(tester, target: kMicrowaveAppliance, onMarkDone: () => done++);
      expect(find.byKey(const ValueKey('suggestion-already-done')), findsNothing);
    });

    testWidgets('시나리오 카드는 신호를 질문 아래(왼쪽 칸)에 보인다', (tester) async {
      await _pump(tester,
          suggestion: const KioskSuggestion(
            id: 'c1',
            purpose: '수면 모드로 바꿀까요?',
            occurrences: 0,
            reason: '불을 끄셨네요.',
            applianceId: 'air',
            scenarioId: 'context_sleep_mode',
            commands: [KioskSuggestionCommand(targetId: 'air', route: 'thinq', summary: '공기청정기 수면 모드')],
            signals: [KioskSuggestionSignal(label: '불을 끄심'), KioskSuggestionSignal(label: '밤')],
          ));
      expect(tester.takeException(), isNull);
      expect(_chips, findsNWidgets(2));
      final question = tester.getRect(find.byKey(const ValueKey('suggestion-question')));
      for (final chip in tester.widgetList(_chips)) {
        final rect = tester.getRect(find.byWidget(chip));
        expect(rect.left, lessThan(800 / 2), reason: '왼쪽 칸');
        expect(rect.top, greaterThanOrEqualTo(question.bottom), reason: '질문 아래');
      }
    });

    // 15.8형 실패널(1920x1080 — 800x480 캔버스를 통째로 확대): 공기질 카드에서 오른쪽 칸(할 일·이유) 아래의 칩 두 개가
    // 위 테두리만 보이고 스크롤해야 보였다. 칩은 스크롤 없이 온전히 보이고, 할 일·이유도 스크롤 없이 보인다.
    // 줄바꿈·칩 줄 수는 글자 폭에 달려 있어 실제 한글 글꼴(맑은 고딕)로 잰다 — 시험 글꼴은 한글을 한 칸 네모로 그려 넓다.
    // 남은 시간이 '1분 40초'(시간 더 주기 뒤)로 길어져도 같다.
    for (final remaining in [40, 100]) {
      testWidgets('공기질 카드(1920x1080, 남은 $remaining초) — 신호 칩·할 일·이유가 스크롤 없이 다 보인다', (tester) async {
        if (!_hasMalgun) return markTestSkipped('맑은 고딕 없음');
        tester.view.physicalSize = const Size(1920, 1080);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(MaterialApp(
          theme: ThemeData(fontFamily: 'Malgun'),
          home: KioskCanvas(
            child: Scaffold(
              body: KioskSuggestionView(
                suggestion: const KioskSuggestion(
                  id: 'air1',
                  purpose: '공기청정기를 켤까요?',
                  occurrences: 0,
                  reason: '공기청정기가 재 보니 종합 공기질이 나빠요.',
                  applianceId: 'air',
                  scenarioId: 'air_quality_power_on',
                  commands: [KioskSuggestionCommand(targetId: 'air', route: 'thinq', summary: '공기청정기 전원 켜기')],
                  signals: [KioskSuggestionSignal(label: '종합 공기질 나쁨'), KioskSuggestionSignal(label: '공기청정기 꺼짐')],
                ),
                scenarioName: '공기가 나빠요',
                cdRemaining: remaining,
                cdTotal: remaining,
                onApprove: () {},
                onReject: () {},
                onExtend: () {},
                onMuteChanged: (_) {},
              ),
            ),
          ),
        ));
        expect(tester.takeException(), isNull);
        expect(_chips, findsNWidgets(2));
        Rect viewportOf(Finder f) =>
            tester.getRect(find.ancestor(of: f, matching: find.byType(Scrollable)).first);
        for (final f in [
          ..._chips.evaluate().map((e) => find.byWidget(e.widget)),
          find.text('공기청정기 전원 켜기'),
          find.textContaining('이유:'),
        ]) {
          final rect = tester.getRect(f);
          final viewport = viewportOf(f);
          expect(rect.bottom, lessThanOrEqualTo(viewport.bottom), reason: '$f — 칸 안에서 스크롤 없이 보인다');
          expect(rect.top, greaterThanOrEqualTo(viewport.top));
        }
      });
    }

    for (final scale in [1.0, 1.5]) {
      testWidgets('800x480·글자 $scale배에서 칩·이미 했어요가 넘치지 않는다', (tester) async {
        await _pump(tester,
            target: kMicrowaveAppliance, suggestion: _habit, textScale: scale, onMarkDone: () {});
        expect(tester.takeException(), isNull);
        expect(find.byKey(const ValueKey('suggestion-already-done')), findsOneWidget);
      });
    }
  });

  // 15.8형 실패널(1920x1080): 전자레인지가 멈춘 뒤 공기청정기 카드 — 맡기기 단추('이번에 하고, 다음부터는 묻지 않고 하기')
  // 줄까지 있는 카드에서 위 칸이 모자라 왼쪽 질문 아래 제한 문장('조리 완료가 아닐 수 있어요')과 오른쪽 '이유' 줄이 칸
  // 경계에서 위아래가 잘려 보였다. 남은 시간이 '1분 12초'처럼 길어 아래 안내문이 두 줄로 접혀도 같다.
  // 실패널 글꼴과 같은 계열(Noto Sans KR)로 잰다 — 시험 글꼴은 한글을 한 칸 네모로 그려 줄바꿈이 다르다.
  group('가열 종료 → 공기청정기 카드(1920x1080)', () {
    const notoPath = r'C:\Windows\Fonts\NotoSansKR-VF.ttf';
    final hasNoto = File(notoPath).existsSync();

    setUpAll(() async {
      if (!hasNoto) return;
      final bytes = File(notoPath).readAsBytesSync();
      await (FontLoader('NotoKR')..addFont(Future.value(ByteData.view(bytes.buffer)))).load();
    });

    KioskSuggestion cookCard({String reason = '전자레인지가 멈춘 것 같아요. 조리 완료가 아닐 수 있어요.'}) => KioskSuggestion(
          id: 'cook1',
          purpose: '공기청정기 바람을 세게 할까요?',
          occurrences: 0,
          reason: reason,
          applianceId: 'air_purifier',
          scenarioId: 'cook_done_air',
          commands: const [
            KioskSuggestionCommand(targetId: 'air_purifier', route: 'thinq', summary: '공기청정기 바람 세기 강')
          ],
          autoRuleOffer: const KioskAutoRuleOffer(
              conditionText: '전자레인지가 데우기를 멈추면',
              actionText: '공기청정기 바람을 세게 해요',
              caveat: '',
              fingerprint: 'f1'),
        );

    Future<void> pumpCook(WidgetTester tester, KioskSuggestion suggestion, int remaining) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(fontFamily: 'NotoKR'),
        home: KioskCanvas(
          child: Scaffold(
            body: KioskSuggestionView(
              suggestion: suggestion,
              scenarioName: '전자레인지가 멈추면 공기청정기 세게',
              cdRemaining: remaining,
              cdTotal: 120,
              onApprove: () {},
              onReject: () {},
              onExtend: () {},
              onMuteChanged: (_) {},
              onAllowAuto: () {},
            ),
          ),
        ),
      ));
      await tester.pump();
    }

    Rect viewportOf(WidgetTester tester, Finder f) =>
        tester.getRect(find.ancestor(of: f, matching: find.byType(Scrollable)).last);

    for (final remaining in [40, 72, 100]) {
      testWidgets('남은 $remaining초 — 질문·제한 문장·할 일·이유가 스크롤 없이 칸 안에 다 보인다', (tester) async {
        if (!hasNoto) return markTestSkipped('Noto Sans KR 없음');
        await pumpCook(tester, cookCard(), remaining);
        expect(tester.takeException(), isNull);
        expect(find.byKey(const ValueKey('suggestion-allow-auto')), findsOneWidget);
        for (final f in [
          find.byKey(const ValueKey('suggestion-question')),
          find.byKey(const ValueKey('suggestion-caveat')),
          find.text('공기청정기 바람 세기 강'),
          find.textContaining('이유:'),
        ]) {
          expect(f, findsOneWidget);
          final rect = tester.getRect(f);
          final viewport = viewportOf(tester, f);
          expect(rect.bottom, lessThanOrEqualTo(viewport.bottom + 0.5), reason: '$f — 칸 경계에서 잘리지 않는다');
          expect(rect.top, greaterThanOrEqualTo(viewport.top - 0.5));
        }
        for (final state in tester.stateList(find.byType(KioskScrollArea))) {
          expect((state as dynamic).moreBelow, isFalse, reason: '넘치지 않으니 흐림도 없다');
        }
        // 제한 문장은 왼쪽 줄 한 번만 — 오른쪽 이유에서 되풀이하지 않는다.
        final why = tester.widget<Text>(find.textContaining('이유:')).textSpan!.toPlainText();
        expect(why.contains('조리 완료가 아닐 수 있어요'), isFalse);
        expect(why.replaceAll(RegExp('[\u2060\u00A0]'), ' '), contains('멈춘 것 같아요'));
        // 시나리오 이름은 위 띠 오른쪽에 있다(본문 줄이 아니다).
        expect(
            find.descendant(
                of: find.byKey(const ValueKey('status-band-detail')),
                matching: find.byWidgetPredicate((w) =>
                    w is Text &&
                    (w.textSpan?.toPlainText() ?? w.data ?? '').replaceAll(RegExp('[\u2060\u00A0]'), ' ') ==
                        '전자레인지가 멈추면 공기청정기 세게')),
            findsOneWidget);
      });
    }

    testWidgets('이유가 길어 넘치면 그 칸만 스크롤 막대와 아래 끝 흐림으로 보인다', (tester) async {
      if (!hasNoto) return markTestSkipped('Noto Sans KR 없음');
      await pumpCook(
          tester,
          cookCard(
              reason: '전자레인지가 멈춘 것 같아요. 조리 완료가 아닐 수 있어요. 연습으로 넣은 신호예요. '
                  '지금까지 12번 허락받은 제안이에요.'),
          100);
      expect(tester.takeException(), isNull);
      final why = find.textContaining('이유:');
      final overflowing = tester.getRect(why).bottom > viewportOf(tester, why).bottom;
      final state = tester.state(find.ancestor(of: why, matching: find.byType(KioskScrollArea)).first);
      expect((state as dynamic).moreBelow, overflowing);
      // 왼쪽 칸(질문·제한 문장)은 그대로 다 보인다.
      final caveat = find.byKey(const ValueKey('suggestion-caveat'));
      expect(tester.getRect(caveat).bottom, lessThanOrEqualTo(viewportOf(tester, caveat).bottom + 0.5));
    });
  });

  test('오른쪽 이유에서 왼쪽에 늘 보이는 제한 문장만 뺀다', () {
    expect(KioskSuggestionView.reasonWithoutShownCaveats('전자레인지가 멈춘 것 같아요. 조리 완료가 아닐 수 있어요.'),
        '전자레인지가 멈춘 것 같아요.');
    expect(
        KioskSuggestionView.reasonWithoutShownCaveats(
            '전자레인지가 멈춘 것 같아요. 조리 완료가 아닐 수 있어요. 연습 신호예요.'),
        '전자레인지가 멈춘 것 같아요. 연습 신호예요.');
    expect(KioskSuggestionView.reasonWithoutShownCaveats('조리 완료가 아닐 수 있어요.'), '');
    expect(KioskSuggestionView.reasonWithoutShownCaveats('공기청정기가 재 보니 종합 공기질이 나빠요.'),
        '공기청정기가 재 보니 종합 공기질이 나빠요.');
  });
}
