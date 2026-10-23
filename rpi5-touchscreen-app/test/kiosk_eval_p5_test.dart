// 평가 5차(2026-10-18) 지적 수리 — 키오스크 5단계. 옛 코드에도 있는 공개 구성만 써서 옛 코드에서 실패하는 것을 확인한다.
//
// 1. 같은 말 두 번 없애기: 비상 버튼 띠가 있으면 상태 칩은 아이콘만(띠·풀기 안내는 그대로), LG 가전 상세의 연습 안내는
//    한 곳, 연습 실패는 '연습이 중간에 멈췄어요' 한 줄.
// 2. 실패 화면: 제목 한 줄 + 할 일 한 줄(무엇이었는지는 가전·이름 한 줄로), '다시 시도' → '한 번 더 하기'(확인 창 유지),
//    '누름 장치로 골라 누르기'는 밑줄 링크가 아니라 버튼.
// 3. 연습 동작 중 화면: "정지를 누르면 '취소' 버튼을 누르는 연습을 해요" 대신 '정지를 눌러 보세요'.
// 4. 평소 화면: 예보가 빠지면 다음 루틴 카드가 안내 바로 아래로 — 가운데가 비지 않는다. 맨 위 회색 줄 없음.
//    가전이 5개 이상이면 4개 + 장 넘김(오른쪽이 비지 않게).
// 5. 큰 글씨 제안 제목: '같이 / 먹을 준비,'처럼 어구 가운데에서 끊기지 않는다(줄 길이를 고르게).
// 6. 'SimpleLay 앱' 대신 '휴대폰 앱'.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/ambient.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/models/thinq.dart';import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/theme/kiosk_colors.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/done_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/estop_banner.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/hold_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/kiosk_phase.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/manual_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/suggestion_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/thinq_panel.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/top_progress_bar.dart';

Future<void> _pump(WidgetTester tester, Widget child, {double scale = 1.0}) async {
  tester.view.physicalSize = const Size(800, 480);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(size: const Size(800, 480), textScaler: TextScaler.linear(scale)),
      child: Scaffold(backgroundColor: KioskColors.bg, body: child),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 300));
}

const _estopDetail = "비상 버튼이 눌려 있어요 — 풀고 '해제하기'를 눌러야 다시 쓸 수 있어요";

const _thinqAir = ApplianceMap(
  id: 'air_purifier',
  name: '공기청정기',
  category: 'air_purifier',
  rows: 0,
  cols: 0,
  buttons: [],
  controlPath: 'thinq',
);

const _washer = ApplianceMap(
    id: 'washer', name: '세탁기', category: 'washing_machine', rows: 1, cols: 1, buttons: []);
const _fan = ApplianceMap(id: 'fan', name: '선풍기', category: 'fan', rows: 1, cols: 1, buttons: []);

const _ok = [
  ConnectionItem(id: 'network', state: 'ok', title: '', message: ''),
  ConnectionItem(id: 'press', state: 'ok', title: '', message: ''),
  ConnectionItem(id: 'plug', state: 'ok', title: '', message: ''),
];

const _hours = [
  AmbientHour(label: '9시', icon: 'partly', temp: 16),
  AmbientHour(label: '12시', icon: 'cloudy', temp: 18),
  AmbientHour(label: '15시', icon: 'rain', temp: 17, pop: 70, precip: true),
  AmbientHour(label: '18시', icon: 'rain', temp: 15, pop: 60, precip: true),
];

const _next = KioskNextRun(
    name: '아침 공기청정기 끄기', dayLabel: '오늘', hhmm: '07:00', modeLabel: '자동 실행');

KioskIdleView _idle({
  List<ApplianceMap> appliances = const [_thinqAir, kMicrowaveAppliance, kInductionAppliance, _washer],
  AmbientInfo? ambient,
  KioskNextRun? next,
  KioskAirReading? air,
}) =>
    KioskIdleView(
      now: DateTime(2026, 10, 18, 3, 29),
      connected: true,
      ambient: ambient,
      connections: _ok,
      appliances: appliances,
      nextRun: next,
      air: air,
      onSelectAppliance: (_) {},
      onOpenConnection: (_) {},
      onDndGesture: () {},
      onSettingsGesture: () {},
      onEstopGuide: () {},
    );

List<String> _allTexts(WidgetTester tester) => [
      for (final p in tester.renderObjectList<RenderParagraph>(find.byType(RichText)))
        p.text.toPlainText(),
    ];

KioskDoneView _failed({String mode = 'real', VoidCallback? onRetry, VoidCallback? onManual}) =>
    KioskDoneView(
      executionMode: mode,
      success: false,
      label: '즉석밥 데워줘',
      target: kMicrowaveAppliance,
      reason: KioskFailureReason.execution,
      onRetry: onRetry,
      onManual: onManual ?? () {},
      onDismiss: () {},
    );

void main() {
  group('1. 같은 말 두 번 없애기', () {
    testWidgets('비상 버튼 띠가 있으면 상태 칩은 띠 제목을 되풀이하지 않는다(평가 14차: 연결이 괜찮으면 칩 없음)', (tester) async {
      var guide = 0;
      await _pump(
          tester,
          KioskEstopLayout(
            banner: KioskEstopBanner(detail: _estopDetail, onRequest: () {}),
            child: KioskIdleView(
              now: DateTime(2026, 10, 18, 7, 8),
              connected: true,
              connections: _ok,
              appliances: const [kMicrowaveAppliance],
              onSelectAppliance: (_) {},
              onOpenConnection: (_) {},
              onDndGesture: () {},
              onEstopGuide: () => guide++,
            ),
          ));
      final chip = find.byKey(const ValueKey('idle-status-chip'));
      // 평가 14차(10/18): 글자 없는 '!' 원은 뜻 없는 장식이었다 — 연결이 괜찮으면 칩을 두지 않는다. 같은 말은 위 띠 한 곳.
      expect(chip, findsNothing);
      // 띠 제목은 그대로 한 번. 풀기 안내는 띠의 '푸는 방법 보기'가 연다.
      expect(find.text('비상 버튼이 눌려 있어요'), findsOneWidget);
      expect(guide, 0);
    });

    testWidgets('LG 가전 상세(연습): 연습 안내는 한 곳(조작 칸 위) — 지금 상태 칸에 연습 문장을 또 쓰지 않는다', (tester) async {
      await _pump(
          tester,
          KioskManualView(
            appliance: _thinqAir,
            onExecute: (_) {},
            onCancel: () {},
            thinqRead: () async => KioskThinqStatus(
              executionMode: 'mock',
              readAt: DateTime(2026, 10, 16, 9, 7),
              state: const {
                'operation': {'airPurifierOperationMode': 'POWER_ON'},
                'airFlow': {'windStrength': 'LOW'},
                'filterInfo': {'filterRemainPercent': 87},
              },
            ),
            thinqSend: (_, __, ___) async => const KioskJobAccepted(jobId: 'j'),
            onThinqAccepted: (_, __) {},
          ));
      await tester.pump(const Duration(milliseconds: 300));
      final all = _allTexts(tester);
      expect(all.where((t) => t.contains('연습')).length, 1, reason: '$all');
      expect(all, contains(kThinqPracticeText));
    });

    testWidgets("연습 실패는 '연습이 중간에 멈췄어요' 한 줄 — 같은 뜻 둘째 줄 없음", (tester) async {
      await _pump(tester, _failed(mode: 'mock'));
      final all = _allTexts(tester).join('\n');
      expect(all, contains('연습이 중간에 멈췄어요'));
      expect(all, isNot(contains('끝내지 못했어요')));
      expect(find.byKey(const ValueKey('done-next-step')), findsNothing);
    });
  });

  group('2. 실패 화면 문법', () {
    testWidgets('제목 한 줄 + 할 일 한 줄, 무엇이었는지는 가전·이름 한 줄', (tester) async {
      await _pump(tester, _failed());
      expect(find.text('눌렸는지 확인하지 못했어요'), findsOneWidget);
      // 할 일은 번호 안내가 한 번만 말한다(평가 15차 10/18 — '가전을 봐 주세요' 줄을 따로 두지 않는다).
      expect(find.text('가전을 봐 주세요'), findsNothing);
      expect(find.byKey(const ValueKey('done-recovery-steps')), findsOneWidget);
      // 가전 이름과 행동 이름이 따로 두 줄이 아니라 한 줄.
      final meta = _allTexts(tester).where((t) => t.contains('즉석밥 데우기')).toList();
      expect(meta, hasLength(1));
      expect(meta.single, contains('전자레인지'));
    });

    testWidgets("'다시 시도' 대신 '한 번 더 하기' — 확인 창은 그대로", (tester) async {
      var retried = 0;
      await _pump(tester, _failed(onRetry: () => retried++));
      expect(find.textContaining('다시 시도'), findsNothing);
      // 휴리스틱 평가(10/18): 눌렸는지 모르면 '안 움직였어요'라고 답한 뒤에만 보인다(R1).
      await tester.tap(find.byKey(const ValueKey('done-check-no')));
      await tester.pump();
      expect(find.text('한 번 더 하기'), findsOneWidget);
      await tester.tap(find.text('한 번 더 하기'));
      await tester.pumpAndSettle();
      // 확인 창이 먼저 — 바로 다시 누르지 않는다.
      expect(retried, 0);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.textContaining('다시 시도'), findsNothing);
      await tester.tap(find.text('네, 한 번 더 하기'));
      await tester.pumpAndSettle();
      expect(retried, 1);
    });

    // 휴리스틱 평가(10/18): 골라 누르기는 확실히 못 한 결과(연습 실패 등)에만 남는다.
    testWidgets("'누름 장치로 골라 누르기'는 밑줄 링크가 아니라 버튼(아이콘·테두리)", (tester) async {
      await _pump(
          tester,
          KioskDoneView(
              success: false,
              executionMode: 'mock',
              label: '즉석밥 데워줘',
              target: kMicrowaveAppliance,
              onRetry: () {},
              onManual: () {},
              onDismiss: () {}));
      final text = tester.widget<Text>(find.text('누름 장치로 골라 누르기'));
      expect(text.style?.decoration, isNot(TextDecoration.underline));
      final button = find.ancestor(of: find.text('누름 장치로 골라 누르기'), matching: find.byType(OutlinedButton));
      expect(button, findsOneWidget);
      expect(find.descendant(of: button, matching: find.byType(Icon)), findsOneWidget);
    });
  });

  // 평가 11차(10/18): 시키는 말 대신 고르는 말 — '정지가 어떻게 되는지 눌러 볼 수 있어요'.
  testWidgets("3. 연습 동작 중: 내부 동작 설명 대신 정지 안내 한 줄", (tester) async {
    await _pump(
        tester,
        KioskHoldView(
          appliance: kMicrowaveAppliance,
          holdState: 'hovering_stop',
          stopButton: '취소',
          executionMode: 'mock',
          elapsed: Duration.zero,
          buttonsPressed: 3,
          onStop: () {},
        ));
    final all = _allTexts(tester).join('\n');
    expect(all, isNot(contains('누르는 연습을 해요')));
    // 평가 14차(10/18): 연습을 마친 대기에는 정지 안내 문장을 두지 않는다.
    expect(all, isNot(contains('눌러 볼 수')));
  });

  group('4. 평소 화면', () {
    // 사용자 결정(10/18): 다음 루틴은 시계 아래 줄로 옮겼다 — 오른쪽은 안내 + 예보가 넉넉히 쓴다(실패널 k01 예보 빠짐 해소).
    testWidgets('긴 안내 + 예보 + 다음 루틴 + 공기 — 예보가 보이고 다음 루틴은 시계 아래, 가운데 빈 칸 없음', (tester) async {
      await _pump(
          tester,
          _idle(
            appliances: const [_thinqAir, kMicrowaveAppliance, kInductionAppliance, _washer, _fan],
            ambient: const AmbientInfo(
              greeting: '좋은 아침이에요.',
              tip: AmbientTip(
                  kind: 'routine',
                  text: '약 드실 시간이에요. 아직 안 드셨으면 지금 챙겨 드세요',
                  icon: 'notice'),
              hourly: _hours,
            ),
            next: _next,
            air: const KioskAirReading(
                applianceId: 'air_purifier', grade: 'NORMAL', pm25: 20, power: 'on'),
          ));
      final next = tester.getRect(find.byKey(const ValueKey('idle-next-run')));
      final hours = find.byKey(const ValueKey('ambient-hours'));
      expect(hours, findsOneWidget, reason: '예보가 빠지지 않는다');
      final tileTop = tester.getRect(find.byKey(const ValueKey('strip-microwave'))).top;
      expect(next.top, greaterThanOrEqualTo(tester.getRect(find.byKey(const ValueKey('idle-clock'))).bottom));
      final lower = next.bottom > tester.getRect(hours).bottom ? next.bottom : tester.getRect(hours).bottom;
      expect(tileTop - lower, lessThan(40), reason: '가운데가 크게 비지 않는다');
      expect(tileTop, greaterThanOrEqualTo(lower));
    });

    testWidgets('예보가 없어도(빈 목록) 다음 루틴은 시계 아래, 안내는 오른쪽 위', (tester) async {
      await _pump(
          tester,
          _idle(
            ambient: const AmbientInfo(
              greeting: '좋은 아침이에요.',
              tip: AmbientTip(kind: 'rain', text: '오전 7시부터 비 예보가 있어요. 우산 챙기세요.', icon: 'rain'),
              hourly: [],
            ),
            next: _next,
            air: const KioskAirReading(
                applianceId: 'air_purifier', grade: 'NORMAL', pm25: 20, power: 'on'),
          ));
      final tip = tester.getRect(find.byKey(const ValueKey('ambient-tip')));
      final next = tester.getRect(find.byKey(const ValueKey('idle-next-run')));
      expect(next.right, lessThanOrEqualTo(tip.left), reason: '다음 루틴은 왼쪽 칸, 안내는 오른쪽 칸');
      expect(next.top, greaterThanOrEqualTo(tester.getRect(find.byKey(const ValueKey('idle-clock'))).bottom));
    });

    testWidgets('평소 화면 맨 위에 용도 없는 회색 줄이 없다(진행 막대는 실행·결과에서만)', (tester) async {
      await _pump(
          tester,
          const SizedBox(
              height: 4, child: TopProgressBar(phase: KioskPhase.idle, execBarValue: 0)));
      expect(find.descendant(of: find.byType(TopProgressBar), matching: find.byType(Container)),
          findsNothing);
      expect(
          find.descendant(of: find.byType(TopProgressBar), matching: find.byType(ColoredBox)),
          findsNothing);
    });

    testWidgets('가전 5개면 한 장에 4개 + 장 넘김(오른쪽이 비지 않는다)', (tester) async {
      await _pump(
          tester,
          _idle(appliances: const [_thinqAir, kMicrowaveAppliance, kInductionAppliance, _washer, _fan]));
      final tiles = <Rect>[
        for (final id in ['air_purifier', 'microwave', 'induction', 'washer', 'fan'])
          if (find.byKey(ValueKey('strip-$id')).evaluate().isNotEmpty)
            tester.getRect(find.byKey(ValueKey('strip-$id'))),
      ];
      expect(tiles, hasLength(4));
      expect(find.byKey(const ValueKey('strip-next')), findsOneWidget);
      // 마지막 타일과 장 넘김 사이가 크게 비지 않는다.
      final next = tester.getRect(find.byKey(const ValueKey('strip-next')));
      final lastTileRight = tiles.fold<double>(0, (m, r) => r.right > m ? r.right : m);
      expect(next.left - lastTileRight, lessThan(60), reason: '타일 끝 $lastTileRight · 다음 $next');
      // 이름은 줄여 말하지 않는다.
      for (final n in ['공기청정기', '전자레인지', '인덕션', '세탁기']) {
        expect(find.text(n), findsOneWidget, reason: n);
      }
    });
  });

  // 5. 실패널 큰 글씨(맑은 고딕)에서는 '라면이랑 같이 / 먹을 준비,'로 끊겼다. 시험 글꼴은 폭이 달라 보통 글씨(오른쪽 버튼판 그림과
  //    나란한 좁은 칸)에서 같은 끊김이 난다 — 두 배율 모두 본다.
  for (final scale in const [1.0, 1.22]) {
    testWidgets("5. 제안 제목: '같이'와 '먹을'은 같은 줄(어구 가운데에서 끊지 않는다, 글자 $scale배)", (tester) async {
      await _pump(
          tester,
          KioskSuggestionView(
            suggestion: const KioskSuggestion(
              id: 'long',
              purpose: '냉동 만두 데워서 라면이랑 같이 먹을 준비',
              occurrences: 6,
              timeBand: '저녁',
              steps: ['해동', '냉동식품', '1분', '1분', '30초', '시작'],
            ),
            target: const ApplianceMap(
              id: 'custom_mw',
              name: '주방 창가 쪽 큰 전자레인지',
              category: 'microwave',
              rows: 1,
              cols: 1,
              buttons: [],
            ),
            cdRemaining: 20,
            cdTotal: 20,
            onApprove: () {},
            onReject: () {},
          ),
          scale: scale);
      final p = tester.renderObject<RenderParagraph>(find.descendant(
          of: find.byKey(const ValueKey('suggestion-question')), matching: find.byType(RichText)).first);
      final shown = p.text.toPlainText(includeSemanticsLabels: false);
      double top(String ch) {
        final i = shown.indexOf(ch);
        return p.getBoxesForSelection(TextSelection(baseOffset: i, extentOffset: i + 1)).first.top;
      }

      expect(top('같'), top('먹'), reason: shown);
      expect(top('준'), top('먹'), reason: shown);
      expect(top('냉'), top('데'), reason: shown);
      // 질문 줄은 따로.
      expect(top('할'), greaterThan(top('준')));
      expect(p.didExceedMaxLines, isFalse);
    });
  }

  group("6. 'SimpleLay 앱' 대신 '휴대폰 앱'", () {
    testWidgets('내 가전 화면', (tester) async {
      await _pump(
          tester,
          KioskManualView(
            appliance: kMicrowaveAppliance,
            onExecute: (_) {},
            onCancel: () {},
            routines: const [KioskRoutine(id: 'morning', name: '아침 데우기', pressCount: 3)],
            onRoutine: (_) {},
          ));
      final all = _allTexts(tester).join('\n');
      expect(all, isNot(contains('SimpleLay')));
      expect(all, contains('휴대폰 앱'));
    });

    testWidgets('가전이 없는 평소 화면', (tester) async {
      await _pump(tester, _idle(appliances: const []));
      final all = _allTexts(tester).join('\n');
      expect(all, isNot(contains('SimpleLay')));
      expect(all, contains('휴대폰 앱'));
    });
  });
}
