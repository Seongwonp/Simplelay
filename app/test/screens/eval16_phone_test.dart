// 평가 16차(2026-10-18, 폰 90.5).
//
// 1. 알림 숫자: 홈 '못 한 일' 줄을 뺀 나머지는 '그 밖에 안 본 알림 N건'(설정 '안 본 알림 N건'과 세는 대상이 드러나게).
// 2. 홈 '못 한 일'은 기록과 같은 행동 이름·'번' 하나('못 한 일: 공기청정기 바람 중간으로 하기 (3번)'), 잘리지 않게.
// 3. 기록 거절 이유는 가전 이름을 주어로 — 꺼짐 근거가 있을 때만 '꺼져 있어서', 아니면 '지금은 바꿀 수 없다고 했어요'.
// 4. 본체 요약 '바람 세기 중'도 폰 안에서는 '바람 중간으로 하기' 하나.
// 5. 루틴 줄바꿈: '· 다음 · 자동'은 한 덩어리, 자동 규칙 안내는 짧게, 규칙 이름 끝 낱말은 앞 낱말과 함께.
// 6. 루틴 목록: 이름-설명 간격 하나, 오른쪽 단추와 아이콘은 같은 세로 가운데.
// 7. 홈 '확인이 필요해요'는 면 없이 왼쪽 굵은 선, 알림 줄은 알림 아이콘.
// 8. 설정 위 묶음 구분선 규칙 하나, 수동 화면 가전 그림은 사진이 없으면 같은 계열 아이콘.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/appliance.dart';
import 'package:simplelay/models/display_status.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/history_screen.dart';
import 'package:simplelay/screens/home_screen.dart';
import 'package:simplelay/screens/manual_control_screen.dart';
import 'package:simplelay/screens/routines_screen.dart';
import 'package:simplelay/screens/settings_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';
import 'package:simplelay/widgets/appliance_portrait.dart';

import '../helpers/test_helpers.dart';

Map<String, dynamic> _custom(String id, String name, String category, {bool mapped = true}) => {
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

final _mw = _custom('mw', '전자레인지', 'microwave');
final _wash = _custom('wash', '세탁기', 'washer', mapped: false);

List<Map<String, dynamic>> _raw = [_mw, _wash, _air];
List<ApplianceMap> get _installed => [for (final j in _raw) ApplianceMap.fromJson(j)];

const _modeDetail = '가전의 지금 모드에서는 이 명령을 받을 수 없어요.';
const _offDetail = '가전이 꺼져 있어 이 명령을 받을 수 없어요. 먼저 켜 주세요.';

Map<String, dynamic> _hist(String id, String purpose, String at, {bool ok = true, String detail = ''}) => {
      'job_id': id,
      'finished_at': '2026-10-18T$at:00',
      'status': ok ? 'succeeded' : 'failed',
      'outcome': ok ? 'success' : 'failed',
      'retry_count': 0,
      'buttons': const [],
      'execution_mode': 'real',
      'route': 'thinq',
      'receipt': ok ? 'accepted' : 'rejected',
      'confirmation': ok ? 'state_confirmed' : 'none',
      'purpose': purpose,
      'detail': detail,
      'appliance_id': 'air',
    };

final _history = [
  _hist('mode-1', '공기청정기 바람 중간으로 해줘', '13:00', ok: false, detail: _modeDetail),
  // 가까운 두 번 — 한 줄.
  _hist('on-a', '공기청정기 켜줘', '12:59'),
  _hist('on-b', '공기청정기 켜줘', '12:55'),
  // 두 시간 앞의 같은 일 — 따로.
  _hist('on-c', '공기청정기 켜줘', '10:51'),
  _hist('off-1', '공기청정기 바람 세게 해줘', '10:40', ok: false, detail: _offDetail),
];

List<Map<String, dynamic>> _care = const [];

Map<String, dynamic> _careEv(int id, String kind, {String? purpose, String? message}) => {
      'id': id,
      'kind': kind,
      'message': message ?? '알림 $id',
      'purpose': purpose,
      'occurred_at': '2026-10-18T08:0$id:00',
    };

final _routines = [
  {
    'schema_version': 1,
    'id': 'rt-eve',
    'name': '저녁 공기청정기 켜기',
    'steps': [
      {
        'kind': 'thinq_command',
        'appliance_id': 'air',
        'action': 'set_power',
        'args': {'power': 'POWER_ON'},
      },
    ],
    'trigger': {
      'kind': 'time',
      'days': [0, 1, 2, 3, 4, 5, 6],
      'time': '22:00',
    },
    'when': '매일 22:00',
    'mode': 'approve',
    'enabled': true,
  },
  {
    'schema_version': 1,
    'id': 'rt-wash',
    'name': '빨래 시작',
    'steps': [
      {
        'kind': 'press_sequence',
        'appliance_id': 'wash',
        'buttons': ['wash-1'],
      },
    ],
    'trigger': {'kind': 'manual'},
    'mode': 'approve',
    'enabled': true,
  },
];

Map<String, dynamic> _rule(String id, String name, {String kind = 'event', String? time}) => {
      'id': id,
      'scenario_id': kind == 'time' ? 'routine_time' : 'cook_done_air',
      'name': name,
      'condition_kind': kind,
      'condition_time': time,
      'condition_text': kind == 'time' ? '매일 밤 10시에' : '전자레인지가 데우기를 멈추면',
      'action_text': kind == 'time' ? '공기청정기를 켜요' : '공기청정기 바람을 세게 해요',
      'action': kind == 'time' ? 'set_power' : 'set_wind_strength',
      'value': kind == 'time' ? 'POWER_ON' : 'HIGH',
      'allowed_values': const [],
      'enabled': true,
      'status_label': '자동 실행 켜짐',
      'disabled_reason': null,
      'fingerprint': 'fp-$id',
    };

final _rules = [
  _rule('ar-t', '저녁 공기청정기 켜기', kind: 'time', time: '22:00'),
  _rule('ar-s', '데우기가 끝나면 공기청정기 세게'),
  _rule('ar-u', '데우기가 끝나면 공기청정기 켜기'),
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
        if (path == '/routines/templates') return _json(const []);
        if (path == '/routines/next') {
          return _json([
            {
              'routine_id': 'rt-eve',
              'name': '저녁 공기청정기 켜기',
              'at': '2026-10-18T22:00:00+09:00',
              'when': '매일 22:00',
              'mode': 'approve',
              'mode_label': '승인 후 실행',
              'auto': true,
              'day_label': '오늘',
            },
          ]);
        }
        if (path == '/routines/auto-rules') return _json(_rules);
        if (path == '/quiet-hours') {
          return _json({'enabled': false, 'start': '22:00', 'end': '07:00', 'active': false});
        }
        if (path == '/history') return _json(_history);
        if (path == '/care-events') return _json(_care);
        if (path == '/suggestions') return _json(const []);
        return _json({'detail': 'not found'}, 404);
      }),
    );

Widget _app(Widget screen, {double scale = 1}) {
  final router = GoRouter(routes: [
    GoRoute(path: '/', builder: (_, __) => screen),
  ]);
  return buildWithProviderState(
    overrides: [
      ...connectedOverrides(),
      ...installedOverrides(_installed),
      rpiServerOverride(RpiConnectionState.connected),
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

Future<void> _pump(WidgetTester tester, Widget screen, {double scale = 1, Size size = const Size(411, 3000)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_app(screen, scale: scale));
  await _settle(tester);
}

Finder _in(Finder parent, Finder child) => find.descendant(of: parent, matching: child);

String _rawText(WidgetTester tester, Finder f) {
  final t = tester.widget<Text>(f);
  return t.data ?? t.textSpan!.toPlainText();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _raw = [_mw, _wash, _air];
    _care = const [];
  });

  RpiCareEvent ev(int id, String kind, {String? purpose, String message = '알림'}) =>
      RpiCareEvent(id: id, kind: kind, message: message, purpose: purpose, occurredAt: DateTime(2026, 10, 18, 8, id));

  group('1·2·4. 홈 알림 줄', () {
    test("못 한 일은 기록과 같은 이름·'번', 나머지는 '그 밖에'", () {
      final l = careAttentionLines([
        ev(7, 'auto_rule'),
        ev(6, 'execution_failed', message: "'공기청정기 바람 세기 중' 하지 못했어요. 가전을 봐 주세요."),
        ev(5, 'execution_failed', message: "'공기청정기 바람 세기 중' 하지 못했어요. 가전을 봐 주세요."),
        ev(4, 'execution_failed', purpose: '공기청정기 바람 중간으로 해줘'),
        ev(3, 'auto_rule'),
        ev(2, 'routine_notice'),
        ev(1, 'auto_rule'),
      ]);
      // 평가 17차(10/18): 끝 괄호 대신 '· 3번 못 했어요'(eval17_phone_test 4).
      expect(l.look, '공기청정기 바람 중간으로 하기 · 3번 못 했어요');
      expect(l.rest, '그 밖에 안 본 알림 4건');
      // 한 번이면 횟수 없이, 다른 일이 섞이면 '외 N번'.
      expect(careAttentionLines([ev(1, 'execution_failed', purpose: '공기청정기 꺼줘')]).look, '못 한 일: 공기청정기 끄기');
      expect(
          careAttentionLines([
            ev(2, 'execution_failed', purpose: '공기청정기 꺼줘'),
            ev(1, 'execution_failed', purpose: '공기청정기 켜줘'),
          ]).look,
          '못 한 일: 공기청정기 끄기 외 1번');
      expect(careAttentionLines([ev(1, 'emergency_stop')]).look, '멈춘 일 1번');
      // 볼 것이 없으면 전체 수 그대로(설정 줄과 같은 수).
      expect(careAttentionLines([ev(2, 'auto_rule'), ev(1, 'routine_notice')]).rest, '안 본 알림 2건');
    });

    test("본체 요약 '바람 세기 중'은 '바람 중간으로 하기'", () {
      expect(summaryActionName('공기청정기 바람 세기 중'), '공기청정기 바람 중간으로 하기');
      expect(summaryActionName('공기청정기 바람 세기 강'), '공기청정기 바람 세게 하기');
      expect(summaryActionName('공기청정기 전원 켜기'), '공기청정기 켜기');
    });

    testWidgets('홈 줄은 말줄임 없이, 설정은 전체 수', (tester) async {
      _care = [
        _careEv(4, 'auto_rule'),
        _careEv(3, 'execution_failed', message: "'공기청정기 바람 세기 중' 하지 못했어요."),
        _careEv(2, 'execution_failed', message: "'공기청정기 바람 세기 중' 하지 못했어요."),
        _careEv(1, 'auto_rule'),
      ];
      await _pump(tester, const HomeScreen(), size: const Size(360, 3000));
      final look = _in(find.byKey(const Key('home-attention-care-look')), find.byType(Text));
      final t = tester.widget<Text>(look.first);
      expect(_rawText(tester, look.first).replaceAll('⁠', '').replaceAll(' ', ' '),
          '공기청정기 바람 중간으로 하기 · 2번 못 했어요');
      expect(t.maxLines, isNull);
      expect(t.overflow, anyOf(isNull, TextOverflow.clip));
      expect(_in(find.byKey(const Key('home-attention-care')), findPlainText('그 밖에 안 본 알림 2건')), findsOneWidget);
      await _pump(tester, const SettingsScreen());
      expect(findPlainText('안 본 알림 4건'), findsOneWidget);
    });
  });

  group('3. 기록 거절 이유 — 가전 이름이 주어', () {
    test('근거만큼', () {
      expect(plainFailReason('가전의 지금 모드에서는 이 명령을 받을 수 없어요', '공기청정기 바람 중간으로 하기', name: '공기청정기'),
          '공기청정기가 지금은 바꿀 수 없다고 했어요');
      expect(plainFailReason('가전이 꺼져 있어 이 명령을 받을 수 없어요', '공기청정기 바람 세게 하기', name: '공기청정기'),
          '공기청정기가 꺼져 있어서 바람 세기를 바꿀 수 없었어요');
      expect(plainFailReason('가전이 꺼져 있어 이 명령을 받을 수 없어요', '제습기 끄기', name: '제습기'), '제습기가 꺼져 있어서 못 했어요');
      expect(plainFailReason('가전이 꺼져 있어 이 명령을 받을 수 없어요', '전기밥솥 끄기', name: '전기밥솥'), '전기밥솥이 꺼져 있어서 못 했어요');
      expect(plainFailReason('가전이 꺼져 있어 이 명령을 받을 수 없어요', '끄기'), '가전이 꺼져 있어서 못 했어요');
      expect(plainFailReason('가전 답이 늦어요', '공기청정기 켜기', name: '공기청정기'), '가전 답이 늦어요');
    });

    testWidgets('기록 화면', (tester) async {
      await _pump(tester, const HistoryScreen());
      expect(tester.widget<Text>(find.byKey(const Key('history-reason-mode-1'))).semanticsLabel,
          '공기청정기가 지금은 바꿀 수 없다고 했어요');
      expect(tester.widget<Text>(find.byKey(const Key('history-reason-off-1'))).semanticsLabel,
          '공기청정기가 꺼져 있어서 바람 세기를 바꿀 수 없었어요');
      expect(findPlainText('가전이 바꿀 수 없는 상태', contains: true), findsNothing);
    });
  });

  group('5. 루틴 줄바꿈', () {
    for (final (width, scale) in [(411.0, 1.0), (300.0, 1.0), (390.0, 1.3)]) {
      testWidgets("'다음 · 자동'은 한 덩어리 ($width, $scale)", (tester) async {
        await _pump(tester, const RoutinesScreen(), size: Size(width, 3000), scale: scale);
        final marks = find.byKey(const Key('routine-marks-rt-eve'));
        expect(marks, findsOneWidget);
        expect(_in(marks, find.byKey(const Key('routine-next-badge-rt-eve'))), findsOneWidget);
        expect(_in(marks, find.byKey(const Key('routine-auto-badge-rt-eve'))), findsOneWidget);
        final next = tester.getCenter(find.byKey(const Key('routine-next-badge-rt-eve')));
        final auto = tester.getCenter(find.byKey(const Key('routine-auto-badge-rt-eve')));
        expect(auto.dy, closeTo(next.dy, 2));
      });
    }

    testWidgets('자동 규칙 안내는 짧게, 규칙 이름 끝 낱말은 앞 낱말과 함께', (tester) async {
      await _pump(tester, const RoutinesScreen());
      await tester.tap(findPlainText('자동 규칙'));
      await _settle(tester);
      final intro = tester.widget<Text>(find.byKey(const Key('auto-rules-intro-text')));
      // 평가 17차(10/18): 한 문장(eval17_phone_test 6).
      expect(intro.semanticsLabel, '스위치가 켜져 있는 동안은 묻지 않고 바로 해요');
      expect(intro.data, contains(' '));
      final name = find.descendant(
          of: find.byKey(const Key('auto-rule-ar-s')),
          matching: find.byWidgetPredicate((w) => w is Text && w.semanticsLabel == '데우기가 끝나면 공기청정기 세게'));
      expect(tester.widget<Text>(name).data!.replaceAll('⁠', ''), contains('공기청정기 세게'));
    });
  });

  group('6. 루틴 목록 세로 기준 하나', () {
    testWidgets('이름-설명 간격이 같고, 오른쪽 단추와 아이콘은 같은 가운데', (tester) async {
      // 시험 글꼴은 한 글자가 넓어 보통 폭에서 이름이 꺾인다 — 이름이 한 줄인 폭에서 잰다.
      await _pump(tester, const RoutinesScreen(), size: const Size(600, 3000));
      // 이름 글자 아래 끝에서 설명 칸 위까지(이름이 몇 줄이든).
      double gap(String key, String name) =>
          tester.getTopLeft(find.byKey(Key('routine-line-box-$key'))).dy -
          tester.getBottomLeft(find.byWidgetPredicate((w) => w is Text && w.semanticsLabel == name)).dy;
      double lineH(String key) => tester.getSize(find.byKey(Key('routine-line-box-$key'))).height;
      expect(lineH('rt-eve'), closeTo(lineH('rt-wash'), 0.5));
      expect(gap('rt-eve', '저녁 공기청정기 켜기'), closeTo(gap('rt-wash', '빨래 시작'), 0.5));
      final iconEve = tester.getCenter(find.byKey(const Key('routine-icon-box-rt-eve'))).dy;
      final runEve = tester.getCenter(find.byKey(const Key('routine-run-rt-eve'))).dy;
      expect(runEve, closeTo(iconEve, 1));
      final iconWash = tester.getCenter(find.byKey(const Key('routine-icon-box-rt-wash'))).dy;
      final setupWash = tester.getCenter(find.byKey(const Key('routine-setup-rt-wash'))).dy;
      expect(setupWash, closeTo(iconWash, 1));
    });
  });

  group('7. 홈 확인 상자 문법', () {
    testWidgets('면·둥근 모서리 없이 왼쪽 굵은 선, 알림 줄은 알림 아이콘', (tester) async {
      _care = [_careEv(2, 'execution_failed', purpose: '공기청정기 꺼줘'), _careEv(1, 'auto_rule')];
      await _pump(tester, const HomeScreen());
      final box = tester.widget<Container>(find.byKey(const Key('home-attention')));
      final d = box.decoration! as BoxDecoration;
      expect(d.color, isNull);
      expect(d.borderRadius, isNull);
      final border = d.border! as Border;
      expect(border.left.width, greaterThanOrEqualTo(3));
      expect(border.top, BorderSide.none);
      final rest = find.byKey(const Key('home-attention-care'));
      expect(_in(rest, find.byIcon(Icons.notifications_none)), findsOneWidget);
      expect(_in(rest, find.byIcon(Icons.family_restroom)), findsNothing);
    });
  });

  group('8. 설정 구분선·수동 화면 그림', () {
    testWidgets("'LG 가전 연결'과 '보호자 알림' 사이에도 구분선", (tester) async {
      await _pump(tester, const SettingsScreen());
      final lgBottom = tester.getBottomLeft(findPlainText('LG 가전 연결')).dy;
      final careTop = tester.getTopLeft(findPlainText('보호자 알림')).dy;
      final between = find.byType(Divider).evaluate().where((e) {
        final y = tester.getCenter(find.byWidget(e.widget)).dy;
        return y > lgBottom && y < careTop;
      });
      expect(between, isNotEmpty);
    });

    testWidgets('사진 없는 가전은 같은 계열 아이콘', (tester) async {
      await _pump(tester, const ManualControlScreen());
      expect(find.byKey(const Key('manual-target-icon')), findsOneWidget);
      expect(find.byType(AppliancePortrait), findsNothing);
    });
  });
}
