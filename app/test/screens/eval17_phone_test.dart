// 평가 17차(2026-10-18, 폰 91).
//
// 1. 루틴 목록: 설명은 이름 바로 아래(홈 '내 루틴'과 같은 촘촘한 틀), '자동' 48dp 손가락 칸은 줄 높이를 늘리지 않는다.
// 2. '다음'·'자동'은 이름 옆 작은 표지 — 설명 줄은 '매일 오후 10:00 · 공기청정기'처럼 짧게, 가운뎃점 머리 줄 없음.
//    큰 글씨 '지금 하기'는 이름 첫 글자와 같은 세로줄.
// 3. 기록: 큰 글씨 '바로 실행' 한 덩어리, 본문과 칩 '봐 주세요' 중복 없음, 볼 것 칩이 제목을 꺾으면 칩을 제목 아래로.
// 4. 홈: ! 아이콘은 머리에만, '(3번)' 대신 '· 3번 못 했어요', 가전은 바로 쓸 수 있는 것 먼저.
// 5. 설정: 본체 아이콘, 개발자 줄 숨김(앱 정보 이름 7번), LG 가전 부제 한 문장.
// 6. 말: 자동 규칙 안내 한 문장, 알려 주기만 하는 창은 '닫기'.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/appliance.dart';
import 'package:simplelay/models/display_status.dart';
import 'package:simplelay/providers/hub_provider.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/app_info_screen.dart';
import 'package:simplelay/screens/history_screen.dart';
import 'package:simplelay/screens/home_screen.dart';
import 'package:simplelay/screens/routines_screen.dart';
import 'package:simplelay/screens/settings_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';
import 'package:simplelay/theme/app_tokens.dart';

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

// 누름 장치가 다 눌렀지만 가전 동작은 확인 못 한 기록(목적 문장 있음 → '바로 실행').
final _pressed = <String, dynamic>{
  'job_id': 'press-1',
  'finished_at': '2026-10-18T08:40:00',
  'status': 'succeeded',
  'outcome': 'success',
  'retry_count': 0,
  'buttons': const <dynamic>[],
  'execution_mode': 'real',
  'route': 'physical',
  'confirmation': 'none',
  'purpose': '즉석밥 데우기 해줘',
  'appliance_id': 'mw',
};

List<Map<String, dynamic>> _extra = const [];
bool _dev = false;
bool _unlocked = false;

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
        if (path == '/history') return _json([..._extra, ..._history]);
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
      if (_dev) developerModeProvider.overrideWithValue(true),
      developerUnlockedProvider.overrideWith((ref) => _unlocked),
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


const _nbsp = ' ';

Finder _named(String label) => find.byWidgetPredicate((w) => w is Text && w.semanticsLabel == label);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _raw = [_mw, _wash, _air];
    _care = const [];
    _extra = const [];
  });

  RpiCareEvent ev(int id, String kind, {String? purpose, String message = '알림'}) =>
      RpiCareEvent(id: id, kind: kind, message: message, purpose: purpose, occurredAt: DateTime(2026, 10, 18, 8, id));

  group('1. 루틴 줄 — 이름 바로 아래 설명, 자동 손가락 칸은 줄 높이를 늘리지 않는다', () {
    testWidgets('이름-설명 간격 6dp 이하(자동 표지가 있는 줄도)', (tester) async {
      await _pump(tester, const RoutinesScreen(), size: const Size(600, 3000));
      for (final (key, name) in [('rt-eve', '저녁 공기청정기 켜기'), ('rt-wash', '빨래 시작')]) {
        final gap = tester.getTopLeft(find.byKey(Key('routine-line-$key'))).dy - tester.getBottomLeft(_named(name)).dy;
        expect(gap, inInclusiveRange(0, 6), reason: key);
      }
    });

    testWidgets("'자동' 표지 둘레 48dp 안을 눌러도 규칙 스위치가 열린다", (tester) async {
      await _pump(tester, const RoutinesScreen(), size: const Size(600, 3000));
      final mark = find.byKey(const Key('routine-auto-badge-rt-eve'));
      final size = tester.getSize(mark);
      expect(size.height, lessThan(40), reason: '보이는 표지는 작게');
      // 표지 칸 밖(아래로 표지 높이 절반 + 8dp)이지만 가운데에서 24dp 안.
      final c = tester.getCenter(mark);
      final p = c + Offset(0, size.height / 2 + 8);
      expect(p.dy - c.dy, lessThan(24));
      await tester.tapAt(p);
      await _settle(tester);
      // 탭 이름과 열린 창 제목이 같은 이름(문구 기준 R9 10/19).
      expect(findPlainText('자동으로 하기'), findsNWidgets(2));
    });
  });

  group("2. '다음'·'자동'은 이름 옆 표지, 설명 줄은 짧게", () {
    for (final (width, scale) in [(411.0, 1.0), (411.0, 2.0)]) {
      testWidgets('설명 줄에 표지·가운뎃점 머리 없음 ($width, $scale)', (tester) async {
        await _pump(tester, const RoutinesScreen(), size: Size(width, 3000), scale: scale);
        final line = find.byKey(const Key('routine-line-rt-eve'));
        expect(tester.widget<Text>(line).semanticsLabel, '매일 오후 10:00 · 공기청정기');
        expect(_in(line, find.byKey(const Key('routine-marks-rt-eve'))), findsNothing);
        final marks = find.byKey(const Key('routine-marks-rt-eve'));
        expect(_in(marks, find.byKey(const Key('routine-next-badge-rt-eve'))), findsOneWidget);
        expect(_in(marks, find.byKey(const Key('routine-auto-badge-rt-eve'))), findsOneWidget);
        // 표지 묶음은 설명 줄보다 위(이름 옆 또는 이름 바로 아래).
        expect(tester.getBottomLeft(marks).dy, lessThanOrEqualTo(tester.getTopLeft(line).dy + 0.5));
        // 가운뎃점 글자가 표지 묶음 안에 없다.
        expect(_in(marks, findPlainText('·', contains: true)), findsNothing);
      });
    }

    testWidgets('보통 폭에서는 이름과 같은 줄', (tester) async {
      await _pump(tester, const RoutinesScreen(), size: const Size(600, 3000));
      final next = tester.getCenter(find.byKey(const Key('routine-next-badge-rt-eve'))).dy;
      expect(next, closeTo(tester.getCenter(_named('저녁 공기청정기 켜기')).dy, 2));
    });

    testWidgets("큰 글씨 '지금 하기' 단추는 이름 첫 글자와 같은 세로줄", (tester) async {
      await _pump(tester, const RoutinesScreen(), scale: 2.0);
      final row = find.byKey(const Key('routine-row-rt-eve'));
      // 휴리스틱 평가(10/18): '지금 하기'는 이름 아래 따로 작은 단추 — 단추 왼쪽 끝이 이름 첫 글자와 같은 세로줄.
      final run = _in(row, find.byKey(const Key('routine-run-rt-eve')));
      expect(run, findsOneWidget);
      expect(tester.getTopLeft(run).dx, closeTo(tester.getTopLeft(_named('저녁 공기청정기 켜기')).dx, 1));
    });
  });

  group('3. 기록', () {
    testWidgets("큰 글씨에서 '바로 실행'은 한 덩어리, 본문은 칩과 같은 부탁을 되풀이하지 않는다", (tester) async {
      _extra = [_pressed];
      await _pump(tester, const HistoryScreen(), scale: 2.0, size: const Size(411, 8000));
      final time = find.byKey(const Key('history-time-press-1'));
      expect(_rawText(tester, time).replaceAll('⁠', ''), contains('바로$_nbsp실행'));
      final reason = tester.widget<Text>(find.byKey(const Key('history-reason-press-1')));
      expect(reason.semanticsLabel, '버튼은 다 눌렀어요. 가전이 움직였는지는 확인하지 못했어요');
      expect(reason.semanticsLabel, isNot(contains('봐 주세요')));
      expect(_in(find.byKey(const Key('history-result-press-1')), findPlainText('봐 주세요', contains: true)),
          findsOneWidget);
    });

    test("'바로 실행'과 '화면에서 직접 골랐어요'은 뜻이 다르다(목적 문장 유무)", () {
      expect(historyLookReason('보냈지만 가전이 받았는지 확인하지 못했어요. 다시 보내기 전에 집에서 가전을 확인해야 해요.'),
          '보냈지만 가전이 받았는지 확인하지 못했어요. 다시 보내기 전에 집에서 가전을 확인해야 해요.');
    });

    testWidgets('볼 것 칩이 제목을 꺾으면 칩은 제목 아래로', (tester) async {
      await _pump(tester, const HistoryScreen());
      final title = find.byKey(const Key('history-title-mode-1'));
      final chip = find.byKey(const Key('history-result-mode-1'));
      expect(tester.getTopLeft(chip).dy, greaterThanOrEqualTo(tester.getBottomLeft(title).dy - 0.5));
      // 제목은 한 줄(꺾이지 않는다).
      expect(tester.getSize(title).height, lessThan(AppFont.body * 2));
    });
  });

  group('4. 홈', () {
    test("여러 번 못 한 일은 '· 3번 못 했어요'로 끝을 붙인다", () {
      final l = careAttentionLines([
        ev(3, 'execution_failed', message: "'공기청정기 바람 세기 중' 하지 못했어요."),
        ev(2, 'execution_failed', message: "'공기청정기 바람 세기 중' 하지 못했어요."),
        ev(1, 'execution_failed', message: "'공기청정기 바람 세기 중' 하지 못했어요."),
      ]);
      expect(l.look, '공기청정기 바람 중간으로 하기 · 3번 못 했어요');
      expect(l.look, isNot(contains('(')));
    });

    testWidgets('실패 경고 아이콘은 한 번(휴리스틱 평가 10/18 — 맨 위 실패 경고)', (tester) async {
      _care = [
        _careEv(2, 'execution_failed', message: "'공기청정기 바람 세기 중' 하지 못했어요."),
        _careEv(1, 'execution_failed', message: "'공기청정기 바람 세기 중' 하지 못했어요."),
      ];
      await _pump(tester, const HomeScreen());
      final box = find.byKey(const Key('home-failure'));
      expect(_in(box, find.byIcon(Icons.cancel_outlined)), findsOneWidget);
      expect(_in(box, find.byIcon(Icons.error_outline)), findsNothing);
    });

    testWidgets('바로 쓸 수 있는 가전이 앞, 설정이 남은 가전이 뒤(본체 화면과 같은 규칙)', (tester) async {
      _raw = [_wash, _mw, _air];
      await _pump(tester, const HomeScreen());
      final grid = find.byKey(const Key('home-appliances'));
      expect(grid, findsOneWidget);
      final wash = tester.getTopLeft(findPlainText('세탁기').first);
      final mw = tester.getTopLeft(findPlainText('전자레인지').first);
      final air = tester.getTopLeft(findPlainText('공기청정기').first);
      expect(wash.dy, greaterThan(mw.dy));
      expect(wash.dy, greaterThan(air.dy));
      expect(homeApplianceOrder(_installed).map((a) => a.id).toList(), ['mw', 'air', 'wash']);
    });
  });

  group('5. 설정', () {
    testWidgets("본체 줄은 본체 모양 아이콘, LG 가전 부제는 한 문장", (tester) async {
      await _pump(tester, const SettingsScreen());
      expect(find.byIcon(Icons.router_outlined), findsOneWidget);
      expect(find.byIcon(Icons.tablet_outlined), findsNothing);
      expect(tester.widget<Text>(find.byKey(const Key('settings-thinq-subtitle'))).semanticsLabel, '등록은 LG 앱에서 해요');
    });

    testWidgets("개발 모드여도 '개발자' 줄은 숨김, 앱 정보 이름을 7번 누르면 열린다", (tester) async {
      _dev = true;
      addTearDown(() => _dev = false);
      await _pump(tester, const SettingsScreen());
      expect(find.byKey(const Key('settings-developer')), findsNothing);
      await _pump(tester, const AppInfoScreen());
      for (var i = 0; i < kDeveloperUnlockTaps; i++) {
        await tester.tap(find.byKey(const Key('app-info-name')));
        await tester.pump();
      }
      final container = ProviderScope.containerOf(tester.element(find.byType(AppInfoScreen)));
      expect(container.read(developerUnlockedProvider), isTrue);
      _unlocked = true;
      addTearDown(() => _unlocked = false);
      await _pump(tester, const SettingsScreen());
      expect(find.byKey(const Key('settings-developer')), findsOneWidget);
    });
  });

  group('6. 말', () {
    testWidgets('자동 조건과 시각 루틴을 바꿀 위치를 안내한다', (tester) async {
      await _pump(tester, const RoutinesScreen());
      await tester.tap(findPlainText('자동으로 하기'));
      await _settle(tester);
      final intro = tester.widget<Text>(find.byKey(const Key('auto-rules-intro-text')));
      expect(intro.semanticsLabel, "허용한 조건에 맞으면 묻지 않고 실행해요. 정해진 시각의 루틴은 '내 루틴'에서 바꿔요.");
    });
  });
}
