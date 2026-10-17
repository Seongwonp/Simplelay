// ThinQ 가전 상세의 '지금 상태' 카드 (2026-10-15).
//
// - 화면에 들어오면 GET /thinq/status/{id}를 한 번 읽어 사람 말로 보인다.
// - 못 읽으면 이유를 말하고 값을 지어내지 않는다('꺼짐'처럼 보이지 않는다). 조작 줄도 없다.
// - '새로 보기'를 눌러야 다시 읽는다. 읽은 시각('HH:MM에 읽음')과 모의 여부를 같이 적는다.
// - 공기청정기 조작: 누르면 한 번 묻고, '바꾸기'를 눌러야 POST /thinq/command를
//   한 번 보낸 뒤 실행 상태 화면으로 간다. 취소·지금 값이면 보내지 않는다.
// - 외부 검토 반영(10/15): 전원 꺼짐이면 켜기만(풍량·운전 모드 줄 없음, 스스로 켜지 않음),
//   미세먼지 칸이 없는 이유, 응답 없는 요청은 '결과 모름'+다시 읽기, 요청 중 잠금,
//   거절 이유(409·412·422·423)는 허브 문장, 칩의 읽는 이름, 360×780·글자 200%.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SemanticsNode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/appliance.dart';
import 'package:simplelay/providers/clock_provider.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/appliance_detail_screen.dart';
import 'package:simplelay/screens/history_screen.dart' show historyProvider;
import 'package:simplelay/services/rpi_api_service.dart';
import 'package:simplelay/widgets/thinq_state_card.dart';

import '../helpers/test_helpers.dart';

const _purifier = ApplianceMap(
  id: 'air_purifier',
  name: '공기청정기',
  category: ApplianceCategory.other,
  rows: 0,
  cols: 0,
  buttons: [],
  controlPath: 'thinq',
  readiness: 'operable',
  readinessKnown: true,
);

Map<String, dynamic> _state({String wind = 'AUTO'}) => {
      'airPurifierJobMode': {'currentJobMode': 'CLEAN'},
      'operation': {'airPurifierOperationMode': 'POWER_ON'},
      'airFlow': {'windStrength': wind, 'windStrengthDetail': wind},
      'airQualitySensor': {
        'PM1': 8,
        'PM2': 11,
        'PM10': 20,
        'PM2Level': 'GOOD',
        'PM10Level': 'NORMAL',
      },
      'filterInfo': {'filterRemainPercent': 100},
    };

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
    utf8.encode(jsonEncode(body)), status,
    headers: {'content-type': 'application/json'});

http.Response _ok(Map<String, dynamic> state, {String mode = 'real'}) => _json(
    {'appliance_id': 'air_purifier', 'execution_mode': mode, 'state': state});

class _Hub {
  _Hub(this.respond, {this.command});
  final http.Response Function(int call) respond;
  final FutureOr<http.Response> Function()? command;
  final reads = <String>[];
  final commands = <Map<String, dynamic>>[];

  RpiApiService service() => RpiApiService(
        'http://rpi5.local:8000',
        client: MockClient((req) async {
          if (req.method == 'GET' && req.url.path.startsWith('/thinq/status/')) {
            reads.add(req.url.path);
            return respond(reads.length);
          }
          if (req.method == 'POST' && req.url.path == '/thinq/command') {
            commands.add(jsonDecode(req.body) as Map<String, dynamic>);
            return await (command ?? () => _json({'job_id': 'job-1'}))();
          }
          return http.Response('{"detail":"not found"}', 404);
        }),
      );
}

Widget _detail(RpiApiService? api, {List<Override> extra = const []}) =>
    buildWithRouter(
      '/detail',
      overrides: [
        ...connectedOverrides(),
        ...installedOverrides([_purifier]),
        rpiServerOverride(RpiConnectionState.connected),
        rpiApiServiceProvider.overrideWithValue(api),
        nowProvider.overrideWithValue(() => DateTime(2026, 10, 15, 9, 12, 5)),
        ...extra,
      ],
      extraRoutes: {
        '/detail': (_) => const ApplianceDetailScreen(applianceId: 'air_purifier'),
      },
    );

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// 실행 상태 추적(주기 조회)을 남기지 않게 화면을 내린다.
Future<void> _teardown(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}

void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(400, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

ChoiceChip _chip(WidgetTester tester, String action, String value) =>
    tester.widget<ChoiceChip>(find.byKey(Key('thinq-set-$action-$value')));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('가전 상세: 지금 상태를 한 번 읽어 사람 말로 보인다', (tester) async {
    _tall(tester);
    final hub = _Hub((_) => _ok(_state()));
    await tester.pumpWidget(_detail(hub.service()));
    await _settle(tester);

    expect(find.byType(ThinqStateCard), findsOneWidget);
    expect(find.text('지금 상태'), findsOneWidget);
    expect(find.text('켜짐'), findsOneWidget);
    expect(find.text('좋음, 11'), findsOneWidget);
    expect(find.text('보통, 20'), findsOneWidget);
    expect(find.text('100%'), findsOneWidget);
    expect(find.text('09:12 기준'), findsOneWidget);
    expect(find.textContaining('에 읽었어요'), findsNothing);
    expect(find.textContaining('모의'), findsNothing);
    // 미세먼지 값이 있으면 이유 줄은 없다.
    expect(find.byKey(const Key('thinq-dust-note')), findsNothing);
    // 지금 값이 조작 줄에서 골라져 있다.
    expect(_chip(tester, 'set_power', 'POWER_ON').selected, isTrue);
    expect(_chip(tester, 'set_wind_strength', 'AUTO').selected, isTrue);
    expect(_chip(tester, 'set_job_mode', 'CLEAN').selected, isTrue);
    expect(hub.reads, ['/thinq/status/air_purifier']);
    expect(hub.commands, isEmpty);
  });

  testWidgets('못 읽으면 이유를 말하고 값·조작 줄을 내걸지 않는다', (tester) async {
    _tall(tester);
    final hub = _Hub((_) => _json(
        {'detail': '상태를 읽지 못했어요 — 가전·인터넷 연결을 확인해 주세요'}, 503));
    await tester.pumpWidget(_detail(hub.service()));
    await _settle(tester);

    expect(
        find.text('지금 상태를 못 불러왔어요. 상태를 읽지 못했어요 — 가전·인터넷 연결을 확인해 주세요'),
        findsOneWidget);
    expect(find.text('켜짐'), findsNothing);
    expect(find.text('꺼짐'), findsNothing);
    expect(find.textContaining(' 기준'), findsNothing);
    expect(find.byType(ChoiceChip), findsNothing);
  });

  testWidgets('허브에 닿지 않으면 연결을 말한다', (tester) async {
    _tall(tester);
    final api = RpiApiService('http://rpi5.local:8000',
        client: MockClient((_) async => throw http.ClientException('down')));
    await tester.pumpWidget(_detail(api));
    await _settle(tester);

    expect(find.textContaining('본체와 연결이 끊겼어요'), findsOneWidget);
    expect(find.text('켜짐'), findsNothing);
    expect(find.byType(ChoiceChip), findsNothing);
  });

  testWidgets("'새로 보기'를 눌러야 다시 읽고, 바뀐 값을 보인다", (tester) async {
    _tall(tester);
    final hub = _Hub((call) => _ok(_state(wind: call == 1 ? 'AUTO' : 'HIGH')));
    await tester.pumpWidget(_detail(hub.service()));
    await _settle(tester);
    expect(_chip(tester, 'set_wind_strength', 'AUTO').selected, isTrue);
    expect(hub.reads.length, 1);

    await tester.tap(find.byKey(const Key('thinq-status-refresh')));
    await _settle(tester);

    expect(hub.reads.length, 2);
    expect(_chip(tester, 'set_wind_strength', 'HIGH').selected, isTrue);
    expect(_chip(tester, 'set_wind_strength', 'AUTO').selected, isFalse);
  });

  testWidgets('모의 실행이면 모의라고 적는다', (tester) async {
    _tall(tester);
    final hub = _Hub((_) => _ok(_state(), mode: 'mock'));
    await tester.pumpWidget(_detail(hub.service()));
    await _settle(tester);

    expect(find.text('지금 상태 (연습)'), findsOneWidget);
    expect(find.text('09:12 기준 (연습)'), findsOneWidget);
  });

  testWidgets("바람 세기 '강' → 한 번 묻고, '바꾸기'를 눌러야 한 번 보내고 실행 상태로 간다",
      (tester) async {
    _tall(tester);
    final hub = _Hub((_) => _ok(_state()));
    await tester.pumpWidget(_detail(hub.service()));
    await _settle(tester);

    // 상태 이름과 버튼 이름을 같게(2차 평가 10/18) — '약·중·강', '약풍·강풍'을 섞지 않는다.
    expect(find.descendant(
            of: find.byKey(const Key('thinq-set-set_wind_strength-HIGH')), matching: find.text('강')),
        findsOneWidget);
    expect(find.textContaining('풍'), findsNothing);
    await tester.tap(find.byKey(const Key('thinq-set-set_wind_strength-HIGH')));
    await _settle(tester);
    expect(find.text('바람 세기를 강으로 바꿀까요?'), findsOneWidget);
    expect(hub.commands, isEmpty); // 묻는 동안에는 보내지 않는다.

    await tester.tap(find.byKey(const Key('thinq-set-confirm')));
    await _settle(tester);

    expect(hub.commands, [
      {
        'appliance_id': 'air_purifier',
        'action': 'set_wind_strength',
        'args': {'wind_strength': 'HIGH'},
      }
    ]);
    expect(find.text('상태 화면'), findsOneWidget);
    await _teardown(tester);
  });

  testWidgets('취소하면 보내지 않는다', (tester) async {
    _tall(tester);
    final hub = _Hub((_) => _ok(_state()));
    await tester.pumpWidget(_detail(hub.service()));
    await _settle(tester);

    await tester.tap(find.byKey(const Key('thinq-set-set_power-POWER_OFF')));
    await _settle(tester);
    await tester.tap(find.text('취소'));
    await _settle(tester);

    expect(hub.commands, isEmpty);
    expect(find.text('상태 화면'), findsNothing);
  });

  testWidgets('지금 값은 눌러도 묻지도 보내지도 않는다', (tester) async {
    _tall(tester);
    final hub = _Hub((_) => _ok(_state()));
    await tester.pumpWidget(_detail(hub.service()));
    await _settle(tester);

    await tester.tap(find.byKey(const Key('thinq-set-set_wind_strength-AUTO')));
    await _settle(tester);

    expect(find.byType(AlertDialog), findsNothing);
    expect(hub.commands, isEmpty);
  });

  testWidgets('허브가 거절하면 이유를 말하고 실행 상태로 가지 않는다', (tester) async {
    _tall(tester);
    final hub = _Hub((_) => _ok(_state()),
        command: () => _json({'detail': "'운전 모드' 값 'SLEEP'은 이 가전 프로필에 없어요"}, 422));
    await tester.pumpWidget(_detail(hub.service()));
    await _settle(tester);

    await tester.tap(find.byKey(const Key('thinq-set-set_job_mode-SLEEP')));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('thinq-set-confirm')));
    await _settle(tester);

    expect(hub.commands.length, 1);
    expect(find.textContaining('이 가전 프로필에 없어요'), findsOneWidget);
    expect(find.text('상태 화면'), findsNothing);
  });

  test('모르는 값은 원래 값 그대로, 없는 칸은 줄을 만들지 않는다', () {
    expect(
      thinqStateRows({
        'airFlow': {'windStrengthDetail': 'TURBO_X'},
      }),
      [('바람 세기', 'TURBO_X')],
    );
    expect(thinqStateRows(const {}), isEmpty);
    // 공기청정기 전원 칸이 없으면 조작 줄도 없다.
    expect(thinqControlsFor(const {}), isEmpty);
  });

  // ── 외부 검토 반영(2026-10-15) ──────────────────────────────────────────

  testWidgets('M2: 전원이 꺼져 있으면 켜기만 두고 풍량·운전 모드 줄은 내걸지 않는다', (tester) async {
    _tall(tester);
    // 실가전: 꺼져 있으면 airQualitySensor가 아예 없다.
    final hub = _Hub((_) => _ok({
          'airPurifierJobMode': {'currentJobMode': 'CLEAN'},
          'operation': {'airPurifierOperationMode': 'POWER_OFF'},
          'airFlow': {'windStrength': 'LOW'},
          'filterInfo': {'filterRemainPercent': 90},
        }));
    await tester.pumpWidget(_detail(hub.service()));
    await _settle(tester);

    expect(find.text('꺼짐'), findsOneWidget);
    expect(find.byKey(const Key('thinq-set-set_power-POWER_ON')), findsOneWidget);
    expect(_chip(tester, 'set_power', 'POWER_ON').onSelected, isNotNull);
    expect(_chip(tester, 'set_power', 'POWER_OFF').selected, isTrue);
    expect(find.byKey(const Key('thinq-set-set_wind_strength-HIGH')), findsNothing);
    expect(find.byKey(const Key('thinq-set-set_job_mode-SLEEP')), findsNothing);
    expect(find.text(kThinqPowerOffNote), findsOneWidget);
    // 10/15 저녁: 꺼져 있어도 값을 보는 길(ThinQ 앱 공기질 센서 '항상')을 함께 알려 준다.
    expect(
        find.text('전원이 꺼져 있어 미세먼지 값이 오지 않아요. '
            "꺼져 있을 때도 보려면 LG 앱에서 공기질 센서를 '항상'으로 바꿔 주세요."),
        findsOneWidget);
    expect(find.textContaining('받을 수 없어요'), findsNothing);
    // 스스로 켜지 않는다.
    expect(hub.commands, isEmpty);
  });

  testWidgets('꺼져 있어도 미세먼지 값이 오면(센서 "항상") 값 줄을 보이고 이유 줄은 없다', (tester) async {
    _tall(tester);
    // 실가전 10/15 저녁: 공기질 센서 '항상'이면 꺼진 채로 PM 값·등급이 온다.
    final hub = _Hub((_) => _ok({
          'airPurifierJobMode': {'currentJobMode': 'CLEAN'},
          'operation': {'airPurifierOperationMode': 'POWER_OFF'},
          'airFlow': {'windStrength': 'AUTO', 'windStrengthDetail': 'AUTO'},
          'airQualitySensor': {
            'PM1': 6,
            'PM2': 8,
            'PM10': 10,
            'PM2Level': 'GOOD',
            'PM10Level': 'BAD',
          },
        }));
    await tester.pumpWidget(_detail(hub.service()));
    await _settle(tester);

    expect(find.text('꺼짐'), findsOneWidget);
    expect(find.text('초미세먼지'), findsOneWidget);
    expect(find.text('좋음, 8'), findsOneWidget);
    expect(find.text('미세먼지'), findsOneWidget);
    expect(find.text('나쁨, 10'), findsOneWidget);
    expect(find.byKey(const Key('thinq-dust-note')), findsNothing);
    // 조작 줄은 꺼짐 규칙 그대로 — 켜기만, 풍량·운전 모드 없음.
    expect(find.text(kThinqPowerOffNote), findsOneWidget);
    expect(find.byKey(const Key('thinq-set-set_wind_strength-HIGH')), findsNothing);
    expect(hub.commands, isEmpty);
  });

  testWidgets('M2: 켜져 있는데 미세먼지 칸이 비면 아직 못 받았다고 말한다', (tester) async {
    _tall(tester);
    final hub = _Hub((_) => _ok({
          'operation': {'airPurifierOperationMode': 'POWER_ON'},
          'airFlow': {'windStrength': 'LOW'},
          'airQualitySensor': <String, dynamic>{},
        }));
    await tester.pumpWidget(_detail(hub.service()));
    await _settle(tester);

    expect(find.text('미세먼지 값이 아직 없어요. 켠 직후에는 잠시 걸려요'),
        findsOneWidget);
    expect(find.text(kThinqPowerOffNote), findsNothing);
    expect(find.byKey(const Key('thinq-set-set_wind_strength-HIGH')), findsOneWidget);
  });

  Future<void> sendHigh(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('thinq-set-set_wind_strength-HIGH')));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('thinq-set-confirm')));
    await _settle(tester);
  }

  testWidgets('M1: 연결 오류는 "보내지 못했어요"가 아니라 결과 모름 — 상태를 다시 읽는다',
      (tester) async {
    _tall(tester);
    final hub = _Hub((_) => _ok(_state()),
        command: () => throw http.ClientException('Connection closed'));
    await tester.pumpWidget(_detail(hub.service()));
    await _settle(tester);
    expect(hub.reads.length, 1);

    await sendHigh(tester);

    expect(find.text(kThinqUnknownOutcome), findsOneWidget);
    expect(find.textContaining('보내지 못했어요'), findsNothing);
    expect(find.text('상태 화면'), findsNothing);
    expect(hub.reads.length, 2); // 다시 읽어 확인한다.
  });

  testWidgets('M1: 응답이 시간 안에 오지 않아도 결과 모름 — 상태를 다시 읽는다', (tester) async {
    _tall(tester);
    final never = Completer<http.Response>();
    final hub = _Hub((_) => _ok(_state()), command: () => never.future);
    await tester.pumpWidget(_detail(hub.service()));
    await _settle(tester);

    await sendHigh(tester);
    expect(hub.commands.length, 1);
    await tester.pump(const Duration(seconds: 9)); // 폰 요청 제한(8초)을 넘긴다.
    await _settle(tester);

    expect(find.text(kThinqUnknownOutcome), findsOneWidget);
    expect(find.textContaining('보내지 못했어요'), findsNothing);
    expect(hub.reads.length, 2);
  });

  testWidgets('M1: 요청이 끝나기 전에는 다른 값을 눌러도 묻지도 보내지도 않는다', (tester) async {
    _tall(tester);
    final pending = Completer<http.Response>();
    final hub = _Hub((_) => _ok(_state()), command: () => pending.future);
    await tester.pumpWidget(_detail(hub.service()));
    await _settle(tester);

    await sendHigh(tester);
    expect(hub.commands.length, 1);
    // 응답 전 — 칩이 잠겨 있고, 눌러도 아무 일도 없다.
    expect(_chip(tester, 'set_job_mode', 'SLEEP').onSelected, isNull);
    await tester.tap(find.byKey(const Key('thinq-set-set_job_mode-SLEEP')),
        warnIfMissed: false);
    await _settle(tester);
    expect(find.byType(AlertDialog), findsNothing);
    expect(hub.commands.length, 1);

    // 허브가 거절로 답하면 잠금이 풀린다.
    pending.complete(_json({'detail': 'an execution is already in progress'}, 409));
    await _settle(tester);
    expect(find.text('다른 일을 하는 중이에요. 끝난 뒤 다시 눌러 주세요.'), findsOneWidget);
    expect(_chip(tester, 'set_job_mode', 'SLEEP').onSelected, isNotNull);
  });

  testWidgets('거절(423)은 허브가 준 이유를 그대로 보인다', (tester) async {
    _tall(tester);
    final hub = _Hub((_) => _ok(_state()),
        command: () => _json({'detail': '비상 정지 중이에요 — 해제한 뒤 다시 해 주세요'}, 423));
    await tester.pumpWidget(_detail(hub.service()));
    await _settle(tester);

    await sendHigh(tester);

    expect(find.text('비상 정지 중이에요 — 해제한 뒤 다시 해 주세요'), findsOneWidget);
    expect(find.textContaining('보내지 못했어요'), findsNothing);
    expect(find.text('상태 화면'), findsNothing);
  });

  testWidgets('409도 허브 문장이 있으면 그 문장(늘 "다른 작업 실행 중"이 아니다)', (tester) async {
    _tall(tester);
    final hub = _Hub((_) => _ok(_state()),
        command: () => _json({'detail': '루틴이 이 가전을 쓰고 있어요'}, 409));
    await tester.pumpWidget(_detail(hub.service()));
    await _settle(tester);

    await sendHigh(tester);

    expect(find.text('루틴이 이 가전을 쓰고 있어요'), findsOneWidget);
    expect(find.textContaining('다른 작업이 실행 중'), findsNothing);
  });

  test('거절 문장 표: 허브 이유 우선, 빈 이유·영어 실행 중만 우리말, 5xx는 결과 모름(null)', () {
    expect(thinqCommandRefusal(RpiApiException(423, '비상 정지 중')), '비상 정지 중');
    expect(thinqCommandRefusal(RpiApiException(412, '프로필을 확인하지 못했어요')),
        '프로필을 확인하지 못했어요');
    expect(thinqCommandRefusal(RpiApiException(409, 'an execution is already in progress')),
        '다른 일을 하는 중이에요. 끝난 뒤 다시 눌러 주세요.');
    expect(thinqCommandRefusal(RpiApiException(409, '')),
        '다른 일을 하는 중이에요. 끝난 뒤 다시 눌러 주세요.');
    expect(thinqCommandRefusal(RpiApiException(422, ' ')), '지금은 이걸 바꿀 수 없어요.');
    expect(thinqCommandRefusal(RpiApiException(500, 'boom')), isNull);
    expect(thinqCommandRefusal(RpiApiException(503, '준비 중')), isNull);
  });

  test('읽은 시각은 HH:MM에 읽음, 낭독은 HH시 MM분', () {
    final t = DateTime(2026, 10, 15, 7, 5, 59);
    expect(thinqReadTimeLine(t), '07:05 기준');
    expect(thinqReadTimeLine(t, mock: true), '07:05 기준 (연습)');
    expect(thinqReadTimeSpoken(t), '07시 05분');
  });

  testWidgets('L3: 칩마다 줄 이름을 붙인 읽는 이름과 선택 상태, 읽은 시각의 읽는 이름', (tester) async {
    _tall(tester);
    final handle = tester.ensureSemantics();
    final hub = _Hub((_) => _ok(_state()));
    await tester.pumpWidget(_detail(hub.service()));
    await _settle(tester);

    SemanticsNode node(String action, String value) =>
        tester.getSemantics(find.byKey(Key('thinq-set-$action-$value')));
    expect(node('set_wind_strength', 'AUTO'),
        isSemantics(label: '바람 세기 자동', isSelected: true, isButton: true));
    expect(node('set_job_mode', 'AUTO'),
        isSemantics(label: '모드 자동', isSelected: false));
    expect(node('set_power', 'POWER_ON'),
        isSemantics(label: '전원 켜기', isSelected: true));
    expect(node('set_power', 'POWER_OFF'),
        isSemantics(label: '전원 끄기', isSelected: false));
    expect(find.bySemanticsLabel('지금 상태, 09시 12분 기준'), findsOneWidget);
    handle.dispose();
  });

  for (final (name, state) in [
    ('켜짐', _state()),
    (
      '꺼짐',
      <String, dynamic>{
        'operation': {'airPurifierOperationMode': 'POWER_OFF'},
        'airFlow': {'windStrength': 'LOW'},
      }
    ),
  ]) {
    testWidgets('L3: 360×780·글자 200%에서 상태 카드가 넘치지 않는다($name)', (tester) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final hub = _Hub((_) => _ok(state, mode: 'mock'));
      await tester.pumpWidget(buildScreen(
        const MediaQuery(
          data: MediaQueryData(
              size: Size(360, 780), textScaler: TextScaler.linear(2.0)),
          child: Scaffold(
            body: SingleChildScrollView(
              padding: EdgeInsets.all(20),
              child: ThinqStateCard(
                  applianceId: 'air_purifier', applianceName: '공기청정기'),
            ),
          ),
        ),
        overrides: [
          ...connectedOverrides(),
          rpiServerOverride(RpiConnectionState.connected),
          rpiApiServiceProvider.overrideWithValue(hub.service()),
        ],
      ));
      await _settle(tester);
      expect(find.byType(ChoiceChip), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('L1: 오늘 사용 — ThinQ 직접 조작은 "직접 누름"이 아니라 허브 문장', (tester) async {
    _tall(tester);
    final hub = _Hub((_) => _ok(_state()));
    RpiHistoryEntry entry(String jobId, int minute, String detail) => RpiHistoryEntry(
          jobId: jobId,
          finishedAt: DateTime(2026, 10, 15, 9, minute),
          status: 'succeeded',
          retryCount: 0,
          buttons: const [],
          applianceId: 'air_purifier',
          route: 'thinq',
          outcome: 'success',
          executionMode: 'real',
          detail: detail,
        );
    await tester.pumpWidget(_detail(hub.service(), extra: [
      historyProvider.overrideWith((_) async => [
            entry('j1', 5, '강풍으로 바꿨어요.'),
            entry('j2', 1, ''),
          ]),
    ]));
    await _settle(tester);

    expect(find.textContaining('직접 누름'), findsNothing);
    expect(find.textContaining('09:05 강풍으로 바꿨어요, '), findsOneWidget);
    expect(find.textContaining('09:01 직접 바꿈, '), findsOneWidget);
  });

}
