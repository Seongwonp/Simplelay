import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/ambient.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/screens/kiosk_screen.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';

import 'kiosk_phase_test.dart' show FakeEventStream, FakeKioskApi, FakeTts;

const _routine = KioskRoutine(
  id: 'rt-30s', name: '30초 데우기', applianceIds: ['microwave'], pressCount: 2,
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
  await tester.pumpWidget(MaterialApp(home: KioskScreen(
    api: api, tts: FakeTts(), events: FakeEventStream(),
  )));
  await tester.pump();
  return api;
}

void main() {
  testWidgets('말하기를 누르면 듣기 뒤 알아들은 말과 확인 카드를 보인다', (tester) async {
    final api = await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('kiosk-voice-button')));
    await tester.pump();
    expect(find.text('듣고 있어요… (5초)'), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
    expect(find.text('생각하고 있어요'), findsOneWidget);
    api.voiceListenPending!.complete(const KioskVoiceListenResult(
      text: '공기청정기 켜 줘', reason: 'ok',
      proposal: KioskIntentProposal(
        id: 'voice-1', question: '공기청정기를 켤까요?', label: '공기청정기 켜기',
        kind: 'thinq', applianceId: 'air-purifier', action: 'set', args: {'power': 'on'},
      ),
    ));
    await tester.pump();
    await tester.pump();
    expect(find.text('들은 말: 공기청정기 켜 줘'), findsOneWidget);
    expect(find.byKey(const ValueKey('voice-proposal-yes')), findsOneWidget);
  });

  testWidgets('말이 없으면 다시 누르라는 안내를 보인다', (tester) async {
    final api = await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('kiosk-voice-button')));
    await tester.pump();
    api.voiceListenPending!.complete(
      const KioskVoiceListenResult(text: '', reason: 'no_speech'),
    );
    await tester.pump();
    expect(find.text('잘 못 들었어요. 다시 눌러 주세요'), findsOneWidget);
    expect(find.byKey(const ValueKey('kiosk-voice-button')), findsOneWidget);
  });
}
