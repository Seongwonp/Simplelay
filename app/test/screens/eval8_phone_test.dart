// 평가 8차(2026-10-18, 폰 87.5).
//
// A. 루틴 목록: 시각 루틴의 부제가 이름과 같은 말('아침 공기청정기 끄기' 아래 '공기청정기 끄기')이면 숨긴다.
//    '다음' 배지는 시각 줄 옆(세 층으로 흩어지지 않게). 줄 끝 ⋮는 없다 — 편집·지우기는 줄을 눌러 들어가는 편집 화면
//    (지우기 확인 대화는 그대로). 그 자리만큼 이름이 넓어져 390dp에서 한 줄, 큰 글씨에서도 최대 두 줄.
// B. 큰 글씨에서 위 탭 '자동으로 하기'가 두 줄로 꺾여 위아래가 잘렸다 → 한 줄, 탭 안에 다 보인다.
// C. 폰이 만드는 시각은 모두 '오전 7:00'·'오후 10:04' 꼴 — 기록·조용한 시간·잠시 쉬기·LG 가전 읽은 시각·자동으로 하기
//    문장(서버 '매일 밤 10시에'는 그 규칙의 condition_time과 정확히 맞을 때만 바꾼다).
// D. 자동으로 하기: 사용자가 끈 규칙은 스위치만(배지 '자동으로 하기를 꺼 두셨어요' 없음), 다른 까닭으로 꺼진 규칙은 배지 유지.
//    탭 머리에 이 목록이 무엇인지 한 줄.
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
import 'package:simplelay/models/auto_rule.dart';
import 'package:simplelay/models/quiet_hours.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/history_screen.dart';
import 'package:simplelay/screens/routines_screen.dart';
import 'package:simplelay/screens/settings_screen.dart';
import 'package:simplelay/widgets/thinq_state_card.dart';
import 'package:simplelay/services/rpi_api_service.dart';

import '../helpers/test_helpers.dart';

Map<String, dynamic> _appliance(String id, String name, String category) => {
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

List<Map<String, dynamic>> get _rawAppliances => [_mw, _air];
List<ApplianceMap> get _installed => [for (final j in _rawAppliances) ApplianceMap.fromJson(j)];

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
      {'kind': 'press_sequence', 'appliance_id': 'mw', 'buttons': ['시작', '시작']},
    ],
    'trigger': {'kind': 'manual'},
    'when': '직접 실행할 때',
    'mode': 'approve',
    'enabled': true,
  },
];

const _userOff = '자동으로 하기를 꺼 두셨어요.';
const _estopOff = '비상 정지로 꺼졌어요. 다시 허락해 주세요.';

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
    'name': '데우기 멈추면 공기청정기',
    'condition_text': '전자레인지가 데우기를 멈추면',
    'action_text': '공기청정기 바람을 세게 해요',
    'enabled': false,
    'disabled_reason': _userOff,
    'fingerprint': 'fp',
  },
  {
    'id': 'ar-estop',
    'name': '아침 공기청정기 끄기',
    'condition_text': '매일 아침 7시에',
    'action_text': '공기청정기를 꺼요',
    'condition_time': '07:00',
    'enabled': false,
    'disabled_reason': _estopOff,
    'fingerprint': 'fp',
  },
];

RpiApiService _api() => RpiApiService(
      'http://rpi5.local:8000',
      client: MockClient((req) async {
        http.Response json(Object body, [int status = 200]) => http.Response.bytes(
            utf8.encode(jsonEncode(body)), status,
            headers: {'content-type': 'application/json'});
        final path = req.url.path;
        if (path.startsWith('/execute') || path.endsWith('/approve')) {
          fail('실행 경로를 불렀어요: ${req.method} $path');
        }
        if (path == '/appliances') return json(_rawAppliances);
        if (path == '/routines') return json(_routines);
        if (path == '/routines/next') {
          return json([
            {
              'routine_id': 'r-eve',
              'name': '저녁 공기청정기 켜기',
              'at': '2026-10-18T22:00:00+09:00',
              'when': '매일 22:00',
              'day_label': '오늘',
              'mode': 'approve',
              'mode_label': '자동 실행',
              'auto': true,
            },
          ]);
        }
        if (path == '/routines/auto-rules') return json(_rules);
        if (path == '/quiet-hours') {
          return json({'enabled': true, 'start': '22:00', 'end': '07:00', 'active': false});
        }
        if (path == '/history') {
          return json([
            {
              'job_id': 'j1',
              'finished_at': '2026-10-18T22:04:00',
              'status': 'succeeded',
              'outcome': 'succeeded',
              'retry_count': 0,
              'buttons': const [],
              'execution_mode': 'real',
              'route': 'thinq',
              'purpose': "자동 실행 · '저녁 공기청정기 켜기' 루틴",
            },
            {
              'job_id': 'j2',
              'finished_at': '2026-10-18T07:00:00',
              'status': 'succeeded',
              'outcome': 'succeeded',
              'retry_count': 0,
              'buttons': const [],
              'execution_mode': 'real',
              'route': 'thinq',
              'purpose': "자동 실행 · '아침 공기청정기 끄기' 루틴",
            },
          ]);
        }
        if (path == '/suggestions') return json(const []);
        return json({'detail': 'not found'}, 404);
      }),
    );

Widget _app(Widget screen, {double scale = 1.0}) {
  final router = GoRouter(routes: [
    GoRoute(path: '/', builder: (_, __) => screen),
    GoRoute(path: '/routine/edit', builder: (_, __) => const Scaffold(body: Text('편집 화면'))),
  ]);
  return buildWithProviderState(
    overrides: [
      ...connectedOverrides(),
      ...installedOverrides(_installed),
      rpiServerOverride(RpiConnectionState.connected),
      rpiApiServiceProvider.overrideWithValue(_api()),
    ],
    child: MaterialApp.router(
      theme: _noKoreanFont == null
          ? ThemeData.light().copyWith(textTheme: ThemeData.light().textTheme.apply(fontFamily: 'Malgun'))
          : ThemeData.light(),
      routerConfig: router,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
    ),
  );
}

Future<void> _pump(WidgetTester tester, Widget screen,
    {Size size = const Size(390, 3000), double scale = 1.0}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_app(screen, scale: scale));
  for (var i = 0; i < 16; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// 글 한 덩이가 몇 줄인가 — 높이를 (글자 크기 × 배율 × 1.45)로 나눠 반올림.
int _lines(WidgetTester tester, Finder text) {
  final t = tester.widget<Text>(text);
  final size = (t.style?.fontSize ?? 14) * MediaQuery.textScalerOf(tester.element(text)).scale(1);
  return (tester.getSize(text).height / (size * 1.45)).round();
}

final _koreanFont = File('C:/Windows/Fonts/malgun.ttf');
final _noKoreanFont = _koreanFont.existsSync() ? null : '맑은 고딕 글꼴이 없어 줄 수 검사를 건너뛰어요';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  setUpAll(() async {
    if (_noKoreanFont != null) return;
    final bytes = _koreanFont.readAsBytesSync();
    await (FontLoader('Malgun')..addFont(Future.value(ByteData.view(bytes.buffer)))).load();
  });

  group('A. 루틴 목록', () {
    testWidgets('시각 루틴 부제가 이름과 같은 말이면 숨긴다 — 누르는 루틴의 부제는 그대로', (tester) async {
      await _pump(tester, const RoutinesScreen());
      final morn = find.byKey(const Key('routine-row-r-morn'));
      expect(find.descendant(of: morn, matching: findPlainText('공기청정기 끄기')), findsNothing);
      expect(find.descendant(of: morn, matching: findPlainText('아침 공기청정기 끄기')), findsOneWidget);
      final heat = find.byKey(const Key('routine-row-r-heat'));
      expect(find.descendant(of: heat, matching: findPlainText('전자레인지 · 누를 버튼 2개')), findsOneWidget);
    });

    // 평가 10차(10/18): 시각 줄이 이름 아래로 내려가 '다음' 배지도 그 한 줄 끝(eval10_phone_test 1·7).
    testWidgets("'다음' 배지는 시각 줄 끝 — 세 층으로 흩어지지 않는다", (tester) async {
      await _pump(tester, const RoutinesScreen());
      final badge = find.byKey(const Key('routine-next-badge-r-eve'));
      final clock = find.byKey(const Key('routine-line-r-eve'));
      final name = findPlainText('저녁 공기청정기 켜기');
      expect(badge, findsOneWidget);
      // 시각 글 안, 이름 아래.
      final c = tester.getCenter(badge).dy;
      expect(c, greaterThanOrEqualTo(tester.getTopLeft(clock).dy - 2));
      expect(c, lessThanOrEqualTo(tester.getBottomLeft(clock).dy + 2));
      expect(tester.getTopLeft(badge).dy, greaterThanOrEqualTo(tester.getBottomLeft(name).dy - 0.5));
    });

    testWidgets('줄 끝 ⋮ 없음 — 줄을 누르면 편집 화면(지우기는 그 안)', (tester) async {
      await _pump(tester, const RoutinesScreen());
      for (final id in ['r-morn', 'r-eve', 'r-heat']) {
        expect(find.byKey(Key('routine-menu-$id')), findsNothing, reason: id);
        expect(find.descendant(of: find.byKey(Key('routine-row-$id')), matching: find.byIcon(Icons.more_vert)),
            findsNothing, reason: id);
      }
      await tester.tap(find.byKey(const Key('routine-r-morn')));
      await tester.pumpAndSettle();
      expect(find.text('편집 화면'), findsOneWidget);
    });

    testWidgets('390dp 보통 글씨: 이름은 한 줄', (tester) async {
      await _pump(tester, const RoutinesScreen());
      for (final name in ['아침 공기청정기 끄기', '저녁 공기청정기 켜기']) {
        expect(_lines(tester, findPlainText(name)), 1, reason: '$name ${tester.getSize(findPlainText(name))}');
      }
    }, skip: _noKoreanFont != null);

    testWidgets('큰 글씨(200%): 이름은 최대 두 줄, 지금 하기 단추는 모든 줄 같은 왼쪽', (tester) async {
      await _pump(tester, const RoutinesScreen(), scale: 2.0);
      for (final name in ['아침 공기청정기 끄기', '저녁 공기청정기 켜기', '30초 데우기']) {
        expect(_lines(tester, findPlainText(name)), lessThanOrEqualTo(2),
            reason: '$name ${tester.getSize(findPlainText(name))}');
      }
      final xs = [
        for (final id in ['r-morn', 'r-eve', 'r-heat']) tester.getTopLeft(find.byKey(Key('routine-run-$id'))).dx,
      ];
      expect(xs.toSet().length, 1, reason: '$xs');
    }, skip: _noKoreanFont != null);
  });

  group('B. 큰 글씨 위 탭', () {
    testWidgets("200%에서 '자동 규칙'은 한 줄이고 탭 안에 다 보인다", (tester) async {
      await _pump(tester, const RoutinesScreen(), scale: 2.0);
      final seg = find.byType(SegmentedButton<int>);
      for (final label in ['내 루틴', '자동 규칙']) {
        final t = findPlainText(label);
        expect(t, findsOneWidget);
        expect(_lines(tester, t), 1, reason: '$label ${tester.getSize(t)}');
        final r = tester.getRect(t);
        final box = tester.getRect(seg);
        expect(r.top, greaterThanOrEqualTo(box.top), reason: '$label $r $box');
        expect(r.bottom, lessThanOrEqualTo(box.bottom), reason: '$label $r $box');
        expect(r.left, greaterThanOrEqualTo(box.left), reason: '$label $r $box');
        expect(r.right, lessThanOrEqualTo(box.right), reason: '$label $r $box');
      }
    }, skip: _noKoreanFont != null);
  });

  group('C. 시각 표기는 오전/오후 하나로', () {
    test('조용한 시간 — 설정 줄·상세 요약·규칙 메모', () {
      const s = QuietHoursStatus(enabled: true, start: '22:00', end: '07:00', active: false, reason: 'schedule');
      expect(quietRowValue(s, hasApi: true), '오후 10:00~오전 7:00');
      expect(s.summary, '매일 오후 10:00~오전 7:00, 지금 조용한 시간이에요');
      final rule = AutoRule.fromJson(_rules.first);
      expect(quietRuleNote(s, rule), '조용한 시간(오후 10:00~오전 7:00)이라 이때는 자동으로 안 해요');
      expect(quietSkipLine(s, [rule]), contains('저녁 공기청정기 켜기(오후 10:00)'));
    });

    test('잠시 쉬기 끝 시각·LG 가전 읽은 시각', () {
      expect(pauseEndClock(DateTime(2026, 10, 18, 22, 4)), '오후 10:04');
      expect(thinqReadTimeLine(DateTime(2026, 10, 18, 7, 5)), '오전 7:05 기준');
      expect(thinqReadTimeSpoken(DateTime(2026, 10, 18, 7, 5)), '오전 7시 5분');
    });

    test("자동으로 하기 문장 — 서버 '매일 밤 10시에'를 그 규칙 시각과 맞을 때만 '매일 오후 10:00에'로", () {
      expect(autoRuleSentence(AutoRule.fromJson(_rules.first)), '매일 오후 10:00에 공기청정기를 켜요');
      expect(autoRuleSentence(AutoRule.fromJson(_rules.last)), '매일 오전 7:00에 공기청정기를 꺼요');
      // 시각이 맞지 않으면(서버 문장이 바뀌었으면) 건드리지 않는다.
      final odd = AutoRule.fromJson({..._rules.first, 'condition_time': '21:00'});
      expect(autoRuleSentence(odd), '매일 밤 10시에 공기청정기를 켜요');
      // 시각 규칙이 아니면 그대로.
      expect(autoRuleSentence(AutoRule.fromJson(_rules[1])), '전자레인지가 데우기를 멈추면 공기청정기 바람을 세게 해요');
    });

    testWidgets("기록 줄 시각은 '오후 10:04'·'오전 7:00'", (tester) async {
      await _pump(tester, const HistoryScreen());
      expect(findPlainText('오후 10:04', contains: true), findsOneWidget);
      expect(findPlainText('오전 7:00', contains: true), findsOneWidget);
      expect(findPlainText('22:04', contains: true), findsNothing);
      expect(findPlainText('07:00', contains: true), findsNothing);
    });

    testWidgets('설정 조용한 시간 줄', (tester) async {
      await _pump(tester, const SettingsScreen());
      expect(findPlainText('오후 10:00~오전 7:00', contains: true), findsWidgets);
      expect(findPlainText('22:00~07:00', contains: true), findsNothing);
    });

    // 평가 14차(10/18): 시각 루틴의 규칙은 루틴 줄 '자동'을 눌러 연다.
    testWidgets('시각 루틴 규칙 카드 문장', (tester) async {
      await _pump(tester, const RoutinesScreen());
      await tester.tap(find.byKey(const Key('routine-auto-badge-r-eve')));
      await tester.pumpAndSettle();
      expect(findPlainText('매일 오후 10:00에 공기청정기를 켜요'), findsOneWidget);
      expect(findPlainText('밤 10시', contains: true), findsNothing);
    });
  });

  group('D. 자동으로 하기 탭', () {
    testWidgets('사용자가 끈 규칙은 스위치만 — 다른 까닭으로 꺼진 규칙은 배지 유지', (tester) async {
      await _pump(tester, const RoutinesScreen());
      await tester.tap(findPlainText('자동 규칙'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('auto-rule-switch-ar-heat')), findsOneWidget);
      expect(find.byKey(const Key('auto-rule-off-ar-heat')), findsNothing);
      expect(findPlainText('자동으로 하기를 꺼 두셨어요', contains: true), findsNothing);
      // 시각 루틴의 규칙(비상 정지로 꺼짐)은 루틴 줄 '자동 꺼짐'에서(평가 14차 10/18).
      expect(find.byKey(const Key('auto-rule-ar-estop')), findsNothing);
      await tester.tap(findPlainText('내 루틴'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('routine-auto-badge-r-morn')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('auto-rule-off-ar-estop')), findsOneWidget);
      expect(findPlainText('비상 정지로 꺼졌어요', contains: true), findsOneWidget);
    });

    testWidgets('탭 머리에 이 목록이 무엇인지 한 줄', (tester) async {
      await _pump(tester, const RoutinesScreen());
      await tester.tap(findPlainText('자동 규칙'));
      await tester.pumpAndSettle();
      final intro = find.byKey(const Key('auto-rules-intro'));
      expect(intro, findsOneWidget);
      expect(find.descendant(of: intro, matching: findPlainText('묻지 않고', contains: true), matchRoot: true),
          findsOneWidget);
      // 첫 규칙 카드보다 위.
      expect(tester.getBottomLeft(intro).dy, lessThanOrEqualTo(tester.getTopLeft(find.byKey(const Key('auto-rule-ar-heat'))).dy));
    });
  });
}
