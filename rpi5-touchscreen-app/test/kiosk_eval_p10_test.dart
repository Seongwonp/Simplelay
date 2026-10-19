// 평가 10차(2026-10-18) 지적 수리 — 키오스크. 옛 코드에도 있는 공개 구성만 써서 옛 코드에서 실패하는 것을 확인한다.
//
// 1. LG 가전 화면에 '명령'(엔지니어 말)을 쓰지 않는다 — 하려는 일로('공기청정기를 켜고 있어요', '바람을 세게 바꾸고 있어요').
//    확인 못 함은 '켜 달라고 했어요 / 켜졌는지는 아직 몰라요 · 가전을 봐 주세요', 이미 그 설정이면 '그대로 두었어요'.
// 2. 보내는 중 위 띠에 무슨 동작인지('공기청정기 켜기').
// 3. 보내는 중 배치 — 가운데 한 열(오른쪽 위가 비지 않게), 정지 단추는 다른 실행 화면과 같은 자리·크기.
// 4. 보내는 중 정지 아래 사실 한 줄 — 서버 /stop은 아직 안 보냈으면 보내지 않고, 이미 보낸 것은 되돌리지 않는다.
// 5. 날짜 옆·예보 칸의 비 — 물방울(습도로 읽힘) 대신 비 오는 구름.
// 6. 결과 창 — '켜졌어요'·'가전에서 바뀐 것을 확인했어요'·'됐어요' 세 번 같은 말 → 아래 줄은 '공기청정기에서 확인했어요'.
// 7. 연습 중 대기 정지 — '가전을 봐 주세요'를 붙이지 않는다(실제 가전은 그대로).
// 8. 정지 확인 기다리는 중 — 위 띠는 가전·할 일 이름만(‘멈추는 중’·손 아이콘을 되풀이하지 않는다).
// 9. 큰 글씨 사용자 정지 — 주 단추 '처음 화면으로'가 보조 단추보다 위.
// 10. 짧은 안내 줄 끝 마침표 없이(처음 화면 알림·연결 창 본문·단계).
// A. 이어받은 실행(폰이 켠 공기청정기) — 서버가 경로 thinq·1단계라고 말하면 같은 LG 가전 화면. 누름 장치 경로는 종전 화면.
// B. LG 가전 타일 — 꺼진 것을 서버가 봤으면 '꺼져 있어요'(손 아이콘 '준비됐어요'가 아니라).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/ambient.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/screens/kiosk_screen.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/theme/kiosk_colors.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/connection_status.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/done_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/executing_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/hold_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_view.dart';

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

KioskSuggestion _card(String action, String summary) => KioskSuggestion(
      id: 'sc-$action',
      purpose: '공기청정기를 바꿀까요?',
      occurrences: 0,
      timeBand: '환경',
      applianceId: 'air_purifier',
      scenarioId: 'air_quality_high',
      commands: [
        KioskSuggestionCommand(targetId: 'air_purifier', route: 'thinq', action: action, summary: summary),
      ],
    );

final _powerOn = _card('set_power', '공기청정기 전원 켜기');
final _windHigh = _card('set_wind_strength', '공기청정기 바람 세기 강');

// 평가 15차(10/18) '더 하지 않아요' → 10/19 이미 보낸 것은 되돌리지 못할 수 있다고 사실대로.
const _stopNote = '정지를 누르면 더 보내지 않아요. 이미 보낸 것은 되돌리지 못할 수 있어요';
final _sending = find.byKey(const ValueKey('thinq-sending'));
final _result = find.byKey(const ValueKey('thinq-result'));
final _band = find.byKey(const ValueKey('status-band'));

void _noop() {}

/// 화면에 보이는 글 전부. 낱말 묶음 문자(U+2060·U+00A0)는 뗀다.
List<String> _texts(WidgetTester tester) => [
      for (final w in tester.widgetList<RichText>(find.byType(RichText)))
        w.text.toPlainText().replaceAll('⁠', '').replaceAll(' ', ' '),
    ];

Future<FakeKioskApi> _start(WidgetTester tester, {List<KioskSuggestion> cards = const []}) async {
  tester.view.physicalSize = const Size(800, 480);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final api = FakeKioskApi()
    ..applianceList = [kMicrowaveAppliance, _purifier]
    ..suggestionList = cards;
  await tester.pumpWidget(MaterialApp(home: KioskScreen(api: api, tts: FakeTts(), events: FakeEventStream())));
  await tester.pump();
  await tester.pump();
  return api;
}

Future<void> _approve(WidgetTester tester, FakeKioskApi api) async {
  api.suggestionList = [];
  await tester.tap(find.byKey(const ValueKey('suggestion-approve')));
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
  String job = 'job-1',
  String outcome = 'success',
  String receipt = 'accepted',
  String confirmation = 'state_confirmed',
  String detail = '전원 켜기로 바꿨어요.',
}) =>
    KioskStatus(
      running: false,
      lastJobId: job,
      lastStatus: outcome == 'success' ? 'succeeded' : outcome,
      lastOutcome: outcome,
      lastRoute: 'thinq',
      lastReceipt: receipt,
      lastConfirmation: confirmation,
      lastDetail: detail,
      lastExecutionMode: 'real',
      lastApplianceId: 'air_purifier',
    );

Future<void> _pumpView(WidgetTester tester, Widget child, {double scale = 1.0}) async {
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

KioskExecutingView _exec({bool thinq = true, String mode = 'real'}) => KioskExecutingView(
      executionMode: mode,
      title: thinq ? '공기청정기를 켤까요?' : '즉석밥 데워줘',
      target: thinq ? _purifier : kMicrowaveAppliance,
      thinqOnly: thinq,
      lastButtons: null,
      currentButton: thinq ? null : '즉석밥',
      currentAttempt: thinq ? null : 1,
      completedSteps: thinq ? null : 0,
      totalSteps: thinq ? 1 : 3,
      verificationConfidence: null,
      verificationDetail: null,
      onStop: _noop,
    );

void main() {
  group('1·2·4. LG 가전 보내는 중 — 하려는 일, 위 띠 동작, 정지 뜻', () {
    testWidgets('켜기: 공기청정기를 켜고 있어요 · 위 띠 공기청정기 켜기 · 명령 낱말 없음 · 정지 아래 사실 한 줄', (tester) async {
      final api = await _start(tester, cards: [_powerOn]);
      await _approve(tester, api);
      expect(_sending, findsOneWidget);
      expect(find.text('공기청정기를 켜고 있어요'), findsOneWidget);
      expect(find.descendant(of: _band, matching: find.text('공기청정기 켜기')), findsOneWidget);
      expect(_texts(tester).where((t) => t.contains('명령')), isEmpty);
      expect(find.text(_stopNote), findsOneWidget);
      // 정지 단추 이름·동작은 그대로.
      await tester.tap(find.text('정지'));
      await tester.pump();
      expect(api.stopCalls, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('바람 세기 강: 바람을 세게 바꾸고 있어요 · 위 띠 공기청정기 바람 세게', (tester) async {
      final api = await _start(tester, cards: [_windHigh]);
      await _approve(tester, api);
      expect(find.text('바람을 세게 바꾸고 있어요'), findsOneWidget);
      expect(find.descendant(of: _band, matching: find.text('공기청정기 바람 세게')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('연습은 정지 뜻 줄을 두지 않고 명령 낱말도 없다', (tester) async {
      await _pumpView(tester, _exec(mode: 'mock'));
      expect(find.text(_stopNote), findsNothing);
      expect(_texts(tester).where((t) => t.contains('명령')), isEmpty);
    });
  });

  group('3. 보내는 중 배치', () {
    for (final scale in [1.0, 1.22]) {
      testWidgets('가운데 한 열 · 정지 단추는 누름 장치 실행 화면과 같은 자리(글씨 x$scale)', (tester) async {
        await _pumpView(tester, _exec(thinq: false), scale: scale);
        final stopPhysical = tester.getRect(find.byKey(const ValueKey('kiosk-stop-area')));
        await _pumpView(tester, _exec(), scale: scale);
        expect(tester.takeException(), isNull);
        final stop = tester.getRect(find.byKey(const ValueKey('kiosk-stop-area')));
        expect(stop, stopPhysical);
        final line = tester.getRect(find.byKey(const ValueKey('thinq-sending-line')));
        expect((line.center.dx - 400).abs(), lessThan(24), reason: '하려는 일 줄이 화면 가운데');
        final spinner = tester.getRect(find.byType(CircularProgressIndicator));
        expect((spinner.center.dx - 400).abs(), lessThan(24));
        // 정지 뜻 줄은 정지 단추 왼쪽, 겹치지 않는다.
        final note = tester.getRect(find.text(_stopNote));
        expect(note.right, lessThanOrEqualTo(stop.left));
        expect(note.overlaps(stop), isFalse);
      });
    }
  });

  group('1·6. LG 가전 결과 창', () {
    testWidgets('확인됨 — 공기청정기가 켜졌어요 + 공기청정기에서 확인했어요(같은 뜻 세 번 금지)', (tester) async {
      final api = await _start(tester, cards: [_powerOn]);
      await _approve(tester, api);
      await _finish(tester, api, _done());
      expect(_result, findsOneWidget);
      expect(find.text('공기청정기가 켜졌어요'), findsOneWidget);
      expect(find.text('가전에서 확인했어요'), findsOneWidget);
      expect(find.text('가전에서 바뀐 것을 확인했어요'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    // 평가 11차(10/18): 제목에 가전 이름 — '켜 달라고 했어요'는 누가 누구에게인지 몰랐다.
    // 평가 15차(10/18): '보냈어요'는 기계가 한 일 — '공기청정기에 켜 달라고 했어요'(가전 이름 포함). 무엇을 볼지는 번호 안내가 한 번만.
    testWidgets('확인 못 함 — 공기청정기에 켜 달라고 했어요 / 켜졌는지는 아직 몰라요, 자동으로 닫지 않는다', (tester) async {
      final api = await _start(tester, cards: [_powerOn]);
      await _approve(tester, api);
      await _finish(tester, api,
          _done(outcome: 'unconfirmed', confirmation: 'none', detail: '가전에 전했지만 설정이 바뀌었는지 몰라요. 가전을 봐 주세요.'));
      expect(_result, findsOneWidget);
      expect(find.text('공기청정기에 켜 달라고 했어요'), findsOneWidget);
      expect(find.text('켜졌는지는 아직 몰라요'), findsOneWidget);
      expect(_texts(tester).where((t) => t.contains('명령')), isEmpty);
      await tester.pump(const Duration(seconds: 30));
      expect(_result, findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('이미 그 설정 — 이미 켜져 있어요 / 그대로 두었어요', (tester) async {
      final api = await _start(tester, cards: [_powerOn]);
      await _approve(tester, api);
      await _finish(
          tester,
          api,
          _done(
              receipt: 'not_dispatched',
              confirmation: 'already_at_target',
              detail: '이미 전원 켜기로 설정돼 있어요. 그래서 보내지 않았어요.'));
      expect(find.text('이미 켜져 있어요'), findsOneWidget);
      expect(find.text('그대로 두었어요'), findsOneWidget);
      expect(_texts(tester).where((t) => t.contains('명령')), isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('A. 이어받은 실행', () {
    testWidgets('폰이 켠 공기청정기(경로 thinq·1단계) — LG 가전 화면, 끝나면 공기청정기가 켜졌어요', (tester) async {
      final api = await _start(tester);
      api.statusResult = KioskStatus.fromJson({
        'running': true,
        'job_id': 'job-9',
        'appliance_id': 'air_purifier',
        'route': 'thinq',
        'total_steps': 1,
        'execution_mode': 'real',
      });
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(find.byType(KioskExecutingView), findsOneWidget);
      expect(_sending, findsOneWidget);
      expect(find.text('준비 중'), findsNothing);
      expect(find.text('공기청정기 설정을 바꾸고 있어요'), findsOneWidget);
      await _finish(tester, api, _done(job: 'job-9'));
      expect(_result, findsOneWidget);
      expect(find.text('공기청정기가 켜졌어요'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('누름 장치 경로(physical)는 종전 실행 화면 — LG 가전 화면으로 잘못 보이지 않는다', (tester) async {
      final api = await _start(tester);
      api.statusResult = KioskStatus.fromJson({
        'running': true,
        'job_id': 'job-8',
        'appliance_id': 'microwave',
        'route': 'physical',
        'total_steps': 1,
        'execution_mode': 'real',
      });
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(find.byType(KioskExecutingView), findsOneWidget);
      expect(_sending, findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('경로를 모르는 옛 서버·여러 단계는 종전 화면', (tester) async {
      final api = await _start(tester);
      api.statusResult = KioskStatus.fromJson({
        'running': true,
        'job_id': 'job-7',
        'appliance_id': 'air_purifier',
        'route': 'thinq',
        'total_steps': 2,
        'execution_mode': 'real',
      });
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(find.byType(KioskExecutingView), findsOneWidget);
      expect(_sending, findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('B. LG 가전 타일 전원', () {
    // 사용자 결정(10/19): 글자 띠 대신 아이콘 자체 — 읽은 꺼짐은 흐리게. 문제 표시는 없다.
    // 사용자 결정(10/19, 두 번째): 밝기 = 켜짐·작동 중 — 켜짐은 흰 아이콘(밝게), 꺼짐·모름·쉬는 중은 tileDim(흐리게). 강조색은 쓰지 않는다.
    testWidgets('서버가 꺼짐을 봤으면 아이콘 흐리게, 켜짐은 밝게(흰색)', (tester) async {
      final api = await _start(tester);
      api.powerOff = {'air_purifier'};
      await tester.pump(const Duration(seconds: 11));
      await tester.pump();
      final tile = find.byKey(const ValueKey('strip-air_purifier'));
      expect(tile, findsOneWidget);
      Color? icon() => tester.widget<Icon>(find.byKey(const ValueKey('tile-icon-air_purifier'))).color;
      expect(icon(), KioskColors.tileDim);
      expect(find.byKey(const ValueKey('tile-mark-air_purifier')), findsNothing);
      expect(find.descendant(of: tile, matching: find.text('준비됐어요')), findsNothing);
      api.powerOff = {};
      api.powerOn = {'air_purifier'};
      await tester.pump(const Duration(seconds: 11));
      await tester.pump();
      expect(icon(), Colors.white);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('5. 비 아이콘', () {
    testWidgets('날짜 옆·예보 칸의 비는 물방울이 아니라 비 오는 구름', (tester) async {
      final ambient = AmbientInfo(
        greeting: '좋은 아침이에요.',
        weatherSource: 'kma',
        now: const AmbientHour(label: '지금', hour: 8, icon: 'rain', temp: 14),
        hourly: const [
          AmbientHour(label: '9시', hour: 9, icon: 'rain', temp: 14),
          AmbientHour(label: '12시', hour: 12, icon: 'clear', temp: 18),
          AmbientHour(label: '15시', hour: 15, icon: 'rain', temp: 17),
        ],
      );
      await _pumpView(
          tester,
          KioskIdleView(
            now: DateTime(2026, 10, 18, 8, 20),
            connected: true,
            ambient: ambient,
            appliances: const [kMicrowaveAppliance],
            onSelectAppliance: (_) {},
            onOpenConnection: (_) {},
            onDndGesture: () {},
          ));
      // 지금 날씨는 예보 줄 첫 칸 '지금'(사용자 요청 10/18 — 날짜 옆에서 옮겼다).
      final outside = find.byKey(const ValueKey('ambient-hour-0'));
      expect(find.descendant(of: outside, matching: find.text('지금')), findsOneWidget);
      expect(find.byIcon(Icons.water_drop_outlined), findsNothing);
      expect(find.descendant(of: outside, matching: find.byKey(const ValueKey('weather-rain-cloud'))), findsOneWidget);
      expect(find.byKey(const ValueKey('weather-rain-cloud')), findsAtLeastNWidgets(2));
    });
  });

  group('7·8·9. 대기·정지·큰 글씨 단추', () {
    // 평가 11차(10/18): 상태 한 문장 — 제목이 '연습을 끝내는 중이에요'(아래 줄로 또 말하지 않는다).
    testWidgets('연습 중 대기에서 정지 — 연습을 끝내는 중이에요(가전을 봐 주세요 없음)', (tester) async {
      await _pumpView(
          tester,
          const KioskHoldView(
            appliance: kMicrowaveAppliance,
            holdState: 'hovering_stop',
            stopButton: '취소',
            executionMode: 'mock',
            elapsed: Duration(minutes: 1),
            stopRequested: true,
            onStop: _noop,
          ));
      expect(find.text('연습을 끝내는 중이에요'), findsOneWidget);
      expect(_texts(tester).where((t) => t.contains('가전을 봐 주세요')), isEmpty);
    });

    testWidgets('정지 확인 기다리는 중 — 위 띠는 가전·할 일 이름만, 멈추는 중·손 아이콘을 되풀이하지 않는다', (tester) async {
      await _pumpView(
          tester,
          KioskDoneView(
            success: false,
            label: '즉석밥 데워줘',
            target: kMicrowaveAppliance,
            executionMode: 'real',
            reason: KioskFailureReason.stopped,
            stopPending: true,
            onRetry: _noop,
            onManual: _noop,
            onDismiss: _noop,
          ));
      // 평가 17차(10/18): 큰 결과 원(모래시계)과 돌아가는 원을 뺐다 — 띠가 '멈추는 중'과 무엇을 말한다.
      expect(find.descendant(of: _band, matching: find.textContaining('멈추는 중')), findsOneWidget);
      // 휴리스틱 평가(10/18): 진행 표시가 없어 멈춘 화면처럼 보였다 — 큰 제목 왼쪽에 돌아가는 표시 하나(띠의 모래시계와 다른 자리).
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.descendant(of: _band, matching: find.byType(CircularProgressIndicator)), findsNothing);
      expect(find.descendant(of: _band, matching: find.textContaining('전자레인지')), findsOneWidget);
      expect(find.descendant(of: _band, matching: find.byIcon(Icons.pan_tool_outlined)), findsNothing);
      // 큰 제목은 한 번.
      expect(find.text('멈추는 중이에요'), findsOneWidget);
    });

    testWidgets('큰 글씨 사용자 정지 — 처음 화면으로가 보조 단추보다 위', (tester) async {
      await _pumpView(
          tester,
          KioskDoneView(
            success: false,
            label: '즉석밥 데워줘',
            target: kMicrowaveAppliance,
            reason: KioskFailureReason.stopped,
            // 멈춘 것을 확인한 정지 — 멈췄는지 모르면 골라 누르기가 없다(평가 15차 10/18, 안전).
            stopLevel: 'verified',
            onRetry: _noop,
            onManual: _noop,
            onDismiss: _noop,
          ),
          scale: 1.22);
      expect(tester.takeException(), isNull);
      final home = tester.getRect(find.byKey(const ValueKey('done-home')));
      final manual = tester.getRect(find.byKey(const ValueKey('done-manual')));
      expect(home.top, lessThan(manual.top));
      expect(home.bottom, lessThanOrEqualTo(480));
      expect(manual.bottom, lessThanOrEqualTo(480));
    });
  });

  group('10. 짧은 안내 줄 끝 마침표', () {
    testWidgets('처음 화면 알림 — 가운데 마침표만, 끝 마침표 없음', (tester) async {
      await _pumpView(
          tester,
          KioskIdleView(
            now: DateTime(2026, 10, 18, 8, 20),
            connected: true,
            ambient: const AmbientInfo(
                greeting: '좋은 아침이에요.',
                tip: AmbientTip(kind: 'rain', text: '오후 3시부터 비 예보가 있어요. 우산 챙기세요.', icon: 'rain')),
            appliances: const [kMicrowaveAppliance],
            onSelectAppliance: (_) {},
            onOpenConnection: (_) {},
            onDndGesture: () {},
          ));
      expect(find.text('오후 3시부터 비 예보가 있어요. 우산 챙기세요'), findsOneWidget);
      expect(find.text('오후 3시부터 비 예보가 있어요. 우산 챙기세요.'), findsNothing);
    });

    testWidgets('연결 창 — 본문·단계 끝 마침표 없음', (tester) async {
      const item = ConnectionItem(
        id: 'network',
        state: 'error',
        title: '와이파이 연결이 끊겼어요',
        message: '본체가 집 와이파이에 연결되지 않았어요. 날씨 안내도 볼 수 없어요.',
        fixes: ['공유기 전원이 켜져 있는지 확인해 주세요.', '그래도 안 되면 본체 전원을 껐다가 다시 켜 주세요.'],
      );
      await _pumpView(tester, KioskConnectionModal(item: item, checking: false, onRecheck: () {}, onClose: () {}));
      final shown = _texts(tester);
      for (final t in [
        '본체가 집 와이파이에 연결되지 않았어요. 날씨 안내도 볼 수 없어요',
        '공유기 전원이 켜져 있는지 확인해 주세요',
        '그래도 안 되면 본체 전원을 껐다가 다시 켜 주세요',
      ]) {
        expect(shown, contains(t));
      }
      expect(shown.where((t) => t.endsWith('.')), isEmpty);
    });
  });
}
