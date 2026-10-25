// 시안 B(키오스크 전면 개편, 사용자 승인 2026-10-24) — 밝은 화면 기본·어두운 화면 고르기, 처음 화면 '무엇을 할까요?',
// 내 가전 저장된 동작 먼저, 결과 화면 가전 그림·어두운 표시창. 승인·정지·연습 구분 같은 안전 계약은 기존 시험이 지킨다.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/ambient.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/screens/kiosk_screen.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/services/kiosk_settings_store.dart';
import 'package:simplelay_touchscreen/theme/kiosk_colors.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/appliance_art.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/appliance_strip.dart' show kTileUnusablePress;
import 'package:simplelay_touchscreen/widgets/kiosk/done_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/executing_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/help_guide.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_featured.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/kiosk_canvas.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/manual_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/suggestion_view.dart';

import 'kiosk_phase_test.dart' show FakeKioskApi, FakeTts, FakeEventStream;
import 'support/idle_menu.dart';

const _morning = KioskRoutine(id: 'morning', name: '아침 데우기', applianceIds: ['microwave'], pressCount: 2);

Future<void> _pumpKiosk(WidgetTester tester, FakeKioskApi api, {KioskSettingsStore? settings}) async {
  tester.view.physicalSize = const Size(800, 480);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: KioskScreen(api: api, tts: FakeTts(), events: FakeEventStream(), settings: settings),
  ));
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

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

KioskIdleView _idle({List<KioskRoutine>? routines, ValueChanged<KioskRoutine>? onRoutine}) => KioskIdleView(
      now: DateTime(2026, 10, 24, 15, 12),
      connected: true,
      appliances: const [kMicrowaveAppliance],
      onSelectAppliance: (_) {},
      onOpenConnection: (_) {},
      onDndGesture: () {},
      routines: routines,
      onRoutine: onRoutine,
    );

void main() {
  tearDown(() {
    KioskColors.setDarkMode(false);
    KioskColors.setHighContrast(false);
    KioskColors.setQuietNight(false);
  });

  group('밝은 화면 기본 · 어두운 화면 고르기', () {
    test('기본은 밝은 화면(폰 팔레트) — 주 색 청록, 채운 면 위 흰 글자', () {
      expect(KioskColors.standard, same(KioskColors.light));
      expect(KioskColors.bg, const Color(0xFFF4F6FA));
      expect(KioskColors.primary, const Color(0xFF175C55));
      expect(KioskColors.onAccent, const Color(0xFFFFFFFF));
      expect(KioskColors.darkMode, isFalse);
    });

    test('고대비는 어두운·밝은 화면 고르기보다 우선하고, 끄면 고른 밝기로 돌아간다', () {
      KioskColors.setDarkMode(true);
      expect(KioskColors.bg, KioskColors.dark.bg);
      KioskColors.setHighContrast(true);
      expect(KioskColors.bg, const Color(0xFF000000));
      KioskColors.setHighContrast(false);
      expect(KioskColors.bg, KioskColors.dark.bg);
    });

    testWidgets("설정 '어두운 화면' — 켜면 바로 어두운 색, 같은 파일에 저장, 다시 켜도 유지", (tester) async {
      final dir = Directory.systemTemp.createTempSync('kiosk-dark');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = KioskSettingsStore(path: '${dir.path}/settings.json');
      final api = FakeKioskApi()..applianceList = [kMicrowaveAppliance];
      await _pumpKiosk(tester, api, settings: store);
      expect(tester.widget<Scaffold>(find.byType(Scaffold).first).backgroundColor, KioskColors.light.bg);
      await tapIdleMenuItem(tester, 'settings-entry');
      await tester.pump();
      final row = find.byKey(const ValueKey('settings-dark-mode'));
      expect(row, findsOneWidget);
      await tester.ensureVisible(row);
      await tester.pump();
      await tester.tap(find.descendant(of: row, matching: find.byType(Switch)));
      await tester.pump();
      expect(KioskColors.darkMode, isTrue);
      // 설정 창이 떠 있어 바탕은 어두운 팔레트 위에 창 막 색(10/24 — 가장자리까지 같은 막).
      expect(tester.widget<Scaffold>(find.byType(Scaffold).first).backgroundColor,
          Color.alphaBlend(Colors.black.withValues(alpha: KioskCanvas.scrimAlpha), KioskColors.dark.bg));
      expect(store.load().darkMode, isTrue);
      expect(File('${dir.path}/settings.json').readAsStringSync(), contains('"dark_mode":true'));
      await tester.pumpWidget(const SizedBox.shrink());
      expect(KioskColors.darkMode, isFalse); // 화면이 사라지면 기본(밝은 화면)

      await _pumpKiosk(tester, api, settings: store);
      expect(KioskColors.darkMode, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('조용한 시간 어둡게 동안은 밝은 화면도 어두운 색 — 끝나면 밝은 색으로', (tester) async {
      final api = FakeKioskApi()
        ..applianceList = [kMicrowaveAppliance]
        ..healthResult = const HealthStatus(ok: true, quietScheduleActive: true);
      await _pumpKiosk(tester, api);
      expect(find.byKey(const ValueKey('idle-quiet')), findsOneWidget);
      expect(KioskColors.quietNight, isTrue);
      expect(KioskColors.bg, KioskColors.dark.bg);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(KioskColors.quietNight, isFalse);
      expect(KioskColors.bg, KioskColors.light.bg);
    });
  });

  group("처음 화면 '무엇을 할까요?'", () {
    testWidgets('저장된 동작이 있으면 카드 하나 — 누르면 루틴 콜백만(바로 누르지 않는다)', (tester) async {
      final tapped = <String>[];
      await _pumpView(tester, _idle(routines: const [_morning], onRoutine: (r) => tapped.add(r.id)));
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('idle-featured')), findsOneWidget);
      expect(find.text('무엇을 할까요?'), findsOneWidget);
      expect(find.text('아침 데우기'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('idle-featured-run')));
      expect(tapped, ['morning']);
    });

    testWidgets('저장된 동작이 없거나 그 가전이 목록에 없으면 카드가 없다(지어내지 않는다)', (tester) async {
      await _pumpView(tester, _idle(routines: const [], onRoutine: (_) {}));
      expect(find.byKey(const ValueKey('idle-featured')), findsNothing);
      await _pumpView(
          tester,
          _idle(routines: const [KioskRoutine(id: 'w', name: '빨래', applianceIds: ['washer'])], onRoutine: (_) {}));
      expect(find.byKey(const ValueKey('idle-featured')), findsNothing);
    });

    // 첫 사용 평가(10/24): 누름 장치가 끊겼는데 '실행하기'가 눌리는 모양이었다 — 흐리게, 이유 한 줄, 눌러도 부르지 않는다.
    testWidgets('누름 장치가 끊겨 할 수 있는 동작이 없으면 실행하기를 흐리게 하고 이유를 적고, 눌러도 부르지 않는다', (tester) async {
      final tapped = <String>[];
      await _pumpView(
          tester,
          KioskIdleView(
            now: DateTime(2026, 10, 24, 15, 12),
            connected: true,
            appliances: const [kMicrowaveAppliance],
            connections: const [ConnectionItem(id: 'press', state: 'error', title: '누름 장치', message: '연결되지 않았어요')],
            onSelectAppliance: (_) {},
            onOpenConnection: (_) {},
            onDndGesture: () {},
            routines: const [_morning],
            onRoutine: (r) => tapped.add(r.id),
          ));
      expect(tester.takeException(), isNull);
      final card = find.byKey(const ValueKey('idle-featured'));
      expect(card, findsOneWidget);
      // 화면에는 짧게(이유는 위 안내 띠), 읽을 때는 이유까지.
      expect(find.descendant(of: card, matching: find.text('지금은 쓸 수 없어요')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('지금은 쓸 수 없어요.*$kTileUnusablePress')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('idle-featured-run')), warnIfMissed: false);
      await tester.pump();
      expect(tapped, isEmpty);
    });

    // 첫 사용 평가 2차(10/24): 흐린 테두리 '실행하기'도 눌리는 모양이었다 — 막히면 '해결 방법 보기'로 바꾸고, 누르면 가전 줄
    // '!'·위 안내 띠와 같은 연결 창을 연다. 서버(루틴) 콜백은 부르지 않는다.
    testWidgets("막힌 카드는 '실행하기' 대신 '해결 방법 보기' — 누르면 같은 연결 창, 루틴은 부르지 않는다", (tester) async {
      final tapped = <String>[];
      final opened = <String>[];
      await _pumpView(
          tester,
          KioskIdleView(
            now: DateTime(2026, 10, 24, 15, 12),
            connected: true,
            appliances: const [kMicrowaveAppliance],
            connections: const [ConnectionItem(id: 'press', state: 'error', title: '누름 장치', message: '연결되지 않았어요')],
            onSelectAppliance: (_) {},
            onOpenConnection: (c) => opened.add(c.id),
            onDndGesture: () {},
            routines: const [_morning],
            onRoutine: (r) => tapped.add(r.id),
          ));
      final card = find.byKey(const ValueKey('idle-featured'));
      expect(find.descendant(of: card, matching: find.text('실행하기')), findsNothing);
      // 첫 사용 평가 4차(10/24): 위 연결 문제 띠와 카드에 같은 '해결 방법 보기'가 둘 — 띠가 있으면 카드는 되풀이하지 않는다.
      expect(find.descendant(of: card, matching: find.text('해결 방법 보기')), findsNothing);
      expect(find.descendant(of: card, matching: find.text('지금은 쓸 수 없어요')), findsOneWidget);
      expect(find.text('해결 방법 보기'), findsOneWidget);
      // 읽을 때는 이유까지 그대로.
      expect(find.bySemanticsLabel(RegExp('지금은 쓸 수 없어요.*$kTileUnusablePress')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('idle-featured-run')));
      await tester.pump();
      expect(tapped, isEmpty);
      expect(opened, ['press']);
    });

    testWidgets("위 띠가 '해결 방법 보기'를 보이지 않을 때만 막힌 카드가 그 단추를 그린다", (tester) async {
      Future<void> pump(bool inBanner) => _pumpView(
          tester,
          KioskFeaturedAction(
            routine: _morning,
            appliance: kMicrowaveAppliance,
            sizeLabel: '',
            onRun: () {},
            blockedReason: kTileUnusablePress,
            onHelp: () {},
            helpInBanner: inBanner,
          ));
      await pump(false);
      expect(find.text('해결 방법 보기'), findsOneWidget);
      await pump(true);
      expect(find.text('해결 방법 보기'), findsNothing);
      expect(find.text('지금은 쓸 수 없어요'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('지금은 쓸 수 없어요.*$kTileUnusablePress')), findsOneWidget);
    });

    // 시안 B 홈(10/24): 큰 시계 칸이 위 줄로 올라가 큰 글씨에서도 카드 자리가 있다 — 가전 줄 하한을 지킬 때만 둔다.
    testWidgets('큰 글씨에서도 카드는 가전 줄을 밀어내지 않을 때만(잘리지 않는다)', (tester) async {
      await _pumpView(tester, _idle(routines: const [_morning], onRoutine: (_) {}), scale: 1.22);
      expect(tester.takeException(), isNull);
      final card = find.byKey(const ValueKey('idle-featured'));
      expect(card, findsOneWidget);
      expect(tester.getRect(card).bottom, lessThanOrEqualTo(480));
      final tile = tester.getRect(find.byKey(const ValueKey('tile-icon-microwave')));
      expect(tile.top, greaterThanOrEqualTo(tester.getRect(card).bottom));
    });

    testWidgets('키오스크에서 누르면 확인 카드(승인)로 간다 — 실행 요청은 없다', (tester) async {
      final api = FakeKioskApi()
        ..applianceList = [kMicrowaveAppliance]
        ..routinesResult = const [_morning]
        ..triggerResult = const RoutineTriggerResult(
          suggestion: KioskSuggestion(
            id: 'card-1',
            purpose: '아침 데우기',
            occurrences: 0,
            applianceId: 'microwave',
            steps: ['30초', '시작'],
            routineId: 'morning',
            routineName: '아침 데우기',
          ),
        );
      await _pumpKiosk(tester, api);
      await tester.tap(find.byKey(const ValueKey('idle-featured-run')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(api.triggeredRoutineIds, ['morning']);
      expect(find.byType(KioskSuggestionView), findsOneWidget);
      expect(api.executeCalls, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  // 첫 사용 평가 2차(10/24): 키오스크에는 자동 실행 끄기가 없다(설계) — 어디서 하는지 사용 방법이 말한다. 최근 기록은 키오스크
  // 아래 '기록' 탭에 있다(QA 10/24).
  test("사용 방법: '자동 실행 끄기는 휴대폰 앱에서, 최근 기록은 기록 탭에서' 안내가 있다", () {
    expect(
        kHelpPages.any((p) => p.body.contains("화면 아래 '기록'") && p.body.contains('자동 실행 끄기') && p.body.contains('휴대폰 앱')),
        isTrue);
  });

  group('내 가전 — 저장된 동작 먼저', () {
    Widget manual({List<KioskRoutine>? routines, List<String>? pressed, List<String>? ran}) => KioskManualView(
          appliance: kMicrowaveAppliance,
          onExecute: (b) => pressed?.add(b.label),
          onCancel: () {},
          routines: routines,
          onRoutine: (r) => ran?.add(r.id),
        );

    testWidgets('루틴이 있으면 큰 칸이 먼저, 버튼판은 버튼 직접 고르기 뒤 — 뒤로는 저장된 동작으로', (tester) async {
      final pressed = <String>[], ran = <String>[];
      await _pumpView(tester, manual(routines: const [_morning], pressed: pressed, ran: ran));
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('routine-morning')), findsOneWidget);
      expect(find.byKey(const ValueKey('manual-pick-buttons')), findsOneWidget);
      expect(find.text('해동'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('routine-morning')));
      expect(ran, ['morning']);
      expect(pressed, isEmpty);

      await tester.tap(find.byKey(const ValueKey('manual-pick-buttons')));
      await tester.pump();
      expect(find.text('해동'), findsOneWidget);
      // 버튼 하나를 눌러도 바로 누르지 않는다 — 한 번 묻는다(기존 계약 그대로).
      await tester.tap(find.text('해동'));
      await tester.pump();
      expect(pressed, isEmpty);
      expect(find.byKey(const ValueKey('manual-press-confirm')), findsOneWidget);
      await tester.tap(find.text('닫기'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('kiosk-back')));
      await tester.pump();
      expect(find.byKey(const ValueKey('manual-pick-buttons')), findsOneWidget);
    });

    testWidgets('루틴이 없으면 버튼판을 바로 — 큰 글씨에서도 넘치지 않는다', (tester) async {
      await _pumpView(tester, manual(routines: const []));
      expect(find.text('해동'), findsOneWidget);
      expect(find.byKey(const ValueKey('manual-pick-buttons')), findsNothing);
      await _pumpView(tester, manual(routines: const [_morning]), scale: 1.22);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('routine-morning')), findsOneWidget);
    });

    testWidgets('머리에 폰과 같은 가전 그림', (tester) async {
      await _pumpView(tester, manual(routines: const []));
      final art = tester.widget<KioskApplianceArt>(
          find.descendant(of: find.byKey(const ValueKey('manual-art')), matching: find.byType(KioskApplianceArt)));
      expect(art.category, 'microwave');
    });
  });

  group('실행·결과 — 가전 그림과 어두운 표시창', () {
    testWidgets('실행 화면: 누를 순서는 어두운 표시창 안 — 왼쪽 칸이 빠듯해 그림 칸은 두지 않는다', (tester) async {
      await _pumpView(
          tester,
          KioskExecutingView(
            executionMode: 'real',
            target: kMicrowaveAppliance,
            title: '아침 데우기',
            lastButtons: null,
            currentButton: '시작',
            currentAttempt: 1,
            totalSteps: 2,
            completedSteps: 1,
            verificationConfidence: null,
            verificationDetail: null,
            doneButtons: const ['30초'],
            onStop: () {},
          ));
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('who-row')), findsNothing);
      expect(find.ancestor(of: find.byKey(const ValueKey('exec-step-trail')), matching: find.byType(KioskGlassPanel)),
          findsOneWidget);
      // 정지는 그대로 닿는다.
      expect(find.text('정지'), findsOneWidget);
    });

    testWidgets('결과 화면: 가전 그림 칸, 큰 글씨에서는 두지 않는다', (tester) async {
      Widget done() => KioskDoneView(
          success: true, executionMode: 'real', label: '아침 데우기', target: kMicrowaveAppliance, onDismiss: () {});
      await _pumpView(tester, done());
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('who-row')), findsOneWidget);
      await _pumpView(tester, done(), scale: 1.22);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('who-row')), findsNothing);
    });
  });
}
