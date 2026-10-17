// ThinQ 공기청정기 — 평소 화면 '실내 공기' 한 줄과 가전 상세(지금 상태 + 큰 조작 단추)(2026-10-16, 사용자 요청).
//
// 규칙:
// - 공기질은 서버 기억(GET /thinq/air)만 — 가전이 매긴 등급이 없거나 오래됐으면 줄을 두지 않는다(지어내지 않는다).
// - 상세는 열 때 한 번 GET /thinq/status를 읽는다. 못 읽으면 이유만 말하고 값·조작을 내걸지 않는다.
// - 조작은 한 번 묻고('바꾸기')만 POST /thinq/command. 취소면 아무것도 보내지 않는다.
// - 전원이 꺼져 있으면 풍량 단추 잠금 + '전원을 켠 뒤 바꿀 수 있어요'. 비상 멈춤 띠가 보이면 모든 조작 잠금.
// 전부 모의(가짜 API·MockClient)다 — 실가전·실클라우드 검증이 아니다.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/models/thinq.dart';
import 'package:simplelay_touchscreen/screens/kiosk_screen.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/theme/kiosk_colors.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/estop_banner.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/executing_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/kiosk_canvas.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/manual_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/thinq_panel.dart';

import 'kiosk_phase_test.dart' show FakeEventStream, FakeKioskApi, FakeTts;

final _purifier = applianceFromServerJson({
  'id': 'air_purifier',
  'name': '공기청정기',
  'category': 'other',
  'rows': 0,
  'cols': 0,
  'buttons': <dynamic>[],
  'control_path': 'thinq',
  'can_execute': true,
  'readiness': 'operable',
});

Map<String, dynamic> _state({String power = 'POWER_ON', String wind = 'LOW', bool sensor = true}) => {
      'operation': {'airPurifierOperationMode': power},
      'airPurifierJobMode': {'currentJobMode': 'CLEAN'},
      'airFlow': {'windStrength': wind},
      if (sensor)
        'airQualitySensor': {
          'PM2': 42,
          'PM10': 90,
          'PM2Level': 'BAD',
          'PM10Level': 'VERY_BAD',
          'totalPollutionLevel': 'BAD',
        },
      'filterInfo': {'filterRemainPercent': 87},
    };

KioskThinqStatus _ok(Map<String, dynamic> state, {String mode = 'real'}) =>
    KioskThinqStatus(state: state, executionMode: mode, readAt: DateTime(2026, 10, 16, 9, 7));

const _fontPath = r'C:\Windows\Fonts\malgun.ttf';
final _hasFont = File(_fontPath).existsSync();

/// 평소 화면 공기 줄의 등급 글(마지막 글 조각) — 색을 본다.
TextSpan _gradeSpan(WidgetTester tester) {
  final rich = tester.widget<RichText>(find.descendant(
      of: find.byKey(const ValueKey('idle-air-headline')), matching: find.byType(RichText)));
  final leaves = <TextSpan>[];
  rich.text.visitChildren((span) {
    if (span is TextSpan && span.text != null) leaves.add(span);
    return true;
  });
  return leaves.last;
}

const _air = KioskAirReading(applianceId: 'air_purifier', grade: 'GOOD', pm25: 8, pm10: 10, power: 'on');

void main() {
  setUpAll(() async {
    if (!_hasFont) return;
    final bytes = File(_fontPath).readAsBytesSync();
    await (FontLoader('Malgun')..addFont(Future.value(ByteData.view(bytes.buffer)))).load();
  });

  // ── 순수 함수 ─────────────────────────────────────────────────────────────

  group('공기질 읽기', () {
    // 외부 평가 10/16 2차 k01: 종합 '보통'과 '초미세먼지 8'(국내 기준 좋음)이 함께 보여 모순처럼 읽혔다.
    test('초미세먼지 등급이 오면 값 옆에 그 등급 말을 붙인다(종합 등급과 따로)', () {
      final r = KioskAirReading.fromJson({
        'appliance_id': 'air_purifier', 'grade': 'NORMAL', 'grade_source': 'total',
        'pm25': 8, 'pm25_level': 'GOOD', 'power': 'on', 'age_s': 3.0,
      })!;
      expect(r.details, ['초미세먼지 8 좋음', '종합은 가전이 매긴 등급', '공기청정기가 켜져 있어요']);
      // 가전의 종합 등급임을 밝힌다 — '보통' 밑 '초미세먼지 좋음'이 모순처럼 읽혔다(외부 평가 10/16 3차).
      expect(r.headline, '실내 공기 종합 보통');
      // 모르는 등급 값은 붙이지 않는다.
      final odd = KioskAirReading.fromJson({
        'appliance_id': 'air_purifier', 'grade': 'NORMAL', 'pm25': 8, 'pm25_level': 'WEIRD', 'age_s': 3.0,
      })!;
      expect(odd.details, ['초미세먼지 8']);
    });

    // UI 평가 4차 10/17: 실패널 '종합 보통' 아래에 '초미세먼지 8 좋음'만 있어 왜 보통인지 몰랐다 — 미세먼지 등급도 보인다.
    test('미세먼지 등급이 오면 미세먼지도 등급과 함께, 초미세먼지 앞에', () {
      final r = KioskAirReading.fromJson({
        'appliance_id': 'air_purifier', 'grade': 'NORMAL', 'grade_source': 'total',
        'pm25': 8, 'pm25_level': 'GOOD', 'pm10': 35, 'pm10_level': 'NORMAL', 'power': 'off', 'age_s': 3.0,
      })!;
      expect(r.details, ['미세먼지 35 보통', '초미세먼지 8 좋음', '공기청정기가 꺼져 있어요']);
      // 등급을 모르면 미세먼지 값은 싣지 않는다(종합 등급 설명이 안 된다).
      final noLevel = KioskAirReading.fromJson(
          {'appliance_id': 'air_purifier', 'grade': 'GOOD', 'pm25': 8, 'pm10': 10, 'age_s': 3.0})!;
      expect(noLevel.details, ['초미세먼지 8']);
    });

    // 실패널 10/17 09:30: '종합 보통' 아래 미세먼지 8 좋음 · 초미세먼지 8 좋음 — 종합이 왜 보통인지 여전히 모순처럼 보였다.
    test('종합 등급이 보이는 먼지 등급보다 나쁘면 가전이 여러 센서로 매긴 등급이라고 밝힌다', () {
      final r = KioskAirReading.fromJson({
        'appliance_id': 'air_purifier', 'grade': 'NORMAL', 'grade_source': 'total',
        'pm25': 8, 'pm25_level': 'GOOD', 'pm10': 8, 'pm10_level': 'GOOD', 'power': 'off', 'age_s': 3.0,
      })!;
      // 두 먼지 등급이 같으면 한 줄로 — 줄이 넷이면 실패널에서 마지막 줄이 잘렸다(10/17 09:33).
      expect(r.details, ['미세·초미세먼지 모두 좋음', '종합은 가전이 매긴 등급', '공기청정기가 꺼져 있어요']);
      // 같으면 붙이지 않는다.
      final same = KioskAirReading.fromJson({
        'appliance_id': 'air_purifier', 'grade': 'NORMAL', 'grade_source': 'total',
        'pm25': 30, 'pm25_level': 'NORMAL', 'age_s': 3.0,
      })!;
      expect(same.details, ['초미세먼지 30 보통']);
    });

    test('서버 항목 → 한 줄(등급·초미세먼지·전원)', () {
      final r = KioskAirReading.fromJson(
          {'appliance_id': 'air_purifier', 'grade': 'GOOD', 'pm25': 8, 'pm10': 10, 'power': 'on', 'age_s': 30.0})!;
      expect(r.line, '실내 공기 좋음 · 초미세먼지 8 · 공기청정기가 켜져 있어요');
      final off = KioskAirReading.fromJson(
          {'appliance_id': 'air_purifier', 'grade': 'VERY_BAD', 'pm25': null, 'power': 'off', 'age_s': 0})!;
      expect(off.line, '실내 공기 매우 나쁨 · 공기청정기가 꺼져 있어요');
      final mock = KioskAirReading.fromJson(
          {'appliance_id': 'air_purifier', 'grade': 'NORMAL', 'pm25': 20, 'age_s': 0},
          mock: true)!;
      expect(mock.line, '실내 공기 보통 · 초미세먼지 20 · 연습이라 진짜 값이 아니에요');
    });

    test('모르는 등급·등급 없음·오래된 값은 null(보이지 않는다)', () {
      expect(KioskAirReading.fromJson({'appliance_id': 'a', 'grade': 'SOMETHING', 'age_s': 0}), isNull);
      expect(KioskAirReading.fromJson({'appliance_id': 'a', 'pm25': 8, 'age_s': 0}), isNull);
      expect(KioskAirReading.fromJson({'appliance_id': 'a', 'grade': 'GOOD', 'age_s': 601}), isNull);
    });

    test('등급 색 — 좋음 초록 · 보통 중립 · 나쁨 앰버 · 매우 나쁨 빨강', () {
      expect(airGradeColor('GOOD'), KioskColors.confirmed);
      expect(airGradeColor('NORMAL'), Colors.white);
      expect(airGradeColor('BAD'), KioskColors.warning);
      expect(airGradeColor('VERY_BAD'), KioskColors.danger);
      expect(airGradeColor(null), Colors.white);
    });

    test('API: GET /thinq/air를 읽고 모의면 연습 값, 실패는 null', () async {
      Future<KioskAirReading?> read(http.Response response) => http.runWithClient(
          () => KioskApiService(baseUrl: 'http://hub.test').thinqAir(),
          () => MockClient((req) async {
                expect(req.url.path, '/thinq/air');
                return response;
              }));
      final body = {
        'execution_mode': 'mock',
        'appliances': [
          {'appliance_id': 'air_purifier', 'grade': 'BAD', 'pm25': 42, 'power': 'on', 'age_s': 12.5}
        ]
      };
      final r = await read(http.Response.bytes(utf8.encode(jsonEncode(body)), 200));
      expect(r!.grade, 'BAD');
      expect(r.mock, isTrue);
      expect(await read(http.Response('{"detail":"x"}', 401)), isNull);
      expect(
          await read(http.Response.bytes(
              utf8.encode(jsonEncode({'execution_mode': 'real', 'appliances': []})), 200)),
          isNull);
    });
  });

  group('상태 줄·조작 표(폰 thinq_state_card에서 옮김)', () {
    test('아는 칸만 사람 말로, 미세먼지 줄에는 가전 등급', () {
      final rows = thinqStateRows(_state());
      expect([for (final r in rows) (r.label, r.value)], [
        ('전원', '켜짐'),
        // '모드 청정'은 뜻을 몰랐다(평가 4차 10/18) — 기본 청정은 줄을 두지 않는다.
        ('바람 세기', '약'),
        ('초미세먼지', '42 · 나쁨'),
        ('미세먼지', '90 · 매우 나쁨'),
        ('필터 남은 양', '87%'),
      ]);
      expect(rows[2].grade, 'BAD');
      expect(rows[3].grade, 'VERY_BAD');
      expect(rows[0].grade, isNull);
      expect(thinqStateRows(const {}), isEmpty);
    });

    test('조작은 전원 칸이 있을 때만 — 전원·풍량, 지금 값 표시', () {
      final controls = thinqControlsFor(_state(wind: 'HIGH'));
      expect([for (final c in controls) c.action], ['set_power', 'set_wind_strength']);
      expect(controls[0].current, 'POWER_ON');
      expect(controls[1].current, 'HIGH');
      expect([for (final (_, w) in controls[1].choices) w], ['약', '중', '강', '자동']);
      expect(thinqControlsFor({'airFlow': {'windStrength': 'LOW'}}), isEmpty);
    });

    test('확인 질문과 실행 제목', () {
      final wind = kKioskAirPurifierControls[1];
      final power = kKioskAirPurifierControls[0];
      expect(wind.question('공기청정기', 'HIGH', '강'), '공기청정기 바람 세기를 강으로 바꿀까요?');
      expect(wind.question('공기청정기', 'AUTO', '자동'), '공기청정기 바람 세기를 자동으로 바꿀까요?');
      expect(power.question('공기청정기', 'POWER_ON', '켜기'), '공기청정기 전원을 켤까요?');
      expect(power.question('공기청정기', 'POWER_OFF', '끄기'), '공기청정기 전원을 끌까요?');
      expect(wind.doneLabel('공기청정기', '강'), '공기청정기 바람 세기 강으로 바꾸기');
      expect(power.doneLabel('공기청정기', '켜기'), '공기청정기 전원 켜기');
    });

    test('거절 문장 — 서버 이유를 그대로, 결과 모름은 null', () {
      expect(thinqCommandRefusal(423, '비상 정지 잠금이에요'), '비상 정지 잠금이에요');
      // '작업' 대신 쉬운 말(평가 4차 10/18).
      expect(thinqCommandRefusal(409, 'job already in progress'), contains('다른 일을 하고 있어요'));
      expect(thinqCommandRefusal(503, 'x'), isNull);
    });

    test('API: 상태 실패는 서버 이유, 명령은 같은 경로·인자', () async {
      final seen = <http.Request>[];
      Future<T> run<T>(Future<T> Function(KioskApiService) f, http.Response r) => http.runWithClient(
          () => f(KioskApiService(baseUrl: 'http://hub.test')),
          () => MockClient((req) async {
                seen.add(req);
                return r;
              }));
      final failed = await run((a) => a.thinqStatus('air_purifier'),
          http.Response.bytes(utf8.encode(jsonEncode({'detail': '상태를 읽지 못했어요 — 가전·인터넷 연결을 확인해 주세요'})), 503));
      expect(failed.ok, isFalse);
      expect(failed.failure, '상태를 읽지 못했어요 — 가전·인터넷 연결을 확인해 주세요');
      expect(seen.last.url.path, '/thinq/status/air_purifier');

      final read = await run((a) => a.thinqStatus('air_purifier'),
          http.Response.bytes(utf8.encode(jsonEncode({'execution_mode': 'mock', 'state': _state()})), 200));
      expect(read.ok, isTrue);
      expect(read.mock, isTrue);
      expect(read.readAt, isNotNull);

      final accepted = await run((a) => a.thinqCommand('air_purifier', 'set_wind_strength', {'wind_strength': 'HIGH'}),
          http.Response('{"job_id":"j-9"}', 200));
      expect(accepted.jobId, 'j-9');
      expect(seen.last.url.path, '/thinq/command');
      expect(seen.last.method, 'POST');
      expect(jsonDecode(seen.last.body), {
        'appliance_id': 'air_purifier',
        'action': 'set_wind_strength',
        'args': {'wind_strength': 'HIGH'},
      });
    });
  });

  // ── 평소 화면 한 줄 ────────────────────────────────────────────────────────

  /// [realFont]면 맑은 고딕·KioskCanvas로 그린다(키오스크와 같은 배치 — 시험 글꼴은 숫자가 정사각형이라 시계가 넘친다).
  Future<void> pumpIdle(WidgetTester tester, KioskAirReading? air,
      {Size size = const Size(800, 480), double scale = 1.0, bool realFont = false}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    Widget wrap(Widget child) => realFont ? KioskCanvas(child: child) : child;
    await tester.pumpWidget(MaterialApp(
      theme: realFont ? ThemeData(fontFamily: 'Malgun', brightness: Brightness.dark) : null,
      home: MediaQuery(
        data: MediaQueryData(size: size, textScaler: TextScaler.linear(scale)),
        child: wrap(Scaffold(
          body: KioskIdleView(
            now: DateTime(2026, 10, 16, 9, 5),
            connected: true,
            appliances: [kMicrowaveAppliance, _purifier],
            temperature: 23,
            humidity: 50,
            air: air,
            onSelectAppliance: (_) {},
            onOpenConnection: (_) {},
            onDndGesture: () {},
          ),
        )),
      ),
    ));
  }

  testWidgets('평소 화면: 실내 공기 한 줄 — 등급(색+말)·초미세먼지·공기청정기 전원', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpIdle(tester, _air);
    expect(find.byKey(const ValueKey('idle-air')), findsOneWidget);
    // 공기는 한 줄 + 색(2차 평가 10/18) — 숫자는 LG 상세 '자세히' 안.
    expect(find.bySemanticsLabel('공기 좋아요. 공기청정기가 켜져 있어요'), findsOneWidget);
    final grade = _gradeSpan(tester);
    expect(grade.text!.replaceAll('⁠', ''), '좋아요');
    expect(grade.style!.color, KioskColors.confirmed);
    expect(find.byIcon(Icons.air), findsOneWidget);
    expect(tester.takeException(), isNull);
    handle.dispose();
  });

  testWidgets('평소 화면: 공기 줄은 시계 아래·가전 줄 위 빈 자리에 다 들어간다(맑은 고딕, 800x480·1920x1080)', (tester) async {
    if (!_hasFont) return markTestSkipped('맑은 고딕 없음');
    for (final size in [const Size(800, 480), const Size(1920, 1080)]) {
      await pumpIdle(tester, _air, size: size, realFont: true);
      await tester.pump();
      expect(tester.takeException(), isNull);
      // 시계보다 아래, 가전 줄보다 위 — 시계·날씨를 밀어내지 않는다.
      final clock = tester.getRect(find.text('9:05'));
      final air = tester.getRect(find.byKey(const ValueKey('idle-air')));
      final strip = tester.getRect(find.byKey(const ValueKey('strip-microwave')));
      expect(air.top, greaterThanOrEqualTo(clock.bottom), reason: '$size');
      expect(air.bottom, lessThanOrEqualTo(strip.top), reason: '$size');
      // 항목마다 따로 — 줄이 바뀌어도 '·'가 줄 끝에 매달리지 않는다(외부 평가 10/16 2차 k01).
      expect(find.text('초미세먼지 8'), findsNothing);
      expect(find.text('공기청정기가 켜져 있어요'), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('idle-air')), matching: find.textContaining('·')),
          findsNothing);
    }
  });

  testWidgets('평소 화면: 나쁨은 앰버, 매우 나쁨은 빨강', (tester) async {
    for (final (grade, color) in [('BAD', KioskColors.warning), ('VERY_BAD', KioskColors.danger)]) {
      await pumpIdle(tester, KioskAirReading(applianceId: 'air_purifier', grade: grade, pm25: 80));
      expect(_gradeSpan(tester).style!.color, color);
      expect(tester.widget<Icon>(find.byIcon(Icons.air)).color, color);
    }
  });

  testWidgets('평소 화면: 공기질을 모르면 줄이 없다(지어내지 않는다)', (tester) async {
    await pumpIdle(tester, null);
    expect(find.byKey(const ValueKey('idle-air')), findsNothing);
    expect(find.textContaining('실내 공기'), findsNothing);
    expect(find.byIcon(Icons.air), findsNothing);
  });

  testWidgets('평소 화면: 큰 글씨(1.22배)에서도 공기 줄이 시계 칸 안에 다 보이고 넘치지 않는다', (tester) async {
    if (!_hasFont) return markTestSkipped('맑은 고딕 없음');
    final handle = tester.ensureSemantics();
    for (final size in [const Size(800, 480), const Size(1920, 1080)]) {
      await pumpIdle(tester,
          const KioskAirReading(applianceId: 'air_purifier', grade: 'VERY_BAD', pm25: 120, power: 'on'),
          size: size, scale: 1.22, realFont: true);
      await tester.pump();
      expect(tester.takeException(), isNull);
      final air = tester.getRect(find.byKey(const ValueKey('idle-air')));
      final strip = tester.getRect(find.byKey(const ValueKey('strip-microwave')));
      expect(air.bottom, lessThanOrEqualTo(strip.top), reason: '$size');
      // 큰 글씨에서는 아래 작은 줄도 뺀다(공기청정기 켜짐은 가전 타일에 있다).
      expect(find.bySemanticsLabel(RegExp('공기 아주 나빠요')), findsOneWidget);
      expect(find.text('초미세먼지 120'), findsNothing);
      expect(find.textContaining('공기청정기가 켜져 있어요'), findsNothing);
    }
    handle.dispose();
  });

  // ── 가전 상세 ─────────────────────────────────────────────────────────────

  Future<({List<(String, Map<String, Object>)> sent, List<(String, String)> accepted, List<int> reads})> pumpPanel(
    WidgetTester tester, {
    required Future<KioskThinqStatus> Function() read,
    Future<KioskJobAccepted> Function(String, Map<String, Object>)? send,
    bool estop = false,
    Size size = const Size(800, 480),
    double scale = 1.0,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final sent = <(String, Map<String, Object>)>[];
    final accepted = <(String, String)>[];
    final reads = <int>[];
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(size: size, textScaler: TextScaler.linear(scale)),
        child: KioskEstopScope(
          shown: estop,
          child: Scaffold(
            body: KioskManualView(
              appliance: _purifier,
              onExecute: (_) => fail('ThinQ 가전에는 누를 버튼판이 없다'),
              onCancel: () {},
              thinqRead: () {
                reads.add(1);
                return read();
              },
              thinqSend: (action, args) {
                sent.add((action, args));
                return send?.call(action, args) ?? Future.value(const KioskJobAccepted(jobId: 'job-7'));
              },
              onThinqAccepted: (jobId, label) => accepted.add((jobId, label)),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();
    return (sent: sent, accepted: accepted, reads: reads);
  }

  testWidgets('상세: 열면 한 번 읽고 상태 줄·읽은 시각·조작 단추를 보인다(버튼판 없음)', (tester) async {
    final r = await pumpPanel(tester, read: () async => _ok(_state()));
    expect(r.reads, hasLength(1));
    expect(find.byKey(const ValueKey('thinq-row-전원')), findsOneWidget);
    expect(find.text('켜짐'), findsOneWidget);
    // 상태 이름은 조작 단추와 같은 말(약풍 → 약, 2차 평가 10/18).
    expect(tester.widget<Text>(find.byKey(const ValueKey('thinq-row-바람 세기'))).textSpan!.toPlainText(),
        '약');
    // 공기는 한 줄 — 먼지 숫자·등급은 '자세히' 안.
    expect(find.text('공기 나빠요'), findsOneWidget);
    expect(find.text('42 · 나쁨'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('thinq-air-more')));
    await tester.pump();
    expect(find.text('42 · 나쁨'), findsOneWidget);
    expect(tester.widget<Text>(find.text('42 · 나쁨')).style!.color, KioskColors.warning);
    expect(tester.widget<Text>(find.text('90 · 매우 나쁨')).style!.color, KioskColors.danger);
    expect(find.text('87%'), findsOneWidget);
    expect(find.text('오전 9시 7분 기준'), findsOneWidget); // 시각은 오전/오후(평가 4차 10/18)
    for (final v in ['POWER_ON', 'POWER_OFF']) {
      expect(find.byKey(ValueKey('thinq-set-set_power-$v')), findsOneWidget);
    }
    for (final v in ['LOW', 'MID', 'HIGH', 'AUTO']) {
      expect(find.byKey(ValueKey('thinq-set-set_wind_strength-$v')), findsOneWidget);
    }
    // 단추 높이는 주 단추(KioskSizes.primaryButton=72) 이상.
    expect(tester.getSize(find.byKey(const ValueKey('thinq-set-set_wind_strength-HIGH'))).height,
        greaterThanOrEqualTo(72));
    // 예전 '휴대폰에서 바꿀 수 있어요'만 있던 안내는 없다.
    expect(find.textContaining('휴대폰의 가전 화면에서 지금 상태를 보고'), findsNothing);
    expect(find.byKey(const ValueKey('thinq-practice')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('상세: 확인 → 바꾸기를 눌러야 같은 경로로 보내고 실행 화면으로 넘긴다', (tester) async {
    final r = await pumpPanel(tester, read: () async => _ok(_state()));
    await tester.tap(find.byKey(const ValueKey('thinq-set-set_wind_strength-HIGH')));
    await tester.pump();
    expect(find.text('공기청정기 바람 세기를 강으로 바꿀까요?'), findsOneWidget);
    expect(r.sent, isEmpty);
    await tester.tap(find.byKey(const ValueKey('thinq-confirm-ok')));
    await tester.pump();
    await tester.pump();
    expect(r.sent.single.$1, 'set_wind_strength');
    expect(r.sent.single.$2, {'wind_strength': 'HIGH'});
    expect(r.accepted, [('job-7', '공기청정기 바람 세기 강으로 바꾸기')]);
  });

  testWidgets('상세: 취소하면 아무것도 보내지 않는다', (tester) async {
    final r = await pumpPanel(tester, read: () async => _ok(_state()));
    await tester.tap(find.byKey(const ValueKey('thinq-set-set_power-POWER_OFF')));
    await tester.pump();
    expect(find.text('공기청정기 전원을 끌까요?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('thinq-confirm-cancel')));
    await tester.pump();
    expect(find.byKey(const ValueKey('thinq-confirm')), findsNothing);
    expect(r.sent, isEmpty);
    expect(r.accepted, isEmpty);
  });

  testWidgets('상세: 지금 값 단추는 눌러도 묻지 않는다', (tester) async {
    final r = await pumpPanel(tester, read: () async => _ok(_state(wind: 'LOW')));
    await tester.tap(find.byKey(const ValueKey('thinq-set-set_wind_strength-LOW')));
    await tester.pump();
    expect(find.byKey(const ValueKey('thinq-confirm')), findsNothing);
    expect(r.sent, isEmpty);
  });

  testWidgets('상세: 전원이 꺼져 있으면 풍량을 잠그고 "전원을 켠 뒤 바꿀 수 있어요" — 켜기는 된다', (tester) async {
    final r = await pumpPanel(tester, read: () async => _ok(_state(power: 'POWER_OFF', sensor: false)));
    expect(find.text(kThinqPowerOffNote), findsOneWidget);
    expect(find.byKey(const ValueKey('thinq-dust-note')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('thinq-set-set_wind_strength-HIGH')), warnIfMissed: false);
    await tester.pump();
    expect(find.byKey(const ValueKey('thinq-confirm')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('thinq-set-set_power-POWER_ON')));
    await tester.pump();
    expect(find.text('공기청정기 전원을 켤까요?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('thinq-confirm-ok')));
    await tester.pump();
    await tester.pump();
    expect(r.sent.single.$1, 'set_power');
    expect(r.sent.single.$2, {'power': 'POWER_ON'});
  });

  testWidgets('상세: 비상 멈춤 띠가 보이면 모든 조작을 잠근다', (tester) async {
    final r = await pumpPanel(tester, read: () async => _ok(_state()), estop: true);
    expect(find.text(kThinqEstopNote), findsOneWidget);
    for (final key in ['thinq-set-set_power-POWER_OFF', 'thinq-set-set_wind_strength-HIGH']) {
      await tester.tap(find.byKey(ValueKey(key)), warnIfMissed: false);
      await tester.pump();
      expect(find.byKey(const ValueKey('thinq-confirm')), findsNothing);
    }
    expect(r.sent, isEmpty);
  });

  testWidgets('상세: 상태를 못 읽으면 이유를 말하고 값·조작을 내걸지 않는다 — 다시 읽기는 한 번 더 읽는다', (tester) async {
    var calls = 0;
    final r = await pumpPanel(tester, read: () async {
      calls++;
      return const KioskThinqStatus(failure: '상태를 읽지 못했어요 — 가전·인터넷 연결을 확인해 주세요');
    });
    expect(find.textContaining('지금 상태를 못 봤어요. 상태를 읽지 못했어요'), findsOneWidget);
    expect(find.byKey(const ValueKey('thinq-controls-unknown')), findsOneWidget);
    expect(find.byKey(const ValueKey('thinq-set-set_power-POWER_ON')), findsNothing);
    expect(find.byKey(const ValueKey('thinq-row-전원')), findsNothing);
    expect(find.byKey(const ValueKey('thinq-read-time')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('thinq-reread')));
    await tester.pump();
    await tester.pump();
    expect(calls, 2);
    expect(r.sent, isEmpty);
  });

  testWidgets('상세: 서버가 거절하면 이유를 그대로 보이고 실행 화면으로 넘기지 않는다', (tester) async {
    final r = await pumpPanel(tester,
        read: () async => _ok(_state()),
        send: (_, __) async => throw KioskApiException(423, '비상 버튼이 눌려 있어 보내지 않았어요'));
    await tester.tap(find.byKey(const ValueKey('thinq-set-set_wind_strength-MID')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('thinq-confirm-ok')));
    await tester.pump();
    await tester.pump();
    expect(find.text('비상 버튼이 눌려 있어 보내지 않았어요'), findsOneWidget);
    expect(r.accepted, isEmpty);
  });

  // 평가 5차(10/18): 연습 안내는 한 곳(조작 칸 위) — 지금 상태 칸의 '연습 화면이에요. 진짜 값이 아니에요'는 같은 말이었다.
  testWidgets('상세: 모의면 연습 표시 — 제목·연습 칸 한 곳', (tester) async {
    await pumpPanel(tester, read: () async => _ok(_state(), mode: 'mock'));
    expect(find.text('지금 상태'), findsOneWidget);
    expect(find.text('지금 상태 (연습)'), findsNothing);
    expect(find.text('연습 화면이에요. 진짜 값이 아니에요'), findsNothing);
    expect(find.byKey(const ValueKey('thinq-practice')), findsOneWidget);
    expect(tester.widget<Icon>(find.descendant(
            of: find.byKey(const ValueKey('thinq-practice')), matching: find.byType(Icon))).color,
        KioskColors.practice);
  });

  // UI 평가 10/17: 큰 글씨에서 켜기·끄기가 화면 아래(스크롤 밖)에 있었다 — 조작을 먼저, 상태는 그 아래.
  testWidgets('상세: 큰 글씨는 한 줄로 쌓고(조작 위·상태 아래) 첫 화면에 켜기·끄기가 보인다', (tester) async {
    for (final size in [const Size(800, 480), const Size(1920, 1080)]) {
      await pumpPanel(tester, read: () async => _ok(_state()), size: size, scale: 1.22);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('thinq-panel-scroll')), findsOneWidget);
      final state = tester.getRect(find.byKey(const ValueKey('thinq-row-전원')));
      final power = tester.getRect(find.byKey(const ValueKey('thinq-set-set_power-POWER_ON')));
      expect(power.bottom, lessThan(state.top), reason: '$size 조작이 상태보다 위');
      expect(find.byKey(const ValueKey('thinq-set-set_power-POWER_ON')).hitTestable(), findsOneWidget,
          reason: '$size 스크롤 없이 켜기를 누를 수 있다');
      // 단추 글자가 단추 안에 있다.
      final word = tester.getRect(find.descendant(
          of: find.byKey(const ValueKey('thinq-set-set_wind_strength-AUTO')), matching: find.text('자동')));
      final button = tester.getRect(find.byKey(const ValueKey('thinq-set-set_wind_strength-AUTO')));
      expect(button.contains(word.topLeft) && button.contains(word.bottomRight - const Offset(1, 1)), isTrue);
    }
  });

  // ── 화면 전체(KioskScreen) ─────────────────────────────────────────────────

  testWidgets('키오스크: 평소 화면에 공기 줄 → 공기청정기를 누르면 상세 → 바꾸기 → 실행 화면', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final api = FakeKioskApi()
      ..applianceList = [kMicrowaveAppliance, _purifier]
      ..air = _air
      ..thinqStatusResult = _ok(_state(), mode: 'mock')
      ..nextJobId = 'job-thinq';
    await tester.pumpWidget(MaterialApp(
      home: KioskScreen(api: api, tts: FakeTts(), events: FakeEventStream()),
    ));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(api.airCalls, greaterThan(0));
    expect(find.byKey(const ValueKey('idle-air')), findsOneWidget);
    // 평소 화면은 상태를 클라우드에서 읽지 않는다.
    expect(api.thinqStatusReads, isEmpty);

    await tester.tap(find.byKey(const ValueKey('strip-air_purifier')));
    await tester.pump();
    await tester.pump();
    expect(api.thinqStatusReads, ['air_purifier']);
    expect(find.byKey(const ValueKey('thinq-panel-air_purifier')), findsOneWidget);
    expect(find.byKey(const ValueKey('thinq-practice')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('thinq-set-set_wind_strength-HIGH')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('thinq-confirm-ok')));
    await tester.pump();
    await tester.pump();
    expect(api.thinqCommands.single.$1, 'air_purifier');
    expect(api.thinqCommands.single.$2, 'set_wind_strength');
    expect(api.thinqCommands.single.$3, {'wind_strength': 'HIGH'});
    expect(find.byType(KioskExecutingView), findsOneWidget);
    // 화면을 정리한다(타이머).
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}
