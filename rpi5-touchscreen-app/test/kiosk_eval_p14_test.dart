// 평가 14차(2026-10-18) — 키오스크 'AI 느낌'(장식·번역투·엔지니어 말) 점검과 말 맞추기. 옛 코드에도 있는 공개 구성만 써서
// 옛 코드에서 실패하는 것을 확인한다.
//
// 1. '오늘은 건너뛰기'는 지금 모양 그대로(사용자 결정 10/18 — 평가 14차의 밑줄 권고는 따르지 않는다): 작은 회색 굵은 글자,
//    밑줄·테두리 없음, 누르는 자리 48 이상. 이 항목은 지금 모양을 지키는 시험이라 옛 코드에서도 통과한다.
// 2. LG 가전 결과(확인됨)는 상자·큰 체크 원 없이 전자레인지 결과와 같은 틀(왼쪽 정렬), 둘째 줄 '가전에서 확인했어요'(이름 두 번 금지).
// 3. 제안 이유 대체문은 '아침에 3번 하셨어요'(높임·낮춤 섞인 '하셔서 여쭤봐요' 금지).
// 4. LG 가전 보내는 중 정지 안내는 한 줄 — 평가 15차(10/18)에서 '정지를 누르면 더 하지 않아요'로('보내다'는 기계가 한 일).
// 5. 화면 문구는 '버튼'으로 통일('단추' 금지), 연습을 마친 대기 화면의 정지 안내 문장은 뺀다.
// 6. 공기 나쁨 줄 아래 할 일 작은 글자 단추(그 공기청정기로), 상태 칩은 모두 괜찮으면 없다(사용자 결정 10/18). 비 확률이 높으면 인사말을 뺀다.
// 7. 연습 띠 안 테두리 칩 없음(띠 안 글자로), 비상 버튼 띠 아래 글자 없는 '!' 칩 없음.
// 8. 누름 보고만인 성공은 폰과 같은 말 — '버튼은 다 눌렀어요' + '가전이 움직이는지 봐 주세요'.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/ambient.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/models/command_result.dart';
import 'package:simplelay_touchscreen/models/thinq.dart';
import 'package:simplelay_touchscreen/models/thinq_run.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/theme/kiosk_colors.dart';
import 'package:simplelay_touchscreen/theme/kiosk_tokens.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/done_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/estop_banner.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/executing_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/hold_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/practice_band.dart';

const _fontPath = r'C:\Windows\Fonts\malgun.ttf';
final _hasFont = File(_fontPath).existsSync();

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

const _okConnections = [
  ConnectionItem(id: 'network', state: 'ok', title: '', message: ''),
  ConnectionItem(id: 'press', state: 'ok', title: '', message: ''),
];

/// 화면에 보이는 글 전부. 낱말 묶음 문자(U+2060·U+00A0)는 뗀다.
List<String> _texts(WidgetTester tester) => [
      for (final w in tester.widgetList<RichText>(find.byType(RichText)))
        w.text.toPlainText().replaceAll('\u2060', '').replaceAll('\u00A0', ' '),
    ];

Future<void> _pumpView(WidgetTester tester, Widget child, {Size size = const Size(800, 480)}) async {
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

KioskNextRun _next() => KioskNextRun.fromJson({
      'routine_id': 'rt-1',
      'name': '저녁 공기청정기 켜기',
      'at': '2026-10-18T22:00:00+09:00',
      'day_label': '오늘',
      'auto': true,
      'mode': 'approve',
      'mode_label': '자동 실행',
      'skipped': false,
      'skip_action_label': '오늘은 건너뛰기',
    })!;

KioskIdleView _idle({
  KioskNextRun? next,
  KioskAirReading? air,
  AmbientInfo? ambient,
  List<ApplianceMap>? appliances,
  List<ConnectionItem> connections = _okConnections,
  ValueChanged<ApplianceMap>? onSelect,
}) =>
    KioskIdleView(
      now: DateTime(2026, 10, 18, 7, 38),
      connected: true,
      ambient: ambient,
      appliances: appliances ?? [_purifier, kMicrowaveAppliance, kInductionAppliance],
      connections: connections,
      temperature: 23,
      humidity: 58,
      air: air,
      nextRun: next,
      onToggleNextRunSkip: (_) {},
      onSelectAppliance: onSelect ?? (_) {},
      onOpenConnection: (_) {},
      onDndGesture: () {},
    );

KioskDoneView _thinqDone() => KioskDoneView(
      success: true,
      executionMode: 'real',
      label: '공기청정기를 켤까요?',
      target: _purifier,
      thinqOnly: true,
      route: 'thinq',
      resultConfirmation: 'state_confirmed',
      detail: '전원 켜기로 바꿨어요.',
      onDismiss: () {},
    );

/// [root] 아래에 사방 테두리(위 변이 있는 Border — 상자·칩·원)를 가진 장식이 있나. 띠의 왼쪽 줄(Border(left:))은 상자가 아니다.
bool _hasBorderBox(WidgetTester tester, Finder root) {
  bool boxed(Decoration? d) =>
      d is BoxDecoration && d.border is Border && (d.border as Border).top.style != BorderStyle.none;
  for (final b in tester.widgetList<DecoratedBox>(find.descendant(of: root, matching: find.byType(DecoratedBox)))) {
    if (boxed(b.decoration)) return true;
  }
  for (final m in tester.widgetList<Material>(find.descendant(of: root, matching: find.byType(Material)))) {
    final s = m.shape;
    if (s is OutlinedBorder && s.side.style != BorderStyle.none) return true;
  }
  return false;
}

/// lib 아래 Dart 파일에서 주석을 뗀 문자열 조각들.
Iterable<(String, String)> _libStrings() sync* {
  final lit = RegExp(r"'([^'\\]|\\.)*'");
  for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
    if (!f.path.endsWith('.dart')) continue;
    for (final raw in f.readAsLinesSync()) {
      final line = raw.trimLeft();
      if (line.startsWith('//')) continue;
      final code = raw.contains(' //') ? raw.substring(0, raw.indexOf(' //')) : raw;
      for (final m in lit.allMatches(code)) {
        yield (f.path, m.group(0)!);
      }
    }
  }
}

void main() {
  setUpAll(() async {
    if (!_hasFont) return;
    final bytes = File(_fontPath).readAsBytesSync();
    await (FontLoader('Malgun')..addFont(Future.value(ByteData.view(bytes.buffer)))).load();
  });

  group('1. 오늘은 건너뛰기 — 지금 모양 지키기(사용자 결정)', () {
    testWidgets('작은 회색 굵은 글자, 밑줄·테두리 없음, 높이 48 이상', (tester) async {
      await _pumpView(tester, _idle(next: _next()));
      final skip = find.byKey(const ValueKey('idle-next-run-skip'));
      expect(skip, findsOneWidget);
      final text = tester.widget<Text>(find.descendant(of: skip, matching: find.byType(Text)));
      expect(text.data, '오늘은 건너뛰기');
      expect(text.style?.fontSize, KioskType.caption);
      expect(text.style?.fontWeight, FontWeight.w700);
      expect(text.style?.color, KioskColors.muted);
      expect(text.style?.decoration, anyOf(isNull, TextDecoration.none));
      expect(_hasBorderBox(tester, skip), isFalse);
      expect(tester.getSize(skip).height, greaterThanOrEqualTo(48));
      expect(tester.takeException(), isNull);
    });
  });

  group('2. LG 가전 결과 — 상자 없이 왼쪽 정렬, 이름 한 번', () {
    test("state_confirmed 둘째 줄은 '가전에서 확인했어요'", () {
      final copy = thinqResultCopy(
          applianceName: '공기청정기',
          kind: ResultKind.success,
          confirmation: 'state_confirmed',
          detail: '전원 켜기로 바꿨어요.',
          executionMode: 'real')!;
      expect(copy.headline, '공기청정기가 켜졌어요');
      expect(copy.sub, '가전에서 확인했어요');
    });

    testWidgets('테두리 상자·큰 체크 원이 없고 제목은 왼쪽에서 시작한다', (tester) async {
      await _pumpView(tester, _thinqDone());
      expect(find.byKey(const ValueKey('thinq-result-ring')), findsNothing);
      final texts = _texts(tester);
      expect(texts, contains('공기청정기가 켜졌어요'));
      expect(texts, contains('가전에서 확인했어요'));
      // 제목에 한 번, 위 띠 오른쪽에 한 번(평가 17차 10/18 — 모든 결과 띠가 가전 이름을 말한다).
      expect(texts.where((t) => t.contains('공기청정기')).length, 2, reason: '가전 이름은 제목·띠에 한 번씩');
      // 상태 띠 아래 본문에 테두리 상자가 없다.
      expect(_hasBorderBox(tester, find.byKey(const ValueKey('thinq-result'))), isFalse);
      // 왼쪽 정렬 — 전자레인지 결과(kiosk15_done_verified)처럼 제목이 왼쪽 여백에서 시작한다.
      final head = tester.getRect(find.byKey(const ValueKey('thinq-result-headline')));
      expect(head.left, lessThan(800 * 0.2));
      expect(tester.takeException(), isNull);
    });
  });

  group('3. 제안 이유 — 번역투 금지', () {
    test("서버 문장이 없을 때 대체문은 '아침에 3번 하셨어요'", () {
      const s = KioskSuggestion(id: 's', purpose: '즉석밥 데우기', occurrences: 3, timeBand: '아침');
      expect(s.whyNow, '아침에 3번 하셨어요');
      expect(s.whyNow, isNot(contains('여쭤')));
    });
  });

  group('4. LG 가전 보내는 중 — 정지 안내 한 줄', () {
    test('짧은 사실 문장', () {
      expect(kThinqStopNote, '정지를 누르면 더 하지 않아요');
    });

    testWidgets('화면에 그 한 줄만, 엔지니어 설명 없음', (tester) async {
      await _pumpView(
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
      final texts = _texts(tester);
      expect(texts, contains('정지를 누르면 더 하지 않아요'));
      expect(texts.where((t) => t.contains('이미 바뀐')), isEmpty);
      expect(tester.takeException(), isNull);
    });
  });

  group("5. '버튼'으로 통일, 연습 마친 화면의 정지 안내 없음", () {
    test("lib 화면 문자열에 '단추'가 없다", () {
      final bad = [
        for (final (path, s) in _libStrings())
          if (s.contains('단추')) '$path: $s',
      ];
      expect(bad, isEmpty);
    });

    testWidgets('연습을 마친 대기 화면에 정지 안내 문장이 없다', (tester) async {
      await _pumpView(
          tester,
          KioskHoldView(
            appliance: kMicrowaveAppliance,
            holdState: 'hovering_stop',
            stopButton: '취소',
            executionMode: 'mock',
            elapsed: const Duration(seconds: 30),
            onStop: () {},
            onClose: () {},
          ));
      final texts = _texts(tester);
      expect(texts, contains('연습이 끝났어요'));
      expect(texts.where((t) => t.contains('눌러 볼 수')), isEmpty);
      expect(texts.where((t) => t.contains('단추')), isEmpty);
      expect(tester.takeException(), isNull);
    });
  });

  group('6. 평소 화면 — 공기 줄에 할 일, 상태 칩은 기기 연결, 비 오면 인사말 없음', () {
    const offAir = KioskAirReading(applianceId: 'air_purifier', grade: 'BAD', pm25: 42, power: 'off');
    const onAir = KioskAirReading(applianceId: 'air_purifier', grade: 'BAD', pm25: 42, power: 'on');

    testWidgets("꺼진 공기청정기 — '공기청정기를 켜 보세요' 작은 글자 단추가 그 가전을 연다", (tester) async {
      ApplianceMap? opened;
      await _pumpView(tester, _idle(air: offAir, onSelect: (a) => opened = a));
      final action = find.byKey(const ValueKey('idle-air-action'));
      expect(action, findsOneWidget);
      expect(find.descendant(of: action, matching: find.text('공기청정기를 켜 보세요')), findsOneWidget);
      // '오늘은 건너뛰기'와 같은 작은 글자 단추 꼴.
      final text = tester.widget<Text>(find.descendant(of: action, matching: find.byType(Text)));
      expect(text.style?.fontSize, KioskType.caption);
      expect(text.style?.fontWeight, FontWeight.w700);
      // 누르는 자리는 공기 말 + 할 일 한 덩어리(평가 15차 10/18) — 48 이상.
      expect(tester.getSize(find.byKey(const ValueKey('idle-air-tap'))).height, greaterThanOrEqualTo(48));
      await tester.tap(action);
      expect(opened?.id, 'air_purifier');
      expect(tester.takeException(), isNull);
    });

    testWidgets('다음 루틴과 함께여도 할 일 단추가 보이고 가전 줄에 걸리지 않는다', (tester) async {
      ApplianceMap? opened;
      await _pumpView(tester, _idle(air: offAir, next: _next(), onSelect: (a) => opened = a));
      final action = find.byKey(const ValueKey('idle-air-action'));
      expect(action, findsOneWidget);
      expect(tester.getRect(action).bottom,
          lessThanOrEqualTo(tester.getRect(find.byKey(const ValueKey('strip-air_purifier'))).top));
      expect(tester.getSize(find.byKey(const ValueKey('idle-air-tap'))).height, greaterThanOrEqualTo(48));
      await tester.tap(action);
      expect(opened?.id, 'air_purifier');
      expect(tester.takeException(), isNull);
    });

    testWidgets("켜진 공기청정기 — '바람을 세게 해 보세요'", (tester) async {
      await _pumpView(tester, _idle(air: onAir));
      expect(
          find.descendant(
              of: find.byKey(const ValueKey('idle-air-action')), matching: find.text('바람을 세게 해 보세요')),
          findsOneWidget);
    });

    testWidgets('가전 목록에 그 공기청정기가 없으면 단추를 두지 않는다(지어내지 않는다)', (tester) async {
      await _pumpView(tester, _idle(air: offAir, appliances: [kMicrowaveAppliance]));
      expect(find.byKey(const ValueKey('idle-air-action')), findsNothing);
      expect(find.byKey(const ValueKey('idle-air')), findsOneWidget);
    });

    testWidgets("연결이 다 괜찮으면 상태 칩이 없다(사용자 결정 10/18 — '기기 모두 정상'도 없다)", (tester) async {
      await _pumpView(tester, _idle());
      expect(find.byKey(const ValueKey('idle-status-chip')), findsNothing);
      expect(find.text('기기 모두 정상'), findsNothing);
    });

    testWidgets('비 확률이 높으면 인사말을 뺀다', (tester) async {
      await _pumpView(
          tester,
          _idle(
              ambient: const AmbientInfo(
            greeting: '좋은 아침이에요.',
            weatherSource: 'kma',
            now: AmbientHour(label: '지금', hour: 7, icon: 'rain', temp: 14, pop: 80, precip: true),
            hourly: [
              AmbientHour(label: '9시', hour: 9, icon: 'rain', temp: 14),
              AmbientHour(label: '12시', hour: 12, icon: 'cloudy', temp: 16),
            ],
          )));
      expect(_texts(tester).where((t) => t.contains('좋은 아침')), isEmpty);
      expect(find.byKey(const ValueKey('ambient-hours')), findsOneWidget);
    });

    testWidgets('비 소식이 없으면 인사말은 그대로', (tester) async {
      await _pumpView(
          tester,
          _idle(
              ambient: const AmbientInfo(
            greeting: '좋은 아침이에요.',
            weatherSource: 'kma',
            now: AmbientHour(label: '지금', hour: 7, icon: 'clear', temp: 14),
            hourly: [AmbientHour(label: '9시', hour: 9, icon: 'partly', temp: 15)],
          )));
      expect(_texts(tester).where((t) => t.contains('좋은 아침')), isNotEmpty);
    });
  });

  group('7. 장식 줄이기', () {
    testWidgets('연습 실패 띠 안에 테두리 칩이 없다 — 연습 표시는 띠 안 글자로 남는다', (tester) async {
      await _pumpView(
          tester,
          KioskDoneView(
            success: false,
            executionMode: 'mock',
            label: '즉석밥 데워줘',
            target: kMicrowaveAppliance,
            onRetry: () {},
            onManual: () {},
            onDismiss: () {},
          ));
      final band = find.byKey(const ValueKey('status-band'));
      expect(find.descendant(of: band, matching: find.byKey(const ValueKey('practice-band'))), findsOneWidget);
      expect(find.descendant(of: band, matching: find.text(kPracticeBandText)), findsOneWidget);
      expect(_hasBorderBox(tester, band), isFalse);
    });

    testWidgets("비상 버튼 띠가 있고 연결이 괜찮으면 오른쪽 위 글자 없는 '!' 칩을 두지 않는다", (tester) async {
      await _pumpView(tester, KioskEstopScope(shown: true, child: _idle()));
      expect(find.byKey(const ValueKey('idle-status-chip')), findsNothing);
      expect(find.byKey(const ValueKey('idle-menu')), findsOneWidget);
    });

    testWidgets('비상 버튼 띠가 있어도 연결 문제가 있으면 글자 있는 칩으로 그 문제를 말한다', (tester) async {
      await _pumpView(
          tester,
          KioskEstopScope(
              shown: true,
              child: _idle(connections: const [
                ConnectionItem(id: 'network', state: 'ok', title: '', message: ''),
                ConnectionItem(id: 'press', state: 'error', title: '작은 팔과 연결이 끊겼어요', message: ''),
              ])));
      final chip = find.byKey(const ValueKey('idle-status-chip'));
      expect(chip, findsOneWidget);
      expect(find.descendant(of: chip, matching: find.text('연결 확인 필요 1')), findsOneWidget);
    });
  });

  group('8. 폰과 같은 말 — 누름 보고만', () {
    testWidgets("제목 '버튼은 다 눌렀어요', 아래 '가전이 움직이는지 봐 주세요'", (tester) async {
      await _pumpView(
          tester,
          KioskDoneView(
            success: true,
            executionMode: 'real',
            label: '즉석밥 데워줘',
            target: kMicrowaveAppliance,
            resultConfirmation: 'reported',
            onDismiss: () {},
          ));
      final texts = _texts(tester);
      expect(texts, contains('버튼은 다 눌렀어요'));
      expect(texts, contains('가전이 움직이는지 봐 주세요'));
      expect(texts.where((t) => t.contains('켜졌는지 봐 주세요')), isEmpty);
    });

    test('음성·상태 한 문장도 같은 말', () {
      expect(finishedMessage(kind: ResultKind.success, executionMode: 'real'),
          '버튼은 다 눌렀어요. 가전이 움직이는지 봐 주세요.');
    });
  });
}
