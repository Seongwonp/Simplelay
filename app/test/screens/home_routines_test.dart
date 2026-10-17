// 홈 개편(2026-10-18, UI 개편안 §4·2차 평가) — 읽는 순서:
// 지금 우리 집(공기·켜진 가전·다음 예정) → 지금 할 일(제안) → 확인이 필요해요 → 가전 → 자주 쓰는 루틴 타일.
// 큰 '바로 실행할 수 있는 루틴' 카드는 없다. 타일은 **승인 카드만** 만든다(실행 경로를 부르지 않는다).
// '추천/자주 쓰는' 같은 이유를 지어내지 않고, 루틴 이름을 코드에 고정하지 않는다.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/appliance.dart';
import 'package:simplelay/models/line_break.dart';
import 'package:simplelay/models/suggestion.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/home_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';

import '../helpers/test_helpers.dart';

Map<String, dynamic> _appliance(String id, String name, {bool mapped = true}) => {
      'id': id,
      'name': name,
      'category': 'microwave',
      'rows': 1,
      'cols': 1,
      'is_custom': true,
      'revision': 1,
      'can_execute': true,
      'readiness': 'operable',
      'readiness_reasons': <String>[],
      'buttons': [
        {'id': '$id-1', 'label': '시작', 'x': 0, 'y': 0},
      ],
      if (mapped)
        'panel_mapping': {
          'photo': {'width': 100, 'height': 100},
        },
    };

Map<String, dynamic> _thinq(String id, String name) => {
      'id': id,
      'name': name,
      'category': 'air_purifier',
      'rows': 1,
      'cols': 1,
      'buttons': const [],
      'control_path': 'thinq',
      'can_execute': true,
      'readiness': 'operable',
      'readiness_reasons': <String>[],
    };

Map<String, dynamic> _routine(
  String id,
  String name, {
  String mode = 'approve',
  bool enabled = true,
  List<Map<String, dynamic>>? steps,
  Map<String, dynamic> trigger = const {'kind': 'manual'},
}) =>
    {
      'id': id,
      'name': name,
      'steps': steps ??
          [
            {'kind': 'press_sequence', 'appliance_id': 'mw', 'buttons': ['시작']},
          ],
      'trigger': trigger,
      'when': trigger['kind'] == 'manual' ? '직접 실행할 때' : '매일 22:00',
      'mode': mode,
      'enabled': enabled,
    };

class _Hub {
  _Hub({this.routines, this.appliances});
  List<Map<String, dynamic>>? routines; // null이면 /routines 500
  List<Map<String, dynamic>>? appliances;
  List<Map<String, dynamic>> suggestions = const [];
  List<Map<String, dynamic>> next = const [];
  List<Map<String, dynamic>> power = const [];
  List<Map<String, dynamic>> air = const [];
  final requests = <String>[];

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
            fail('홈이 실행 경로를 불렀어요: ${req.method} $path');
          }
          if (req.method == 'GET' && path == '/appliances') {
            return _json(appliances ?? [_appliance('mw', '주방 전자레인지')]);
          }
          if (req.method == 'GET' && path == '/routines') {
            final list = routines;
            return list == null ? _json({'detail': 'boom'}, 500) : _json(list);
          }
          if (req.method == 'GET' && path == '/routines/next') return _json(next);
          if (req.method == 'GET' && path == '/thinq/power') {
            return _json({'execution_mode': 'real', 'appliances': power});
          }
          if (req.method == 'GET' && path == '/thinq/air') {
            return _json({'execution_mode': 'real', 'appliances': air});
          }
          if (req.method == 'POST' && path.endsWith('/trigger')) {
            return _json({
              'kind': 'suggestion',
              'suggestion': {'id': 'card-1'},
            });
          }
          if (path == '/suggestions') return _json(suggestions);
          return _json({'detail': 'not found'}, 404);
        }),
      );
}

Widget _home(_Hub hub,
    {List<Suggestion> suggestions = const [],
    List<ApplianceMap> installed = const []}) {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (_, __) => const HomeScreen()),
      GoRoute(
        path: '/suggestion/:id',
        builder: (_, state) =>
            Scaffold(body: Text('승인 화면 ${state.pathParameters['id']}')),
      ),
      GoRoute(
        path: '/routine/edit',
        builder: (_, __) => const Scaffold(body: Text('루틴 편집기')),
      ),
      GoRoute(
        path: '/routines',
        builder: (_, __) => const Scaffold(body: Text('루틴 탭')),
      ),
      GoRoute(
        path: '/appliance/detail/:id',
        builder: (_, state) =>
            Scaffold(body: Text('가전 상세 ${state.pathParameters['id']}')),
      ),
    ],
  );
  return buildWithProviderState(
    overrides: [
      ...connectedOverrides(),
      ...installedOverrides(installed),
      rpiServerOverride(RpiConnectionState.connected),
      rpiApiServiceProvider.overrideWithValue(hub.api()),
    ],
    suggestions: suggestions,
    // 이 노트북 Flutter의 잉크 셰이더 판 불일치를 피한다(동작과 무관).
    child: MaterialApp.router(
        theme: ThemeData.dark().copyWith(splashFactory: InkRipple.splashFactory),
        routerConfig: router),
  );
}

void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(400, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 16; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Finder _tile(String id) => find.byKey(Key('home-routine-tile-$id'));

const _suggestionJson = {
  'id': 's1',
  'purpose': '즉석밥 데우기',
  'time_band': '아침',
  'occurrences': 3,
  'steps': ['즉석밥', '시작'],
  'appliance_id': 'mw',
};

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('읽는 순서: 지금 우리 집 → 지금 할 일 → 확인이 필요해요 → 가전 → 자주 쓰는 루틴', (tester) async {
    final hub = _Hub(appliances: [
      _appliance('mw', '주방 전자레인지'),
      _appliance('w1', '세탁기', mapped: false),
      _thinq('air', '공기청정기'),
    ], routines: [
      _routine('r-b', '30초 데우기'),
    ])
      ..suggestions = [_suggestionJson]
      ..power = [
        {'appliance_id': 'air', 'power': 'on', 'age_s': 3},
      ];
    _tall(tester);
    await tester.pumpWidget(_home(hub, suggestions: const [
      Suggestion(sequenceId: 's1', label: '즉석밥 데우기', steps: ['BT-08']),
    ]));
    await _settle(tester);

    double y(Finder f) => tester.getTopLeft(f).dy;
    final now = find.byKey(const Key('home-now'));
    final todo = find.byKey(const Key('home-suggestion'));
    final attention = find.byKey(const Key('home-attention'));
    final appliances = find.byKey(const Key('home-appliances'));
    final routines = find.byKey(const Key('home-routines'));
    for (final f in [now, todo, attention, appliances, routines]) {
      expect(f, findsOneWidget);
    }
    expect(y(now), lessThan(y(todo)));
    expect(y(todo), lessThan(y(attention)));
    expect(y(attention), lessThan(y(appliances)));
    expect(y(appliances), lessThan(y(routines)));
    // 큰 '바로 실행할 수 있는 루틴' 카드는 없다.
    expect(find.byKey(const Key('home-routine-hero')), findsNothing);
    expect(find.text('바로 실행할 수 있는 루틴'), findsNothing);
  });

  testWidgets('채운 주 버튼은 화면에 하나 — 제안의 "지금 하기"', (tester) async {
    final hub = _Hub(routines: [
      _routine('r-a', '아침 데우기'),
      _routine('r-b', '30초 데우기'),
      _routine('r-c', '해동하기'),
    ])
      ..suggestions = [_suggestionJson];
    _tall(tester);
    await tester.pumpWidget(_home(hub, suggestions: const [
      Suggestion(sequenceId: 's1', label: '즉석밥 데우기', steps: ['BT-08']),
    ]));
    await _settle(tester);
    expect(find.byType(FilledButton), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '지금 하기'), findsOneWidget);
    expect(find.text('실행하기'), findsNothing, reason: '같은 모양 실행하기 버튼을 줄줄이 두지 않는다');
  });

  testWidgets('홈 루틴은 줄 목록 — 직접 실행하는 적격 루틴만, 넷까지, 나머지는 루틴 탭으로', (tester) async {
    final hub = _Hub(routines: [
      _routine('r-notify', '세탁 알림', mode: 'notify'),
      _routine('r-off', '꺼둔 것', enabled: false),
      _routine('r-announce', '말만 하기', steps: [
        {'kind': 'announce', 'text': '안녕'},
      ]),
      _routine('r-t', '저녁 데우기 예약',
          trigger: {'kind': 'time', 'days': [0, 1, 2, 3, 4, 5, 6], 'time': '22:00'}),
      for (var i = 0; i < 6; i++) _routine('r-$i', '루틴 $i'),
    ]);
    _tall(tester);
    await tester.pumpWidget(_home(hub));
    await _settle(tester);

    for (var i = 0; i < 4; i++) {
      expect(_tile('r-$i'), findsOneWidget, reason: 'r-$i');
    }
    expect(_tile('r-4'), findsNothing);
    // 줄 목록(평가 5차 10/18: 가전 타일과 다른 모양) — 위아래로 선다.
    expect(tester.getTopLeft(_tile('r-0')).dx, tester.getTopLeft(_tile('r-1')).dx);
    expect(tester.getTopLeft(_tile('r-0')).dy, lessThan(tester.getTopLeft(_tile('r-1')).dy));
    // 시각 루틴은 정해진 때 저절로 돈다 — 타일로 겹쳐 두지 않는다(같은 루틴 여러 번 노출 금지).
    expect(_tile('r-t'), findsNothing);
    for (final name in ['세탁 알림', '꺼둔 것', '말만 하기']) {
      expect(find.text(name), findsNothing, reason: name);
    }
    final more = find.byKey(const Key('home-routines-more'));
    expect(more, findsOneWidget);
    expect(tester.getSize(more).height, greaterThanOrEqualTo(48));
    await tester.tap(more);
    await _settle(tester);
    expect(find.text('루틴 탭'), findsOneWidget);
    // 고르는 이유를 지어내지 않는다 — 쓴 횟수를 모르니 '자주 쓰는'이라 하지 않는다.
    expect(find.textContaining('추천'), findsNothing);
    expect(find.textContaining('자주'), findsNothing);
  });

  testWidgets('타일을 누르면 승인 카드만 만들고 승인 화면으로 간다(실행 경로 없음)', (tester) async {
    final hub = _Hub(routines: [_routine('r-b', '저녁 데우기')]);
    _tall(tester);
    await tester.pumpWidget(_home(hub));
    await _settle(tester);
    expect(tester.getSize(_tile('r-b')).height, greaterThanOrEqualTo(48));
    await tester.tap(_tile('r-b'));
    await _settle(tester);
    expect(hub.requests.where((r) => r.endsWith('/trigger')).length, 1);
    expect(find.text('승인 화면 card-1'), findsOneWidget);
  });

  testWidgets('설정이 필요한 가전의 루틴 타일은 실행 대신 그 가전 설정으로 간다', (tester) async {
    final washer = _appliance('washer', '세탁기', mapped: false);
    final mw = _appliance('mw', '주방 전자레인지');
    final hub = _Hub(appliances: [washer, mw], routines: [
      _routine('r-w', '빨래 시작', steps: [
        {'kind': 'press_sequence', 'appliance_id': 'washer', 'buttons': ['시작']},
      ]),
      _routine('r-b', '저녁 데우기'),
    ]);
    _tall(tester);
    await tester.pumpWidget(_home(hub,
        installed: [ApplianceMap.fromJson(washer), ApplianceMap.fromJson(mw)]));
    await _settle(tester);

    // 준비된 루틴이 먼저, 설정이 필요한 루틴은 뒤.
    expect(tester.getTopLeft(_tile('r-b')).dy, lessThan(tester.getTopLeft(_tile('r-w')).dy));
    // 타일은 설정 경고를 말하지 않는다(확인 카드 한 곳, 평가 3차 10/18) — 누르면 그 가전 설정으로 간다.
    expect(find.descendant(of: _tile('r-w'), matching: findPlainText('설정이 필요해요', contains: true)),
        findsNothing);
    await tester.tap(_tile('r-w'));
    await _settle(tester);
    expect(find.text('가전 상세 washer'), findsOneWidget);
    expect(hub.requests.where((r) => r.endsWith('/trigger')), isEmpty);
  });

  testWidgets('지금 우리 집: 공기·켜진 가전·다음 예정 시각(본체 시각 그대로)·자동 배지', (tester) async {
    final hub = _Hub(appliances: [_thinq('air', '공기청정기')], routines: const [])
      ..power = [
        {'appliance_id': 'air', 'power': 'on', 'age_s': 3},
      ]
      ..air = [
        {'appliance_id': 'air', 'grade': 'BAD'},
      ]
      ..next = [
        {
          'routine_id': 'r-n',
          'name': '저녁 공기청정기 켜기',
          'at': '2026-10-18T22:00:00-03:00',
          'when': '매일 22:00',
          'mode': 'approve',
          'mode_label': '자동 실행',
          'auto': true,
          'day_label': '오늘',
        },
      ];
    _tall(tester);
    await tester.pumpWidget(_home(hub));
    await _settle(tester);

    final now = find.byKey(const Key('home-now'));
    expect(find.descendant(of: now, matching: findPlainText('공기 나쁨')), findsOneWidget);
    expect(find.descendant(of: now, matching: findPlainText('공기청정기 켜짐')), findsOneWidget);
    // 오전/오후 표기(평가 7차 10/18) — 큰 '10:00' 위에 작은 '오후'.
    expect(find.descendant(of: now, matching: find.text('10:00')), findsOneWidget);
    expect(find.descendant(of: now, matching: find.text('오후')), findsOneWidget);
    expect(find.descendant(of: now, matching: findPlainText('저녁 공기청정기 켜기')), findsOneWidget);
    expect(find.descendant(of: now, matching: findPlainText('자동으로 해요')), findsOneWidget);
    expect(find.descendant(of: now, matching: findPlainText('오늘', contains: true)), findsWidgets);
    // 큰 시각은 32 숫자 단계.
    expect(tester.widget<Text>(find.descendant(of: now, matching: find.text('10:00'))).style?.fontSize, 32);
  });

  testWidgets('지금 우리 집: 모르는 것은 말하지 않는다 — 공기·전원·예정이 모두 없으면 칸이 없다', (tester) async {
    final hub = _Hub(routines: const []);
    _tall(tester);
    await tester.pumpWidget(_home(hub));
    await _settle(tester);
    expect(find.byKey(const Key('home-now')), findsNothing);
    expect(find.textContaining('공기 '), findsNothing);
  });

  testWidgets('LG 가전 타일: 읽은 꺼짐일 때만 "꺼져 있어요", 모르면 전원을 말하지 않고 할 일만', (tester) async {
    final hub = _Hub(appliances: [_thinq('air', '공기청정기'), _thinq('dh', '제습기')], routines: const [])
      ..power = [
        {'appliance_id': 'air', 'power': 'off', 'age_s': 3},
      ];
    _tall(tester);
    await tester.pumpWidget(_home(hub));
    await _settle(tester);
    expect(find.descendant(of: find.byKey(const Key('appliance-status-air')), matching: findPlainText('꺼져 있어요')),
        findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('appliance-status-dh')), matching: findPlainText('준비됐어요')),
        findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('appliance-card-dh')), matching: findPlainText('꺼져 있어요')),
        findsNothing);
  });

  testWidgets('확인이 필요해요: 설정이 남은 가전이 있을 때만, 가전 목록 위에', (tester) async {
    final hub = _Hub(routines: const [], appliances: [
      _appliance('mw', '주방 전자레인지'),
      _appliance('w1', '세탁기', mapped: false),
      _appliance('w2', '건조기', mapped: false),
    ]);
    _tall(tester);
    await tester.pumpWidget(_home(hub));
    await _settle(tester);

    final attention = find.byKey(const Key('home-attention'));
    expect(attention, findsOneWidget);
    expect(find.descendant(of: attention, matching: find.text('확인이 필요해요')), findsOneWidget);
    expect(find.descendant(of: attention, matching: find.byKey(const Key('setup-summary-card'))), findsOneWidget);
    final lastTile = find.byKey(const Key('appliance-card-w2'));
    expect(tester.getTopLeft(attention).dy, lessThan(tester.getTopLeft(lastTile).dy));
    // 타일은 아이콘 점 + 띠 문장 '설정이 필요해요'(평가 7차 10/18) — 무엇이 남았는지는 확인 카드 한 곳.
    expect(find.byKey(const Key('appliance-setup-dot-w2')), findsOneWidget);
    expect(find.descendant(of: lastTile, matching: find.text(keepWordsTogether('설정이 필요해요'))),
        findsOneWidget);
    // 준비된 가전은 할 일만 — '바로 쓸 수 있어요'로 단정하지 않는다.
    expect(find.descendant(of: find.byKey(const Key('appliance-status-mw')), matching: findPlainText('준비됐어요')),
        findsOneWidget);
    expect(find.textContaining('바로 쓸 수 있어요'), findsNothing);
  });

  testWidgets('확인할 것이 없으면 "확인이 필요해요" 칸이 없다', (tester) async {
    final hub = _Hub(routines: const [], appliances: const []);
    _tall(tester);
    await tester.pumpWidget(_home(hub));
    await _settle(tester);
    expect(find.byKey(const Key('home-attention')), findsNothing);
    expect(find.text('확인이 필요해요'), findsNothing);
  });

  testWidgets('루틴 조회 실패는 "루틴이 없다"로 말하지 않는다', (tester) async {
    final hub = _Hub(routines: null);
    _tall(tester);
    await tester.pumpWidget(_home(hub));
    await _settle(tester);
    expect(find.text('루틴을 불러오지 못했어요.'), findsOneWidget);
    expect(find.byKey(const Key('home-new-routine')), findsNothing);
  });

  testWidgets('루틴이 0개면 새 루틴 진입 하나만 둔다', (tester) async {
    final hub = _Hub(routines: const []);
    _tall(tester);
    await tester.pumpWidget(_home(hub));
    await _settle(tester);
    expect(find.byKey(const Key('home-new-routine')), findsOneWidget);
    await tester.tap(find.byKey(const Key('home-new-routine')));
    await _settle(tester);
    expect(find.text('루틴 편집기'), findsOneWidget);
  });

  testWidgets('타일 접근성 이름에 상태가 들어간다(excludeSemantics로 빠지지 않게)',
      (tester) async {
    final handle = tester.ensureSemantics();
    final hub = _Hub(routines: [_routine('r-b', '저녁 데우기')], appliances: [
      _appliance('w1', '세탁기', mapped: false),
    ]);
    _tall(tester);
    await tester.pumpWidget(_home(hub));
    await _settle(tester);
    expect(find.bySemanticsLabel('세탁기, 설정이 필요해요'), findsOneWidget);
    expect(find.bySemanticsLabel('저녁 데우기 실행하기'), findsOneWidget);
    handle.dispose();
  });

  // ── 2026-10-14 보드 날 발견 5: 접근성 트리 ─────────────────────────────────────────
  testWidgets('접근성: 루틴 타일마다 제 이름으로 따로 읽힌다', (tester) async {
    final handle = tester.ensureSemantics();
    final hub = _Hub(routines: [
      _routine('r-a', '아침 데우기'),
      _routine('r-b', '빨래 시작'),
      _routine('r-c', '문 열기'),
    ]);
    _tall(tester);
    await tester.pumpWidget(_home(hub));
    await _settle(tester);
    for (final name in ['아침 데우기', '빨래 시작', '문 열기']) {
      expect(find.bySemanticsLabel('$name 실행하기'), findsOneWidget);
    }
    handle.dispose();
  });

  testWidgets('접근성: 제안 카드의 버튼 이름에 대상(루틴·제안 이름)이 들어간다', (tester) async {
    final handle = tester.ensureSemantics();
    final hub = _Hub(routines: const [])
      ..suggestions = [
        {
          'id': 's1',
          'purpose': "'아침 데우기' 루틴을 실행할까요?",
          'time_band': '루틴',
          'occurrences': 0,
          'steps': ['시작'],
          'appliance_id': 'mw',
          'routine_id': 'rt-1',
          'routine_name': '아침 데우기',
        },
      ];
    _tall(tester);
    await tester.pumpWidget(_home(hub, suggestions: const [
      Suggestion(
          sequenceId: 's1',
          label: "'아침 데우기' 루틴을 실행할까요?",
          routineName: '아침 데우기',
          steps: ['BT-08']),
    ]));
    await _settle(tester);
    expect(find.bySemanticsLabel('아침 데우기 지금 하기'), findsOneWidget);
    expect(find.bySemanticsLabel('아침 데우기 다음에'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^지금 하기$')), findsNothing);
    handle.dispose();
  });

  // ── 2026-10-14 보드 날 발견 7: 낱말 중간 줄바꿈 ─────────────────────────────────────
  testWidgets('루틴 타일 부제와 가전 타일 상태는 낱말 중간에서 꺾이지 않게 그린다', (tester) async {
    final hub = _Hub(routines: [
      _routine('r-a', '아침 데우기'),
      _routine('r-b', '빨래 시작'),
    ]);
    _tall(tester);
    await tester.pumpWidget(_home(hub));
    await _settle(tester);
    bool shown(String fragment) => find
        .byWidgetPredicate((w) => w is Text && (w.data ?? '').contains(fragment))
        .evaluate()
        .isNotEmpty;
    expect(shown(keepPhrasesTogether('주방 전자레인지 · 누를 버튼 1개', wholeParts: true)), isTrue);
    expect(shown(keepWordsTogether('준비됐어요')), isTrue);
  });
}
