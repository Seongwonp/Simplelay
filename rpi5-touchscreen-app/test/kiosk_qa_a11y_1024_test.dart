// 키오스크 QA(2026-10-24) — 방해 금지·설정·사용 방법·메뉴·연결 창이 떠 있으면 화면 읽기도 그 창만 읽는다(뒤 처음 화면 단추가
// 읽히고 눌리지 않게). 누르기 확인 창(manual-press-confirm)과 같은 방식. 닫기 단추에는 무엇을 닫는지 이름이 있다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/ambient.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/screens/kiosk_screen.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/settings_overlay.dart';

import 'kiosk_phase_test.dart' show FakeEventStream, FakeKioskApi, FakeTts;

const _menuLabel = '메뉴. 방해 금지, 설정, 연결, 사용 방법';

Future<void> _pump(WidgetTester tester, {bool pressDown = false}) async {
  tester.view.physicalSize = const Size(800, 480);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final api = FakeKioskApi()..applianceList = [kMicrowaveAppliance];
  if (pressDown) {
    api.connectionsResult = const [
      ConnectionItem(id: 'network', state: 'ok', title: '', message: ''),
      ConnectionItem(id: 'press', state: 'error', title: '누름 장치와 연결이 끊겼어요', message: ''),
    ];
  }
  await tester.pumpWidget(MaterialApp(home: KioskScreen(api: api, tts: FakeTts(), events: FakeEventStream())));
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _tap(WidgetTester tester, String key) async {
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void _backgroundHidden(String why) {
  expect(find.semantics.byLabel(_menuLabel), findsNothing, reason: '$why: 뒤 처음 화면 메뉴 단추가 읽힌다');
  expect(find.semantics.byLabel(RegExp(r'탭$')), findsNothing, reason: '$why: 아래 탭이 읽힌다');
}

void main() {
  testWidgets('평소에는 메뉴 단추가 읽힌다(시험의 기준)', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester);
    expect(find.semantics.byLabel(_menuLabel), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    handle.dispose();
  });

  testWidgets('메뉴·사용 방법 창', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester);
    await _tap(tester, 'idle-menu');
    _backgroundHidden('메뉴');
    await _tap(tester, 'help-entry');
    _backgroundHidden('사용 방법');
    await _tap(tester, 'help-close');
    expect(find.semantics.byLabel(_menuLabel), findsOneWidget, reason: '창을 닫으면 다시 읽힌다');
    await tester.pumpWidget(const SizedBox.shrink());
    handle.dispose();
  });

  testWidgets('방해 금지 창 — 닫기에 이름', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester);
    await _tap(tester, 'idle-menu');
    await _tap(tester, 'dnd-entry');
    _backgroundHidden('방해 금지');
    expect(find.semantics.byLabel('방해 금지 창 닫기'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    handle.dispose();
  });

  testWidgets('설정 창 — 닫기에 이름', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester);
    await _tap(tester, 'idle-menu');
    await _tap(tester, 'settings-entry');
    expect(find.byKey(const ValueKey('settings-close')), findsOneWidget);
    _backgroundHidden('설정');
    expect(find.semantics.byLabel('설정 닫기'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    handle.dispose();
  });

  // 지금 구성은 Wi-Fi 콘센트 주소를 쓰지 않는다 — 사용자 화면에는 칸 자체가 없다. 코드는 켜면 그대로 쓴다.
  testWidgets("설정에 '설치용' 칸과 콘센트 주소 입력이 보이지 않는다", (tester) async {
    await _pump(tester);
    await _tap(tester, 'idle-menu');
    await _tap(tester, 'settings-entry');
    expect(find.byKey(const ValueKey('settings-installer')), findsNothing);
    expect(find.text('설치용'), findsNothing);
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.byKey(const ValueKey('settings-close')));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets("켜 두면 '설치용'을 펼쳐 콘센트 주소를 넣을 수 있다", (tester) async {
    tester.view.physicalSize = const Size(800, 480);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: KioskSettingsOverlay(
      currentAppliance: kMicrowaveAppliance,
      appliances: const [kMicrowaveAppliance],
      api: FakeKioskApi(),
      ttsEnabled: true,
      onTtsChanged: (_) {},
      onDismiss: () {},
      showInstallerSection: true,
    ))));
    await tester.pump();
    await tester.pump();
    final installer = find.byKey(const ValueKey('settings-installer'));
    await tester.scrollUntilVisible(installer, 100,
        scrollable: find.descendant(of: find.byType(KioskSettingsOverlay), matching: find.byType(Scrollable)).first);
    await tester.tap(installer);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('settings-installer-note')), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('연결 창', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, pressDown: true);
    await _tap(tester, 'idle-status-chip');
    _backgroundHidden('연결');
    await tester.pumpWidget(const SizedBox.shrink());
    handle.dispose();
  });
}
