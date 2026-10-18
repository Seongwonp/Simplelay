// 다음 루틴 '오늘은 건너뛰기'(사용자 결정 2026-10-18, 서버 계약 f37d82e5 — POST /routines/next/skip·unskip).
//
// - 서버 항목의 skipped·skip_label·skip_action_label을 그대로 쓴다(키오스크가 날짜 말을 만들지 않는다).
// - 본문은 /routines/next 항목의 routine_id·at 그대로. 409·404·422의 detail은 화면에 그대로, 409면 다시 불러온다.
// - 건너뛰면 서버 말('오늘은 건너뛰어요') + '되돌리기'. 확인 창 없이 바로, 보내는 동안 단추를 막는다.
// - 조용한 시간이라 건너뛰는 회차는 단추 대신 그 이유만.
// - 단추는 손가락 크기(높이 48 이상)지만 작은 글자 단추(테두리 없음, 10/18) — 큰 글씨·넓은 글꼴에서도 화면 안에서 눌린다.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simplelay_touchscreen/models/ambient.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/models/thinq.dart';
import 'package:simplelay_touchscreen/screens/kiosk_screen.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/theme/kiosk_colors.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/kiosk_canvas.dart';

import 'kiosk_phase_test.dart' show FakeKioskApi, FakeTts, FakeEventStream;

const _at = '2026-10-18T22:00:00+09:00';

// 실제 한글 글꼴(맑은 고딕 — 시험 글꼴보다 넓다, kiosk_large_eval3_test와 같은 틀). 없으면 그 시험은 건너뛴다.
const _fontPath = r'C:\Windows\Fonts\malgun.ttf';
final _hasFont = File(_fontPath).existsSync();

Map<String, dynamic> _json({bool skipped = false, String day = '오늘', bool quiet = false}) => {
      'routine_id': 'rt-1',
      'name': '저녁 공기청정기 켜기',
      'at': _at,
      'when': '매일 22:00',
      'day_label': day,
      'auto': true,
      'mode': 'approve',
      'mode_label': quiet ? '조용한 시간이라 건너뜀' : '자동 실행',
      if (quiet) 'quiet_skip': true,
      'skipped': skipped,
      'skip_label': skipped ? '$day은 건너뛰어요' : null,
      'skip_action_label': '$day은 건너뛰기',
    };

KioskNextRun _next({bool skipped = false, String day = '오늘', bool quiet = false}) =>
    KioskNextRun.fromJson(_json(skipped: skipped, day: day, quiet: quiet))!;

Future<void> _pumpIdle(WidgetTester tester, KioskNextRun next,
    {ValueChanged<KioskNextRun>? onToggle,
    bool busy = false,
    String? notice,
    double scale = 1.0,
    double letterSpacing = 0}) async {
  tester.view.physicalSize = const Size(800, 480);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(size: const Size(800, 480), textScaler: TextScaler.linear(scale)),
      child: Scaffold(
        backgroundColor: KioskColors.bg,
        body: DefaultTextStyle.merge(
          style: TextStyle(letterSpacing: letterSpacing),
          child: KioskIdleView(
            now: DateTime(2026, 10, 18, 19, 30),
            connected: true,
            ambient: const AmbientInfo(
              greeting: '편안한 저녁 보내세요.',
              weatherSource: 'mock',
              tip: AmbientTip(kind: 'rain', text: '밤 9시부터 비 예보가 있어요. 우산 챙기세요.', icon: 'rain'),
              hourly: [
                AmbientHour(label: '21시', hour: 21, icon: 'rain', temp: 15, pop: 70, precip: true),
                AmbientHour(label: '0시', hour: 0, icon: 'cloudy', temp: 13),
                AmbientHour(label: '3시', hour: 3, icon: 'cloudy', temp: 12),
                AmbientHour(label: '6시', hour: 6, icon: 'partly', temp: 12),
              ],
            ),
            appliances: [kMicrowaveAppliance, kInductionAppliance],
            temperature: 23,
            humidity: 58,
            nextRun: next,
            nextRunBusy: busy,
            nextRunNotice: notice,
            onToggleNextRunSkip: onToggle,
            onSelectAppliance: (_) {},
            onOpenConnection: (_) {},
            onDndGesture: () {},
          ),
        ),
      ),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 300));
}

final _skip = find.byKey(const ValueKey('idle-next-run-skip'));
final _unskip = find.byKey(const ValueKey('idle-next-run-unskip'));

Future<KioskSkipResult> _post(int status, Object body, {bool skip = true, KioskNextRun? next}) =>
    http.runWithClient(
        () => KioskApiService(baseUrl: 'http://hub.test').setNextRoutineSkip(next ?? _next(), skip: skip),
        () => MockClient((req) async {
              expect(req.method, 'POST');
              expect(req.url.path, skip ? '/routines/next/skip' : '/routines/next/unskip');
              expect(jsonDecode(req.body), {'routine_id': 'rt-1', 'at': _at}, reason: '/routines/next 항목 그대로');
              return http.Response.bytes(utf8.encode(jsonEncode(body)), status,
                  headers: {'content-type': 'application/json; charset=utf-8'});
            }));

Future<void> _pumpKiosk(WidgetTester tester, FakeKioskApi api, {double scale = 1.0}) async {
  tester.view.physicalSize = const Size(800, 480);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(size: const Size(800, 480), textScaler: TextScaler.linear(scale)),
      child: KioskScreen(api: api, tts: FakeTts(), events: FakeEventStream()),
    ),
  ));
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  setUpAll(() async {
    if (!_hasFont) return;
    final bytes = File(_fontPath).readAsBytesSync();
    await (FontLoader('Malgun')..addFont(Future.value(ByteData.view(bytes.buffer)))).load();
  });

  group('서버 항목', () {
    test('skipped·skip_label·skip_action_label·routine_id·at을 읽는다', () {
      final n = _next(day: '내일');
      expect(n.routineId, 'rt-1');
      expect(n.at, _at);
      expect(n.skipped, isFalse);
      expect(n.skipActionLabel, '내일은 건너뛰기');
      expect(n.canSkip, isTrue);
      final s = _next(skipped: true, day: '토요일');
      expect(s.skipped, isTrue);
      expect(s.skipLabel, '토요일은 건너뛰어요');
      expect(s.statusWord, '토요일은 건너뛰어요');
      expect(s.canSkip, isTrue, reason: '되돌리기');
    });

    test('조용한 시간이라 건너뛰는 회차·옛 서버(단추 말 없음)는 단추를 두지 않는다', () {
      expect(_next(quiet: true).canSkip, isFalse);
      final old = KioskNextRun.fromJson({
        'routine_id': 'rt-1', 'name': '저녁 공기청정기 켜기', 'at': _at, 'day_label': '오늘', 'mode_label': '자동 실행'})!;
      expect(old.canSkip, isFalse);
    });
  });

  group('POST /routines/next/skip·unskip', () {
    test('200 — 바뀐 항목', () async {
      final r = await _post(200, _json(skipped: true));
      expect(r.item?.skipped, isTrue);
      expect(r.item?.skipLabel, '오늘은 건너뛰어요');
      expect(r.message, isNull);
      final u = await _post(200, _json(), skip: false, next: _next(skipped: true));
      expect(u.item?.skipped, isFalse);
    });

    test('409 — 서버 detail 그대로 + 다시 불러오기', () async {
      final r = await _post(409, {'detail': '이미 지난 회차예요 — 다음 루틴을 다시 확인해 주세요'});
      expect(r.item, isNull);
      expect(r.message, '이미 지난 회차예요 — 다음 루틴을 다시 확인해 주세요');
      expect(r.reload, isTrue);
    });

    test('422·404 — detail 그대로(404는 다시 불러온다)', () async {
      final bad = await _post(422, {'detail': '어느 루틴인지 routine_id를 보내 주세요'});
      expect(bad.message, '어느 루틴인지 routine_id를 보내 주세요');
      expect(bad.reload, isFalse);
      final gone = await _post(404, {'detail': '없는 루틴이에요'});
      expect(gone.message, '없는 루틴이에요');
      expect(gone.reload, isTrue);
    });

    test('그 밖의 실패 — 짧은 안내(서버 원문을 보이지 않는다)', () async {
      final r = await _post(500, {'detail': 'Internal Server Error'});
      expect(r.message, KioskSkipResult.failed);
      final off = await http.runWithClient(
          () => KioskApiService(baseUrl: 'http://hub.test').setNextRoutineSkip(_next(), skip: true),
          () => MockClient((_) async => throw http.ClientException('down')));
      expect(off.message, KioskSkipResult.unreachable);
    });
  });

  group('평소 화면 단추', () {
    testWidgets("'오늘은 건너뛰기' — 서버 말 그대로, 손가락 크기, 누르면 그 회차를 넘긴다", (tester) async {
      final taps = <KioskNextRun>[];
      await _pumpIdle(tester, _next(), onToggle: taps.add);
      expect(find.descendant(of: _skip, matching: find.text('오늘은 건너뛰기')), findsOneWidget);
      final r = tester.getRect(_skip);
      expect(r.height, greaterThanOrEqualTo(48));
      expect(r.width, greaterThanOrEqualTo(48));
      // 주인공이 아니다 — 채움도 테두리도 없는 작은 글자 단추(사용자 요청 10/18, 테두리 단추가 너무 튀었다).
      expect(
          find.descendant(
              of: _skip,
              matching: find.byWidgetPredicate((w) => w is Container && w.decoration != null)),
          findsNothing);
      await tester.tap(_skip);
      expect(taps.single.routineId, 'rt-1');
      expect(taps.single.at, _at);
      expect(tester.takeException(), isNull);
    });

    testWidgets('내일 회차는 서버 말(내일은 건너뛰기)을 그대로', (tester) async {
      await _pumpIdle(tester, _next(day: '내일'), onToggle: (_) {});
      expect(find.text('내일은 건너뛰기'), findsOneWidget);
      expect(find.text('오늘은 건너뛰기'), findsNothing);
    });

    testWidgets("건너뛴 상태 — '오늘은 건너뛰어요' + '되돌리기'", (tester) async {
      final taps = <KioskNextRun>[];
      await _pumpIdle(tester, _next(skipped: true), onToggle: taps.add);
      expect(find.text('오늘은 건너뛰어요'), findsOneWidget);
      expect(_skip, findsNothing);
      expect(find.descendant(of: _unskip, matching: find.text('되돌리기')), findsOneWidget);
      await tester.tap(_unskip);
      expect(taps.single.skipped, isTrue);
    });

    testWidgets('조용한 시간이라 건너뛰는 회차 — 단추 없이 이유만', (tester) async {
      await _pumpIdle(tester, _next(quiet: true), onToggle: (_) {});
      expect(_skip, findsNothing);
      expect(_unskip, findsNothing);
      expect(find.text('조용한 시간이라 건너뛰어요'), findsOneWidget);
    });

    testWidgets('보내는 중 — 단추가 눌리지 않는다', (tester) async {
      final taps = <KioskNextRun>[];
      await _pumpIdle(tester, _next(), onToggle: taps.add, busy: true);
      await tester.tap(_skip, warnIfMissed: false);
      expect(taps, isEmpty);
    });

    testWidgets('실패 안내 한 줄', (tester) async {
      await _pumpIdle(tester, _next(), onToggle: (_) {}, notice: '이미 지난 회차예요');
      expect(find.byKey(const ValueKey('idle-next-run-notice')), findsOneWidget);
      expect(find.text('이미 지난 회차예요'), findsOneWidget);
    });

    for (final (scale, spacing) in [(1.0, 0.0), (1.0, 2.1), (1.0, 3.0), (1.22, 0.0), (1.22, 2.1)]) {
      for (final skipped in [false, true]) {
        testWidgets('배율 $scale 글자마다 +$spacing 건너뜀 $skipped — 단추가 화면 안에서 눌린다', (tester) async {
          final taps = <KioskNextRun>[];
          await _pumpIdle(tester, _next(skipped: skipped),
              onToggle: taps.add, scale: scale, letterSpacing: spacing, notice: '이미 지난 회차예요');
          expect(tester.takeException(), isNull);
          final button = skipped ? _unskip : _skip;
          final r = tester.getRect(button);
          final tile = tester.getRect(find.byKey(const ValueKey('strip-microwave')));
          expect(r.bottom, lessThanOrEqualTo(tile.top), reason: '가전 줄 위');
          expect(r.height, greaterThanOrEqualTo(48));
          expect(tester.getRect(find.byKey(const ValueKey('idle-next-run'))).bottom, lessThanOrEqualTo(tile.top),
              reason: '실패 안내까지 잘리지 않는다');
          await tester.tap(button);
          expect(taps, hasLength(1));
        });
      }
    }
  });

  group('키오스크 화면', () {
    testWidgets('누르면 서버에 그 회차를 보내고, 응답 말로 바뀌고, 되돌리기로 돌아온다', (tester) async {
      final api = FakeKioskApi()..nextRun = _next();
      await _pumpKiosk(tester, api);
      expect(_skip, findsOneWidget);
      await tester.tap(_skip);
      await tester.pump();
      await tester.pump();
      expect(api.skipRequests, [('rt-1', _at, true)]);
      expect(find.text('오늘은 건너뛰어요'), findsOneWidget);
      await tester.tap(_unskip);
      await tester.pump();
      await tester.pump();
      expect(api.skipRequests.last, ('rt-1', _at, false));
      expect(_skip, findsOneWidget);
      expect(find.text('오늘은 건너뛰어요'), findsNothing);
    });

    testWidgets('보내는 동안 두 번 눌러도 요청은 하나', (tester) async {
      final api = FakeKioskApi()
        ..nextRun = _next()
        ..skipPending = Completer<KioskSkipResult>();
      await _pumpKiosk(tester, api);
      await tester.tap(_skip);
      await tester.pump();
      await tester.tap(_skip, warnIfMissed: false);
      await tester.pump();
      expect(api.skipRequests, hasLength(1));
      api.skipPending!.complete(KioskSkipResult(item: _next(skipped: true)));
      await tester.pump();
      await tester.pump();
      expect(find.text('오늘은 건너뛰어요'), findsOneWidget);
    });

    testWidgets('409 — 서버 말을 짧게 보이고 다음 루틴을 다시 불러온다', (tester) async {
      final api = FakeKioskApi()
        ..nextRun = _next()
        ..skipResult = const KioskSkipResult(message: '이미 지난 회차예요 — 다음 루틴을 다시 확인해 주세요', reload: true);
      await _pumpKiosk(tester, api);
      final before = api.nextRunCalls;
      api.nextRun = _next(day: '내일');
      await tester.tap(_skip);
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(find.text('이미 지난 회차예요 — 다음 루틴을 다시 확인해 주세요'), findsOneWidget);
      expect(api.nextRunCalls, greaterThan(before));
      expect(find.text('내일은 건너뛰기'), findsOneWidget, reason: '다시 불러온 회차');
      // 안내는 잠시 뒤 사라진다.
      await tester.pump(const Duration(seconds: 9));
      expect(find.text('이미 지난 회차예요 — 다음 루틴을 다시 확인해 주세요'), findsNothing);
    });
  });

  group('실제 한글 글꼴(맑은 고딕)·1920x1080 캔버스', () {
    for (final scale in [1.0, 1.22]) {
      for (final skipped in [false, true]) {
        testWidgets('배율 $scale 건너뜀 $skipped — 날씨 안내·나쁜 공기·온습도와 함께 다음 루틴 줄과 단추가 다 보인다', (tester) async {
          if (!_hasFont) return markTestSkipped('맑은 고딕 없음');
          tester.view.physicalSize = const Size(1920, 1080);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);
          final taps = <KioskNextRun>[];
          await tester.pumpWidget(MaterialApp(
            theme: ThemeData(fontFamily: 'Malgun', brightness: Brightness.dark),
            home: Builder(builder: (context) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
                  child: KioskCanvas(
                    child: Scaffold(
                      backgroundColor: KioskColors.bg,
                      body: KioskIdleView(
                        now: DateTime(2026, 10, 18, 19, 30),
                        connected: true,
                        ambient: const AmbientInfo(
                          greeting: '편안한 저녁 보내세요.',
                          weatherSource: 'mock',
                          tip: AmbientTip(kind: 'rain', text: '밤 9시부터 비 예보가 있어요. 우산 챙기세요.', icon: 'rain'),
                          hourly: [
                            AmbientHour(label: '21시', hour: 21, icon: 'rain', temp: 15, pop: 70, precip: true),
                            AmbientHour(label: '0시', hour: 0, icon: 'cloudy', temp: 13),
                            AmbientHour(label: '3시', hour: 3, icon: 'cloudy', temp: 12),
                            AmbientHour(label: '6시', hour: 6, icon: 'partly', temp: 12),
                          ],
                        ),
                        appliances: [kMicrowaveAppliance, kInductionAppliance],
                        temperature: 23,
                        humidity: 58,
                        air: const KioskAirReading(applianceId: 'air_purifier', grade: 'VERY_BAD', pm25: 120, power: 'off'),
                        nextRun: _next(skipped: skipped),
                        onToggleNextRunSkip: taps.add,
                        onSelectAppliance: (_) {},
                        onOpenConnection: (_) {},
                        onDndGesture: () {},
                      ),
                    ),
                  ),
                )),
          ));
          await tester.pump(const Duration(milliseconds: 300));
          expect(tester.takeException(), isNull);
          final tile = tester.getRect(find.byKey(const ValueKey('strip-microwave')));
          final line = tester.getRect(find.byKey(const ValueKey('idle-next-run')));
          expect(line.bottom, lessThanOrEqualTo(tile.top + 0.5), reason: '다음 루틴 줄이 가전 줄 위에서 끝난다');
          expect(tester.getRect(find.byKey(const ValueKey('idle-air'))).bottom, lessThanOrEqualTo(line.top));
          final button = skipped ? _unskip : _skip;
          expect(tester.getRect(button).bottom, lessThanOrEqualTo(tile.top + 0.5));
          await tester.tap(button);
          expect(taps, hasLength(1));
          if (scale == 1.0) {
            expect(find.byKey(const ValueKey('ambient-hours')), findsOneWidget, reason: '보통 글씨에서는 예보도 보인다');
            // 루틴 이름이 가운데서 꺾여 '켜기'만 홀로 남지 않는다(줄을 바꾸면 시각 뒤에서).
            final para = tester.renderObject<RenderParagraph>(find.descendant(
                of: find.byKey(const ValueKey('idle-next-run-text')), matching: find.byType(RichText)));
            final drawn = para.text.toPlainText();
            final from = drawn.indexOf('저');
            final to = drawn.lastIndexOf('기');
            double dy(int i) => para.getOffsetForCaret(TextPosition(offset: i), Rect.zero).dy;
            expect(dy(from), closeTo(dy(to), 1), reason: '이름 한 줄: $drawn');
          }
        });
      }
    }
  });
}
