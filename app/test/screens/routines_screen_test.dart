// 루틴 탭·편집기(UI 확정 §2, 2026-09-30) — 가짜 서버로 목록 → 편집 → 저장까지.
//
// 이 화면들은 **실행하지 않는다.** 저장은 POST/PUT /routines, '지금 실행'도
// 카드를 만들 뿐이다 -- 아래 서버는 실행 경로(/execute*, approve)가 불리면
// 테스트를 실패시킨다.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/appliance.dart';
import 'package:simplelay/models/routine.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/routine_editor_screen.dart';
import 'package:simplelay/screens/routines_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';

import '../helpers/test_helpers.dart';

Map<String, dynamic> _routine({String mode = 'approve'}) => {
      'schema_version': 1,
      'id': 'rt-1',
      'name': '아침 데우기',
      'icon': null,
      'steps': [
        {
          'kind': 'press_sequence',
          'appliance_id': 'microwave',
          'buttons': ['BT-07', 'BT-03', 'BT-05'],
        },
      ],
      'trigger': {
        'kind': 'time',
        'days': [0, 1, 2, 3, 4],
        'time': '07:30',
      },
      'conditions': <dynamic>[],
      'mode': mode,
      'enabled': true,
      'when': '평일 07:30',
      'mode_label': mode == 'approve' ? '승인 후 실행' : '알림만',
    };

const _template = {
  'template_id': 'visitor',
  'scene': '낮',
  'name': '방문자 문 열기',
  'icon': 'door',
  'description': '인터폰으로 방문자를 확인하고, 승인하면 문 열림 버튼을 눌러요',
  'caution': '인터폰 호출 감지는 아직 없어요. 지금은 직접 실행해서 승인 카드를 띄워요',
  'trigger': {'kind': 'manual'},
  'conditions': <dynamic>[],
  'mode': 'approve',
  'steps': [
    {
      'kind': 'press_sequence',
      'appliance_id': 'microwave',
      'buttons': ['시작'],
    },
  ],
  'is_template': true,
};

class _Server {
  Map<String, dynamic> stored = _routine();

  /// 있으면 GET /routines가 이것을 돌려준다(저장 경로는 쓰지 않는 테스트용).
  List<Map<String, dynamic>>? routines;

  /// GET /appliances 응답. 없으면 404(가전 목록 조회 실패).
  List<Map<String, dynamic>>? appliances;
  final requests = <String>[];
  Map<String, dynamic>? lastBody;
  String? rejectDetail;

  http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
        utf8.encode(jsonEncode(body)),
        status,
        headers: {'content-type': 'application/json'},
      );

  RpiApiService api() => RpiApiService(
        'http://rpi5.local:8000',
        client: MockClient((req) async {
          final path = req.url.path;
          requests.add('${req.method} $path');
          if (path.startsWith('/execute') || path.endsWith('/approve')) {
            fail('루틴 화면이 실행 경로를 불렀어요: ${req.method} $path');
          }
          if (req.method == 'GET' && path == '/routines') {
            return _json(routines ?? [stored]);
          }
          if (req.method == 'GET' && path == '/appliances') {
            final list = appliances;
            if (list != null) return _json(list);
          }
          if (req.method == 'GET' && path == '/routines/templates') {
            return _json([_template]);
          }
          if (req.method == 'GET' && path == '/routines/next') {
            return _json([
              {
                'routine_id': 'rt-1',
                'name': '아침 데우기',
                'icon': null,
                'at': DateTime(2026, 10, 1, 7, 30).toIso8601String(),
                'when': '평일 07:30',
                'mode': 'approve',
                'mode_label': '승인 후 실행',
              },
            ]);
          }
          if ((req.method == 'PUT' && path == '/routines/rt-1') ||
              (req.method == 'POST' && path == '/routines')) {
            lastBody = jsonDecode(utf8.decode(req.bodyBytes)) as Map<String, dynamic>;
            final reject = rejectDetail;
            if (reject != null) return _json({'detail': reject}, 422);
            final saved = {
              ..._routine(mode: lastBody!['mode'] as String),
              ...lastBody!,
              'id': req.method == 'POST' ? 'rt-2' : 'rt-1',
            };
            if (req.method == 'PUT') stored = saved;
            return _json(saved, req.method == 'POST' ? 201 : 200);
          }
          if (path == '/suggestions') return _json(<dynamic>[]);
          return _json({'detail': 'not found'}, 404);
        }),
      );
}

Widget _build(_Server server, {List<ApplianceMap>? installed}) {
  final router = GoRouter(
    initialLocation: '/routines',
    routes: [
      GoRoute(path: '/routines', builder: (_, __) => const RoutinesScreen()),
      GoRoute(
        path: '/routine/edit',
        builder: (_, state) =>
            RoutineEditorScreen(initial: state.extra as Routine?),
      ),
    ],
  );
  return buildWithProviderState(
    overrides: [
      ...connectedOverrides(),
      ...installedOverrides(installed ?? [kTestAppliance]),
      rpiApiServiceProvider.overrideWithValue(server.api()),
    ],
    child: MaterialApp.router(theme: ThemeData.dark(), routerConfig: router),
  );
}

void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(500, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 16; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('다음 실행과 내 루틴 목록을 보여 준다', (tester) async {
    _tall(tester);
    await tester.pumpWidget(_build(_Server()));
    await _settle(tester);

    expect(find.text('다음 실행 · 아침 데우기'), findsOneWidget);
    expect(find.text('07:30'), findsOneWidget);
    expect(find.text('아침 데우기'), findsOneWidget);
    // 언제 · 대상 · 실행 방식을 한 줄로.
    expect(find.textContaining('평일 07:30 · 전자레인지 1단계 · 승인 후 실행'),
        findsOneWidget);
    expect(find.text('새 루틴'), findsOneWidget);
  });

  testWidgets('루틴 줄은 가전 ID가 아니라 이름을 쓴다 -- 서버에만 등록된 가전도',
      (tester) async {
    // 2026-10-07 에뮬레이터: "직접 실행할 때 · home_mw 2단계 · 승인 후 실행".
    // home_mw·washer는 PUT /appliances로 서버에만 올린 사용자 가전이다.
    Map<String, dynamic> appliance(String id, String name, String category) => {
          'id': id,
          'name': name,
          'category': category,
          'rows': 1,
          'cols': 1,
          'is_custom': true,
          'revision': 1,
          'buttons': [
            {'id': '$id-1', 'label': '시작', 'x': 0, 'y': 0},
          ],
        };
    Map<String, dynamic> manual(
            String id, String name, List<Map<String, dynamic>> steps) =>
        {
          ..._routine(),
          'id': id,
          'name': name,
          'trigger': {'kind': 'manual'},
          'when': '직접 실행할 때',
          'steps': steps,
        };
    final server = _Server()
      ..appliances = [
        appliance('home_mw', '전자레인지', 'microwave'),
        appliance('washer', '세탁기', 'washing_machine'),
      ]
      ..routines = [
        manual('rt-mw', '즉석밥', [
          {'kind': 'press_sequence', 'appliance_id': 'home_mw', 'buttons': ['시작']},
          {'kind': 'wait_until_done', 'appliance_id': 'home_mw'},
        ]),
        manual('rt-wash', '빨래', [
          {'kind': 'press_sequence', 'appliance_id': 'washer', 'buttons': ['시작']},
        ]),
        manual('rt-ghost', '모르는 가전', [
          {'kind': 'press_sequence', 'appliance_id': 'ghost', 'buttons': ['시작']},
        ]),
      ];
    _tall(tester);
    await tester.pumpWidget(_build(server, installed: const []));
    await _settle(tester);

    expect(find.text('직접 실행할 때 · 전자레인지 2단계 · 승인 후 실행'),
        findsOneWidget);
    expect(find.text('직접 실행할 때 · 세탁기 1단계 · 승인 후 실행'), findsOneWidget);
    expect(find.textContaining('home_mw'), findsNothing);
    expect(find.textContaining('washer'), findsNothing);
    // 이름을 모르는 가전만 ID로 남는다.
    expect(find.text('직접 실행할 때 · ghost 1단계 · 승인 후 실행'), findsOneWidget);
  });

  testWidgets('루틴을 열어 알림만으로 바꿔 저장하면 PUT하고 목록이 다시 읽힌다',
      (tester) async {
    final server = _Server();
    _tall(tester);
    await tester.pumpWidget(_build(server));
    await _settle(tester);

    await tester.tap(find.byKey(const Key('routine-rt-1')));
    await _settle(tester);

    // 문장형 카드: 언제 · 무엇을.
    expect(find.text('언제'), findsOneWidget);
    expect(find.text('무엇을'), findsOneWidget);
    expect(find.text('평일 07:30'), findsOneWidget);
    expect(find.text('해동 → 1분 → 시작'), findsOneWidget);
    // 저장한 루틴은 '지금 실행'을 낼 수 있다(카드만 만든다).
    expect(find.text('지금 실행'), findsOneWidget);

    await tester.tap(find.text('알림만'));
    await tester.pump();
    expect(find.text('알림만 보내요. 가전은 누르지 않아요.'), findsOneWidget);
    // 고치는 중에는 '지금 실행'을 내리지 않는다 -- 저장 전 내용으로 카드가 뜬다.
    expect(find.text('지금 실행'), findsNothing);

    server.requests.clear();
    await tester.tap(find.byKey(const Key('routine-save')));
    await _settle(tester);

    expect(server.requests, contains('PUT /routines/rt-1'));
    expect(server.lastBody!['mode'], 'notify');
    expect(server.lastBody!['name'], '아침 데우기');
    expect(server.lastBody!['steps'], [
      {
        'kind': 'press_sequence',
        'appliance_id': 'microwave',
        'buttons': ['BT-07', 'BT-03', 'BT-05'],
      },
    ]);
    expect(server.lastBody!.containsKey('id'), isFalse);
    // 편집기가 닫히고 목록이 다시 읽혔다.
    expect(find.text('언제'), findsNothing);
    expect(server.requests, contains('GET /routines'));
    expect(find.textContaining('알림만'), findsOneWidget);
  });

  testWidgets('추천을 골라 저장하면 새 루틴(POST)이 된다',
      (tester) async {
    final server = _Server();
    _tall(tester);
    await tester.pumpWidget(_build(server));
    await _settle(tester);

    await tester.tap(find.text('추천'));
    await _settle(tester);
    expect(find.text('방문자 문 열기'), findsOneWidget);

    await tester.tap(find.text('방문자 문 열기'));
    await _settle(tester);
    // 새 초안이라 '지금 실행'은 없고 주의 문장이 보인다.
    expect(find.text('새 루틴'), findsOneWidget);
    expect(find.text('지금 실행'), findsNothing);
    expect(find.textContaining('인터폰 호출 감지는 아직 없어요'), findsOneWidget);

    await tester.tap(find.text('직접 실행으로 정하기'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('routine-save')));
    await _settle(tester);
    expect(server.requests, contains('POST /routines'));
    expect(server.lastBody!['name'], '방문자 문 열기');
    expect(server.lastBody!.containsKey('template_id'), isFalse);
  });

  testWidgets('서버가 거절(422)하면 그 문장을 그대로 보여 주고 머문다', (tester) async {
    final server = _Server()
      ..rejectDetail = "'전자레인지' 조작부 사진에 없는 버튼이에요: 순간이동";
    _tall(tester);
    await tester.pumpWidget(_build(server));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('routine-rt-1')));
    await _settle(tester);

    await tester.tap(find.text('알림만'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('routine-save')));
    await _settle(tester);

    expect(find.text("'전자레인지' 조작부 사진에 없는 버튼이에요: 순간이동"),
        findsOneWidget);
    expect(find.text('언제'), findsOneWidget);
  });
}
