// 첫 환영 화면 — 본체가 '연결된 휴대폰 0대'를 확인했을 때만 뜨고, 쓰던 본체에서는 어떤 경우에도 뜨지 않는다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/ambient.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/screens/kiosk_screen.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/services/kiosk_tts_service.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/danger_alert_overlay.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/room_sleep.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/welcome_gate.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/welcome_view.dart';

import 'kiosk_phase_test.dart' show FakeEventStream, FakeKioskApi, FakeTts;

const _onePixelPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

class _Api extends FakeKioskApi {
  String pairState = 'open';
  int sessions = 0;
  int approved = 0;

  @override
  Future<void> approvePairing(String requestId, bool approved) async {
    if (approved) this.approved++;
  }

  @override
  Future<Map<String, dynamic>> pairingSession({bool create = false}) async {
    if (create) sessions++;
    return {
      'state': pairState,
      'code': '012345',
      'host': 'http://192.0.2.10:8000',
      'expires_in': 300,
      'request_id': 'abcdef-request',
      'phone': '내 폰',
      'qr_png': _onePixelPng,
    };
  }
}

_Api _api(int? phones) => _Api()
  ..phonesResult = phones
  ..applianceList = [kMicrowaveAppliance]
  ..connectionsResult = const [ConnectionItem(id: 'network', state: 'ok', title: '', message: '')];

Future<void> _start(WidgetTester tester, _Api api, {KioskTtsService? tts}) async {
  tester.view.physicalSize = const Size(800, 480);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: KioskScreen(api: api, tts: tts ?? FakeTts(), events: FakeEventStream())));
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _settleEntrance(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 1600));
  await tester.pump();
}

Future<void> _end(WidgetTester tester) async => tester.pumpWidget(const SizedBox.shrink());

final _welcome = find.byKey(const ValueKey('welcome-view'));

void main() {
  group('표시 조건', () {
    testWidgets('휴대폰 0대면 뜬다 — 환영·안내·QR·코드가 한 화면에', (tester) async {
      await _start(tester, _api(0));
      await _settleEntrance(tester);
      expect(_welcome, findsOneWidget);
      expect(find.text(kWelcomeTitleLines), findsOneWidget);
      expect(find.text(kWelcomeGuideLines), findsOneWidget);
      expect(find.byKey(const Key('pair-code')), findsOneWidget);
      expect(find.bySemanticsLabel('휴대폰 연결 QR 코드'), findsOneWidget);
      expect(find.text('처음'), findsNothing, reason: '아래 탭이 없다');
      await _end(tester);
    });

    testWidgets('휴대폰이 1대면 뜨지 않고 다시 묻지도 않는다', (tester) async {
      final api = _api(1);
      await _start(tester, api);
      await tester.pump(const Duration(seconds: 10));
      expect(_welcome, findsNothing);
      api.phonesResult = 0; // 그 뒤 값이 바뀌어도 쓰던 본체다
      await tester.pump(const Duration(seconds: 10));
      expect(_welcome, findsNothing);
      await _end(tester);
    });

    testWidgets('본체가 모르면(null) 뜨지 않는다', (tester) async {
      await _start(tester, _api(null));
      await tester.pump(const Duration(seconds: 10));
      expect(_welcome, findsNothing);
      await _end(tester);
    });

    testWidgets('본체가 늦게 켜지면 0을 확인한 뒤에 뜬다', (tester) async {
      final api = _api(null);
      await _start(tester, api);
      expect(_welcome, findsNothing);
      api.phonesResult = 0;
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(_welcome, findsOneWidget);
      await _end(tester);
    });

    testWidgets('떠 있는 동안 한 번 놓쳐도 코드가 사라지지 않고, 계속 모르면 닫는다', (tester) async {
      final api = _api(0);
      await _start(tester, api);
      api.phonesResult = null;
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(_welcome, findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(_welcome, findsNothing);
      await _end(tester);
    });
  });

  group('연결 완료', () {
    testWidgets('폰이 키를 받으면 완료 화면·음성 뒤 일반 화면으로', (tester) async {
      final api = _api(0);
      final tts = FakeTts();
      await _start(tester, api, tts: tts);
      await _settleEntrance(tester);
      api.pairState = 'consumed';
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text(kWelcomeConnected), findsOneWidget);
      expect(find.text(kWelcomeTitleLines), findsNothing);
      expect(tts.utterances, [kWelcomeSpeech, kWelcomeConnectedSpeech]);
      await tester.pump(const Duration(seconds: 3));
      expect(_welcome, findsOneWidget, reason: '읽을 시간');
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(_welcome, findsNothing);
      await tester.pump(const Duration(seconds: 6));
      expect(tts.utterances, hasLength(2));
      await _end(tester);
    });

    testWidgets('허락 없이는 연결되지 않는다 — 폰 요청은 환영 화면에서도 묻는다', (tester) async {
      final api = _api(0);
      await _start(tester, api);
      await _settleEntrance(tester);
      api.pairState = 'pending';
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.text('이 휴대폰을 연결할까요?'), findsOneWidget);
      expect(find.text(kWelcomeConnected), findsNothing);
      expect(tester.takeException(), isNull, reason: '좁은 카드에서 단추가 잘리면 허락할 수 없다');
      await tester.tap(find.text('이 휴대폰 연결하기'));
      await tester.pump();
      expect(api.approved, 1);
      await _end(tester);
    });

    testWidgets('코드를 거치지 않고 연결돼도(본체 수 1) 완료로 넘어간다', (tester) async {
      final api = _api(0);
      final tts = FakeTts();
      await _start(tester, api, tts: tts);
      await _settleEntrance(tester);
      api.phonesResult = 1;
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text(kWelcomeConnected), findsOneWidget);
      expect(tts.utterances.where((t) => t == kWelcomeConnectedSpeech), hasLength(1));
      await _end(tester);
    });
  });

  testWidgets('건너뛰면 일반 화면 — 연결 창을 닫고, 이 실행에서는 다시 뜨지 않는다', (tester) async {
    final api = _api(0);
    await _start(tester, api);
    await _settleEntrance(tester);
    await tester.tap(find.byKey(const ValueKey('welcome-skip')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(_welcome, findsNothing);
    expect(api.closePairingCalls, 1);
    await tester.pump(const Duration(seconds: 10));
    expect(_welcome, findsNothing);
    await _end(tester);
  });

  group('음성', () {
    testWidgets('떠 있는 동안 1회, 다시 켜면 또 1회', (tester) async {
      final tts = FakeTts();
      await _start(tester, _api(0), tts: tts);
      await tester.pump(const Duration(seconds: 30));
      expect(tts.utterances, [kWelcomeSpeech]);
      await _end(tester);
      await _start(tester, _api(0), tts: tts);
      await tester.pump(const Duration(seconds: 5));
      expect(tts.utterances, [kWelcomeSpeech, kWelcomeSpeech]);
      await _end(tester);
    });

    testWidgets('음성 끄기면 말하지 않고 화면은 그대로', (tester) async {
      final tts = FakeTts()..enabled = false;
      await _start(tester, _api(0), tts: tts);
      await tester.pump(const Duration(seconds: 5));
      expect(tts.utterances, isEmpty);
      expect(_welcome, findsOneWidget);
      await _end(tester);
    });

    testWidgets('소리 끄기면 합성기를 부르지 않는다', (tester) async {
      final calls = <List<String>>[];
      final tts = KioskTtsService(runner: (c) async => calls.add(c))..muted = true;
      await _start(tester, _api(0), tts: tts);
      await tester.pump(const Duration(seconds: 5));
      expect(calls, isEmpty);
      await _end(tester);
    });

    testWidgets('음성이 실패해도 화면은 정상', (tester) async {
      final tts = KioskTtsService(runner: (_) async => throw StateError('no speaker'));
      await _start(tester, _api(0), tts: tts);
      await tester.pump(const Duration(seconds: 5));
      expect(tester.takeException(), isNull);
      expect(_welcome, findsOneWidget);
      await _end(tester);
    });

    testWidgets('조용한 시간에는 소리 없이, 끝나도 뒤늦게 말하지 않는다', (tester) async {
      final api = _api(0)..healthResult = const HealthStatus(ok: true, quietActive: true);
      final tts = FakeTts();
      await _start(tester, api, tts: tts);
      await tester.pump(const Duration(seconds: 5));
      expect(_welcome, findsOneWidget);
      expect(tts.utterances, isEmpty);
      api.healthResult = const HealthStatus(ok: true);
      await tester.pump(const Duration(minutes: 2));
      expect(tts.utterances, isEmpty);
      await _end(tester);
    });

    testWidgets('조용한 시간을 아직 모르면 기다렸다가 말한다', (tester) async {
      final api = _api(0)..healthResult = HealthStatus.disconnected;
      final tts = FakeTts();
      await _start(tester, api, tts: tts);
      await tester.pump(const Duration(seconds: 5));
      expect(tts.utterances, isEmpty);
      api.healthResult = const HealthStatus(ok: true);
      await tester.pump(const Duration(minutes: 2));
      expect(tts.utterances, [kWelcomeSpeech]);
      await _end(tester);
    });
  });

  group('다른 화면과의 관계', () {
    testWidgets('사람 감지 화면 쉬기가 덮지 않는다', (tester) async {
      final api = _api(0)..room = const RoomPresenceInfo(state: 'away', sleepScreen: true);
      await _start(tester, api);
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(find.byType(KioskRoomSleep), findsNothing);
      expect(_welcome, findsOneWidget);
      await _end(tester);
    });

    testWidgets('위험 경보는 환영 화면 위에 뜬다', (tester) async {
      final api = _api(0)..alertState = const AlertState(active: true, kind: 'fire');
      await _start(tester, api);
      await tester.pump();
      expect(_welcome, findsOneWidget);
      expect(find.byType(DangerAlertOverlay).hitTestable(), findsOneWidget, reason: '가운데를 누르면 경보에 닿는다');
      expect(find.byKey(const ValueKey('welcome-skip')).hitTestable(), findsNothing, reason: '경보가 뒤를 가린다');
      await _end(tester);
    });

    testWidgets('비상 멈춤 띠와 해제 단추가 가려지지 않는다', (tester) async {
      final api = _api(0)..statusResult = const KioskStatus(running: false, estopLatched: true);
      await _start(tester, api);
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(_welcome, findsOneWidget);
      final banner = find.textContaining('비상');
      expect(banner, findsWidgets);
      expect(tester.getRect(banner.first).bottom, lessThanOrEqualTo(tester.getRect(_welcome).top + 1));
      await _end(tester);
    });
  });

  group('잘림 없음', () {
    for (final size in const [Size(800, 480), Size(1920, 1080)]) {
      for (final dark in const [false, true]) {
        testWidgets('${size.width.toInt()}x${size.height.toInt()} ${dark ? "어두운" : "밝은"} 화면, 큰 글씨까지', (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(MaterialApp(
              home: MediaQuery(
            data: MediaQueryData(size: size, textScaler: const TextScaler.linear(1.22)),
            child: SizedBox(
              width: 800,
              height: 480,
              child: Scaffold(
                  body: KioskWelcomeView(api: _api(0), connected: false, onConnected: () {}, onSkip: () {})),
            ),
          )));
          await tester.pump();
          await _settleEntrance(tester);
          expect(tester.takeException(), isNull);
          for (final text in [kWelcomeTitleLines, kWelcomeGuideLines]) {
            final rect = tester.getRect(find.text(text));
            expect(rect.right, lessThanOrEqualTo(size.width));
            expect(rect.bottom, lessThanOrEqualTo(size.height));
          }
          await tester.pumpWidget(const SizedBox.shrink());
        });
      }
    }

    testWidgets('애니메이션을 끈 기기에서는 바로 다 보인다', (tester) async {
      await tester.pumpWidget(MaterialApp(
          home: MediaQuery(
        data: const MediaQueryData(size: Size(800, 480), disableAnimations: true),
        child: Scaffold(body: KioskWelcomeView(api: _api(0), connected: true, onConnected: () {}, onSkip: () {})),
      )));
      await tester.pump();
      expect(find.text(kWelcomeConnected), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('게이트 규칙', () {
    test('닫은 뒤에는 어떤 값에도 다시 뜨지 않는다', () {
      final gate = KioskWelcomeGate()
        ..readPhones(0)
        ..close();
      expect(gate.readPhones(0), isFalse);
      expect(gate.showing, isFalse);
    });

    test('연결은 한 번만 알린다', () {
      final gate = KioskWelcomeGate()..readPhones(0);
      expect(gate.readPhones(1), isTrue);
      expect(gate.readPhones(1), isFalse);
      expect(gate.markConnected(), isFalse);
    });

    test('띄운 적 없이 1대를 보면 닫힌다', () {
      final gate = KioskWelcomeGate()..readPhones(null);
      expect(gate.readPhones(1), isFalse);
      expect(gate.closed, isTrue);
    });
  });
}
