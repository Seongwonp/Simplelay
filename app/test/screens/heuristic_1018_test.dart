// 독립 휴리스틱 평가(닐슨 10원칙, 2026-10-18 폰 66점) + 보호자(45세) 과업 걷기 평가 반영.
//
// 1. 루틴 '지금 하기'는 한 번 묻는다 — '지금 30초 데우기를 할까요? 전자레인지 버튼 2개를 눌러요'(취소·지금 하기 대등).
//    LG 가전만이면 가전 이름·할 일, 연습 가전만이면 '연습으로 해 볼까요?'. 홈 루틴 줄도 같은 시트. 확인 뒤 경로는 그대로.
// 2. 홈: 맨 위에 실패 경고만 따로(할 일 단추), 그 아래 '해야 할 일'(설정 남음), 알림은 설정과 같은 전체 수 하나.
// 3. 기록 실패 줄을 펼치면 다음 행동 — LG 가전 거절은 '○○ 상태 보기', 보내지 못한(안 누른) 루틴은 '다시 해 보기'(확인 시트),
//    눌렸는지 모르면 다시 누르기 단추 없이 집에서 확인하라는 안내(R1).
// 4. 연습 가전: 이름에서 '(연습)'을 빼고 '연습' 표지, 띠는 연습 색. LG 가전 띠는 손 아이콘 '준비됐어요' 대신 '확인 전이에요'.
// 5. 타일 원인은 짧게 말줄임 없이('누름 장치가 다른 가전 위에 있어요'), 띠는 키오스크와 같은 '설정이 필요해요'.
// 6. 설정 '사용 방법' — 누름 장치·LG 가전·멈추는 방법·연습·보호자 알림.
// 7. 마이크 옆 '말로 하기' 글자, 본체 끊김은 설정 위 배너 한 번(줄은 '못 불러왔어요'), ⋮ 메뉴 읽는 이름에 항목.
// A. 정해진 시각 루틴 줄에 켜기·끄기 스위치(규칙이 있으면 규칙, 없으면 루틴), '지금 하기'는 따로 작은 단추, 끈 뒤 알림.
// B. 기록 '못 한 일만' 거르기, 날짜 머리(오늘·어제), 멈춘 까닭 한 줄, '한 번 더 눌렀지만 눌렸는지 몰라요'.
// C. 폰은 멀리 있는 보호자도 쓴다 — '가전이 움직이는지 봐 주세요' 대신 '집에서 확인이 필요해요' 꼴.
// D. 설정의 연습 가전 부제 '연습용이라 등록할 필요 없어요'.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/appliance.dart';
import 'package:simplelay/models/display_status.dart';
import 'package:simplelay/models/execution_status.dart';
import 'package:simplelay/providers/server_appliance_provider.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/history_screen.dart';
import 'package:simplelay/screens/home_screen.dart';
import 'package:simplelay/screens/routine_editor_screen.dart';
import 'package:simplelay/models/routine.dart';
import 'package:simplelay/screens/routines_screen.dart';
import 'package:simplelay/screens/settings_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';
import 'package:simplelay/theme/app_colors.dart';

import '../helpers/test_helpers.dart';

const _gantryAbsent = '누름 장치가 이 가전 위에 없어서 누를 수 없어요';

Map<String, dynamic> _custom(String id, String name, String category,
        {String readiness = 'operable', bool canExecute = true, List<String> reasons = const []}) =>
    {
      'id': id,
      'name': name,
      'category': category,
      'rows': 1,
      'cols': 1,
      'is_custom': true,
      'revision': 1,
      'can_execute': canExecute,
      'readiness': readiness,
      'readiness_reasons': reasons,
      'buttons': [
        {'id': '$id-1', 'label': '시작', 'x': 0, 'y': 0},
      ],
      'panel_mapping': {
        'photo': {'width': 100, 'height': 100},
      },
    };

Map<String, dynamic> _thinq(String id, String name, String category) => {
      'id': id,
      'name': name,
      'category': category,
      'rows': 0,
      'cols': 0,
      'buttons': <dynamic>[],
      'control_path': 'thinq',
      'can_execute': true,
      'readiness': 'operable',
      'readiness_reasons': <String>[],
    };

final _mw = _custom('mw', '전자레인지', 'microwave');
final _ind = _custom('ind', '인덕션', 'induction',
    readiness: 'needs_setup', canExecute: false, reasons: const [_gantryAbsent]);
final _air = _thinq('air', '공기청정기', 'air_purifier');
final _pwash = _thinq('pwash', 'LG 세탁기(연습)', 'washing_machine');

List<Map<String, dynamic>> _raw = [_mw, _air, _pwash, _ind];
List<ApplianceMap> get _installed => [for (final j in _raw) ApplianceMap.fromJson(j)];

Map<String, dynamic> _press(String id, String name, String appliance, int n) => {
      'schema_version': 1,
      'id': id,
      'name': name,
      'steps': [
        {'kind': 'press_sequence', 'appliance_id': appliance, 'buttons': List.filled(n, '$appliance-1')},
      ],
      'trigger': {'kind': 'manual'},
      'mode': 'approve',
      'enabled': true,
    };

Map<String, dynamic> _lg(String id, String name, String appliance, String action, Map<String, dynamic> args,
        {String? time}) =>
    {
      'schema_version': 1,
      'id': id,
      'name': name,
      'steps': [
        {'kind': 'thinq_command', 'appliance_id': appliance, 'action': action, 'args': args},
      ],
      'trigger': time == null
          ? {'kind': 'manual'}
          : {
              'kind': 'time',
              'days': [0, 1, 2, 3, 4, 5, 6],
              'time': time,
            },
      if (time != null) 'when': '매일 $time',
      'mode': 'approve',
      'enabled': true,
    };

final _routines = [
  _press('r-mw', '30초 데우기', 'mw', 2),
  _lg('r-air', '공기청정기 켜 두기', 'air', 'set_power', {'power': 'POWER_ON'}),
  _lg('r-pw', '연습 빨래', 'pwash', 'set_operation', {'operation': 'START'}),
  _lg('rt-eve', '저녁 공기청정기 켜기', 'air', 'set_power', {'power': 'POWER_ON'}, time: '22:00'),
  _lg('rt-morn', '아침 공기청정기 끄기', 'air', 'set_power', {'power': 'POWER_OFF'}, time: '07:00'),
];

final _rules = [
  {
    'id': 'ar-t',
    'scenario_id': 'routine_time',
    'name': '저녁 공기청정기 켜기',
    'condition_kind': 'time',
    'condition_time': '22:00',
    'condition_text': '매일 밤 10시에',
    'action_text': '공기청정기를 켜요',
    'action': 'set_power',
    'value': 'POWER_ON',
    'allowed_values': const [],
    'enabled': true,
    'disabled_reason': null,
    'fingerprint': 'fp-t',
  },
  {
    'id': 'ar-s',
    'scenario_id': 'cook_done_air',
    'name': '전자레인지가 멈추면 공기청정기 세게',
    'condition_kind': 'event',
    'condition_text': '전자레인지가 데우기를 멈추면',
    'action_text': '공기청정기 바람을 세게 해요',
    'action': 'set_wind_strength',
    'value': 'HIGH',
    'allowed_values': const [
      {'value': 'MID', 'label': '중'},
      {'value': 'HIGH', 'label': '강'},
    ],
    'enabled': true,
    'disabled_reason': null,
    'fingerprint': 'fp-s',
  },
];

Map<String, dynamic> _h(String id, String at,
        {String? purpose,
        String status = 'failed',
        String? outcome,
        String route = 'physical',
        String receipt = 'accepted',
        String confirmation = 'none',
        String termination = 'unknown',
        String detail = '',
        String? abort,
        String appliance = 'mw',
        List<Map<String, dynamic>> buttons = const []}) =>
    {
      'job_id': id,
      'finished_at': at,
      'status': status,
      'outcome': outcome,
      'retry_count': 0,
      'buttons': buttons,
      'execution_mode': 'real',
      'route': route,
      'receipt': receipt,
      'confirmation': confirmation,
      'termination': termination,
      'purpose': purpose,
      'detail': detail,
      'abort_reason': abort,
      'appliance_id': appliance,
    };

final _history = [
  _h('ok-1', '2026-09-09T08:30:00',
      purpose: '공기청정기 켜줘',
      status: 'succeeded',
      outcome: 'success',
      route: 'thinq',
      confirmation: 'state_confirmed',
      appliance: 'air'),
  _h('fail-air', '2026-09-09T08:20:00',
      purpose: '공기청정기 바람 중간으로 해줘',
      outcome: 'failed',
      route: 'thinq',
      receipt: 'rejected',
      detail: '가전의 지금 모드에서는 이 명령을 받을 수 없어요.',
      appliance: 'air'),
  _h('fail-ex', '2026-09-08T20:00:00',
      purpose: "'30초 데우기' 루틴",
      outcome: 'failed',
      termination: 'retries_exhausted',
      buttons: const [
        {'button': '시작', 'success': false, 'attempts': 3},
      ]),
  _h('fail-nd', '2026-09-08T19:00:00',
      purpose: "'30초 데우기' 루틴",
      outcome: 'failed',
      receipt: 'not_dispatched',
      buttons: const [
        {'button': '시작', 'success': false, 'attempts': 0},
      ]),
  _h('stop-u', '2026-09-08T18:00:00',
      purpose: '즉석밥 데워줘', status: 'safety_stopped', termination: 'stopped_by_user'),
  _h('stop-l', '2026-09-08T17:00:00', purpose: '즉석밥 데워줘', outcome: 'safety_stop', abort: 'motion_link_lost'),
];

List<Map<String, dynamic>> _care = const [];
final List<String> _calls = [];

Map<String, dynamic> _careEv(int id, String kind, {String? purpose, String? message}) => {
      'id': id,
      'kind': kind,
      'message': message ?? '알림 $id',
      'purpose': purpose,
      'occurred_at': '2026-09-09T08:0$id:00',
    };

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
    utf8.encode(jsonEncode(body)), status,
    headers: {'content-type': 'application/json'});

RpiApiService _api() => RpiApiService(
      'http://rpi5.local:8000',
      client: MockClient((req) async {
        final path = req.url.path;
        if (req.method != 'GET') _calls.add('${req.method} $path ${req.body}');
        if (path.startsWith('/execute') || path.endsWith('/approve')) {
          fail('실행 경로를 불렀어요: ${req.method} $path');
        }
        if (path == '/appliances') return _json(_raw);
        if (path == '/routines') return _json(_routines);
        if (path == '/routines/templates') return _json(const []);
        if (path == '/routines/next') {
          return _json([
            {
              'routine_id': 'rt-eve',
              'name': '저녁 공기청정기 켜기',
              'at': '2026-09-09T22:00:00+09:00',
              'when': '매일 22:00',
              'mode': 'approve',
              'mode_label': '자동 실행',
              'auto': true,
              'day_label': '오늘',
            },
          ]);
        }
        if (path == '/routines/auto-rules') return _json(_rules);
        final enableRule = RegExp(r'^/routines/auto-rules/([^/]+)/enable$').firstMatch(path);
        if (enableRule != null) {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          final rule = _rules.firstWhere((r) => r['id'] == enableRule[1]);
          return _json({...rule, 'enabled': body['enabled']});
        }
        final enableRoutine = RegExp(r'^/routines/([^/]+)/enable$').firstMatch(path);
        if (enableRoutine != null) {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          final r = _routines.firstWhere((r) => r['id'] == enableRoutine[1]);
          return _json({...r, 'enabled': body['enabled']});
        }
        final trigger = RegExp(r'^/routines/([^/]+)/trigger$').firstMatch(path);
        if (trigger != null) {
          return _json({
            'kind': 'suggestion',
            'suggestion': {'id': 'card-${trigger[1]}'},
          });
        }
        if (path == '/quiet-hours') {
          return _json({'enabled': false, 'start': '22:00', 'end': '07:00', 'active': false});
        }
        if (path == '/history') return _json(_history);
        if (path == '/care-events') return _json(_care);
        if (path == '/suggestions') return _json(const []);
        if (path == '/thinq/power') return _json({'execution_mode': 'real', 'appliances': const []});
        return _json({'detail': 'not found'}, 404);
      }),
    );

Widget _app(Widget screen, {double scale = 1, RpiConnectionState hub = RpiConnectionState.connected}) {
  final router = GoRouter(routes: [
    GoRoute(path: '/', builder: (_, __) => screen),
    GoRoute(path: '/suggestion/:id', builder: (_, s) => Scaffold(body: Text('승인 화면 ${s.pathParameters['id']}'))),
    GoRoute(path: '/history', builder: (_, __) => const HistoryScreen()),
    GoRoute(path: '/care', builder: (_, __) => const Scaffold(body: Text('알림함'))),
    GoRoute(path: '/status', builder: (_, __) => const Scaffold(body: Text('상태 화면'))),
    GoRoute(path: '/routine/edit', builder: (_, __) => const Scaffold(body: Text('루틴 고치기 화면'))),
    GoRoute(
        path: '/appliance/detail/:id',
        builder: (_, s) => Scaffold(body: Text('가전 상세 ${s.pathParameters['id']}'))),
  ]);
  return buildWithProviderState(
    overrides: [
      ...connectedOverrides(),
      ...installedOverrides(_installed),
      rpiServerOverride(hub),
      rpiApiServiceProvider.overrideWithValue(_api()),
    ],
    child: MaterialApp.router(
      theme: ThemeData.light(),
      routerConfig: router,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
    ),
  );
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 16; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _pump(WidgetTester tester, Widget screen,
    {double scale = 1, Size size = const Size(411, 3000), RpiConnectionState hub = RpiConnectionState.connected}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_app(screen, scale: scale, hub: hub));
  await _settle(tester);
}

Finder _in(Finder parent, Finder child) => find.descendant(of: parent, matching: child);

int _triggers() => _calls.where((c) => c.contains('/trigger')).length;

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _raw = [_mw, _air, _pwash, _ind];
    _care = const [];
    _calls.clear();
  });

  group("1. 루틴 '지금 하기'는 한 번 묻는다", () {
    testWidgets('누름 장치 루틴 — 무엇을 누르는지 묻고, 취소하면 아무것도 보내지 않는다', (tester) async {
      await _pump(tester, const RoutinesScreen());
      await tester.tap(find.byKey(const Key('routine-run-r-mw')));
      await _settle(tester);
      expect(_triggers(), 0, reason: '묻기 전에 카드를 만들지 않는다');
      expect(findPlainText('지금 30초 데우기를 할까요?'), findsOneWidget);
      expect(findPlainText('전자레인지 버튼 2개를 눌러요'), findsOneWidget);
      final cancel = find.byKey(const Key('routine-confirm-cancel'));
      final run = find.byKey(const Key('routine-confirm-run'));
      expect(_in(run, findPlainText('지금 하기')), findsOneWidget);
      expect(_in(cancel, findPlainText('취소')), findsOneWidget);
      // 대등 — 같은 폭·같은 높이.
      expect(tester.getSize(cancel).width, closeTo(tester.getSize(run).width, 1));
      expect(tester.getSize(cancel).height, closeTo(tester.getSize(run).height, 1));
      await tester.tap(cancel);
      await _settle(tester);
      expect(_triggers(), 0);
      expect(findPlainText('지금 30초 데우기를 할까요?'), findsNothing);
    });

    testWidgets('확인하면 그대로 승인 카드 경로(트리거 한 번 → 승인 화면)', (tester) async {
      await _pump(tester, const RoutinesScreen());
      await tester.tap(find.byKey(const Key('routine-run-r-mw')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('routine-confirm-run')));
      await _settle(tester);
      expect(_triggers(), 1);
      expect(find.text('승인 화면 card-r-mw'), findsOneWidget);
    });

    testWidgets('LG 가전만 있는 루틴 — 가전 이름·할 일', (tester) async {
      await _pump(tester, const RoutinesScreen());
      await tester.tap(find.byKey(const Key('routine-run-r-air')));
      await _settle(tester);
      expect(findPlainText('지금 공기청정기 켜 두기를 할까요?'), findsOneWidget);
      expect(findPlainText('공기청정기 켜기', contains: true), findsWidgets);
      expect(_in(find.byKey(const Key('routine-confirm-sheet')), findPlainText('누를', contains: true)), findsNothing);
    });

    testWidgets("연습 가전만 — '연습으로 해 볼까요?'", (tester) async {
      await _pump(tester, const RoutinesScreen());
      await tester.tap(find.byKey(const Key('routine-run-r-pw')));
      await _settle(tester);
      expect(findPlainText('연습으로 해 볼까요?'), findsOneWidget);
    });

    testWidgets('홈 루틴 줄도 같은 시트', (tester) async {
      await _pump(tester, const HomeScreen());
      final tile = find.byKey(const Key('home-routine-tile-r-mw'));
      await tester.ensureVisible(tile);
      await tester.tap(tile);
      await _settle(tester);
      expect(_triggers(), 0);
      expect(findPlainText('지금 30초 데우기를 할까요?'), findsOneWidget);
    });
  });

  group('2·E. 홈 — 실패 경고 맨 위, 해야 할 일, 알림 수는 설정과 같다', () {
    setUp(() {
      _care = [
        _careEv(7, 'auto_rule'),
        _careEv(6, 'execution_failed', purpose: '공기청정기 바람 중간으로 해줘'),
        _careEv(5, 'execution_failed', purpose: '공기청정기 바람 중간으로 해줘'),
        _careEv(4, 'execution_failed', purpose: '공기청정기 바람 중간으로 해줘'),
        _careEv(3, 'auto_rule'),
        _careEv(2, 'routine_notice'),
        _careEv(1, 'auto_rule'),
      ];
      _raw = [_mw, _air, _pwash, _ind, _custom('wash', '세탁기', 'washer')..remove('panel_mapping')];
    });

    testWidgets('실패 경고는 맨 위 따로, 할 일 단추가 있다', (tester) async {
      await _pump(tester, const HomeScreen());
      final alert = find.byKey(const Key('home-failure'));
      expect(alert, findsOneWidget);
      expect(_in(alert, findPlainText('공기청정기 바람 중간으로 하기 · 3번 못 했어요')), findsOneWidget);
      final action = _in(alert, find.byKey(const Key('home-failure-action')));
      expect(action, findsOneWidget);
      expect(_in(action, findPlainText('기록 보기')), findsOneWidget);
      // '지금 우리 집'보다 위.
      expect(tester.getTopLeft(alert).dy, lessThan(tester.getTopLeft(find.byKey(const Key('home-now'))).dy));
      // 알림·설정 남음은 이 경고 안에 섞지 않는다.
      expect(_in(alert, findPlainText('안 본 알림', contains: true)), findsNothing);
      expect(_in(alert, findPlainText('설정', contains: true)), findsNothing);
    });

    testWidgets("'해야 할 일'(설정 남음)은 따로, 알림은 전체 수 하나 — 설정과 같은 7건", (tester) async {
      await _pump(tester, const HomeScreen());
      final todo = find.byKey(const Key('home-todo'));
      expect(todo, findsOneWidget);
      expect(_in(todo, findPlainText('해야 할 일')), findsOneWidget);
      expect(findPlainText('그 밖에', contains: true), findsNothing);
      expect(_in(find.byKey(const Key('home-unread')), findPlainText('안 본 알림 7건')), findsOneWidget);
      await _pump(tester, const SettingsScreen());
      expect(findPlainText('안 본 알림 7건'), findsOneWidget);
    });

    testWidgets("'기록 보기'는 못 한 일만 거른 기록으로", (tester) async {
      await _pump(tester, const HomeScreen());
      await tester.tap(find.byKey(const Key('home-failure-action')));
      await _settle(tester);
      expect(find.byType(HistoryScreen), findsOneWidget);
      final chip = tester.widget<FilterChip>(find.byKey(const Key('history-filter-failed')));
      expect(chip.selected, isTrue);
      expect(find.byKey(const ValueKey('history-ok-1')), findsNothing);
    });
  });

  group('3. 기록 실패 줄의 다음 행동', () {
    testWidgets("LG 가전 거절 — '공기청정기 상태 보기'", (tester) async {
      await _pump(tester, const HistoryScreen());
      await tester.tap(find.byKey(const Key('history-tap-fail-air')));
      await _settle(tester);
      final go = find.byKey(const Key('history-action-detail-fail-air'));
      expect(_in(go, findPlainText('공기청정기 상태 보기')), findsOneWidget);
      await tester.tap(go);
      await _settle(tester);
      expect(find.text('가전 상세 air'), findsOneWidget);
    });

    testWidgets("보내지 못한 루틴 — '다시 해 보기'는 확인 시트를 거친다", (tester) async {
      await _pump(tester, const HistoryScreen());
      final row = find.byKey(const Key('history-tap-fail-nd'));
      await tester.ensureVisible(row);
      await tester.tap(row);
      await _settle(tester);
      final retry = find.byKey(const Key('history-action-retry-fail-nd'));
      expect(_in(retry, findPlainText('다시 해 보기')), findsOneWidget);
      await tester.ensureVisible(retry);
      await tester.tap(retry);
      await _settle(tester);
      expect(_triggers(), 0);
      expect(findPlainText('지금 30초 데우기를 할까요?'), findsOneWidget);
    });

    testWidgets('눌렸는지 모르면 다시 누르는 단추 없이 집에서 확인하라는 말(R1)', (tester) async {
      await _pump(tester, const HistoryScreen());
      final row = find.byKey(const Key('history-tap-fail-ex'));
      await tester.ensureVisible(row);
      await tester.tap(row);
      await _settle(tester);
      expect(find.byKey(const Key('history-action-retry-fail-ex')), findsNothing);
      expect(findPlainText('버튼판에서 직접 누르기'), findsNothing);
      expect(findPlainText('다시 누르기 전에 집에서 전자레인지를 확인해야 해요'), findsOneWidget);
    });
  });

  group('4·D. 연습 가전과 LG 가전 띠', () {
    test('연습 색은 글자로 써도 7:1 이상(라이트 흰 카드·다크 카드)', () {
      double lum(Color c) {
        double ch(double v) => v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
        return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
      }

      double contrast(Color a, Color b) {
        final (x, y) = (lum(a), lum(b));
        return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
      }

      expect(contrast(AppColors.practiceLight, AppColors.surfaceLowLight), greaterThanOrEqualTo(7));
      expect(contrast(AppColors.practice, AppColors.surfaceLow), greaterThanOrEqualTo(7));
    });

    test('연습 가전 판정과 표시 이름', () {
      final w = ApplianceMap.fromJson(_pwash);
      expect(isPracticeAppliance(w), isTrue);
      expect(applianceTileName(w), 'LG 세탁기');
      expect(isPracticeAppliance(ApplianceMap.fromJson(_air)), isFalse);
    });

    testWidgets("이름에서 '(연습)'을 빼고 '연습' 표지, 띠는 연습 색 — 손 아이콘 '준비됐어요'가 아니다", (tester) async {
      await _pump(tester, const HomeScreen());
      final card = find.byKey(const Key('appliance-card-pwash'));
      expect(_in(card, findPlainText('LG 세탁기(연습)')), findsNothing);
      expect(_in(card, findPlainText('LG 세탁기')), findsOneWidget);
      expect(_in(card, find.byKey(const Key('appliance-practice-pwash'))), findsOneWidget);
      final band = tester.widget<Container>(find.byKey(const Key('appliance-band-pwash')));
      final c = (band.color ?? Colors.transparent).withValues(alpha: 1);
      // 청록 — 초록·파랑이 빨강보다 뚜렷이 높다(회색·주황·초록 확인색과 다르다).
      expect(c.g - c.r, greaterThan(0.25), reason: '$c');
      expect(c.b - c.r, greaterThan(0.2), reason: '$c');
      expect(_in(find.byKey(const Key('appliance-status-pwash')), find.byIcon(Icons.touch_app_outlined)), findsNothing);
      expect(_in(find.byKey(const Key('appliance-status-pwash')), findPlainText('준비됐어요')), findsNothing);
    });

    testWidgets("전원을 모르는 LG 가전은 '확인 전이에요'", (tester) async {
      await _pump(tester, const HomeScreen());
      final status = find.byKey(const Key('appliance-status-air'));
      expect(_in(status, findPlainText('확인 전이에요')), findsOneWidget);
      expect(_in(status, find.byIcon(Icons.touch_app_outlined)), findsNothing);
      // 누름 장치 가전은 이 말을 쓰지 않는다(LG 가전만).
      expect(_in(find.byKey(const Key('appliance-status-mw')), findPlainText('확인 전이에요')), findsNothing);
    });

    testWidgets("설정의 연습 가전 부제 '연습용이라 등록할 필요 없어요'", (tester) async {
      await _pump(tester, const SettingsScreen());
      expect(findPlainText('연습용이라 등록할 필요 없어요'), findsOneWidget);
      expect(findPlainText('LG 세탁기(연습)'), findsNothing);
    });
  });

  group('5. 타일 원인은 짧게, 말줄임 없이', () {
    testWidgets("인덕션 — '누름 장치가 다른 가전 위에 있어요', 띠 '설정이 필요해요'", (tester) async {
      await _pump(tester, const HomeScreen(), size: const Size(360, 3000));
      final card = find.byKey(const Key('appliance-card-ind'));
      final reason = _in(card, findPlainText('누름 장치가 다른 가전 위에 있어요'));
      expect(reason, findsOneWidget);
      final t = tester.widget<Text>(reason);
      expect(t.overflow, isNot(TextOverflow.ellipsis));
      expect(_in(card, findPlainText(_gantryAbsent, contains: true)), findsNothing);
      expect(_in(find.byKey(const Key('appliance-status-ind')), findPlainText('설정이 필요해요')), findsOneWidget);
    });

    test('서버 준비 필요 판정은 키오스크와 같은 말', () {
      final s = applianceTileStatus(
        appliance: ApplianceMap.fromJson(_ind),
        readinessSource: ApplianceMap.fromJson(_ind),
        hub: RpiConnectionState.connected,
        catalog: ServerCatalogStatus.loaded,
        execution: const ExecutionStatus(),
      );
      expect(s.text, '설정이 필요해요');
      expect(tileReasonText(_gantryAbsent), '누름 장치가 다른 가전 위에 있어요');
    });
  });

  group('6. 사용 방법', () {
    testWidgets("설정 '사용 방법' → 짧은 안내", (tester) async {
      await _pump(tester, const SettingsScreen());
      final row = find.byKey(const Key('settings-help'));
      expect(_in(row, findPlainText('사용 방법')), findsOneWidget);
      await tester.ensureVisible(row);
      await tester.tap(row);
      await _settle(tester);
      for (final word in ['누름 장치', 'LG 가전', '멈춰', '정지', '연습', '보호자 알림']) {
        expect(findPlainText(word, contains: true), findsWidgets, reason: word);
      }
    });
  });

  group('7. 작은 것', () {
    testWidgets("마이크 옆에 '말로 하기' 글자", (tester) async {
      await _pump(tester, const HomeScreen());
      expect(findPlainText('말로 하기'), findsOneWidget);
    });

    testWidgets('본체가 끊기면 설정 위에 배너 한 번, 줄은 못 불러왔어요만', (tester) async {
      await _pump(tester, const SettingsScreen(), hub: RpiConnectionState.unreachable);
      expect(find.byKey(const Key('settings-hub-banner')), findsOneWidget);
      expect(findPlainText('본체와 연결이 끊겨 못 불러왔어요'), findsNothing);
      expect(findPlainText('못 불러왔어요'), findsWidgets);
    });

    testWidgets('⋮ 메뉴는 읽는 이름에 안의 항목을 말한다', (tester) async {
      await _pump(tester, const RoutinesScreen());
      await tester.tap(findPlainText('자동 규칙'));
      await _settle(tester);
      final menu = tester.widget<Semantics>(find
          .ancestor(of: find.byKey(const Key('auto-rule-menu-ar-s')), matching: find.byType(Semantics))
          .first);
      expect(menu.properties.label, contains('지우기'));
      expect(menu.properties.label, contains('바람 세기 바꾸기'));
    });
  });

  group('A. 정해진 시각 루틴 줄에서 바로 끄고 켜기', () {
    testWidgets('규칙이 붙은 루틴은 규칙 스위치 — 끄면 바로, 알림과 표시', (tester) async {
      await _pump(tester, const RoutinesScreen());
      final sw = find.byKey(const Key('routine-switch-rt-eve'));
      expect(tester.widget<Switch>(sw).value, isTrue);
      await tester.tap(sw);
      await _settle(tester);
      expect(_calls.where((c) => c.contains('/routines/auto-rules/ar-t/enable') && c.contains('"enabled":false')),
          hasLength(1));
      expect(findPlainText('껐어요', contains: true), findsWidgets);
    });

    testWidgets('규칙이 없는 시각 루틴은 루틴 켜기 스위치', (tester) async {
      await _pump(tester, const RoutinesScreen());
      final sw = find.byKey(const Key('routine-switch-rt-morn'));
      expect(tester.widget<Switch>(sw).value, isTrue);
      await tester.tap(sw);
      await _settle(tester);
      expect(_calls.where((c) => c.contains('/routines/rt-morn/enable') && c.contains('"enabled":false')),
          hasLength(1));
      expect(findPlainText('껐어요', contains: true), findsWidgets);
    });

    testWidgets("'지금 하기'는 따로 작은 단추, 줄을 누르면 고치기", (tester) async {
      await _pump(tester, const RoutinesScreen());
      final run = find.byKey(const Key('routine-run-rt-eve'));
      expect(tester.widget(run), isA<OutlinedButton>());
      // 결선 모의 평가(10/18): '고치기' 단추 대신 줄 오른쪽 > (스위치가 있는 줄도).
      expect(_in(find.byKey(const Key('routine-row-rt-eve')), findPlainText('고치기')), findsNothing);
      expect(_in(find.byKey(const Key('routine-rt-eve')), find.byIcon(Icons.chevron_right)), findsOneWidget);
    });

    testWidgets("자동 루틴 편집기 스위치 설명 '끄면 때가 되어도 하지 않아요'", (tester) async {
      await _pump(tester, RoutineEditorScreen(initial: Routine.fromJson(_routines[3])));
      expect(findPlainText('끄면 때가 되어도 하지 않아요'), findsOneWidget);
      expect(findPlainText('끄면 때가 되어도 묻지 않아요'), findsNothing);
    });
  });

  group('B. 기록 — 못 한 일만, 날짜 머리, 멈춘 까닭', () {
    testWidgets("'못 한 일만'을 고르면 됐어요 줄이 빠지고 어제 실패가 남는다", (tester) async {
      await _pump(tester, const HistoryScreen());
      expect(findPlainText('오늘'), findsOneWidget);
      expect(findPlainText('어제'), findsOneWidget);
      await tester.tap(find.byKey(const Key('history-filter-failed')));
      await _settle(tester);
      expect(find.byKey(const ValueKey('history-ok-1')), findsNothing);
      expect(find.byKey(const ValueKey('history-fail-ex')), findsOneWidget);
    });

    test("멈춘 까닭 — 정지 요청·연결 끊김, '한 번 더 눌렀지만 눌렸는지 몰라요'", () {
      RpiHistoryEntry e(Map<String, dynamic> j) => RpiHistoryEntry.fromJson(j);
      expect(historyResult(e(_history[4])).sentence, '멈춰 달라는 요청으로 멈췄어요');
      expect(historyResult(e(_history[5])).sentence, '연결이 끊겨 스스로 멈췄어요');
      expect(historyResult(e(_history[2])).sentence, '한 번 더 눌렀지만 눌렸는지 몰라요');
    });

    testWidgets('멈춘 줄에는 까닭 한 줄', (tester) async {
      await _pump(tester, const HistoryScreen());
      expect(tester.widget<Text>(find.byKey(const Key('history-reason-stop-l'))).semanticsLabel, '연결이 끊겨 스스로 멈췄어요');
    });
  });

  group('C. 멀리 있는 보호자에게 집 안을 보라고 하지 않는다', () {
    test('폰 소스에 현장 확인 부탁 문장이 없다', () {
      final banned = [
        '움직이는지 봐 주세요',
        '가전을 봐 주세요',
        '가전을 직접 봐 주세요',
        '가전을 먼저 봐 주세요',
        '가전은 직접 봐 주세요',
        '멈췄는지 봐 주세요',
        '동작을 봐 주세요',
        '상태를 봐 주세요',
        '누름 장치를 봐 주세요',
      ];
      final offenders = <String>[];
      for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        final lines = f.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final l = lines[i].trim();
          if (l.startsWith('//')) continue;
          for (final b in banned) {
            if (l.contains(b)) offenders.add('${f.path}:${i + 1}: $l');
          }
        }
      }
      expect(offenders, isEmpty, reason: offenders.join('\n'));
    });

    test('기록의 다음 행동은 집에서 확인', () {
      final r = historyResult(RpiHistoryEntry.fromJson(_h('u', '2026-09-09T08:00:00',
          status: 'failed', outcome: 'unconfirmed', purpose: '즉석밥 데워줘')));
      expect(r.next, contains('집에서'));
      expect(kPressedAllSentence, contains('집에서 확인이 필요해요'));
    });
  });
}
