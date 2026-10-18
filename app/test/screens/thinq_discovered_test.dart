// 'LG 가전 연결' 안의 'LG 앱에서 찾은 가전' 구획 (2026-10-13).
//
// - 찾은 가전마다 지원 여부: 추가할 수 있으면 '추가' 버튼, 지원 안 함·상태만이면 이유 한 줄.
// - 추가는 사용자가 누를 때만. 누르기 전에는 허브에 아무것도 보내지 않는다.
// - 조회 실패(토큰·연결·허브 꺼짐)는 '0대'가 아니라 이유. 정말 없을 때만 0대.
// - 추가하면 홈 타일(ThinQ 배지)과 루틴 대상 목록에 바로 나온다.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/providers/appliance_provider.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/home_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';
import 'package:simplelay/widgets/thinq_discovered_section.dart';

import '../helpers/test_helpers.dart';

Map<String, dynamic> _found(
  String key,
  String kindLabel,
  String alias, {
  String support = 'controllable',
  String supportReason = '제어할 수 있어요 — 전원 · 풍량 · 운전 모드',
  bool added = false,
  String? source,
  bool canAdd = false,
  String? reason,
}) =>
    {
      'key': key,
      'device_type': 'DEVICE_X',
      'kind_label': kindLabel,
      'alias': alias,
      'model_name': 'FAKE',
      'support': support,
      'support_reason': supportReason,
      'actions': <String>[],
      'added': added,
      'source': source,
      'appliance_id': added ? 'x' : null,
      'name': added ? alias : null,
      'can_add': canAdd,
      'reason': reason,
    };

Map<String, dynamic> _discovery(List<Map<String, dynamic>> devices,
        {bool reachable = true, String? error}) =>
    {
      'mode': 'fake_cloud',
      'execution_mode': 'mock',
      'mock_cloud': true,
      'reachable': reachable,
      'error': error,
      'devices': devices,
    };

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
    utf8.encode(jsonEncode(body)), status,
    headers: {'content-type': 'application/json'});

/// 허브 흉내 — 공기청정기 한 대를 찾고, '추가'를 받으면 가전 목록에 올린다.
class _Hub {
  bool added = false;
  final posts = <Map<String, dynamic>>[];

  static const purifierKey = 'ab12cd34ef56ab78';

  Map<String, dynamic> get _purifier => _found(
        purifierKey,
        '공기청정기',
        '공기청정기(연습용 클라우드)',
        added: added,
        source: added ? 'added' : null,
        canAdd: !added,
      );

  RpiApiService service() => RpiApiService(
        'http://rpi5.local:8000',
        client: MockClient((req) async {
          if (req.method == 'GET' && req.url.path == '/thinq/discovered') {
            return _json(_discovery([_purifier]));
          }
          if (req.method == 'POST' && req.url.path == '/thinq/added') {
            posts.add(jsonDecode(req.body) as Map<String, dynamic>);
            added = true;
            return _json({
              'appliance_id': 'air_purifier',
              'name': '공기청정기(연습용 클라우드)',
              'added': true,
              'source': 'added',
            });
          }
          if (req.method == 'GET' && req.url.path == '/appliances') {
            return _json([
              if (added)
                {
                  'id': 'air_purifier',
                  'name': '공기청정기(연습용 클라우드)',
                  'category': 'air_purifier',
                  'rows': 0,
                  'cols': 0,
                  'buttons': <dynamic>[],
                  'is_custom': false,
                  'control_path': 'thinq',
                  'can_execute': true,
                  'readiness': 'operable',
                },
            ]);
          }
          return http.Response('{"detail":"not found"}', 404);
        }),
      );
}

RpiApiService _serving(http.Response Function() respond) => RpiApiService(
      'http://rpi5.local:8000',
      client: MockClient((req) async => respond()),
    );

Widget _section(RpiApiService? api,
        {void Function(ProviderContainer)? onContainerReady}) =>
    buildScreen(
      Scaffold(body: ListView(children: const [ThinqDiscoveredSection()])),
      overrides: [
        ...connectedOverrides(),
        ...installedOverrides(const []),
        rpiServerOverride(RpiConnectionState.connected),
        rpiApiServiceProvider.overrideWithValue(api),
      ],
      onContainerReady: onContainerReady,
    );

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(400, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('찾은 가전: 추가할 수 있는 것만 버튼, 지원 안 함·상태만은 이유 한 줄',
      (tester) async {
    _tall(tester);
    await tester.pumpWidget(_section(_serving(() => _json(_discovery([
          _found('k1', '공기청정기', '거실 공기청정기', canAdd: true),
          _found('k2', '공기청정기', '안방 공기청정기',
              support: 'status_only',
              supportReason: '상태만 볼 수 있어요 — 바꿀 수 있는 동작이 없어요',
              reason: '상태만 볼 수 있어요 — 바꿀 수 있는 동작이 없어요'),
          _found('k3', '냉장고', '냉장고',
              support: 'unsupported',
              supportReason: '지원하지 않아요 — SimpleLay가 아직 다루지 않는 가전 종류예요',
              reason: '지원하지 않아요 — SimpleLay가 아직 다루지 않는 가전 종류예요'),
          _found('k4', '제습기', '제습기(연습용 클라우드)',
              added: true, source: 'config'),
        ])))));
    await _settle(tester);

    expect(find.text('LG 앱에서 찾은 가전 (연습)'), findsOneWidget);
    expect(find.byKey(const Key('thinq-add-k1')), findsOneWidget);
    expect(find.text('제어할 수 있어요 — 전원 · 풍량 · 운전 모드'), findsOneWidget);
    expect(find.byKey(const Key('thinq-add-k2')), findsNothing);
    expect(find.byKey(const Key('thinq-add-k3')), findsNothing);
    expect(find.byKey(const Key('thinq-add-k4')), findsNothing);
    expect(find.textContaining('상태만 볼 수 있어요'), findsOneWidget);
    expect(find.textContaining('다루지 않는 가전 종류'), findsOneWidget);
    expect(find.text('설치할 때 넣은 가전이에요'), findsOneWidget);
    // 모델 코드는 보이지 않는다(외부 평가 10/16 p09).
    expect(find.textContaining('FAKE'), findsNothing);
    // 서버 설정으로 넣은 가전은 여기서 빼지 않는다.
    expect(find.byKey(const Key('thinq-remove-k4')), findsNothing);
    // 사용자가 허용한 자동 실행이 있으므로 '언제나 확인'이라고 하지 않는다(외부 검토 M4, 10/15).
    expect(find.textContaining('언제나 확인'), findsNothing);
    expect(find.textContaining('바꿀 때마다 한 번 물어봐요'), findsOneWidget);
    expect(find.textContaining('추가한 가전만 홈과 루틴에 나와요'), findsOneWidget);
  });

  testWidgets('토큰 오류는 0대가 아니라 이유를 말한다', (tester) async {
    _tall(tester);
    await tester.pumpWidget(_section(_serving(() => _json(_discovery(const [],
        reachable: false,
        error: 'ThinQ 토큰(PAT)이 유효하지 않아요 — 다시 발급해 주세요')))));
    await _settle(tester);

    expect(find.byKey(const Key('thinq-found-failure')), findsOneWidget);
    expect(find.textContaining('PAT'), findsOneWidget);
    expect(find.textContaining('0대'), findsNothing);
    expect(find.text('다시 찾기'), findsOneWidget);
    // 실패해도 모의 클라우드 표시는 남는다.
    expect(find.text('LG 앱에서 찾은 가전 (연습)'), findsOneWidget);
  });

  testWidgets('허브에 닿지 않으면 0대가 아니라 이유', (tester) async {
    _tall(tester);
    await tester.pumpWidget(_section(RpiApiService('http://rpi5.local:8000',
        client: MockClient((req) async => throw http.ClientException('down')))));
    await _settle(tester);
    expect(find.textContaining('본체와 연결이 끊겼어요'), findsOneWidget);
    expect(find.textContaining('0대'), findsNothing);
  });

  testWidgets('허브에서 ThinQ가 꺼져 있으면 0대가 아니라 이유', (tester) async {
    _tall(tester);
    await tester.pumpWidget(_section(
        _serving(() => http.Response('{"detail":"off"}', 404))));
    await _settle(tester);
    expect(find.textContaining('LG 가전 연결이 꺼져 있어요'), findsOneWidget);
    expect(find.textContaining('0대'), findsNothing);
  });

  testWidgets('정말 등록된 가전이 없을 때만 0대라고 말한다', (tester) async {
    _tall(tester);
    await tester.pumpWidget(_section(_serving(() => _json(_discovery(const [])))));
    await _settle(tester);
    expect(find.byKey(const Key('thinq-found-empty')), findsOneWidget);
    expect(find.byKey(const Key('thinq-found-failure')), findsNothing);
  });

  testWidgets('추가는 누를 때만 보내고, 추가하면 홈 타일·루틴 대상에 바로 나온다',
      (tester) async {
    _tall(tester);
    final hub = _Hub();
    late ProviderContainer container;
    await tester.pumpWidget(_section(hub.service(),
        onContainerReady: (c) => container = c));
    await _settle(tester);

    // 찾기만으로는 아무것도 추가하지 않는다.
    expect(hub.posts, isEmpty);
    expect(container.read(installedAppliancesProvider), isEmpty);

    await tester.tap(find.byKey(const Key('thinq-add-${_Hub.purifierKey}')));
    await _settle(tester);

    expect(hub.posts, [
      {'key': _Hub.purifierKey}
    ]);
    expect(find.textContaining('추가했어요'), findsOneWidget);
    expect(find.text('추가한 가전이에요. 홈과 루틴에 나와요'), findsOneWidget);
    expect(find.byKey(const Key('thinq-add-${_Hub.purifierKey}')), findsNothing);
    // '빼기'는 테두리 있는 버튼이다(외부 평가 10/16 p09).
    expect(
        tester.widget(find.byKey(const Key('thinq-remove-${_Hub.purifierKey}'))),
        isA<OutlinedButton>());

    // 루틴 대상(설치 가전 목록)에 ThinQ 가전으로 들어왔다.
    final installed = container.read(installedAppliancesProvider);
    expect(installed.map((a) => a.id), ['air_purifier']);
    expect(installed.single.isThinq, isTrue);

    // 홈 타일: ThinQ 배지.
    tester.state<NavigatorState>(find.byType(Navigator)).push(
        MaterialPageRoute<void>(builder: (_) => const HomeScreen()));
    await _settle(tester);
    expect(find.byKey(const Key('appliance-card-air_purifier')), findsOneWidget);
    // 'LG 가전'은 칩이 아니라 이름 아래 작은 글자(평가 14차 10/18).
    expect(find.byKey(const Key('appliance-lg-air_purifier')), findsOneWidget);
  });
}
