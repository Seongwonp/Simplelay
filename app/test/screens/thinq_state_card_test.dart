// ThinQ 가전 상세의 '지금 상태' 카드 (2026-10-15).
//
// - 화면에 들어오면 GET /thinq/status/{id}를 한 번 읽어 사람 말로 보인다.
// - 못 읽으면 이유를 말하고 값을 지어내지 않는다('꺼짐'처럼 보이지 않는다). 조작 줄도 없다.
// - '다시 읽기'를 눌러야 다시 읽는다. 읽은 시각과 모의 여부를 같이 적는다.
// - 공기청정기 조작: 누르면 한 번 묻고, '바꾸기'를 눌러야 POST /thinq/command를
//   한 번 보낸 뒤 실행 상태 화면으로 간다. 취소·지금 값이면 보내지 않는다.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/appliance.dart';
import 'package:simplelay/providers/clock_provider.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/appliance_detail_screen.dart';
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
  final http.Response Function()? command;
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
            return (command ?? () => _json({'job_id': 'job-1'}))();
          }
          return http.Response('{"detail":"not found"}', 404);
        }),
      );
}

Widget _detail(RpiApiService? api) => buildWithRouter(
      '/detail',
      overrides: [
        ...connectedOverrides(),
        ...installedOverrides([_purifier]),
        rpiServerOverride(RpiConnectionState.connected),
        rpiApiServiceProvider.overrideWithValue(api),
        nowProvider.overrideWithValue(() => DateTime(2026, 10, 15, 9, 12, 5)),
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
    expect(find.text('11 · 좋음'), findsOneWidget);
    expect(find.text('20 · 보통'), findsOneWidget);
    expect(find.text('100%'), findsOneWidget);
    expect(find.text('ThinQ에서 09:12:05에 읽었어요'), findsOneWidget);
    expect(find.textContaining('모의'), findsNothing);
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
        find.text('지금 상태를 읽지 못했어요 — 상태를 읽지 못했어요 — 가전·인터넷 연결을 확인해 주세요'),
        findsOneWidget);
    expect(find.text('켜짐'), findsNothing);
    expect(find.text('꺼짐'), findsNothing);
    expect(find.textContaining('에 읽었어요'), findsNothing);
    expect(find.byType(ChoiceChip), findsNothing);
  });

  testWidgets('허브에 닿지 않으면 연결을 말한다', (tester) async {
    _tall(tester);
    final api = RpiApiService('http://rpi5.local:8000',
        client: MockClient((_) async => throw http.ClientException('down')));
    await tester.pumpWidget(_detail(api));
    await _settle(tester);

    expect(find.textContaining('허브에 닿지 않아요'), findsOneWidget);
    expect(find.text('켜짐'), findsNothing);
    expect(find.byType(ChoiceChip), findsNothing);
  });

  testWidgets("'다시 읽기'를 눌러야 다시 읽고, 바뀐 값을 보인다", (tester) async {
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

    expect(find.text('지금 상태 (모의)'), findsOneWidget);
    expect(find.text('ThinQ에서 09:12:05에 읽었어요 (모의)'), findsOneWidget);
  });

  testWidgets("풍량 '강풍' → 한 번 묻고, '바꾸기'를 눌러야 한 번 보내고 실행 상태로 간다",
      (tester) async {
    _tall(tester);
    final hub = _Hub((_) => _ok(_state()));
    await tester.pumpWidget(_detail(hub.service()));
    await _settle(tester);

    await tester.tap(find.byKey(const Key('thinq-set-set_wind_strength-HIGH')));
    await _settle(tester);
    expect(find.text('풍량을 강풍으로 바꿀까요?'), findsOneWidget);
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
      [('풍량', 'TURBO_X')],
    );
    expect(thinqStateRows(const {}), isEmpty);
    // 공기청정기 전원 칸이 없으면 조작 줄도 없다.
    expect(thinqControlsFor(const {}), isEmpty);
  });
}
