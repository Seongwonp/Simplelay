// 평가 11차(2026-10-18, 폰 90).
//
// 1. 루틴 목록: '자동'·'다음' 표시는 칩이 아니라 설명 줄 끝 작은 글자(+아이콘) — 따로 한 줄을 쓰지 않는다.
//    오른쪽 칸은 모든 줄이 같은 글자 단추 — '지금 하기 >' / '설정하기 >'(회색 '설정 필요' 칩 없음).
// 2. 자동으로 하기 탭: 스위치와 같은 뜻인 '자동으로 해요'·'꺼 둠' 칩은 없다(다른 까닭으로 꺼진 규칙의 까닭은 그대로).
// 3. 홈: 위 카드는 공기 상태와 다음 루틴만(가전 전원은 타일이 말한다). 안 본 알림 줄은 무슨 알림인지 말한다.
// 4. 설정: LG 가전 부제는 '켜기·끄기는 여기서, 등록은 LG 앱에서'. 못 보낸 변경을 다시 보내는 단추는 하는 일 그대로.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/appliance.dart';
import 'package:simplelay/providers/care_events_provider.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/home_screen.dart';
import 'package:simplelay/screens/routines_screen.dart';
import 'package:simplelay/screens/settings_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';
import 'package:simplelay/widgets/status_badge.dart';

import '../helpers/test_helpers.dart';

Map<String, dynamic> _appliance(String id, String name, String category, {bool mapped = true}) => {
      'id': id,
      'name': name,
      'category': category,
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

const _air = {
  'id': 'air',
  'name': '공기청정기',
  'category': 'air_purifier',
  'rows': 1,
  'cols': 1,
  'buttons': <dynamic>[],
  'control_path': 'thinq',
  'can_execute': true,
  'readiness': 'operable',
  'readiness_reasons': <String>[],
};

final _mw = _appliance('mw', '전자레인지', 'microwave');
final _washer = _appliance('washer', '세탁기', 'washing_machine', mapped: false);

List<Map<String, dynamic>> get _raw => [_mw, _washer, _air];
List<ApplianceMap> get _installed => [for (final j in _raw) ApplianceMap.fromJson(j)];

Map<String, dynamic> _thinq(String id, String name, String time, String power) => {
      'id': id,
      'name': name,
      'steps': [
        {'kind': 'thinq_command', 'appliance_id': 'air', 'action': 'set_power', 'args': {'power': power}},
      ],
      'trigger': {'kind': 'time', 'days': [0, 1, 2, 3, 4, 5, 6], 'time': time},
      'when': '매일 $time',
      'mode': 'approve',
      'enabled': true,
    };

final _routines = [
  _thinq('r-eve', '저녁 공기청정기 켜기', '22:00', 'POWER_ON'),
  _thinq('r-morn', '아침 공기청정기 끄기', '07:00', 'POWER_OFF'),
  {
    'id': 'r-heat',
    'name': '30초 데우기',
    'steps': [
      {'kind': 'press_sequence', 'appliance_id': 'mw', 'buttons': ['시작']},
    ],
    'trigger': {'kind': 'manual'},
    'when': '직접 실행할 때',
    'mode': 'approve',
    'enabled': true,
  },
  {
    'id': 'r-wash',
    'name': '빨래 시작',
    'steps': [
      {'kind': 'press_sequence', 'appliance_id': 'washer', 'buttons': ['시작']},
    ],
    'trigger': {'kind': 'manual'},
    'when': '직접 실행할 때',
    'mode': 'approve',
    'enabled': true,
  },
];

Map<String, dynamic> _next(String id, String name, String at) => {
      'routine_id': id,
      'name': name,
      'at': at,
      'when': '매일',
      'day_label': '오늘',
      'mode': 'approve',
      'mode_label': '자동 실행',
      'auto': true,
    };

final _rules = [
  {
    'id': 'ar-eve',
    'name': '저녁 공기청정기 켜기',
    'condition_text': '매일 밤 10시에',
    'action_text': '공기청정기를 켜요',
    'condition_time': '22:00',
    'enabled': true,
    'fingerprint': 'fp',
  },
  {
    'id': 'ar-heat',
    'name': '데우기가 끝나면 공기청정기 세게',
    'condition_text': '전자레인지가 데우기를 멈추면',
    'action_text': '공기청정기 바람을 세게 해요',
    'enabled': false,
    'disabled_reason': '자동으로 하기를 꺼 두셨어요.',
    'fingerprint': 'fp',
  },
  {
    'id': 'ar-estop',
    'name': '아침 공기청정기 끄기',
    'condition_text': '매일 아침 7시에',
    'action_text': '공기청정기를 꺼요',
    'condition_time': '07:00',
    'enabled': false,
    'disabled_reason': '비상 정지로 꺼졌어요. 다시 허락해 주세요.',
    'fingerprint': 'fp',
  },
];

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
    utf8.encode(jsonEncode(body)), status,
    headers: {'content-type': 'application/json'});

RpiApiService _api() => RpiApiService(
      'http://rpi5.local:8000',
      client: MockClient((req) async {
        final path = req.url.path;
        if (path.startsWith('/execute') || path.endsWith('/approve')) {
          fail('실행 경로를 불렀어요: ${req.method} $path');
        }
        if (path == '/appliances') return _json(_raw);
        if (path == '/routines') return _json(_routines);
        if (path == '/routines/next') {
          final all = [
            _next('r-eve', '저녁 공기청정기 켜기', '2026-10-18T22:00:00+09:00'),
            _next('r-morn', '아침 공기청정기 끄기', '2026-10-19T07:00:00+09:00'),
          ];
          final limit = int.tryParse(req.url.queryParameters['limit'] ?? '') ?? 3;
          return _json(all.take(limit).toList());
        }
        if (path == '/routines/auto-rules') return _json(_rules);
        if (path == '/quiet-hours') {
          return _json({'enabled': true, 'start': '22:00', 'end': '07:00', 'active': false});
        }
        if (path == '/thinq/power') {
          return _json({
            'execution_mode': 'real',
            'appliances': [
              {'appliance_id': 'air', 'power': 'on', 'age_s': 3},
            ],
          });
        }
        if (path == '/thinq/air') {
          return _json({
            'execution_mode': 'real',
            'appliances': [
              {'appliance_id': 'air', 'grade': 'NORMAL'},
            ],
          });
        }
        if (path == '/history') return _json(const []);
        if (path == '/suggestions') return _json(const []);
        return _json({'detail': 'not found'}, 404);
      }),
    );

class _SeededCare extends CareEventsNotifier {
  _SeededCare(super.ref, CareEventsState seed) {
    state = seed;
  }

  @override
  Future<void> refresh() async {}
}

RpiCareEvent _ev(int id, String kind) =>
    RpiCareEvent(id: id, kind: kind, message: '알림 $id', occurredAt: DateTime(2026, 10, 18, 8, id));

final _visited = <String>[];

Widget _app(Widget screen, {List<RpiCareEvent> care = const []}) {
  final router = GoRouter(routes: [
    GoRoute(path: '/', builder: (_, __) => screen),
    GoRoute(path: '/appliance/detail/:id', builder: (_, s) {
      _visited.add('/appliance/detail/${s.pathParameters['id']}');
      return const Scaffold();
    }),
    GoRoute(path: '/care', builder: (_, __) {
      _visited.add('/care');
      return const Scaffold();
    }),
    GoRoute(path: '/routine/edit', builder: (_, __) => const Scaffold(body: Text('편집 화면'))),
  ]);
  return buildWithProviderState(
    overrides: [
      ...connectedOverrides(),
      ...installedOverrides(_installed),
      rpiServerOverride(RpiConnectionState.connected),
      rpiApiServiceProvider.overrideWithValue(_api()),
      careEventsProvider.overrideWith(
          (ref) => _SeededCare(ref, CareEventsState(status: CareInboxStatus.ready, events: care))),
    ],
    child: MaterialApp.router(
        theme: _noKoreanFont == null
            ? ThemeData.light().copyWith(textTheme: ThemeData.light().textTheme.apply(fontFamily: 'Malgun'))
            : ThemeData.light(),
        routerConfig: router),
  );
}

// 폭 411은 평가 실기기(1080 px, 밀도 2.625)의 논리 폭.
Future<void> _pump(WidgetTester tester, Widget screen, {List<RpiCareEvent> care = const []}) async {
  tester.view.physicalSize = const Size(411, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_app(screen, care: care));
  for (var i = 0; i < 16; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Finder _in(Finder parent, Finder child) => find.descendant(of: parent, matching: child);

// 줄 수는 실제 한글 글꼴로만 잴 수 있다(시험 글꼴은 글자마다 정사각형이라 늘 넘친다).
final _koreanFont = File('C:/Windows/Fonts/malgun.ttf');
final _noKoreanFont = _koreanFont.existsSync() ? null : '맑은 고딕 글꼴이 없어 줄 수 검사를 건너뛰어요';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _visited.clear();
  });
  setUpAll(() async {
    if (_noKoreanFont != null) return;
    final bytes = _koreanFont.readAsBytesSync();
    await (FontLoader('Malgun')..addFont(Future.value(ByteData.view(bytes.buffer)))).load();
  });

  group('1. 루틴 목록', () {
    testWidgets("'자동'·'다음'은 칩이 아니라 설명 줄 끝 작은 표시 — 따로 한 줄을 쓰지 않는다", (tester) async {
      await _pump(tester, const RoutinesScreen());
      for (final id in ['r-eve', 'r-morn']) {
        final row = find.byKey(Key('routine-row-$id'));
        expect(_in(row, find.byType(StatusBadge)), findsNothing, reason: id);
        final line = find.byKey(Key('routine-line-$id'));
        final mark = find.byKey(Key('routine-auto-badge-$id'));
        expect(_in(line, mark), findsOneWidget, reason: id);
        // 규칙이 꺼져 있으면(비상 정지로 꺼진 아침 규칙) '자동 꺼짐'(평가 14차 10/18 — 규칙 값이 먼저).
        expect(_in(mark, findPlainText(id == 'r-morn' ? '자동 꺼짐' : '자동')), findsOneWidget, reason: id);
        // 설명 줄은 한 줄 — 표시가 다음 줄로 밀리지 않는다.
        if (_noKoreanFont == null) {
          final t = tester.widget<Text>(line);
          final lineH = (t.style?.fontSize ?? 14) * 1.6;
          expect(tester.getSize(line).height, lessThan(lineH), reason: '$id ${tester.getSize(line)}');
        }
        final r = tester.getRect(line);
        expect(tester.getCenter(mark).dy, inInclusiveRange(r.top, r.bottom), reason: id);
      }
      final next = find.byKey(const Key('routine-next-badge-r-eve'));
      expect(_in(find.byKey(const Key('routine-line-r-eve')), next), findsOneWidget);
      expect(_in(next, findPlainText('다음')), findsOneWidget);
    });

    testWidgets("오른쪽 칸은 같은 글자 단추 — '지금 하기 >' / '설정하기 >'", (tester) async {
      await _pump(tester, const RoutinesScreen());
      expect(findPlainText('설정 필요'), findsNothing);
      final setup = find.byKey(const Key('routine-setup-r-wash'));
      expect(_in(setup, findPlainText('설정하기')), findsOneWidget);
      expect(_in(setup, find.byIcon(Icons.chevron_right)), findsOneWidget);
      expect(_in(setup, find.byType(StatusBadge)), findsNothing);
      final run = find.byKey(const Key('routine-run-r-heat'));
      expect(_in(run, findPlainText('지금 하기')), findsOneWidget);
      // 글자 크기·굵기가 같다.
      final a = tester.widget<Text>(_in(setup, findPlainText('설정하기')));
      final b = tester.widget<Text>(_in(run, findPlainText('지금 하기')));
      expect(a.style?.fontSize, b.style?.fontSize);
      expect(a.style?.fontWeight, b.style?.fontWeight);
      await tester.tap(setup);
      await tester.pumpAndSettle();
      expect(_visited, ['/appliance/detail/washer']);
    });
  });

  group('2. 자동으로 하기 탭', () {
    testWidgets("스위치와 같은 뜻인 '자동으로 해요'·'꺼 둠'은 없다, 다른 까닭은 그대로", (tester) async {
      await _pump(tester, const RoutinesScreen());
      await tester.tap(findPlainText('자동 규칙'));
      await tester.pumpAndSettle();
      expect(_in(find.byKey(const Key('auto-rule-ar-eve')), findPlainText('자동으로 해요')), findsNothing);
      expect(findPlainText('꺼 둠'), findsNothing);
      expect(find.byKey(const Key('auto-rule-paused-ar-heat')), findsNothing);
      // 시각 루틴의 규칙은 루틴 줄에서 연다(평가 14차 10/18).
      await tester.tap(findPlainText('내 루틴'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('routine-auto-badge-r-eve')));
      await tester.pumpAndSettle();
      expect(_in(find.byKey(const Key('auto-rule-ar-eve')), findPlainText('자동으로 해요')), findsNothing);
      Navigator.of(tester.element(find.byKey(const Key('auto-rule-ar-eve')))).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('routine-auto-badge-r-morn')));
      await tester.pumpAndSettle();
      expect(findPlainText('비상 정지로 꺼졌어요', contains: true), findsOneWidget);
    });
  });

  group('3. 홈', () {
    testWidgets('위 카드는 공기와 다음 루틴만 — 가전 전원은 타일이 말한다', (tester) async {
      await _pump(tester, const HomeScreen());
      final now = find.byKey(const Key('home-now'));
      expect(now, findsOneWidget);
      expect(_in(now, findPlainText('공기 보통')), findsOneWidget);
      expect(_in(now, findPlainText('켜짐', contains: true)), findsNothing);
      expect(_in(now, findPlainText('켜진 가전', contains: true)), findsNothing);
      expect(_in(now, findPlainText('저녁 공기청정기 켜기')), findsOneWidget);
      // 전원은 가전 타일 한 곳.
      expect(_in(find.byKey(const Key('appliance-status-air')), findPlainText('켜져 있어요')), findsOneWidget);
    });

    testWidgets('안 본 알림 줄은 무슨 알림인지 말한다', (tester) async {
      await _pump(tester, const HomeScreen(), care: [
        _ev(4, 'execution_failed'),
        _ev(3, 'emergency_stop'),
        _ev(2, 'execution_failed'),
        _ev(1, 'quiet_routine'),
      ]);
      final row = find.byKey(const Key('home-attention-care'));
      expect(_in(row, findPlainText('안 본 알림 4건, 못 한 일이 있어요')), findsOneWidget);
      expect(_in(row, findPlainText('읽지 않은', contains: true)), findsNothing);
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(_visited, ['/care']);
    });

    test('알림 줄 말 — 종류 수에 따라', () {
      // 평가 13차(10/18): 이름은 '안 본 알림 N건' 하나, 볼 것이 섞이면 가장 무거운 것 한 마디(eval13_phone_test 1).
      expect(careAttentionText([_ev(1, 'quiet_routine')]), '안 본 알림 1건, 안부 신호가 있어요');
      expect(careAttentionText([_ev(2, 'danger_sound'), _ev(1, 'execution_failed')]),
          '안 본 알림 2건, 위험 소리가 났어요');
      expect(careAttentionText([_ev(1, 'something_new')]), '안 본 알림 1건');
    });
  });

  group('4. 설정', () {
    testWidgets("LG 가전 부제는 '켜기·끄기는 여기서, 등록은 LG 앱에서'", (tester) async {
      await _pump(tester, const SettingsScreen());
      expect(findPlainText('등록은 LG 앱에서', contains: true), findsOneWidget);
      expect(findPlainText('LG 앱에서 관리해요'), findsNothing);
    });

    test('못 보낸 변경을 다시 보내는 단추는 하는 일 그대로', () {
      expect(kResyncLabel, '본체 화면에 반영하기');
      expect(kResyncLabel, isNot(contains('불러오기')));
    });
  });
}
