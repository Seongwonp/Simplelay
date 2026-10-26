// 10/26 — 화면 밝기 자동(방 밝기 따라가기)과 휴대폰에서 말한 확인 질문을 키오스크에도 띄우기.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/screens/kiosk_screen.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/services/kiosk_settings_store.dart';
import 'package:simplelay_touchscreen/theme/kiosk_colors.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/executing_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/voice_proposal_view.dart';

import 'kiosk_phase_test.dart' show FakeKioskApi, FakeTts, FakeEventStream;

Future<void> _pump(WidgetTester tester, FakeKioskApi api, {FakeTts? tts, KioskSettingsStore? settings}) async {
  tester.view.physicalSize = const Size(800, 480);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: KioskScreen(api: api, tts: tts ?? FakeTts(), events: FakeEventStream(), settings: settings),
  ));
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _poll(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 2));
  await _settle(tester);
}

/// 화면 바꿈 효과(250 ms)까지 기다린다.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

const _air = KioskIntentProposal(
    id: 'p1', question: '공기청정기를 켤까요?', label: '공기청정기 전원 켜기', kind: 'thinq',
    applianceId: 'air', action: 'set_power', args: {'power': 'POWER_ON'});

const _rice = KioskIntentProposal(
    id: 'p2', question: '즉석밥을 데울까요?', label: '전자레인지 즉석밥 데우기', kind: 'buttons',
    applianceId: 'microwave', buttons: ['즉석밥', '시작']);

void main() {
  tearDown(() {
    KioskColors.setDarkMode(false);
    KioskColors.setHighContrast(false);
  });

  group('화면 밝기 — 밝게·어둡게·자동', () {
    test('옛 설정 옮기기: 어두운 화면 켜짐 → 어둡게, 꺼짐·없음 → 자동, 새 값 그대로', () {
      expect(KioskSettings.fromJson({'dark_mode': true}).screenTone, KioskScreenTone.dark);
      expect(KioskSettings.fromJson({'dark_mode': false}).screenTone, KioskScreenTone.auto);
      expect(KioskSettings.fromJson({}).screenTone, KioskScreenTone.auto);
      expect(KioskSettings.fromJson({'screen_tone': 'light', 'dark_mode': true}).screenTone, KioskScreenTone.light);
      expect(const KioskSettings().screenTone, KioskScreenTone.auto);
      final json = const KioskSettings(screenTone: KioskScreenTone.dark).toJson();
      expect(json['screen_tone'], 'dark');
      expect(KioskSettings.fromJson(jsonDecode(jsonEncode(json)) as Map<String, dynamic>).screenTone,
          KioskScreenTone.dark);
    });

    testWidgets('자동 — 방이 어두우면 어둡게, 밝으면 밝게, 모름이면 그대로', (tester) async {
      final api = FakeKioskApi()..applianceList = [kMicrowaveAppliance];
      await _pump(tester, api);
      expect(KioskColors.darkMode, isFalse);
      api.roomLight = 'dark';
      await _poll(tester);
      expect(KioskColors.darkMode, isTrue);
      api.roomLight = 'unknown';
      await _poll(tester);
      expect(KioskColors.darkMode, isTrue, reason: '모르면 지금 밝기를 지킨다');
      api.roomLight = 'light';
      await _poll(tester);
      expect(KioskColors.darkMode, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('밝게를 고르면 방이 어두워도 밝게, 설정에 저장', (tester) async {
      final dir = Directory.systemTemp.createTempSync('kiosk-tone');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = KioskSettingsStore(path: '${dir.path}/settings.json');
      store.save(const KioskSettings(screenTone: KioskScreenTone.light));
      final api = FakeKioskApi()
        ..applianceList = [kMicrowaveAppliance]
        ..roomLight = 'dark';
      await _pump(tester, api, settings: store);
      await _poll(tester);
      expect(KioskColors.darkMode, isFalse);
      expect(store.load().screenTone, KioskScreenTone.light);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('휴대폰에서 말한 확인 질문', () {
    testWidgets('처음 화면에 질문 그대로·작은 설명, 알림음 뒤 읽기 — 네는 본체에 먼저 정한 뒤 LG 가전 명령', (tester) async {
      final tts = FakeTts();
      final api = FakeKioskApi()
        ..applianceList = [kMicrowaveAppliance]
        ..voiceProposals = [_air];
      await _pump(tester, api, tts: tts);
      await _poll(tester);
      expect(find.byType(KioskVoiceProposalView), findsOneWidget);
      expect(find.text('공기청정기를 켤까요?'), findsOneWidget);
      expect(find.text(KioskVoiceProposalView.caption), findsOneWidget);
      expect(tts.chimes, 1);
      expect(tts.utterances.last, contains('공기청정기를 켤까요?'));
      expect(api.thinqCommands, isEmpty);

      await tester.tap(find.byKey(const ValueKey('voice-proposal-yes')));
      await tester.pump();
      await tester.pump();
      expect(api.voiceResolves, [('p1', true)]);
      expect(api.thinqCommands.single.$1, 'air');
      expect(api.thinqCommands.single.$2, 'set_power');
      expect(api.thinqRequestIds.single, isNotNull);
      expect(find.byType(KioskExecutingView), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('폰이 먼저 정했으면(409) 실행하지 않고 알린다', (tester) async {
      final api = FakeKioskApi()
        ..applianceList = [kMicrowaveAppliance]
        ..voiceProposals = [_rice]
        ..voiceResolveError = KioskApiException(409, '다른 곳에서 이미 정했어요.');
      await _pump(tester, api);
      await _poll(tester);
      await tester.tap(find.byKey(const ValueKey('voice-proposal-yes')));
      await _settle(tester);
      expect(api.executeCalls, 0);
      expect(find.text('휴대폰에서 이미 정했어요'), findsOneWidget);
      expect(find.byType(KioskVoiceProposalView), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('누름 동작은 같은 접수 경로로, 아니요는 실행 없이 내린다', (tester) async {
      final api = FakeKioskApi()
        ..applianceList = [kMicrowaveAppliance]
        ..voiceProposals = [_rice];
      await _pump(tester, api);
      await _poll(tester);
      await tester.tap(find.byKey(const ValueKey('voice-proposal-no')));
      await _settle(tester);
      expect(api.voiceResolves, [('p2', false)]);
      expect(api.executeCalls, 0);
      expect(find.byType(KioskVoiceProposalView), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());

      final api2 = FakeKioskApi()
        ..applianceList = [kMicrowaveAppliance]
        ..voiceProposals = [_rice];
      await _pump(tester, api2);
      await _poll(tester);
      await tester.tap(find.byKey(const ValueKey('voice-proposal-yes')));
      await tester.pump();
      await tester.pump();
      expect(api2.executeCalls, 1);
      expect(api2.requestIds.single, isNotNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('폰에서 정해 목록에서 빠지면 카드를 내린다 · 모르는 가전이면 네 없이 휴대폰에서 정해 달라고', (tester) async {
      final api = FakeKioskApi()
        ..applianceList = [kMicrowaveAppliance]
        ..voiceProposals = [
          const KioskIntentProposal(
              id: 'p3', question: '세탁기를 켤까요?', label: '세탁기', kind: 'buttons',
              applianceId: 'washer', buttons: ['전원'])
        ];
      await _pump(tester, api);
      await _poll(tester);
      expect(find.text('세탁기를 켤까요?'), findsOneWidget);
      expect(find.byKey(const ValueKey('voice-proposal-yes')), findsNothing);
      expect(find.text(KioskVoiceProposalView.phoneOnly), findsOneWidget);
      api.voiceProposals = [];
      await _poll(tester);
      expect(find.byType(KioskVoiceProposalView), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    // 실패널 10/26 — 질문 카드가 떠 있는데 아래 탭(홈·가전·자동 실행·기록)이 남아 눌렸다. 정해질 때까지 숨긴다.
    testWidgets('질문 카드가 뜬 동안 아래 탭이 없고, 아니요로 정하면 돌아온다', (tester) async {
      final tabs = find.byKey(const ValueKey('kiosk-tab-bar'));
      final api = FakeKioskApi()..applianceList = [kMicrowaveAppliance];
      await _pump(tester, api);
      expect(tabs, findsOneWidget);
      api.voiceProposals = [_rice];
      await _poll(tester);
      expect(find.byType(KioskVoiceProposalView), findsOneWidget);
      expect(tabs, findsNothing);
      expect(find.byKey(const ValueKey('kiosk-tab-appliances')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('voice-proposal-no')));
      await _settle(tester);
      expect(find.byType(KioskVoiceProposalView), findsNothing);
      expect(tabs, findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('폰에서 정해 질문이 목록에서 빠져도 아래 탭이 돌아온다', (tester) async {
      final tabs = find.byKey(const ValueKey('kiosk-tab-bar'));
      final api = FakeKioskApi()
        ..applianceList = [kMicrowaveAppliance]
        ..voiceProposals = [_air];
      await _pump(tester, api);
      await _poll(tester);
      expect(tabs, findsNothing);
      api.voiceProposals = [];
      await _poll(tester);
      expect(find.byType(KioskVoiceProposalView), findsNothing);
      expect(tabs, findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    test('본체 응답 모양 — 닫힌 목록 동작만, 이상한 값은 버린다', () {
      final p = KioskIntentProposal.tryParse({
        'id': 'abc',
        'question': '즉석밥을 데울까요?',
        'label': '즉석밥',
        'action': {'kind': 'buttons', 'appliance_id': 'microwave', 'buttons': ['즉석밥', '시작']},
      })!;
      expect(p.kind, 'buttons');
      expect(p.buttons, ['즉석밥', '시작']);
      expect(KioskIntentProposal.tryParse({'id': 'a/b', 'question': 'q', 'label': 'l', 'action': {}}), isNull);
      expect(KioskIntentProposal.tryParse('x'), isNull);
    });
  });
}
