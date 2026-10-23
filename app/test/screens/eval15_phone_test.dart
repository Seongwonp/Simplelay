// 평가 15차(2026-10-18, 폰 91.5 — 결선 심사 기준).
//
// 1. 홈 가전 카드: 아이콘 바탕은 어느 카드에도 없다(상태는 띠가 말한다).
// 2. 자동 규칙 탭: 그림자 카드가 아니라 '내 루틴'과 같은 면 없는 줄 + 구분선, 안내는 쉬운 말 한 문장.
// 3. 설정: 테두리 묶음 없이 한 목록 문법 — 아이콘 열 하나·화살표 열 하나·값은 오른쪽, 숫자 칩과 글자 중복 없음.
// 4. 기록: 거절 이유는 쉬운 말(근거가 꺼짐일 때만 '꺼져 있을 땐'), 묶음은 가까운 시각(10분 안)만.
// 5. 홈 '확인이 필요해요': 못 한 일이 있으면 무엇을 못 했는지 한 줄, 나머지 알림은 따로 한 줄.
// 6. 루틴 '자동': 밑줄 없이 홈과 같은 글자, 누를 칸은 48dp 이상. '지금 하기'와 같은 두 낱말 '설정 열기'.
// 7. 큰 글씨: '설정 2개 남았어요'로 짧게, 루틴·기록 아이콘도 글자 배율을 따라(상한).
// 8. 루틴 편집: 설명은 낱말 단위 줄바꿈, 끝 여백으로 '루틴 켜기'가 단추 줄에 붙지 않는다.
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
import 'package:simplelay/screens/history_screen.dart';
import 'package:simplelay/screens/home_screen.dart';
import 'package:simplelay/screens/routine_editor_screen.dart';
import 'package:simplelay/screens/routines_screen.dart';
import 'package:simplelay/screens/settings_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';
import 'package:simplelay/theme/app_colors.dart';
import 'package:simplelay/theme/app_icons.dart';
import 'package:simplelay/theme/app_tokens.dart';
import 'package:simplelay/widgets/appliance_artwork.dart';

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
final _door = _custom('door', '인터폰', 'other', mapped: false);

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
  _rule('ar-s', '전자레인지가 멈추면 공기청정기 세게'),
  _rule('ar-u', '전자레인지가 멈추면 공기청정기 켜기'),
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

  group('1. 홈 가전 카드 — 아이콘 바탕은 하나로(없음)', () {
    testWidgets('설정이 남은 카드·켜진 카드에도 아이콘 바탕 칸이 없다', (tester) async {
      await _pump(tester, const HomeScreen());
      for (final id in ['mw', 'wash', 'air']) {
        final card = find.byKey(Key('appliance-card-$id'));
        expect(card, findsOneWidget, reason: id);
        final tinted = _in(
          card,
          find.byWidgetPredicate((w) =>
              w is Container &&
              w.child is Icon &&
              w.decoration is BoxDecoration &&
              (w.decoration as BoxDecoration).color != null),
        );
        expect(tinted, findsNothing, reason: id);
      }
    });
  });

  group('2. 자동 규칙 탭 — 내 루틴과 같은 목록 문법', () {
    testWidgets('규칙 줄은 그림자 카드가 아니고, 줄 사이 구분선', (tester) async {
      await _pump(tester, const RoutinesScreen());
      await tester.tap(findPlainText('자동으로 하기'));
      await _settle(tester);
      final row = find.byKey(const Key('auto-rule-ar-s'));
      expect(row, findsOneWidget);
      expect(_in(row, find.byType(Card)), findsNothing);
      expect(find.ancestor(of: row, matching: find.byType(Card)), findsNothing);
      // 두 규칙 사이 구분선.
      expect(find.byKey(const Key('auto-rule-ar-u')), findsOneWidget);
      expect(find.byType(Divider), findsWidgets);
    });

    testWidgets('안내는 번역투 명사문이 아니라 쉬운 말', (tester) async {
      await _pump(tester, const RoutinesScreen());
      await tester.tap(findPlainText('자동으로 하기'));
      await _settle(tester);
      final intro = tester.widget<Text>(find.byKey(const Key('auto-rules-intro-text'))).semanticsLabel!;
      expect(intro, isNot(contains('허락한 일.')));
      // 평가 16차(10/18): 더 짧게 — eval16_phone_test 5.
      // 평가 17차(10/18): 토막 두 마디 → 한 문장(eval17_phone_test 6).
      expect(intro, contains('조건에 맞으면 묻지 않고 실행해요'));
    });
  });

  group('3. 설정 — 한 목록 문법', () {
    testWidgets('테두리 묶음이 없다', (tester) async {
      await _pump(tester, const SettingsScreen());
      final bordered = find.ancestor(
        of: findPlainText('본체'),
        matching: find.byWidgetPredicate((w) =>
            w is Container && w.decoration is BoxDecoration && (w.decoration as BoxDecoration).border != null),
      );
      expect(bordered, findsNothing);
    });

    testWidgets('왼쪽 아이콘 열 하나·오른쪽 화살표 열 하나', (tester) async {
      await _pump(tester, const SettingsScreen());
      final lefts = <String, double>{
        '본체': tester.getTopLeft(find.byIcon(Icons.router_outlined)).dx,
        '보호자 알림': tester.getTopLeft(find.byIcon(Icons.family_restroom)).dx,
        '잠시 쉬기': tester.getTopLeft(find.byIcon(AppIcons.pause)).dx,
        '어두운 화면': tester.getTopLeft(find.byIcon(Icons.contrast)).dx,
        '음성 안내': tester.getTopLeft(find.byIcon(Icons.record_voice_over)).dx,
        // 가전 그림 통일(10/24): 가전 줄 왼쪽은 아이콘 대신 홈과 같은 ApplianceArtwork 그림.
        '전자레인지': tester
            .getTopLeft(find.byKey(Key('appliance-artwork-${ApplianceMap.fromJson(_mw).category.value}')).first)
            .dx,
      };
      for (final e in lefts.entries) {
        expect(e.value, closeTo(lefts['본체']!, 0.5), reason: '${e.key} $lefts');
      }
      final rights = {
        for (final e in find.byIcon(Icons.chevron_right).evaluate())
          tester.getTopRight(find.byWidget(e.widget)).dx.roundToDouble(),
      };
      expect(rights.length, 1, reason: '$rights');
    });

    testWidgets("조용한 시간도 값은 오른쪽 — 이름과 한 줄", (tester) async {
      await _pump(tester, const SettingsScreen());
      final row = find.byKey(const Key('settings-row-quiet'));
      final name = _in(row, findPlainText('조용한 시간'));
      final value = _in(row, findPlainText('꺼짐'));
      expect(value, findsOneWidget);
      expect(tester.getCenter(value).dy, closeTo(tester.getCenter(name).dy, 4));
      expect(tester.getTopLeft(value).dx, greaterThan(tester.getTopRight(name).dx));
    });

    testWidgets('보호자 알림은 숫자 칩 없이 글자 하나, 볼 것이 섞이면 그 글자가 경고색', (tester) async {
      _care = [_careEv(2, 'execution_failed'), _careEv(1, 'auto_rule')];
      await _pump(tester, const SettingsScreen());
      expect(findPlainText('안 본 알림 2건'), findsOneWidget);
      expect(findPlainText('2'), findsNothing);
      final text = tester.widget<Text>(findPlainText('안 본 알림 2건'));
      expect(text.style?.color, tester.element(findPlainText('안 본 알림 2건')).appWarning);
    });
  });

  group('4. 기록 — 쉬운 이유, 가까운 시각만 묶기', () {
    test("거절 이유는 근거만큼 — '모드'·'명령' 없이", () {
      // 평가 16차(10/18): 가전 이름이 주어 — eval16_phone_test 3.
      expect(plainFailReason('가전의 지금 모드에서는 이 명령을 받을 수 없어요', '공기청정기 바람 중간으로 하기'),
          '가전이 지금은 바꿀 수 없다고 했어요');
      expect(plainFailReason('가전이 꺼져 있어 이 명령을 받을 수 없어요', '공기청정기 바람 세게 하기'),
          '가전이 꺼져 있어서 바람 세기를 바꿀 수 없었어요');
      expect(plainFailReason('가전이 꺼져 있어 이 명령을 받을 수 없어요', '공기청정기 끄기'), '가전이 꺼져 있어서 못 했어요');
      // 모르는 문장은 그대로.
      expect(plainFailReason('가전 답이 늦어요', '공기청정기 켜기'), '가전 답이 늦어요');
    });

    testWidgets("화면에 '모드'·'명령'이 없다 — 펼쳐도", (tester) async {
      await _pump(tester, const HistoryScreen());
      final reason = find.byKey(const Key('history-reason-mode-1'));
      expect(tester.widget<Text>(reason).semanticsLabel, '공기청정기가 지금은 바꿀 수 없다고 했어요');
      expect(tester.widget<Text>(find.byKey(const Key('history-reason-off-1'))).semanticsLabel,
          '공기청정기가 꺼져 있어서 바람 세기를 바꿀 수 없었어요');
      await tester.tap(find.byKey(const Key('history-tap-mode-1')));
      await _settle(tester);
      expect(findPlainText('모드', contains: true), findsNothing);
      expect(findPlainText('명령', contains: true), findsNothing);
    });

    testWidgets('같은 일이라도 두 시간 떨어지면 따로, 가까우면 한 줄', (tester) async {
      await _pump(tester, const HistoryScreen());
      expect(find.byKey(const ValueKey('history-on-a')), findsOneWidget);
      expect(find.byKey(const ValueKey('history-on-b')), findsNothing);
      expect(find.byKey(const ValueKey('history-on-c')), findsOneWidget);
      expect(_in(find.byKey(const ValueKey('history-on-a')), findPlainText('~', contains: true)), findsOneWidget);
      expect(_in(find.byKey(const ValueKey('history-on-c')), findPlainText('~', contains: true)), findsNothing);
    });
  });

  group('5. 홈 — 못 한 일은 무엇인지 한 줄, 나머지 알림은 따로', () {
    RpiCareEvent ev(int id, String kind, {String? purpose, String message = '알림'}) =>
        RpiCareEvent(id: id, kind: kind, message: message, purpose: purpose, occurredAt: DateTime(2026, 10, 18, 8, id));

    test('두 줄로 가른다', () {
      final l = careAttentionLines([
        ev(3, 'auto_rule'),
        ev(2, 'execution_failed', purpose: '공기청정기 바람 중간으로 해줘'),
        ev(1, 'auto_rule'),
      ]);
      // 평가 16차(10/18): '번' 하나, 나머지는 '그 밖에' — eval16_phone_test 1.
      expect(l.look, '못 한 일: 공기청정기 바람 중간으로 하기');
      // 휴리스틱 평가(10/18): 알림 수는 설정과 같은 전체 수.
      expect(l.rest, '안 본 알림 3건');
      // 볼 것이 없으면 중립 한 줄.
      final n = careAttentionLines([ev(2, 'auto_rule'), ev(1, 'routine_notice')]);
      expect(n.look, isNull);
      expect(n.rest, '안 본 알림 2건');
      // 목적 문장이 없으면 알림 문장의 따옴표 속 이름, 그것도 없으면 건수만.
      expect(careAttentionLines([ev(1, 'execution_failed', message: "'30초 데우기' 실행이 완료되지 못했어요.")]).look,
          '못 한 일: 30초 데우기');
      expect(careAttentionLines([ev(1, 'emergency_stop')]).look, '멈춘 일 1번');
      // 가장 최근 것의 이름.
      expect(
          careAttentionLines([
            ev(2, 'execution_failed', purpose: '공기청정기 꺼줘'),
            ev(1, 'execution_failed', purpose: '공기청정기 켜줘'),
          ]).look,
          '못 한 일: 공기청정기 끄기 외 1번');
    });

    testWidgets('홈 화면에 두 줄', (tester) async {
      _care = [
        _careEv(3, 'auto_rule'),
        _careEv(2, 'execution_failed', purpose: '공기청정기 바람 중간으로 해줘'),
        _careEv(1, 'auto_rule'),
      ];
      await _pump(tester, const HomeScreen());
      expect(_in(find.byKey(const Key('home-failure')),
              findPlainText('못 한 일: 공기청정기 바람 중간으로 하기', contains: true)),
          findsOneWidget);
      expect(_in(find.byKey(const Key('home-unread')), findPlainText('안 본 알림 3건')), findsOneWidget);
      expect(findPlainText('못 한 일이 있어요', contains: true), findsNothing);
    });
  });

  group("6. 루틴 '자동' 모양·누를 칸, 오른쪽 글자 꼴", () {
    testWidgets("밑줄 없이 홈과 같은 글자, 누를 칸 48dp 이상", (tester) async {
      await _pump(tester, const RoutinesScreen());
      final mark = find.byKey(const Key('routine-auto-badge-rt-eve'));
      expect(mark, findsOneWidget);
      final text = tester.widget<Text>(_in(mark, findPlainText('자동')));
      expect(text.style?.decoration, anyOf(isNull, TextDecoration.none));
      expect(text.style?.fontSize, AppFont.caption);
      expect(text.style?.fontWeight, FontWeight.w700);
      // 누를 칸은 48×48 이상 — 평가 17차(10/18)부터 줄 높이를 늘리지 않는 투명 확장 칸. 보이는 표지 밖, 가운데에서
      // 22dp 아래를 눌러도 열린다.
      final c = tester.getCenter(mark);
      expect(tester.getSize(mark).height, lessThan(44));
      await tester.tapAt(c + const Offset(0, 22));
      await _settle(tester);
      expect(find.byKey(const Key('auto-rule-switch-ar-t')), findsOneWidget);
    });

    testWidgets("'지금 하기'와 같은 두 낱말 꼴 '설정 열기'", (tester) async {
      await _pump(tester, const RoutinesScreen());
      final setup = find.byKey(const Key('routine-setup-rt-wash'));
      expect(_in(setup, findPlainText('설정 열기')), findsOneWidget);
      expect(findPlainText('설정하기'), findsNothing);
    });
  });

  group('7. 큰 글씨', () {
    // 전자레인지도 연습 자리 확인이 남아 셋이다(이 시험의 가전 정의).
    testWidgets("설정이 남은 가전이 여럿이면 '설정 N개 남았어요'로 짧게", (tester) async {
      _raw = [_mw, _wash, _door, _air];
      await _pump(tester, const HomeScreen(), scale: 2.0);
      expect(findPlainText('설정 3개 남았어요'), findsOneWidget);
      expect(findPlainText('설정이 남았어요', contains: true), findsNothing);
    });

    testWidgets('보통 글씨에서는 이름을 말한다', (tester) async {
      _raw = [_mw, _wash, _door, _air];
      await _pump(tester, const HomeScreen());
      expect(findPlainText('세탁기', contains: true), findsWidgets);
      expect(findPlainText('설정이 남았어요', contains: true), findsOneWidget);
      expect(findPlainText('개 남았어요', contains: true), findsNothing);
    });

    testWidgets('루틴·기록 아이콘도 글자 배율을 따라 커진다(상한 있음)', (tester) async {
      await _pump(tester, const RoutinesScreen(), scale: 2.0);
      final box = tester.getSize(find.byKey(const Key('routine-icon-box-rt-eve')));
      expect(box.width, greaterThan(AppSpace.xxxl + AppSpace.sm));
      expect(box.width, lessThanOrEqualTo((AppSpace.xxxl + AppSpace.sm) * 1.6 + 0.01));

      await _pump(tester, const HistoryScreen(), scale: 2.0);
      // 가전 그림 통일(10/24): LG 가전 기록 아이콘은 ApplianceArtwork(기본 24) — 배율을 따르되 상한 1.6배.
      final art = find.descendant(
          of: find.byKey(const Key('history-icon-on-c')), matching: find.byType(ApplianceArtwork));
      expect(art, findsOneWidget);
      final artSize = tester.widget<ApplianceArtwork>(art).size;
      expect(artSize, greaterThan(24));
      expect(artSize, lessThanOrEqualTo(24 * 1.6 + 0.01));
      expect(tester.getSize(art).width, closeTo(artSize, 0.01));
    });
  });

  group('8. 루틴 편집', () {
    const draft = Routine(
      name: '아침 데우기',
      steps: [RoutineStep.press('mw', ['mw-1'])],
      trigger: RoutineTrigger.manual(),
    );

    testWidgets('실행 방식 설명은 낱말 단위로만 꺾인다', (tester) async {
      await _pump(tester, const RoutineEditorScreen(initial: draft), size: const Size(390, 1400));
      final note = find.byKey(const Key('routine-mode-note'));
      expect(note, findsOneWidget);
      final raw = _rawText(tester, note);
      expect(raw, contains(kWordJoiner));
      expect(raw.replaceAll(kWordJoiner, ''), tester.widget<Text>(note).semanticsLabel);
    });

    testWidgets("끝까지 내리면 '루틴 켜기'와 아래 단추 줄 사이가 넉넉하다", (tester) async {
      await _pump(tester, const RoutineEditorScreen(initial: draft), size: const Size(390, 700));
      await tester.drag(find.byType(ListView).first, const Offset(0, -3000));
      await _settle(tester);
      final sw = tester.getRect(find.byType(SwitchListTile));
      final save = tester.getRect(find.byKey(const Key('routine-save')));
      expect(save.top - sw.bottom, greaterThan(AppSpace.xxxl + AppSpace.lg));
    });
  });
}
