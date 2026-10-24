// 키오스크 직접 써 보기 점검 2차(2026-10-25 QA) — 큰 글씨에서 저장된 동작 칸이 아래 탭에 가리지 않고, 탭 화면에도
// 메뉴가 있으며, 큰 글씨 메뉴의 마지막 줄이 잘리지 않고, 건너뛴 자동 실행의 다음 시각을 보이고, 내가 고른 저장 동작
// 확인 카드에도 버튼판 그림과 누름 순서가 나온다.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/ambient.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/screens/kiosk_screen.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/services/kiosk_settings_store.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/suggestion_view.dart';

import 'kiosk_phase_test.dart' show FakeEventStream, FakeKioskApi, FakeTts;

const _routine30 = KioskRoutine(id: 'rt-30s', name: '30초 데우기', applianceIds: ['microwave'], pressCount: 2);
const _routineDefrost =
    KioskRoutine(id: 'rt-defrost', name: '해동하기', applianceIds: ['microwave'], pressCount: 2);

Future<FakeKioskApi> _pumpKiosk(WidgetTester tester,
    {Size size = const Size(800, 480),
    bool large = true,
    List<KioskRoutine> routines = const [_routine30, _routineDefrost],
    void Function(FakeKioskApi api)? setup}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final tempDir = Directory.systemTemp.createTempSync('kiosk-qa2');
  addTearDown(() => tempDir.deleteSync(recursive: true));
  final store = KioskSettingsStore(path: '${tempDir.path}${Platform.pathSeparator}settings.json');
  store.save(KioskSettings(largeText: large));
  final api = FakeKioskApi()
    ..applianceList = [kMicrowaveAppliance, kInductionAppliance]
    ..routinesResult = routines;
  setup?.call(api);
  await tester.pumpWidget(
      MaterialApp(home: KioskScreen(api: api, tts: FakeTts(), events: FakeEventStream(), settings: store)));
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  return api;
}

final _tabs = find.byKey(const ValueKey('kiosk-tab-bar'));

void _expectAboveTabs(WidgetTester tester, Finder f, String what) {
  expect(f, findsOneWidget, reason: what);
  final bar = tester.getRect(_tabs);
  final r = tester.getRect(f);
  expect(r.bottom, lessThanOrEqualTo(bar.top + 0.5), reason: '$what 이(가) 아래 탭에 가린다 $r / $bar');
  expect(f.hitTestable(), findsOneWidget, reason: '$what 이(가) 눌리지 않는다');
}

void main() {
  group('1. 큰 글씨 저장된 동작 칸이 스크롤 없이 다 보인다', () {
    for (final size in const [Size(800, 480), Size(1920, 1080)]) {
      testWidgets('${size.width.toInt()}x${size.height.toInt()} 루틴 2개 + 버튼 직접 고르기', (tester) async {
        await _pumpKiosk(tester, size: size);
        await tester.tap(find.byKey(const ValueKey('strip-microwave')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);
        for (final key in ['routine-rt-30s', 'routine-rt-defrost', 'manual-pick-buttons']) {
          final f = find.byKey(ValueKey(key));
          _expectAboveTabs(tester, f, key);
          final r = tester.getRect(f);
          expect(r.height, greaterThanOrEqualTo(48), reason: '$key 누름 높이');
          expect(r.width, greaterThanOrEqualTo(48), reason: '$key 누름 폭');
        }
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
    testWidgets('루틴 4개 + 버튼 직접 고르기(두 줄)도 납작한 칸으로 다 보인다', (tester) async {
      await _pumpKiosk(tester, routines: [
        for (var i = 0; i < 4; i++)
          KioskRoutine(id: 'rt-$i', name: '데우기 $i번', applianceIds: const ['microwave'], pressCount: 2),
      ]);
      await tester.tap(find.byKey(const ValueKey('strip-microwave')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
      for (final key in ['rt-0', 'rt-1', 'rt-2', 'rt-3']) {
        _expectAboveTabs(tester, find.byKey(ValueKey('routine-$key')), key);
      }
      _expectAboveTabs(tester, find.byKey(const ValueKey('manual-pick-buttons')), '버튼 직접 고르기');
      expect(tester.getRect(find.byKey(const ValueKey('manual-pick-buttons'))).height, greaterThanOrEqualTo(48));
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('2. 탭 화면(가전·자동 실행·기록)에도 같은 메뉴', () {
    for (final tab in ['appliances', 'auto', 'history']) {
      testWidgets("'$tab' 탭 위쪽 메뉴가 처음 화면과 같은 창을 연다", (tester) async {
        await _pumpKiosk(tester, large: false);
        await tester.tap(find.byKey(ValueKey('kiosk-tab-$tab')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        final menu = find.byKey(const ValueKey('idle-menu'));
        expect(menu, findsOneWidget, reason: '$tab 탭에 메뉴가 없다');
        expect(tester.getRect(menu).top, lessThan(120), reason: '메뉴는 위쪽');
        await tester.tap(menu);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        for (final key in ['dnd-entry', 'settings-entry', 'connections-entry', 'help-entry']) {
          expect(find.byKey(ValueKey(key)), findsOneWidget, reason: '$tab 메뉴 $key');
        }
        // 창이 떠 있으면 아래 탭을 숨긴다(처음 화면 메뉴와 같은 규칙).
        expect(_tabs.hitTestable(), findsNothing);
        await tester.tap(find.byKey(const ValueKey('idle-sheet-close')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byKey(const ValueKey('idle-sheet')), findsNothing);
        expect(find.byKey(ValueKey('kiosk-tab-$tab')), findsOneWidget, reason: '닫으면 그 탭 그대로');
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  });

  group('3. 큰 글씨 메뉴 창의 네 줄이 다 보인다', () {
    for (final size in const [Size(800, 480), Size(1920, 1080)]) {
      testWidgets('${size.width.toInt()}x${size.height.toInt()}', (tester) async {
        await _pumpKiosk(tester, size: size);
        await tester.tap(find.byKey(const ValueKey('idle-menu')));
        await tester.pump();
        expect(tester.takeException(), isNull);
        final sheet = tester.getRect(find.byKey(const ValueKey('idle-sheet')));
        final screen = Offset.zero & size;
        for (final key in ['dnd-entry', 'settings-entry', 'connections-entry', 'help-entry']) {
          final f = find.byKey(ValueKey(key));
          expect(f, findsOneWidget);
          final r = tester.getRect(f);
          expect(r.bottom, lessThanOrEqualTo(sheet.bottom + 0.5), reason: '$key 가 창 아래로 잘린다 $r / $sheet');
          expect(r.bottom, lessThanOrEqualTo(screen.bottom), reason: '$key 가 화면 밖');
          expect(r.height, greaterThanOrEqualTo(48), reason: '$key 누름 높이');
          expect(f.hitTestable(), findsOneWidget, reason: '$key 가 눌리지 않는다');
        }
        // 창이 스크롤로 마지막 줄을 숨기지 않는다.
        final scrollable = find.descendant(
            of: find.byKey(const ValueKey('idle-sheet')), matching: find.byType(Scrollable));
        for (final s in tester.stateList<ScrollableState>(scrollable)) {
          expect(s.position.maxScrollExtent, lessThanOrEqualTo(0.5), reason: '메뉴 창이 넘쳐 스크롤된다');
        }
        await tester.tap(find.byKey(const ValueKey('idle-sheet-close')));
        await tester.pump();
        await tester.pump();
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  });

  group('4. 건너뛴 자동 실행의 다음 시각', () {
    Map<String, dynamic> run({bool skipped = true, bool after = true}) => {
          'routine_id': 'rt-morning',
          'name': '아침 공기청정기 끄기',
          'at': '2026-10-26T07:00:00+09:00',
          'day_label': '내일',
          'auto': true,
          'mode_label': '자동 실행',
          'skipped': skipped,
          'skip_label': skipped ? '내일은 건너뛰어요' : null,
          'skip_action_label': '내일은 건너뛰기',
          if (skipped && after) 'next_after_skip_at': '2026-10-27T07:00:00+09:00',
          if (skipped && after) 'next_after_skip_day_label': '화요일',
        };

    test('모델 — 서버 값이 있을 때만 말을 만든다', () {
      expect(KioskNextRun.fromJson(run())!.afterSkipText, '다음은 화요일 오전 7:00');
      expect(KioskNextRun.fromJson(run(after: false))!.afterSkipText, isNull);
      expect(KioskNextRun.fromJson(run(skipped: false))!.afterSkipText, isNull);
    });

    for (final large in [false, true]) {
      testWidgets("'자동 실행' 탭 줄과 처음 화면 다음 루틴 줄 (큰 글씨 $large)", (tester) async {
        await _pumpKiosk(tester, large: large, setup: (api) {
          api.nextRun = KioskNextRun.fromJson(run());
          api.upcoming = [KioskNextRun.fromJson(run())!];
        });
        // 처음 화면 다음 루틴 줄 — 잘리지 않고 보인다.
        final home = find.text('다음은 화요일 오전 7:00');
        expect(home, findsOneWidget, reason: '처음 화면에 다음 시각이 없다');
        expect(tester.getRect(home).bottom, lessThanOrEqualTo(tester.getRect(_tabs).top + 0.5));
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const ValueKey('kiosk-tab-auto')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        final tab = find.text('다음은 화요일 오전 7:00');
        expect(tab, findsOneWidget, reason: "'자동 실행' 탭에 다음 시각이 없다");
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }

    testWidgets('값이 없으면 덧붙이지 않는다', (tester) async {
      await _pumpKiosk(tester, large: false, setup: (api) {
        api.nextRun = KioskNextRun.fromJson(run(after: false));
        api.upcoming = [KioskNextRun.fromJson(run(after: false))!];
      });
      expect(find.textContaining('다음은'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('kiosk-tab-auto')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('다음은'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('6. 내가 고른 저장 동작 확인 카드에도 버튼판 그림·누름 순서', () {
    KioskSuggestion card({List<KioskSuggestionCommand>? commands, bool user = true}) => KioskSuggestion(
          id: 'card-30s',
          purpose: "'30초 데우기' 루틴을 실행할까요?",
          occurrences: 0,
          reason: user ? '직접 실행을 눌렀어요' : '아침에 자주 하셨어요',
          timeBand: '루틴',
          applianceId: 'microwave',
          routineId: 'rt-30s',
          routineName: '30초 데우기',
          commands: commands ??
              const [
                KioskSuggestionCommand(
                    targetId: 'microwave', route: 'physical', buttons: ['30초', '시작'], summary: '전자레인지 30초 → 시작'),
              ],
        );

    Future<void> pumpCard(WidgetTester tester, KioskSuggestion s) async {
      tester.view.physicalSize = const Size(800, 480);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: KioskSuggestionView(
                  suggestion: s,
                  target: kMicrowaveAppliance,
                  cdRemaining: 20,
                  cdTotal: 20,
                  startedByUser: true,
                  onApprove: () {},
                  onReject: () {}))));
      await tester.pump();
    }

    testWidgets('전자레인지 30초 → 시작: 그림과 순서 번호', (tester) async {
      await pumpCard(tester, card());
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('panel-picture')), findsOneWidget, reason: '확인 카드에 버튼판 그림이 없다');
      expect(find.byKey(const ValueKey('suggestion-panel-caption')), findsOneWidget);
      // 누르는 순서 번호(1·2)가 그림 위에 있다.
      final picture = find.byKey(const ValueKey('panel-picture'));
      expect(find.descendant(of: picture, matching: find.text('1')), findsWidgets);
      expect(find.descendant(of: picture, matching: find.text('2')), findsWidgets);
      expect(find.byKey(const ValueKey('suggestion-approve')), findsOneWidget);
    });

    testWidgets('ThinQ가 섞이거나 판에 없는 버튼이면 그림 대신 지금처럼 목록', (tester) async {
      await pumpCard(
          tester,
          card(commands: const [
            KioskSuggestionCommand(targetId: 'microwave', route: 'physical', buttons: ['30초', '시작'], summary: '전자레인지'),
            KioskSuggestionCommand(targetId: 'air_purifier', route: 'thinq', action: 'set_power', summary: '공기청정기 켜기'),
          ]));
      expect(find.byKey(const ValueKey('panel-picture')), findsNothing);
      await pumpCard(
          tester,
          card(commands: const [
            KioskSuggestionCommand(targetId: 'microwave', route: 'physical', buttons: ['없는버튼'], summary: '전자레인지'),
          ]));
      expect(find.byKey(const ValueKey('panel-picture')), findsNothing);
    });
  });
}
