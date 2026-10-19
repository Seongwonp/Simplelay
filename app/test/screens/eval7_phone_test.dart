// 평가 7차(2026-10-18, 교수 기준 폰 86).
//
// A. 루틴 목록: '지금 하기 >'는 모든 줄에서 이름 줄 오른쪽 같은 자리. 시각은 이름 위 작은 칩('매일 오전 7:00') —
//    큰 07:00이 이름보다 커서 위계가 뒤집혀 보였다. 오전/오후 표기는 홈(다음 예정·루틴 줄)과 같다.
// B. 홈 가전 타일 상태 띠는 문장 하나로: '켜져 있어요'·'꺼져 있어요'·'설정이 필요해요'·'준비됐어요'.
// C. 기록: 멈춘 기록은 '봐 주세요'와 다른 글자('멈췄어요'·'스스로 멈췄어요'). 루틴 기록은 출처를 밝힌다 —
//    서버 기록에는 '지금 하기'와 '정해진 시각에 물어본 카드'를 가르는 필드가 없다. 가를 수 있는 것은 자동 실행
//    ('자동 실행 · ' 머리)뿐이라, 그 밖의 루틴 기록은 사람이 허락하고 실행한 것이라고만 말한다.
// D. 아이콘: 기능 하나 = 아이콘 하나. 조용한 시간 = 달, 잠시 쉬기 = 일시정지 — AppIcons 한 곳에서.
// E. 설정 가전 줄: 버튼 자리를 맞추지 않은 가전은 짧은 부제 + 줄 끝 >. 지우기는 가전 상세 화면 ⋮ 한 곳.
// F. 직접 누르기: 설명은 한 줄, 버튼은 더 크게(아래 빈 곳을 줄인다).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/appliance.dart';
import 'package:simplelay/models/display_status.dart';
import 'package:simplelay/providers/appliance_provider.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/appliance_detail_screen.dart';
import 'package:simplelay/screens/history_screen.dart';
import 'package:simplelay/screens/home_screen.dart';
import 'package:simplelay/screens/manual_control_screen.dart';
import 'package:simplelay/screens/routines_screen.dart';
import 'package:simplelay/screens/settings_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';
import 'package:simplelay/theme/app_icons.dart';

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
final _intercom = _appliance('door', '인터폰', 'other', mapped: false);

List<Map<String, dynamic>> get _rawAppliances => [_mw, _air, _washer, _intercom];
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

RpiApiService _api({String power = 'on'}) => RpiApiService(
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
        // 실제 자리 확인을 마친 가전(평가 10차 10/18부터 자리 확인을 모르면 띠가 그 말 한 문장이라 '준비됐어요' 시험은 근거를 준다).
        if (path.endsWith('/verify-pass')) return json({'state': 'done', 'execution_mode': 'real'});
        if (path == '/routines') return json(_routines);
        if (path == '/routines/next') {
          return json([
            {
              'routine_id': 'r-morn',
              'name': '아침 공기청정기 끄기',
              'at': '2026-10-19T07:00:00+09:00',
              'when': '매일 07:00',
              'day_label': '내일',
              'mode': 'approve',
              'mode_label': '자동 실행',
              'auto': true,
            },
          ]);
        }
        if (path == '/routines/auto-rules') return json(const []);
        if (path == '/quiet-hours') {
          return json({'enabled': false, 'start': '22:00', 'end': '07:00', 'active': false});
        }
        if (path == '/thinq/power') {
          return json({
            'execution_mode': 'real',
            'appliances': [
              {'appliance_id': 'air', 'power': power, 'age_s': 3},
            ],
          });
        }
        if (path == '/thinq/air') {
          return json({
            'execution_mode': 'real',
            'appliances': [
              {'appliance_id': 'air', 'grade': 'NORMAL', 'age_s': 3},
            ],
          });
        }
        if (path == '/suggestions') return json(const []);
        return json({'detail': 'not found'}, 404);
      }),
    );

Widget _app(Widget screen, {String power = 'on', bool korean = false, double scale = 1.0}) {
  final router = GoRouter(routes: [
    GoRoute(path: '/', builder: (_, __) => screen),
  ]);
  return buildWithProviderState(
    overrides: [
      ...connectedOverrides(),
      ...installedOverrides(_installed),
      rpiServerOverride(RpiConnectionState.connected),
      rpiApiServiceProvider.overrideWithValue(_api(power: power)),
    ],
    child: MaterialApp.router(
      theme: korean
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
    {Size size = const Size(400, 3000), String power = 'on', bool korean = false, double scale = 1.0}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_app(screen, power: power, korean: korean, scale: scale));
  for (var i = 0; i < 16; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// 글 한 줄의 높이 — 글자 크기의 1.9배보다 낮으면 한 줄로 본다.
bool _oneLine(WidgetTester tester, Finder text) {
  final t = tester.widget<Text>(text);
  final size = (t.style?.fontSize ?? 14) * MediaQuery.textScalerOf(tester.element(text)).scale(1);
  return tester.getSize(text).height < size * 1.9;
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

  group('A. 루틴 목록 — 같은 자리의 지금 하기, 낮춘 시각', () {
    test('오전/오후 표기', () {
      expect(ampmClock('07:00'), '오전 7:00');
      expect(ampmClock('22:00'), '오후 10:00');
      expect(ampmClock('12:30'), '오후 12:30');
      expect(ampmClock('00:05'), '오전 12:05');
      expect(ampmClock('7:5'), '7:5', reason: '모르는 꼴은 그대로');
    });

    // 휴리스틱 평가(10/18): '지금 하기'는 이름 아래 따로 작은 단추 — 시각 줄·필요할 때 줄 모두 같은 왼쪽 자리.
    testWidgets("'지금 하기'는 시각 줄·필요할 때 줄 모두 이름 아래 같은 자리", (tester) async {
      await _pump(tester, const RoutinesScreen());
      final morn = find.byKey(const Key('routine-run-r-morn'));
      final heat = find.byKey(const Key('routine-run-r-heat'));
      expect(morn, findsOneWidget);
      expect(heat, findsOneWidget);
      expect(tester.getTopLeft(morn).dx, moreOrLessEquals(tester.getTopLeft(heat).dx, epsilon: 0.5));
      for (final (run, name) in [(morn, '아침 공기청정기 끄기'), (heat, '30초 데우기')]) {
        expect(tester.getTopLeft(run).dy, greaterThanOrEqualTo(tester.getBottomLeft(findPlainText(name)).dy), reason: name);
      }
    });

    // 평가 10차(10/18): 시각은 이름 위 칩이 아니라 이름 아래 한 줄 '매일 오전 7:00 · 공기청정기'(모든 줄이 같은 꼴).
    testWidgets("시각은 이름 아래 작은 한 줄 '매일 오전 7:00' — 이름보다 크지 않다", (tester) async {
      await _pump(tester, const RoutinesScreen());
      final chip = find.byKey(const Key('routine-line-r-morn'));
      expect(find.descendant(of: chip, matching: findPlainText('매일 오전 7:00', contains: true), matchRoot: true),
          findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('routine-line-r-eve')),
          matching: findPlainText('매일 오후 10:00', contains: true), matchRoot: true), findsOneWidget);
      final name = findPlainText('아침 공기청정기 끄기');
      final chipText = tester.widget<Text>(find.descendant(of: chip, matching: find.byType(Text), matchRoot: true).first);
      final nameText = tester.widget<Text>(name);
      expect(chipText.style!.fontSize!, lessThan(nameText.style!.fontSize!));
      expect(tester.getTopLeft(chip).dy, greaterThanOrEqualTo(tester.getBottomLeft(name).dy - 0.5));
      // 부제에서 '매일'을 되풀이하지 않는다.
      expect(find.descendant(of: find.byKey(const Key('routine-row-r-morn')), matching: findPlainText('매일', contains: true)),
          findsOneWidget);
    });

    testWidgets('큰 글씨에서는 단추가 이름 아래로(규칙 유지)', (tester) async {
      await _pump(tester, const RoutinesScreen(), scale: 2.0);
      final run = find.byKey(const Key('routine-run-r-heat'));
      expect(tester.getTopLeft(run).dy, greaterThanOrEqualTo(tester.getBottomLeft(findPlainText('30초 데우기')).dy - 0.5));
    });

    testWidgets('홈 다음 예정도 같은 오전/오후 표기', (tester) async {
      await _pump(tester, const HomeScreen());
      final now = find.byKey(const Key('home-now'));
      expect(find.descendant(of: now, matching: findPlainText('오전')), findsOneWidget);
      expect(find.descendant(of: now, matching: findPlainText('7:00')), findsOneWidget);
      expect(find.descendant(of: now, matching: findPlainText('07:00')), findsNothing);
    });
  });

  // 사용자 결정(10/19): 상태 띠를 없앴다 — 상태 말(문장)은 화면 읽기 이름과 문제 표시 문장이 한다. 명사 꼴은 여전히 쓰지 않는다.
  group('B. 홈 가전 타일 상태 — 문장 하나로(화면 읽기·표시)', () {
    testWidgets("'켜져 있어요'·설정 표시 문장·준비는 표시 없음 — 명사 '켜짐'·'설정 필요' 없음", (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, const HomeScreen());
      expect(find.bySemanticsLabel(RegExp('켜져 있어요')), findsOneWidget);
      expect(tileMarkText(tester, 'washer'), kTilePanelSetup);
      expect(tileMarkText(tester, 'mw'), isNull);
      expect(find.bySemanticsLabel(RegExp('켜짐')), findsNothing);
      expect(find.bySemanticsLabel(RegExp('설정 필요')), findsNothing);
      handle.dispose();
    });

    testWidgets("꺼진 LG 가전은 화면 읽기 '꺼져 있어요'", (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, const HomeScreen(), power: 'off');
      expect(find.bySemanticsLabel(RegExp('꺼져 있어요')), findsOneWidget);
      handle.dispose();
    });

    testWidgets('412dp 두 칸에서 표시는 이름과 겹치지 않는다', (tester) async {
      await _pump(tester, const HomeScreen(), size: const Size(412, 3000), korean: true);
      final mark = tester.getRect(find.byKey(const Key('appliance-mark-washer')));
      final name = tester.getRect(find.descendant(
          of: find.byKey(const Key('appliance-card-washer')), matching: findPlainText('세탁기', contains: true)).first);
      expect(mark.overlaps(name), isFalse, reason: '표시 $mark 이름 $name');
    }, skip: _noKoreanFont != null);
  });

  group('C. 기록 — 멈춤 배지·루틴 출처', () {
    RpiHistoryEntry e(Map<String, dynamic> extra) => RpiHistoryEntry.fromJson({
          'job_id': 'j',
          'finished_at': '2026-10-18T22:04:00',
          'status': 'succeeded',
          'retry_count': 0,
          'buttons': const [],
          'execution_mode': 'real',
          'route': 'physical',
          ...extra,
        });

    test("멈춘 기록은 '봐 주세요'와 다른 글자 — 색은 그대로", () {
      final unknown = historyBadgeOf(e({'outcome': 'unconfirmed'}));
      final stopped = historyBadgeOf(e({'outcome': 'stopped', 'status': 'stopped'}));
      final safety = historyBadgeOf(e({'outcome': 'safety_stop', 'status': 'safety_stopped'}));
      expect(unknown.label, '봐 주세요');
      expect(stopped.label, '멈췄어요');
      expect(safety.label, '스스로 멈췄어요');
      expect(stopped.tone, unknown.tone);
      expect(safety.tone, unknown.tone);
      expect(stopped.icon, Icons.front_hand_outlined);
    });

    // 평가 10차(10/18): '허락하고 실행' → '물어보고'(eval10_phone_test 3). 평가 13차: 목적 문장이 있는 직접 실행은
    // '바로 실행'(eval13_phone_test 3).
    test("루틴 기록은 출처를 밝힌다 — 자동으로와 물어보고", () {
      expect(historySourceLabel(e({'purpose': "'아침 공기청정기 끄기' 루틴"})), '루틴 · 물어보고');
      expect(historySourceLabel(e({'purpose': "자동 실행 · '아침 공기청정기 끄기' 루틴"})), '루틴 · 자동으로');
      expect(historySourceLabel(e({'purpose': '공기청정기 켜줘'})), '바로 실행');
      expect(historySourceLabel(e({'purpose': '자동 실행 · 공기청정기 바람을 세게 해요'})), '자동');
    });
  });

  group('D. 아이콘 — 기능 하나에 아이콘 하나', () {
    test('공통 정의: 조용한 시간 = 달, 잠시 쉬기 = 일시정지', () {
      expect(AppIcons.quietHours, Icons.bedtime_outlined);
      expect(AppIcons.pause, Icons.pause_circle_outline);
    });

    test('폰 화면 코드는 달·일시정지·방해 금지 아이콘을 직접 쓰지 않는다(AppIcons만)', () {
      final offenders = <String>[];
      for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart') || f.path.replaceAll('\\', '/').endsWith('theme/app_icons.dart')) continue;
        final src = f.readAsStringSync();
        for (final name in ['Icons.bedtime', 'Icons.pause_circle', 'Icons.do_not_disturb']) {
          if (src.contains(name)) offenders.add('${f.path}: $name');
        }
      }
      expect(offenders, isEmpty);
    });

    testWidgets('설정 알림 줄: 잠시 쉬기 = 일시정지, 조용한 시간 = 달', (tester) async {
      await _pump(tester, const SettingsScreen());
      expect(find.descendant(of: find.byKey(const Key('settings-row-dnd')), matching: find.byIcon(AppIcons.pause)),
          findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('settings-row-quiet')), matching: find.byIcon(AppIcons.quietHours)),
          findsOneWidget);
    });
  });

  group('E. 설정 가전 줄', () {
    testWidgets("버튼 자리를 맞추지 않은 가전: 짧은 부제 한 줄 + 줄 끝 > 하나(⋮ 없음)", (tester) async {
      await _pump(tester, const SettingsScreen());
      for (final id in ['washer', 'door']) {
        final name = id == 'washer' ? '세탁기' : '인터폰';
        final row = find.widgetWithText(ListTile, name);
        expect(row, findsOneWidget);
        expect(find.descendant(of: row, matching: findPlainText('버튼 자리를 맞춰 주세요')), findsOneWidget);
        expect(find.descendant(of: row, matching: find.byIcon(Icons.chevron_right)), findsOneWidget);
        expect(find.byKey(Key('appliance-menu-$id')), findsNothing);
      }
      // 모든 가전 줄이 같은 끝 표시.
      for (final name in ['전자레인지', '공기청정기']) {
        expect(find.descendant(of: find.widgetWithText(ListTile, name), matching: find.byIcon(Icons.chevron_right)),
            findsOneWidget);
      }
    });

    testWidgets('지우기는 가전 상세 화면 ⋮ 한 곳(확인을 한 번 더 받는다)', (tester) async {
      await _pump(tester, const ApplianceDetailScreen(applianceId: 'washer'));
      final menu = find.byKey(const Key('appliance-menu-washer'));
      expect(menu, findsOneWidget);
      await tester.tap(menu);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('appliance-delete-washer')));
      await tester.pumpAndSettle();
      expect(find.text("'세탁기'를 지울까요?"), findsOneWidget);
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
    });

    testWidgets('LG 가전 상세에는 지우기 메뉴가 없다', (tester) async {
      await _pump(tester, const ApplianceDetailScreen(applianceId: 'air'));
      expect(find.byKey(const Key('appliance-menu-air')), findsNothing);
    });
  });

  group('F. 직접 누르기', () {
    const mw = ApplianceMap(
      id: 'mw4',
      name: '전자레인지',
      category: ApplianceCategory.microwave,
      rows: 4,
      cols: 3,
      isCustom: true,
      buttons: [
        ApplianceButton(id: 'a', label: '10초', x: 0, y: 0),
        ApplianceButton(id: 'b', label: '30초', x: 1, y: 0),
        ApplianceButton(id: 'c', label: '1분', x: 2, y: 0),
        ApplianceButton(id: 'd', label: '해동', x: 0, y: 1),
        ApplianceButton(id: 'e', label: '라면', x: 1, y: 1),
        ApplianceButton(id: 'f', label: '즉석밥', x: 0, y: 2),
        ApplianceButton(id: 'g', label: '취소', x: 1, y: 3),
        ApplianceButton(id: 'h', label: '시작', x: 2, y: 3),
      ],
    );

    Future<void> pumpManual(WidgetTester tester) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final container = ProviderContainer(overrides: [
        ...connectedOverrides(),
        rpiServerOverride(RpiConnectionState.connected),
      ]);
      addTearDown(container.dispose);
      await container.read(customAppliancesProvider.notifier).ensureLoaded();
      await container.read(customAppliancesProvider.notifier).add(mw);
      await container.read(selectedApplianceProvider.notifier).select(mw);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: _noKoreanFont == null
              ? ThemeData.light().copyWith(textTheme: ThemeData.light().textTheme.apply(fontFamily: 'Malgun'))
              : ThemeData.light(),
          home: const ManualControlScreen(),
        ),
      ));
      await tester.pump();
    }

    testWidgets('설명은 한 줄 하나 — 같은 말을 두 곳에서 하지 않는다', (tester) async {
      await pumpManual(tester);
      expect(findPlainText('누름 장치', contains: true), findsOneWidget);
      expect(findPlainText('한 번에 하나씩', contains: true), findsNothing);
      if (_noKoreanFont == null) {
        expect(_oneLine(tester, findPlainText('누름 장치', contains: true)), isTrue);
      }
    });

    testWidgets('버튼이 커져 아래 빈 곳이 줄어든다', (tester) async {
      await pumpManual(tester);
      final cell = find.ancestor(of: find.text('시작'), matching: find.byType(AnimatedContainer));
      expect(tester.getSize(cell).height, greaterThanOrEqualTo(96));
      // 마지막 줄 버튼 아래 빈 곳이 화면의 1/4보다 작다.
      expect(915 - tester.getBottomLeft(cell).dy, lessThan(915 / 4));
    });
  });
}
