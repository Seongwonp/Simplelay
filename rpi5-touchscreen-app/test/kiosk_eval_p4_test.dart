// 평가 4차(2026-10-18) 지적 수리 — 키오스크 4단계. 이 파일은 옛 코드에도 있는 공개 구성만 써서 쓴다
// (옛 코드에서 하나하나 실패하는 것을 확인하려고). 새 함수 단위 시험은 kiosk_eval_p4_api_test.dart.
//
// A. 비상 버튼이 눌려 있으면 상태 칩이 '모두 정상'이라고 하지 않는다 — 빨강 '비상 버튼이 눌려 있어요',
//    작은 팔로 누르는 가전 타일은 '지금 못 써요'(작은 팔 끊김과 같은 처리). LG 가전 타일은 그대로.
// B. 한 글자 줄바꿈 금지 — 그려진 글(골든과 같은 배치)에서 낱말 가운데·숫자와 단위 사이가 줄로 끊기지 않고,
//    마지막 줄이 한 글자만 남지 않는다('버튼 3|번'·'쉬어|요').
// C. 기계 말투 → 사람 말: '멈추라고 보냈어요'·'다 눌렀다고 알려 왔어요'·'연습용 숫자예요'·'모드 청정'·'콘센트'·
//    '작업'·'화면으로 조작하기'·'작은 팔 위치'·'단추'를 쓰지 않는다.
// D. 실행·결과 제목에 사람 명령문('즉석밥 데워줘') 대신 '즉석밥 데우기'. 다음 루틴 카드 '자동 실행' → '자동으로 해요'.
// E. 연습 띠 한 문장('연습이에요. 실제 가전은 그대로예요'), 연습 화면에서 부딪히는 문장('눌렸는지 몰라요'·
//    '가전은 보지 않아요'·'끝나는 시간은 몰라요') 없음.
// F. 평소 화면: 시각은 모두 오전/오후(시계 '오전 7:08', 루틴 '오전 7시', 예보 '오후 3시'), 예보의 비 확률은 '비 70%',
//    가전 4개면 한 줄에 4개(장 넘김 없음), 시계·안내와 타일 사이 빈 띠가 크지 않음, 큰 글씨에서도 '실내'.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/ambient.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/models/command_result.dart';
import 'package:simplelay_touchscreen/models/thinq.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/theme/kiosk_colors.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/dnd_overlay.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/done_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/estop_banner.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/executing_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/hold_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_top.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/manual_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/panel_picture.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/practice_band.dart';

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

const _ok = [
  ConnectionItem(id: 'network', state: 'ok', title: '', message: ''),
  ConnectionItem(id: 'press', state: 'ok', title: '', message: ''),
  ConnectionItem(id: 'plug', state: 'ok', title: '', message: ''),
];

const _ambient = AmbientInfo(
  greeting: '좋은 아침이에요.',
  weatherSource: 'mock',
  tip: AmbientTip(kind: 'rain', text: '오후 3시부터 비 예보가 있어요. 우산 챙기세요.', icon: 'rain'),
  hourly: [
    AmbientHour(label: '9시', icon: 'partly', temp: 16),
    AmbientHour(label: '12시', icon: 'cloudy', temp: 18),
    AmbientHour(label: '15시', icon: 'rain', temp: 17, pop: 70, precip: true),
    AmbientHour(label: '18시', icon: 'rain', temp: 15, pop: 60, precip: true),
  ],
);

const _next = KioskNextRun(
    name: '아침 공기청정기 끄기', dayLabel: '오늘', hhmm: '07:00', modeLabel: '자동 실행');

KioskIdleView _idle({
  List<ApplianceMap> appliances = const [_thinqAir, kMicrowaveAppliance, kInductionAppliance, _washer],
  AmbientInfo? ambient = _ambient,
  KioskNextRun? next,
  KioskAirReading? air,
  double? temperature = 23,
  ValueChanged<ApplianceMap>? onSelect,
  ValueChanged<ConnectionItem>? onOpen,
}) =>
    KioskIdleView(
      now: DateTime(2026, 10, 18, 7, 8),
      connected: true,
      ambient: ambient,
      connections: _ok,
      appliances: appliances,
      temperature: temperature,
      humidity: temperature == null ? null : 58,
      nextRun: next,
      air: air,
      onSelectAppliance: onSelect ?? (_) {},
      onOpenConnection: onOpen ?? (_) {},
      onDndGesture: () {},
      onSettingsGesture: () {},
    );

Widget _underEstop(Widget child) => KioskEstopLayout(
      banner: KioskEstopBanner(detail: _estopDetail, onRequest: () {}),
      child: child,
    );

/// 화면에 그려진 모든 글(원래 문장 — 화면 읽기 문장 포함).
List<String> _allTexts(WidgetTester tester) => [
      for (final p in tester.renderObjectList<RenderParagraph>(find.byType(RichText)))
        p.text.toPlainText(),
    ];

bool _hangul(int r) => r >= 0xAC00 && r <= 0xD7A3;
bool _sep(String c) => c == ' ' || c == '\n' || c == '\t' || c == '⁠' || c == ' ';

/// 그려진 글의 줄바꿈 검사(B) — 골든과 같은 배치에서 줄이 어디서 바뀌었나를 글자 상자 위치로 잰다.
/// 1) 낱말 가운데(띄어쓰기 아닌 두 글자 사이)에서 줄이 바뀌면 안 된다 — '3|번', '쉬어|요'.
/// 2) 여러 줄 문단의 마지막 줄이 한글 한 글자뿐이면 안 된다.
/// 한 낱말이 한 줄보다 길어 어쩔 수 없이 끊긴 경우(그 낱말이 줄 전체)는 따지지 않는다.
List<String> _badBreaks(WidgetTester tester) {
  final bad = <String>[];
  for (final p in tester.renderObjectList<RenderParagraph>(find.byType(RichText))) {
    if (p.didExceedMaxLines) continue;
    final shown = p.text.toPlainText(includeSemanticsLabels: false);
    // 3) 여러 줄로 갈 수 있는 한글 여러 낱말 문단은 어절 묶기(keepWords)로 그린다 — 실패널 글꼴은 시험 글꼴보다 넓어
    //    시험에서 한 줄이던 글도 패널에서는 줄이 바뀐다. 보호 없는 한글은 글자마다 끊길 수 있다('쉬어|요').
    final wraps = p.softWrap && (p.maxLines == null || p.maxLines! > 1);
    if (wraps &&
        shown.trim().contains(' ') &&
        shown.runes.any(_hangul) &&
        !shown.contains('⁠')) {
      bad.add('어절 묶기 없음: "${p.text.toPlainText()}"');
    }
    final chars = shown.split('');
    // 글자마다 윗변(상자가 없는 글자는 건너뛴다).
    final tops = <int, double>{};
    for (var i = 0; i < chars.length; i++) {
      if (_sep(chars[i])) continue;
      final boxes = p.getBoxesForSelection(TextSelection(baseOffset: i, extentOffset: i + 1));
      if (boxes.isEmpty) continue;
      tops[i] = boxes.first.top;
    }
    final idx = tops.keys.toList()..sort();
    final lineStarts = <int>[if (idx.isNotEmpty) idx.first];
    for (var k = 1; k < idx.length; k++) {
      if (tops[idx[k]]! > tops[idx[k - 1]]! + 2) lineStarts.add(idx[k]);
    }
    if (lineStarts.length < 2) continue;
    final plain = p.text.toPlainText();
    for (var k = 1; k < lineStarts.length; k++) {
      final s = lineStarts[k];
      // 바로 앞이 띄어쓰기·줄바꿈이면 괜찮다.
      var j = s - 1;
      while (j >= 0 && chars[j] == '⁠') {
        j--;
      }
      if (j < 0 || chars[j] == ' ' || chars[j] == '\n' || chars[j] == ' ') continue;
      // 이 줄이 한 낱말로 꽉 찬 경우(낱말이 줄보다 길다)는 넘어간다.
      final prevStart = lineStarts[k - 1];
      final prevLine = chars.sublist(prevStart, s).join();
      if (!prevLine.contains(' ') && !prevLine.contains(' ')) continue;
      bad.add('낱말 가운데 줄바꿈: "$plain" (${chars[j]}|${chars[s]})');
    }
    final last = chars.sublist(lineStarts.last).where((c) => !_sep(c) && c != '.').join();
    if (last.runes.length == 1 && _hangul(last.runes.first) &&
        !chars.sublist(lineStarts.last).contains('\n')) {
      bad.add('마지막 줄 한 글자: "$plain"');
    }
  }
  return bad;
}

void main() {
  group('A. 비상 버튼이 눌려 있으면 칩·타일이 그 사실을 따른다', () {
    testWidgets('칩은 모두 정상이라고 하지 않는다(평가 14차: 연결이 괜찮으면 칩 없음)', (tester) async {
      await _pump(tester, _underEstop(_idle()));
      final chip = find.byKey(const ValueKey('idle-status-chip'));
      // 평가 14차(10/18): 연결이 괜찮으면 칩을 두지 않는다 — '모두 정상'도 글자 없는 '!' 원도 없다.
      expect(chip, findsNothing);
      expect(find.text('기기 모두 정상'), findsNothing);
    });

    testWidgets('작은 팔로 누르는 가전 타일은 지금 못 써요, LG 가전은 그대로', (tester) async {
      await _pump(tester, _underEstop(_idle()));
      expect(
          tester.widget<Text>(find.byKey(const ValueKey('tile-status-microwave'))).data, '지금 못 써요');
      expect(tester.widget<Text>(find.byKey(const ValueKey('tile-status-air_purifier'))).data,
          isNot('지금 못 써요'));
    });

    testWidgets('비상 버튼이 없고 연결이 괜찮으면 칩이 없다(사용자 결정 10/18)', (tester) async {
      await _pump(tester, _idle());
      expect(find.byKey(const ValueKey('idle-status-chip')), findsNothing);
      expect(find.text('지금 못 써요'), findsNothing);
    });
  });

  group('B. 한 글자 줄바꿈이 없다(그려진 글 검사)', () {
    final screens = <String, Widget Function()>{
      '내 가전 루틴 카드': () => KioskManualView(
            appliance: kMicrowaveAppliance,
            onExecute: (_) {},
            onCancel: () {},
            routines: const [
              KioskRoutine(id: 'morning', name: '아침 데우기', pressCount: 3),
              KioskRoutine(id: 'evening', name: '저녁 데우기', pressCount: 4),
            ],
            onRoutine: (_) {},
          ),
      'LG 가전 상세(연습)': () => KioskManualView(
            appliance: _thinqAir,
            onExecute: (_) {},
            onCancel: () {},
            thinqRead: () async => KioskThinqStatus(
              executionMode: 'mock',
              readAt: DateTime(2026, 10, 16, 9, 7),
              state: const {
                'operation': {'airPurifierOperationMode': 'POWER_ON'},
                'airPurifierJobMode': {'currentJobMode': 'CLEAN'},
                'airFlow': {'windStrength': 'LOW'},
                'airQualitySensor': {'PM2': 42, 'PM10': 90, 'PM2Level': 'BAD', 'PM10Level': 'NORMAL'},
                'filterInfo': {'filterRemainPercent': 87},
              },
            ),
            thinqSend: (_, __) async => const KioskJobAccepted(jobId: 'j'),
            onThinqAccepted: (_, __) {},
          ),
      '잠시 쉬기 창': () => DndOverlay(dndUntil: null, onSet: (_) {}, onClear: () {}, onDismiss: () {}),
      '평소': () => _idle(next: _next),
      '평소 비상 버튼': () => _underEstop(_idle()),
      '동작 중 연습': () => KioskHoldView(
            appliance: kMicrowaveAppliance,
            holdState: 'hovering_stop',
            stopButton: '취소',
            executionMode: 'mock',
            elapsed: const Duration(minutes: 1),
            buttonsPressed: 3,
            operationConfirmed: true,
            operationSource: 'mock',
            onStop: () {},
          ),
      '결과': () => KioskDoneView(
          executionMode: 'unknown',
          success: true,
          label: '즉석밥 데워줘',
          target: kMicrowaveAppliance,
          resultConfirmation: 'reported',
          onDismiss: () {}),
      '정지 결과': () => KioskDoneView(
          executionMode: 'real',
          success: false,
          label: '즉석밥 데워줘',
          target: kMicrowaveAppliance,
          reason: KioskFailureReason.stopped,
          stopLevel: 'sent',
          onManual: () {},
          onDismiss: () {}),
    };
    for (final e in screens.entries) {
      for (final scale in const [1.0, 1.22]) {
        testWidgets('${e.key} (글자 $scale배)', (tester) async {
          await _pump(tester, e.value(), scale: scale);
          expect(_badBreaks(tester), isEmpty);
        });
      }
    }
  });

  group('C. 기계 말투 대신 사람 말', () {
    testWidgets('정지를 보냄 단계는 멈추는 중 — 보냈다·화살표가 아니다, 멈췄다고 단정하지 않는다', (tester) async {
      await _pump(
          tester,
          KioskDoneView(
              executionMode: 'real',
              success: false,
              label: '즉석밥 데워줘',
              target: kMicrowaveAppliance,
              reason: KioskFailureReason.stopped,
              stopLevel: 'sent',
              onDismiss: () {}));
      final all = _allTexts(tester).join('\n');
      expect(all, isNot(contains('보냈어요')));
      // 끝난 결과 화면에서는 진행 말('멈추는 중이에요') 대신 확인하지 못했다고(평가 8차 10/18).
      expect(all, contains('작은 팔이 멈췄는지 몰라요'));
      expect(all, isNot(contains('중이에요')));
      expect(all, isNot(contains('멈췄어요')));
      expect(stopLevelConfirmed('sent'), isFalse);
    });

    testWidgets('동작 중 화면에서 정지를 보낸 줄도 멈추는 중 — 보내기 화살표 없음', (tester) async {
      await _pump(
          tester,
          KioskHoldView(
              appliance: kMicrowaveAppliance,
              holdState: 'hovering_stop',
              stopButton: '취소',
              executionMode: 'real',
              elapsed: Duration.zero,
              stopRequested: true,
              onStop: () {}));
      expect(find.textContaining('보냈어요'), findsNothing);
      expect(find.byIcon(Icons.send), findsNothing);
      expect(find.textContaining('멈추는 중이에요'), findsOneWidget);
    });

    testWidgets('실행 환경을 모르는 누름 보고도 버튼은 다 눌렀어요 하나로(확인 수준은 그대로 확인해 주세요)', (tester) async {
      await _pump(
          tester,
          KioskDoneView(
              executionMode: 'unknown',
              success: true,
              label: '즉석밥 데워줘',
              target: kMicrowaveAppliance,
              resultConfirmation: 'reported',
              onDismiss: () {}));
      expect(find.textContaining('알려 왔어요'), findsNothing);
      expect(find.text('버튼은 다 눌렀어요'), findsOneWidget);
      expect(find.text('확인 필요'), findsOneWidget);
      expect(finishedMessage(kind: ResultKind.success, executionMode: 'unknown'),
          isNot(contains('알려 왔어요')));
    });

    test('LG 가전 상세: 연습 시각 줄은 연습 화면이라는 말, 모드 청정 줄은 없다', () {
      expect(thinqReadTimeLine(DateTime(2026, 10, 16, 9, 7), mock: true), '연습 화면이에요. 진짜 값이 아니에요');
      final rows = thinqStateRows({
        'operation': {'airPurifierOperationMode': 'POWER_ON'},
        'airPurifierJobMode': {'currentJobMode': 'CLEAN'},
        'airFlow': {'windStrength': 'LOW'},
      });
      expect(rows.map((r) => r.label), isNot(contains('모드')));
      expect(rows.map((r) => r.value), isNot(contains('청정')));
    });

    test('콘센트는 전기 플러그', () {
      expect(connectionShortName('plug'), '전기 플러그');
    });

    testWidgets('실패 화면 글자 단추는 작은 팔로 골라 누르기', (tester) async {
      await _pump(
          tester,
          KioskDoneView(
              executionMode: 'real',
              success: false,
              label: '즉석밥 데워줘',
              target: kMicrowaveAppliance,
              reason: KioskFailureReason.execution,
              onManual: () {},
              onDismiss: () {}));
      expect(find.text('화면으로 조작하기'), findsNothing);
      expect(find.text('작은 팔로 골라 누르기'), findsOneWidget);
    });

    testWidgets("큰 글씨 버튼판 한 줄은 '작은 팔 위치' 대신 작은 팔이 어디 위에 있는지", (tester) async {
      final cancel = kMicrowaveAppliance.buttons.firstWhere((b) => b.label == '취소');
      await _pump(
          tester,
          SizedBox(
            width: 500,
            height: 96,
            child: KioskPanelPicture(
                appliance: kMicrowaveAppliance, caption: '', current: cancel, compact: true),
          ));
      expect(find.textContaining('작은 팔 위치'), findsNothing);
      expect(find.textContaining('작은 팔이'), findsOneWidget);
      expect(find.textContaining('위에 있어요'), findsOneWidget);
    });

    testWidgets('비상 버튼일 때 동작 중 화면에 단추라는 말이 없다(버튼으로 통일)', (tester) async {
      final semantics = tester.ensureSemantics();
      await _pump(
          tester,
          _underEstop(KioskHoldView(
              appliance: kMicrowaveAppliance,
              holdState: 'hovering_stop',
              stopButton: '취소',
              executionMode: 'real',
              elapsed: Duration.zero,
              onStop: () {})));
      expect(_allTexts(tester).join('\n'), isNot(contains('단추')));
      expect(find.bySemanticsLabel(RegExp('단추')), findsNothing);
      semantics.dispose();
    });
  });

  group('D. 실행·결과 제목은 명령문이 아니라 ~하기', () {
    testWidgets('결과 화면 이름 줄', (tester) async {
      await _pump(
          tester,
          KioskDoneView(
              executionMode: 'real',
              success: false,
              label: '즉석밥 데워줘',
              target: kMicrowaveAppliance,
              reason: KioskFailureReason.execution,
              onDismiss: () {}));
      expect(find.textContaining('데워줘'), findsNothing);
      // 실패 화면은 가전·이름 한 줄(평가 5차 10/18).
      expect(find.text('전자레인지 · 즉석밥 데우기'), findsOneWidget);
    });

    testWidgets('실행 화면 위 띠', (tester) async {
      await _pump(
          tester,
          KioskExecutingView(
            executionMode: 'real',
            title: '즉석밥 데워줘',
            target: kMicrowaveAppliance,
            lastButtons: null,
            currentButton: '즉석밥',
            currentAttempt: 1,
            completedSteps: 0,
            totalSteps: 2,
            verificationConfidence: null,
            verificationDetail: null,
            onStop: () {},
          ));
      final all = _allTexts(tester).join('\n');
      expect(all, isNot(contains('데워줘')));
      expect(all, contains('즉석밥 데우기'));
    });

    // 사용자 결정(10/18): '자동으로 해요' 대신 작은 머리말 '자동 루틴'.
    testWidgets('다음 루틴의 자동 계열 이름은 머리말 자동 루틴', (tester) async {
      await _pump(tester, _idle(next: _next));
      final all = _allTexts(tester).join('\n');
      expect(all, isNot(contains('자동 실행')));
      expect(all, contains('자동 루틴'));
      expect(all, isNot(contains('자동으로 해요')));
    });
  });

  group('E. 연습 뜻 한 문장, 부딪히는 문장 없음', () {
    test('연습 띠 한 줄', () {
      // 연습(실행 모드 mock)은 작은 팔이 실제 모터를 돌리지 않고(RPi4 모의 모션), LG 가전도 실제로 바꾸지 않는다.
      expect(kPracticeBandText, '연습이에요. 실제 가전은 그대로예요');
    });

    testWidgets('동작 중 연습: 가전은 보지 않아요·끝나는 시간은 몰라요 없음', (tester) async {
      await _pump(
          tester,
          KioskHoldView(
              appliance: kMicrowaveAppliance,
              holdState: 'hovering_stop',
              stopButton: '취소',
              executionMode: 'mock',
              elapsed: Duration.zero,
              buttonsPressed: 3,
              operationConfirmed: true,
              operationSource: 'mock',
              onStop: () {}));
      final all = _allTexts(tester).join('\n');
      expect(all, isNot(contains('보지 않아요')));
      expect(all, isNot(contains('끝나는 시간은 몰라요')));
      expect(all, contains(kPracticeBandText));
    });

    for (final r in [KioskFailureReason.execution, KioskFailureReason.safetyStop]) {
      testWidgets('연습 실패($r)에 눌렸는지 몰라요 없음', (tester) async {
        await _pump(
            tester,
            KioskDoneView(
                executionMode: 'mock',
                success: false,
                label: '즉석밥 데워줘',
                target: kMicrowaveAppliance,
                reason: r,
                onDismiss: () {}));
        expect(_allTexts(tester).join('\n'), isNot(contains('눌렸는지 몰라')));
      });
    }

    testWidgets('연습 성공(눌림 모름 기록)에도 눌렸는지 몰라요 없음', (tester) async {
      await _pump(
          tester,
          KioskDoneView(
              executionMode: 'mock',
              success: true,
              label: '즉석밥 데워줘',
              target: kMicrowaveAppliance,
              resultConfirmation: 'none',
              confirmation: confirmationLabel(confirmation: 'none', executionMode: 'mock'),
              operationConfirmed: true,
              operationSource: 'mock',
              onDismiss: () {}));
      final all = _allTexts(tester).join('\n');
      expect(all, isNot(contains('눌렸는지 몰라')));
      expect(all, isNot(contains('보지 않았어요')));
    });
  });

  group('F. 평소 화면 시각·예보·타일', () {
    testWidgets('시계는 오전 7:08, 다음 루틴은 오전 7:00(오늘이면 날 말 없이, 분까지 — 평가 13차), 예보 칸은 오전/오후', (tester) async {
      await _pump(tester, _idle(next: _next));
      final all = _allTexts(tester);
      expect(all, contains('오전'));
      expect(all, contains('7:08'));
      expect(all.where((t) => t.startsWith('오전 7:00 · ') || t.startsWith('오전 7:00\n')), hasLength(1));
      expect(all.join('\n'), isNot(contains('07:00')));
      expect(find.text('오후 3시'), findsOneWidget);
      expect(find.text('15시'), findsNothing);
    });

    testWidgets("예보에 기온과 비 확률이 섞이면 비 확률은 '비 70%'", (tester) async {
      await _pump(tester, _idle());
      expect(find.text('비 70%'), findsOneWidget);
      expect(find.text('70%'), findsNothing);
    });

    testWidgets('가전 4개는 한 줄에 4개, 장 넘김 없음', (tester) async {
      await _pump(tester, _idle());
      for (final id in ['air_purifier', 'microwave', 'induction', 'washer']) {
        expect(find.byKey(ValueKey('strip-$id')), findsOneWidget, reason: id);
      }
      expect(find.byKey(const ValueKey('strip-page')), findsNothing);
    });

    testWidgets('안내·예보 아래와 타일 사이 빈 띠가 크지 않다(타일이 남은 자리를 쓴다)', (tester) async {
      await _pump(tester, _underEstop(_idle()));
      // 가운데 두 칸 중 더 긴 쪽의 끝(오른쪽 예보 · 왼쪽 시계 아래 줄)과 타일 위 사이 — 두 칸 모두 비는 띠.
      final tileTop = tester.getRect(find.byKey(const ValueKey('strip-microwave'))).top;
      final hoursBottom = tester.getRect(find.byKey(const ValueKey('ambient-hours'))).bottom;
      // 왼쪽 칸(시계·온습도) 글의 끝 — 위 비상 띠·날짜 줄(위 140 안)은 빼고 타일 위까지.
      final leftBottom = tester
          .widgetList<RichText>(find.byType(RichText))
          .map((w) => tester.getRect(find.byWidget(w)))
          .where((r) => r.left < 300 && r.top > 140 && r.bottom <= tileTop)
          .fold<double>(0, (m, r) => r.bottom > m ? r.bottom : m);
      final contentBottom = hoursBottom > leftBottom ? hoursBottom : leftBottom;
      expect(tileTop - contentBottom, lessThan(40));
    });

    testWidgets("큰 글씨에서도 온도 줄에 '실내'", (tester) async {
      await _pump(tester, _idle(), scale: 1.22);
      expect(_allTexts(tester).join('\n'), contains('실내'));
    });
  });

  group('B. 숫자와 단위', () {
    testWidgets('루틴 카드의 누를 버튼 3개는 한 덩어리로 그린다', (tester) async {
      await _pump(
          tester,
          KioskManualView(
            appliance: kMicrowaveAppliance,
            onExecute: (_) {},
            onCancel: () {},
            routines: const [KioskRoutine(id: 'morning', name: '아침 데우기', pressCount: 3)],
            onRoutine: (_) {},
          ));
      final shown = [
        for (final p in tester.renderObjectList<RenderParagraph>(find.byType(RichText)))
          p.text.toPlainText(includeSemanticsLabels: false),
      ];
      expect(shown.any((s) => s.contains('3⁠개')), isTrue, reason: '$shown');
    });
  });

  // 실행 화면에 띠·정지 자리 등 안전 계약은 기존 시험이 지킨다(kiosk_design_test 등). 여기서는 연습 실행 화면에도
  // 연습 띠가 그대로 있는지만 본다.
  testWidgets('연습 실행 화면에도 연습 띠 그대로', (tester) async {
    await _pump(
        tester,
        KioskExecutingView(
          executionMode: 'mock',
          title: '즉석밥 데워줘',
          target: kMicrowaveAppliance,
          lastButtons: const <KioskButtonResult>[],
          currentButton: null,
          currentAttempt: null,
          completedSteps: null,
          verificationConfidence: null,
          verificationDetail: null,
          onStop: () {},
        ));
    expect(find.text(kPracticeBandText), findsOneWidget);
  });
}
