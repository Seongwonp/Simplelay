import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/ambient.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/screens/kiosk_screen.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';

import 'kiosk_phase_test.dart' show FakeEventStream, FakeKioskApi, FakeTts;

const _routine = KioskRoutine(
  id: 'rt-30s',
  name: '30초 데우기',
  applianceIds: ['microwave'],
  pressCount: 2,
);

Future<FakeKioskApi> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1024, 600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final api = FakeKioskApi()
    ..applianceList = [kMicrowaveAppliance]
    ..routinesResult = [_routine]
    ..voiceListenPending = Completer<KioskVoiceListenResult>();
  await tester.pumpWidget(MaterialApp(
      home: KioskScreen(
    api: api,
    tts: FakeTts(),
    events: FakeEventStream(),
  )));
  await tester.pump();
  return api;
}

void main() {
  testWidgets('말하기는 메뉴 왼쪽의 같은 크기 위쪽 단추다', (tester) async {
    await _pump(tester);

    final voice = find.byKey(const ValueKey('kiosk-voice-button'));
    final menu = find.byKey(const ValueKey('idle-menu'));
    expect(voice, findsOneWidget);
    expect(tester.getSize(voice), const Size(60, 60));
    expect(tester.getSize(menu), const Size(60, 60));
    expect(tester.getRect(voice).right, lessThan(tester.getRect(menu).left));
    expect(find.descendant(of: voice, matching: find.byIcon(Icons.mic_none)),
        findsOneWidget);
    expect(
        find.descendant(of: voice, matching: find.text('말하기')), findsOneWidget);
  });

  testWidgets('말하기를 누르면 듣기 뒤 알아들은 말과 확인 카드를 보인다', (tester) async {
    final api = await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('kiosk-voice-button')));
    await tester.pump();
    expect(find.byKey(const ValueKey('kiosk-voice-modal')), findsOneWidget);
    expect(find.text('듣고 있어요'), findsOneWidget);
    expect(find.text('5초'), findsOneWidget);
    expect(find.byIcon(Icons.mic), findsOneWidget);
    expect(find.byKey(const ValueKey('kiosk-tab-bar')), findsNothing);

    await tester.pump(const Duration(seconds: 5));
    expect(find.text('생각하고 있어요'), findsOneWidget);
    api.voiceListenPending!.complete(const KioskVoiceListenResult(
      text: '공기청정기 켜 줘',
      reason: 'ok',
      proposal: KioskIntentProposal(
        id: 'voice-1',
        question: '공기청정기를 켤까요?',
        label: '공기청정기 켜기',
        kind: 'thinq',
        applianceId: 'air-purifier',
        action: 'set',
        args: {'power': 'on'},
      ),
    ));
    await tester.pump();
    await tester.pump();
    expect(find.text('본체에서 말한 내용'), findsOneWidget);
    expect(find.byIcon(Icons.mic), findsOneWidget);
    expect(find.byIcon(Icons.smartphone), findsNothing);
    expect(find.text('들은 말: 공기청정기 켜 줘'), findsOneWidget);
    expect(find.byKey(const ValueKey('voice-proposal-yes')), findsOneWidget);
  });

  testWidgets('말이 없으면 다시 말하기와 닫기를 보인다', (tester) async {
    final api = await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('kiosk-voice-button')));
    await tester.pump();
    api.voiceListenPending!.complete(
      const KioskVoiceListenResult(text: '', reason: 'no_speech'),
    );
    await tester.pump();
    expect(find.text('잘 못 들었어요'), findsOneWidget);
    expect(find.byKey(const ValueKey('kiosk-voice-retry')), findsOneWidget);
    expect(find.byKey(const ValueKey('kiosk-voice-close')), findsOneWidget);
    expect(find.byKey(const ValueKey('kiosk-tab-bar')), findsNothing);
  });

  testWidgets('취소하면 창을 닫고 늦은 결과를 무시한다', (tester) async {
    final api = await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('kiosk-voice-button')));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('kiosk-voice-cancel')));
    await tester.pump();
    expect(find.byKey(const ValueKey('kiosk-voice-modal')), findsNothing);
    expect(find.byKey(const ValueKey('kiosk-tab-bar')), findsOneWidget);

    api.voiceListenPending!.complete(const KioskVoiceListenResult(
      text: '전기 켜 줘',
      reason: 'ok',
      proposal: KioskIntentProposal(
        id: 'late',
        question: '전기를 켤까요?',
        label: '전기 켜기',
        kind: 'thinq',
        applianceId: 'light',
        action: 'set',
        args: {'power': 'on'},
      ),
    ));
    await tester.pump();
    expect(find.byKey(const ValueKey('voice-proposal-yes')), findsNothing);
  });
}
