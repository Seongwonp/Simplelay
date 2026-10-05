// 비상정지 걸림(2026-10-05) — /status의 새 필드, POST /stop/ack, 그리고 화면.
//
// 규칙:
// - 걸리면 평소·실행·동작 중 화면 위쪽에 전폭 경고가 뜬다. 모달이 아니다 —
//   정지 버튼은 그대로 닿는다.
// - "확인하고 해제"는 같은 경고 안에서 확인 문장을 거쳐서만 해제를 보낸다.
//   화면이 스스로 해제하는 경로는 없다.
// - 실패(버튼 눌림·409·504·통신 실패)면 경고를 남기고 이유를 적는다.
// - 걸림이 새로 생길 때 한 번만 말한다.
// 서버 규약은 rpi/api/router.py acknowledge_estop. 실물 검증이 아니다.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/models/estop.dart';
import 'package:simplelay_touchscreen/screens/kiosk_screen.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/theme/kiosk_colors.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/estop_banner.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/executing_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/hold_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/kiosk_canvas.dart';

import 'kiosk_phase_test.dart' show FakeEventStream, FakeKioskApi, FakeTts;

const _detail = '콘센트 모듈의 비상정지 버튼이 눌렸어요';
const _banner = ValueKey('estop-banner');
const _ack = ValueKey('estop-ack');
const _confirm = ValueKey('estop-confirm');
const _cancel = ValueKey('estop-cancel');

const _latchedIdle =
    KioskStatus(running: false, estopLatched: true, estopDetail: _detail);

KioskStatus _hover({bool latched = true}) => KioskStatus(
      running: false,
      holdState: 'hovering_stop',
      holdApplianceId: 'microwave',
      holdStopButton: '취소',
      holdExecutionMode: 'mock',
      estopLatched: latched,
      estopDetail: latched ? _detail : null,
    );

http.Response _json(Object body, int status) => http.Response.bytes(
    utf8.encode(jsonEncode(body)), status,
    headers: {'content-type': 'application/json'});

KioskApiService _realApi(Future<http.Response> Function(http.Request) reply) =>
    http.runWithClient(() => KioskApiService(baseUrl: 'http://hub.test'),
        () => MockClient(reply));

Future<void> _pump(WidgetTester tester, FakeKioskApi api,
    {FakeTts? tts, Size size = const Size(1920, 1080)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: KioskScreen(api: api, tts: tts ?? FakeTts(), events: FakeEventStream()),
  ));
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

/// 다음 폴링(2초)까지 보낸다.
Future<void> _nextPoll(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 2));
  await _settle(tester);
}

Future<void> _ackFlow(WidgetTester tester) async {
  await tester.tap(find.byKey(_ack));
  await _settle(tester);
  expect(find.text(kEstopConfirmQuestion), findsOneWidget);
  await tester.tap(find.byKey(_confirm));
  await _settle(tester);
}

void main() {
  group('KioskStatus 비상정지 필드', () {
    test('없거나 null이면 걸리지 않음', () {
      final old = KioskStatus.fromJson(const {'running': false});
      expect(old.estopLatched, isFalse);
      expect(old.estopDetail, isNull);
      final none = KioskStatus.fromJson(
          const {'running': false, 'estop_latched': null, 'estop_detail': null});
      expect(none.estopLatched, isFalse);
    });

    test('걸림과 사유를 읽는다', () {
      final s = KioskStatus.fromJson(const {
        'running': false,
        'estop_latched': true,
        'estop_detail': _detail,
      });
      expect(s.estopLatched, isTrue);
      expect(s.estopDetail, _detail);
    });
  });

  group('KioskApiService.ackEstop', () {
    test('POST /stop/ack, ok면 해제됨', () async {
      final seen = <String>[];
      final api = _realApi((r) async {
        seen.add('${r.method} ${r.url.path}');
        return _json({'ok': true, 'latched': false}, 200);
      });
      expect((await api.ackEstop()).outcome, EstopAckOutcome.cleared);
      expect(seen, ['POST /stop/ack']);
    });

    test('버튼 눌림·409·504·500·통신 실패를 가른다', () async {
      Future<EstopAckOutcome> run(Future<http.Response> Function(http.Request) f) async =>
          (await _realApi(f).ackEstop()).outcome;
      expect(
          await run((_) async => _json(
              {'ok': false, 'latched': true, 'reason': 'estop_button_pressed'}, 200)),
          EstopAckOutcome.buttonPressed);
      expect(await run((_) async => _json({'detail': '보고 안 함'}, 409)),
          EstopAckOutcome.notLatched);
      expect(await run((_) async => _json({'detail': '무응답'}, 504)),
          EstopAckOutcome.noAnswer);
      expect(await run((_) async => _json({'detail': 'x'}, 500)),
          EstopAckOutcome.failed);
      expect(await run((_) async => throw http.ClientException('down')),
          EstopAckOutcome.failed);
    });
  });

  group('화면', () {
    testWidgets('걸리지 않았으면 경고가 없다', (tester) async {
      await _pump(tester, FakeKioskApi());
      expect(find.byKey(_banner), findsNothing);
    });

    testWidgets('평소 화면 — 걸리면 경고가 뜨고, 풀리면 내려간다', (tester) async {
      final api = FakeKioskApi()..statusResult = _latchedIdle;
      await _pump(tester, api);
      expect(find.byKey(_banner), findsOneWidget);
      expect(find.text(kEstopTitle), findsOneWidget);
      expect(find.text(_detail), findsOneWidget);

      api.statusResult = const KioskStatus(running: false);
      await _nextPoll(tester);
      expect(find.byKey(_banner), findsNothing);
      expect(api.estopAckCalls, 0);
    });

    testWidgets('걸림이 생길 때 한 번만 말한다', (tester) async {
      final tts = FakeTts();
      final api = FakeKioskApi()..statusResult = _latchedIdle;
      await _pump(tester, api, tts: tts);
      await _nextPoll(tester);
      await _nextPoll(tester);
      expect(tts.utterances.where((u) => u == kEstopSpoken).length, 1);

      // 풀렸다 다시 걸리면 다시 말한다.
      api.statusResult = const KioskStatus(running: false);
      await _nextPoll(tester);
      api.statusResult = _latchedIdle;
      await _nextPoll(tester);
      expect(tts.utterances.where((u) => u == kEstopSpoken).length, 2);
    });

    testWidgets('자동 해제 금지 — 폴링을 거듭해도, 취소해도 보내지 않는다', (tester) async {
      final api = FakeKioskApi()..statusResult = _latchedIdle;
      await _pump(tester, api);
      for (var i = 0; i < 3; i++) {
        await _nextPoll(tester);
      }
      expect(api.estopAckCalls, 0);

      await tester.tap(find.byKey(_ack));
      await _settle(tester);
      expect(find.text(kEstopConfirmQuestion), findsOneWidget);
      await tester.tap(find.byKey(_cancel));
      await _settle(tester);
      expect(api.estopAckCalls, 0);
      expect(find.byKey(_banner), findsOneWidget);
      expect(find.text(kEstopConfirmQuestion), findsNothing);
    });

    testWidgets('확인하고 해제 → 성공이면 상태를 다시 읽고 경고를 내린다', (tester) async {
      final api = FakeKioskApi()
        ..statusResult = _latchedIdle
        ..statusAfterAck = const KioskStatus(running: false);
      await _pump(tester, api);
      await _ackFlow(tester);
      expect(api.estopAckCalls, 1);
      expect(find.byKey(_banner), findsNothing);
    });

    for (final outcome in [
      EstopAckOutcome.buttonPressed,
      EstopAckOutcome.notLatched,
      EstopAckOutcome.noAnswer,
      EstopAckOutcome.failed,
    ]) {
      testWidgets('해제 실패($outcome)면 경고를 남기고 이유를 보인다', (tester) async {
        final api = FakeKioskApi()
          ..statusResult = _latchedIdle
          ..estopAckResult = EstopAckResult(outcome);
        await _pump(tester, api);
        await _ackFlow(tester);
        expect(api.estopAckCalls, 1);
        expect(find.byKey(_banner), findsOneWidget);
        expect(find.text(EstopAckResult(outcome).message), findsOneWidget);
        // 다음 폴링에도 이유가 남고, 다시 시도할 수 있다.
        await _nextPoll(tester);
        expect(find.text(EstopAckResult(outcome).message), findsOneWidget);
        expect(find.byKey(_ack).hitTestable(), findsOneWidget);
      });
    }

    testWidgets('동작 중 화면 — 경고와 정지 버튼이 함께 닿는다', (tester) async {
      final api = FakeKioskApi()..statusResult = _hover();
      await _pump(tester, api);
      await _nextPoll(tester);
      expect(find.byType(KioskHoldView), findsOneWidget);
      expect(find.byKey(_banner), findsOneWidget);
      final stop = find.descendant(
          of: find.byType(KioskHoldView), matching: find.text('정지'));
      expect(stop.hitTestable(), findsOneWidget);
      await tester.tap(stop);
      await _settle(tester);
      expect(api.stopCalls, 1);
      expect(api.estopAckCalls, 0);
    });

    testWidgets('실행 화면 — 경고와 긴급 정지가 함께 닿는다', (tester) async {
      final api = FakeKioskApi()
        ..statusResult = const KioskStatus(
            running: true,
            jobId: 'job-9',
            applianceId: 'microwave',
            totalSteps: 3,
            completedSteps: 1,
            estopLatched: true,
            estopDetail: _detail);
      await _pump(tester, api);
      await _nextPoll(tester);
      expect(find.byType(KioskExecutingView), findsOneWidget);
      await _nextPoll(tester);
      expect(find.byKey(_banner), findsOneWidget);
      final stop = find.descendant(
          of: find.byType(KioskExecutingView), matching: find.text('정지'));
      expect(stop.hitTestable(), findsOneWidget);
      await tester.tap(stop);
      await _settle(tester);
      expect(api.stopCalls, 1);
      expect(api.estopAckCalls, 0);
    });

    testWidgets('1920x1080 — 경고(확인 중 포함)의 누르는 자리가 가장자리 48px 안쪽',
        (tester) async {
      final api = FakeKioskApi()..statusResult = _hover();
      await _pump(tester, api);
      await _nextPoll(tester);
      const safe = Rect.fromLTRB(48, 48, 1920 - 48, 1080 - 48);
      void expectSafe(String what) {
        for (final key in [_ack, _confirm, _cancel]) {
          final f = find.byKey(key);
          if (f.evaluate().isEmpty) continue;
          final r = tester.getRect(f);
          expect(
              r.left >= safe.left - .5 &&
                  r.top >= safe.top - .5 &&
                  r.right <= safe.right + .5 &&
                  r.bottom <= safe.bottom + .5,
              isTrue,
              reason: '$what: $key $r');
        }
      }

      expectSafe('경고');
      await tester.tap(find.byKey(_ack));
      await _settle(tester);
      expectSafe('확인 중');
      expect(find.byKey(_confirm), findsOneWidget);
    });
  });

  group('큰 글씨(1.22배) — 경고와 화면이 잘리지 않는다', () {
    const fontPath = r'C:\Windows\Fonts\malgun.ttf';
    final hasFont = File(fontPath).existsSync();
    setUpAll(() async {
      if (!hasFont) return;
      final bytes = File(fontPath).readAsBytesSync();
      await (FontLoader('Malgun')..addFont(Future.value(ByteData.view(bytes.buffer))))
          .load();
    });

    Future<void> pumpLayout(WidgetTester tester, Widget banner, Widget child,
        {required bool panel15}) async {
      tester.view.physicalSize =
          panel15 ? const Size(1920, 1080) : KioskCanvas.design;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(fontFamily: 'Malgun', brightness: Brightness.dark),
        home: Builder(builder: (context) {
          final scaled = MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.22)),
            child: Scaffold(
              backgroundColor: KioskColors.bg,
              body: KioskEstopLayout(banner: banner, child: child),
            ),
          );
          return panel15 ? KioskCanvas(child: scaled) : scaled;
        }),
      ));
      await tester.pump(const Duration(milliseconds: 300));
    }

    void visible(WidgetTester tester, Finder f, {bool isText = true}) {
      expect(f, findsOneWidget, reason: '$f');
      if (isText) {
        expect(tester.renderObject<RenderParagraph>(f).didExceedMaxLines, isFalse,
            reason: '$f 말줄임');
      }
      final rect = tester.getRect(f);
      final screen = Offset.zero & tester.view.physicalSize;
      expect(screen.contains(rect.topLeft) &&
              screen.contains(rect.bottomRight - const Offset(.01, .01)),
          isTrue,
          reason: '$f 화면 밖 $rect');
      for (final s in find.ancestor(of: f, matching: find.byType(Scrollable)).evaluate()) {
        final view = tester.getRect(find.byWidget(s.widget));
        expect(rect.top >= view.top - .5 && rect.bottom <= view.bottom + .5, isTrue,
            reason: '$f 스크롤해야 보인다');
      }
    }

    KioskHoldView hold() => KioskHoldView(
          appliance: kMicrowaveAppliance,
          holdState: 'hovering_stop',
          stopButton: '취소',
          executionMode: 'mock',
          elapsed: const Duration(minutes: 1, seconds: 2),
          buttonsPressed: 3,
          operationConfirmed: true,
          operationSource: 'mock',
          stopRequested: true,
          onStop: () {},
        );

    for (final panel15 in [false, true]) {
      final where = panel15 ? '1920x1080' : '800x480';
      for (final (name, banner) in [
        ('경고', const KioskEstopBanner(detail: _detail)),
        ('확인 중', const KioskEstopBanner(detail: _detail, confirming: true)),
        (
          '실패 이유',
          KioskEstopBanner(
              detail: _detail,
              message: const EstopAckResult(EstopAckOutcome.buttonPressed).message),
        ),
      ]) {
        testWidgets('$where $name + 동작 중 화면', (tester) async {
          if (!hasFont) return markTestSkipped('맑은 고딕 없음');
          await pumpLayout(tester, banner, hold(), panel15: panel15);
          expect(tester.takeException(), isNull);
          visible(tester, find.text(kEstopTitle));
          visible(tester, find.text('정지'));
          visible(tester, find.text('정지 요청을 보냈어요'));
          if (name == '확인 중') {
            visible(tester, find.text(kEstopConfirmQuestion));
            visible(tester, find.byKey(_confirm), isText: false);
            visible(tester, find.byKey(_cancel), isText: false);
          } else {
            visible(tester, find.text(_detail));
            visible(tester, find.byKey(_ack), isText: false);
          }
          if (name == '실패 이유') {
            visible(tester,
                find.text(const EstopAckResult(EstopAckOutcome.buttonPressed).message));
          }
        });
      }
    }
  });
}
