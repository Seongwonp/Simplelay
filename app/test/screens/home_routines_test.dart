// 홈 B안(2026-10-13) — 제안이 없으면 서버가 준 루틴 순서의 첫 적격 루틴을 크게,
// 나머지 적격 루틴은 간결한 행. 설정 안내는 가전 목록 아래, 타일은 상태를 말한다.
// '추천/자주 쓰는' 같은 말을 붙이지 않고, 루틴 이름을 코드에 고정하지 않는다.
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
  tester.view.physicalSize = const Size(400, 2400);
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

  // 외부 평가 10/16 4차: 큰 카드가 이미 저절로 도는 시각 루틴이었고, 설정 필요 행이 준비된 루틴보다 위에 있었다.
  testWidgets('큰 카드는 직접 실행 루틴을 먼저, 설정이 필요한 루틴 행은 맨 아래로', (tester) async {
    final washer = _appliance('washer', '세탁기', mapped: false);
    final mw = _appliance('mw', '주방 전자레인지');
    final hub = _Hub(appliances: [washer, mw], routines: [
      _routine('r-w', '빨래 시작', steps: [
        {'kind': 'press_sequence', 'appliance_id': 'washer', 'buttons': ['시작']},
      ]),
      _routine('r-t', '저녁 데우기 예약',
          trigger: {'kind': 'time', 'days': [0, 1, 2, 3, 4, 5, 6], 'time': '22:00'}),
      _routine('r-b', '30초 데우기'),
    ]);
    _tall(tester);
    await tester.pumpWidget(_home(hub,
        installed: [ApplianceMap.fromJson(washer), ApplianceMap.fromJson(mw)]));
    await _settle(tester);

    final hero = find.byKey(const Key('home-routine-hero'));
    expect(find.descendant(of: hero, matching: find.text('30초 데우기')), findsOneWidget);
    final timeRow = tester.getTopLeft(find.byKey(const Key('home-routine-row-r-t'))).dy;
    final setupRow = tester.getTopLeft(find.byKey(const Key('home-routine-row-r-w'))).dy;
    expect(timeRow, lessThan(setupRow), reason: '설정 필요 행은 맨 아래');
  });

  // 외부 평가 10/16 2차: 첫 화면 맨 위 카드가 '설정이 필요해요'인 세탁기의 '빨래 시작'이었다.
  testWidgets('큰 카드는 설정이 필요한 가전의 루틴을 건너뛴다(그 루틴은 아래 행으로)', (tester) async {
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

    final hero = find.byKey(const Key('home-routine-hero'));
    expect(find.descendant(of: hero, matching: find.text('저녁 데우기')), findsOneWidget);
    expect(find.byKey(const Key('home-routine-row-r-w')), findsOneWidget);
    // 외부 평가 10/16 3차: 아래 행도 설정이 필요한 가전이면 실행 버튼을 끄고 이유를 말한다.
    final run = tester.widget<OutlinedButton>(find.byKey(const Key('home-routine-run-r-w')));
    expect(run.onPressed, isNull);
    expect(
        find.descendant(
            of: find.byKey(const Key('home-routine-row-r-w')),
            matching: findPlainText('가전 설정이 필요해요', contains: true)),
        findsOneWidget);
    // 어절 단위 줄바꿈('버/튼' 방지, UI 평가 10/17).
    expect(tester.widget<Text>(findPlainText('가전 설정이 필요해요', contains: true)).data,
        contains(kWordJoiner));
  });

  testWidgets('제안이 없으면 서버 순서의 첫 적격 루틴이 큰 카드, 나머지 적격 루틴은 간결한 행',
      (tester) async {
    final hub = _Hub(routines: [
      _routine('r-notify', '세탁 알림', mode: 'notify'),
      _routine('r-off', '꺼둔 것', enabled: false),
      _routine('r-announce', '말만 하기', steps: [
        {'kind': 'announce', 'text': '안녕'},
      ]),
      _routine('r-b', '저녁 데우기'),
      _routine('r-c', '해동하기'),
    ]);
    _tall(tester);
    await tester.pumpWidget(_home(hub));
    await _settle(tester);

    final hero = find.byKey(const Key('home-routine-hero'));
    expect(hero, findsOneWidget);
    expect(find.descendant(of: hero, matching: find.text('저녁 데우기')), findsOneWidget);
    expect(find.byKey(const Key('home-routine-row-r-c')), findsOneWidget);
    // 적격이 아닌 루틴은 홈 실행 후보가 아니다.
    for (final name in ['세탁 알림', '꺼둔 것', '말만 하기']) {
      expect(find.text(name), findsNothing, reason: name);
    }
    // 고르는 이유를 지어내지 않는다.
    expect(find.textContaining('추천'), findsNothing);
    expect(find.textContaining('자주'), findsNothing);
    // 빈 제안 문장은 두지 않는다.
    expect(find.text('지금 확인할 제안이 없어요.'), findsNothing);
  });

  testWidgets('제안이 있으면 제안이 큰 자리, 루틴은 큰 카드로 겹쳐 강조하지 않는다',
      (tester) async {
    final hub = _Hub(routines: [_routine('r-b', '저녁 데우기')])
      ..suggestions = [
        {
          'id': 's1',
          'purpose': '즉석밥 데우기',
          'time_band': '아침',
          'occurrences': 3,
          'steps': ['즉석밥', '시작'],
          'appliance_id': 'mw',
        },
      ];
    _tall(tester);
    await tester.pumpWidget(_home(hub, suggestions: const [
      Suggestion(sequenceId: 's1', label: '즉석밥 데우기', steps: ['BT-08']),
    ]));
    await _settle(tester);
    expect(find.text('다음에'), findsOneWidget, reason: '제안 카드가 큰 자리에 있다');
    expect(find.byKey(const Key('home-routine-hero')), findsNothing);
    expect(find.byKey(const Key('home-routine-row-r-b')), findsOneWidget);
  });

  testWidgets('큰 카드의 실행하기는 승인 카드만 만들고 승인 화면으로 간다', (tester) async {
    final hub = _Hub(routines: [_routine('r-b', '저녁 데우기')]);
    _tall(tester);
    await tester.pumpWidget(_home(hub));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('home-routine-run-r-b')));
    await _settle(tester);
    expect(hub.requests.where((r) => r.endsWith('/trigger')).length, 1);
    expect(find.text('승인 화면 card-1'), findsOneWidget);
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

  testWidgets('설정 안내는 가전 목록 아래 배치(크기는 보지 않음), 해당 타일은 "설정이 필요해요"', (tester) async {
    final hub = _Hub(routines: const [], appliances: [
      _appliance('mw', '주방 전자레인지'),
      _appliance('w1', '세탁기', mapped: false),
      _appliance('w2', '건조기', mapped: false),
    ]);
    _tall(tester);
    await tester.pumpWidget(_home(hub));
    await _settle(tester);

    final summary = find.byKey(const Key('setup-summary-card'));
    expect(summary, findsOneWidget);
    expect(find.textContaining('설정할 가전'), findsOneWidget);
    final lastTile = find.byKey(const Key('appliance-card-w2'));
    expect(tester.getTopLeft(summary).dy, greaterThan(tester.getTopLeft(lastTile).dy));
    expect(find.descendant(of: lastTile, matching: find.text(keepWordsTogether('설정이 필요해요'))),
        findsOneWidget);
    // 준비된 가전은 상태 줄을 두지 않는다(2026-10-14 UX) — '바로 쓸 수 있어요'로 단정하지도 않는다.
    expect(find.byKey(const Key('appliance-status-mw')), findsNothing);
    expect(find.textContaining('바로 쓸 수 있어요'), findsNothing);
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
  testWidgets('접근성: 루틴마다 글이 제 노드를 갖는다(세 줄이 한 덩어리로 읽히지 않게)', (tester) async {
    final handle = tester.ensureSemantics();
    final hub = _Hub(routines: [
      _routine('r-a', '아침 데우기'),
      _routine('r-b', '빨래 시작'),
      _routine('r-c', '문 열기'),
    ]);
    _tall(tester);
    await tester.pumpWidget(_home(hub));
    await _settle(tester);
    const names = ['아침 데우기', '빨래 시작', '문 열기'];
    for (final name in names) {
      final label = tester.getSemantics(find.text(name)).label;
      expect(label, contains(name));
      for (final other in names.where((n) => n != name)) {
        expect(label, isNot(contains(other)), reason: '"$name" 노드에 "$other"가 섞였다: $label');
      }
    }
    // 실행 버튼은 여전히 루틴 이름으로 따로 읽힌다.
    for (final name in names) {
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
    expect(find.bySemanticsLabel('아침 데우기 실행하기'), findsOneWidget);
    expect(find.bySemanticsLabel('아침 데우기 다음에'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^실행하기$')), findsNothing);
    handle.dispose();
  });

  // ── 2026-10-14 보드 날 발견 7: 낱말 중간 줄바꿈 ─────────────────────────────────────
  testWidgets('홈 루틴 줄과 가전 타일 상태는 낱말 중간에서 꺾이지 않게 그린다("1단 / 계"·"주 / 세요")',
      (tester) async {
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
    // 홈 루틴 줄(큰 카드·간결한 행)의 "1단계"는 단과 계 사이도 붙어 있다.
    expect(shown('1\u2060단\u2060계'), isTrue);
    expect(shown('1\u2060단계'), isFalse);
    // 타일 상태 줄도 같은 규칙('설정이 필요해요'는 위 배치 테스트가 본다). 평소 상태는 줄이 없다.
    expect(find.byKey(const Key('appliance-status-mw')), findsNothing);
  });
}
