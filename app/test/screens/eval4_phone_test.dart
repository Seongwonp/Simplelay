// 평가 4차(2026-10-18, 종합 79) 지적 — 폰 줄바꿈·개발자 시점 문장·이름 통일·설정 구조.
//
// B. 줄바꿈 사고: '생활 습관 알아가 / 기', '읽지 않은 알림 / 4건', 'LG / 가전 설정 1번', 홈 확인 카드 '세탁 / 기'.
//    실제로 그려진 줄을 보고(낱말 중간·한 글자 줄·묶음 갈림) 폭·글자 크기를 바꿔 가며 확인한다.
// C. 개발자 시점 문장: '처음부터 들어 있는 가전이에요'·'빼기는 LG 가전 연결에서 해요' 없음, '가전 목록 새로 받기',
//    '콘센트' → '전기 플러그'.
// D. 이름 통일: 상태·배지는 '자동으로 해요' / '지금은 안 해요'. 옛 기록 제목 '약풍·강풍·중풍' → '바람 약하게/세게/중간으로'.
// G. 설정 '물어보기' 섹션 → '생활 습관'. 알림만 루틴은 종 아이콘 + '알려 드려요' 배지로 의도를 보인다.
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
import 'package:simplelay/models/display_status.dart';
import 'package:simplelay/models/estop.dart';
import 'package:simplelay/providers/care_events_provider.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/home_screen.dart';
import 'package:simplelay/screens/routines_screen.dart';
import 'package:simplelay/screens/settings_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';

import '../helpers/line_check.dart';
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

final _mw = _appliance('mw', '전자레인지', mapped: false);
final _washer = _appliance('washer', '세탁기', mapped: false);
final _intercom = _appliance('intercom', '인터폰');

List<ApplianceMap> get _installed =>
    [for (final j in [_mw, _washer, _intercom, _air]) ApplianceMap.fromJson(j)];

final _routines = [
  {
    'id': 'r-notify',
    'name': '세탁 끝 알림',
    'steps': <dynamic>[],
    'trigger': {'kind': 'event', 'event': 'wash_complete'},
    'when': '세탁이 끝나면',
    'mode': 'notify',
    'enabled': true,
  },
  {
    'id': 'r-air',
    'name': '저녁 공기청정기 켜기',
    'steps': [
      {
        'kind': 'thinq_command',
        'appliance_id': 'air',
        'action': 'set_power',
        'args': {'power': 'on'},
      },
    ],
    'trigger': {'kind': 'time', 'days': [0, 1, 2, 3, 4, 5, 6], 'time': '22:00'},
    'when': '매일 22:00',
    'mode': 'approve',
    'enabled': true,
  },
  {
    'id': 'r-door',
    'name': '문 열기',
    'steps': [
      {'kind': 'press_sequence', 'appliance_id': 'intercom', 'buttons': ['시작']},
    ],
    'trigger': {'kind': 'manual'},
    'when': '직접 실행할 때',
    'mode': 'approve',
    'enabled': true,
  },
];

const _next = {
  'routine_id': 'r-air',
  'name': '아침 공기청정기 끄기',
  'at': '2026-10-19T07:00:00+09:00',
  'when': '매일 07:00',
  'mode': 'approve',
  'mode_label': '자동 실행',
  'auto': true,
  'day_label': '오늘',
};

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
        if (path == '/appliances') return json([_mw, _washer, _intercom, _air]);
        if (path == '/routines') return json(_routines);
        if (path == '/routines/next') return json([_next]);
        if (path == '/thinq/power' || path == '/thinq/air') {
          return json({'execution_mode': 'real', 'appliances': const []});
        }
        if (path == '/suggestions') return json(const []);
        return json({'detail': 'not found'}, 404);
      }),
    );

class _SeededCare extends CareEventsNotifier {
  _SeededCare(super.ref, CareEventsState seed) {
    state = seed;
  }

  @override
  Future<void> refresh() async {}
}

final _care = careEventsProvider.overrideWith((ref) => _SeededCare(
    ref,
    CareEventsState(status: CareInboxStatus.ready, events: [
      for (var i = 4; i >= 1; i--)
        RpiCareEvent(
            id: i, kind: 'execution_failed', message: '실패 $i', occurredAt: DateTime(2026, 10, 18, 8, i)),
    ])));

Widget _app(Widget screen, {required double scale, bool hub = true}) {
  final router = GoRouter(routes: [
    GoRoute(path: '/', builder: (_, __) => screen),
    GoRoute(path: '/appliance/detail/:id', builder: (_, __) => const Scaffold()),
  ]);
  return buildWithProviderState(
    overrides: [
      ...connectedOverrides(),
      ...installedOverrides(_installed),
      rpiServerOverride(RpiConnectionState.connected),
      if (hub) rpiApiServiceProvider.overrideWithValue(_api()),
      _care,
    ],
    child: MaterialApp.router(
      // 실제 한글 글꼴로 배치한다(아래 [_koreanFont]). 시험 기본 글꼴은 빈칸·숫자까지 한 칸 폭이라 줄이 실화면과 다르다.
      theme: ThemeData.light().copyWith(textTheme: ThemeData.light().textTheme.apply(fontFamily: 'Malgun')),
      routerConfig: router,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
    ),
  );
}

Future<void> _pump(WidgetTester tester, Widget screen,
    {required double width, required double scale, bool hub = true}) async {
  tester.view.physicalSize = Size(width, 6000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_app(screen, scale: scale, hub: hub));
  for (var i = 0; i < 16; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// 실폰 폭(360~412)·흔한 글자 크기(1.0·1.15·1.3)·큰 글씨(2.0, 골든과 같은 배율).
const _sizes = [(360.0, 1.0), (390.0, 1.0), (412.0, 1.15), (390.0, 1.3), (390.0, 2.0)];

/// 골든과 같은 한글 글꼴(맑은 고딕). 없는 PC(비 Windows)에서는 줄 검사를 건너뛴다 — 시험 기본 글꼴은 빈칸·숫자까지
/// 한 칸 폭이라 실화면 줄을 말할 수 없다.
final _koreanFont = File('C:/Windows/Fonts/malgun.ttf');
final _noKoreanFont = _koreanFont.existsSync() ? null : '맑은 고딕 글꼴이 없어 줄 검사를 건너뛰어요';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  setUpAll(() async {
    if (_noKoreanFont != null) return;
    final bytes = _koreanFont.readAsBytesSync();
    await (FontLoader('Malgun')..addFont(Future.value(ByteData.view(bytes.buffer)))).load();
  });

  group('B. 줄바꿈 사고', () {
    for (final (width, scale) in _sizes) {
      // 큰 글씨에서는 긴 묶음이 한 줄보다 길 수 있다 — 낱말 중간·한 글자 줄만 본다.
      final big = scale > 1.3;
      testWidgets('설정 — 낱말 중간·한 글자 줄·값 갈림 없음 ($width, $scale)', (tester) async {
        await _pump(tester, const SettingsScreen(), width: width, scale: scale, hub: false);
        expect(
            brokenLines(tester,
                keepTogether: big ? ['4건'] : ['읽지 않은 알림 4건', '연결됐는지 몰라요', '휴대폰 설정', '알아 둔 습관']),
            isEmpty);
        // 값은 한 줄 — 이름 옆에 다 안 들어가면 이름 아래로 내린다(값이 두 줄로 갈리지 않게).
        if (!big) {
          for (final v in ['읽지 않은 알림 4건', '연결됐는지 몰라요']) {
            expect(lineCountOf(tester, findPlainText(v)), 1, reason: v);
          }
        }
      }, skip: _noKoreanFont != null);

      testWidgets('루틴 탭 — 단위 묶음이 갈리지 않는다 ($width, $scale)', (tester) async {
        await _pump(tester, const RoutinesScreen(), width: width, scale: scale);
        expect(findPlainText('공기청정기 켜기', contains: true), findsWidgets);
        expect(
            brokenLines(tester,
                keepTogether: big
                    ? ['버튼 1개']
                    : ['누를 버튼 1개', '자동으로 해요']),
            isEmpty);
      }, skip: _noKoreanFont != null);

      testWidgets('홈 — 확인 카드·타일에 낱말 중간 줄바꿈 없음 ($width, $scale)', (tester) async {
        await _pump(tester, const HomeScreen(), width: width, scale: scale);
        expect(find.byKey(const Key('home-attention')), findsOneWidget);
        expect(brokenLines(tester, keepTogether: big ? ['버튼 1개'] : ['누를 버튼 1개', '설정 필요']), isEmpty);
      }, skip: _noKoreanFont != null);
    }
  });

  group('C. 개발자 시점 문장', () {
    testWidgets('내 가전 줄에 "처음부터 들어 있는"·"빼기는" 없음, LG 가전은 할 일만', (tester) async {
      await _pump(tester, const SettingsScreen(), width: 400, scale: 1.0, hub: false);
      expect(findPlainText('처음부터 들어 있는', contains: true), findsNothing);
      expect(findPlainText('빼기는', contains: true), findsNothing);
      expect(findPlainText('LG 앱에서 관리해요'), findsOneWidget);
    });

    test('다시 맞추기 → 가전 목록 새로 받기', () => expect(kResyncLabel, '가전 목록 새로 받기'));

    test('콘센트 → 전기 플러그', () {
      const r = EstopAckResult(EstopAckOutcome.outletUnreachable);
      expect(r.message, contains('전기 플러그'));
      expect(r.message, isNot(contains('콘센트')));
    });

    test('폰 화면 문자열에 콘센트·작업·단추·자동 실행이 없다(서버 문장 해석용 머리 제외)', () {
      final literal = RegExp(r"'[^'\n]*(콘센트|작업|단추|자동 실행)[^'\n]*'");
      final hits = <String>[];
      for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        final lines = f.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i].trimLeft();
          if (line.startsWith('//')) continue;
          final code = line.split(' //').first;
          if (!literal.hasMatch(code)) continue;
          // 서버 기록 목적 문장의 머리('자동 실행 · ')를 알아보는 상수 — 화면에 내지 않는다.
          if (code.contains('_autoPrefix')) continue;
          hits.add('${f.path}:${i + 1}: $code');
        }
      }
      expect(hits, isEmpty);
    });
  });

  group('D. 이름 통일', () {
    testWidgets('다음 실행 줄은 "자동으로 해요", 홈 배지도 같은 말', (tester) async {
      await _pump(tester, const RoutinesScreen(), width: 400, scale: 1.0);
      expect(findPlainText('다음: 아침 공기청정기 끄기 · 오늘 · 매일 07:00 · 자동으로 해요'), findsOneWidget);
      expect(findPlainText('자동 실행', contains: true), findsNothing);

      await _pump(tester, const HomeScreen(), width: 400, scale: 1.0);
      expect(findPlainText('자동으로 해요'), findsOneWidget);
      expect(find.text('자동'), findsNothing);
    });

    RpiHistoryEntry e(String purpose) => RpiHistoryEntry.fromJson({
          'job_id': 'j',
          'finished_at': '2026-10-18T10:00:00',
          'purpose': purpose,
          'status': 'succeeded',
          'retry_count': 0,
          'buttons': const [],
        });

    test('옛 기록 제목의 약풍·강풍·중풍은 바람 약하게·세게·중간으로', () {
      expect(historyTitle(e('공기청정기 약풍으로 바꿔줘')), '공기청정기 바람 약하게 하기');
      expect(historyTitle(e('공기청정기 강풍으로 바꿀까요?')), '공기청정기 바람 세게 하기');
      expect(historyTitle(e('자동 실행 · 공기청정기 중풍으로 바꾸기')), '공기청정기 바람 중간으로 하기');
      expect(historyTitle(e('공기청정기 강풍')), '공기청정기 바람 세게');
      expect(historyTitle(e('공기청정기 풍량을 강으로 바꿀까요?')), '공기청정기 바람 세게 하기');
      expect(historyTitle(e('공기청정기 바람 세기를 약으로 바꿀까요?')), '공기청정기 바람 약하게 하기');
    });
  });

  group('G. 설정 구조·알림만 루틴', () {
    testWidgets("'물어보기' 섹션 대신 '생활 습관' — 그 안의 줄은 '알아 둔 습관'", (tester) async {
      await _pump(tester, const SettingsScreen(), width: 400, scale: 1.0, hub: false);
      expect(find.text('물어보기'), findsNothing);
      expect(find.text('생활 습관'), findsOneWidget);
      expect(findPlainText('알아 둔 습관'), findsOneWidget);
      expect(findPlainText('생활 습관 알아가기'), findsNothing);
    });

    testWidgets("알림만 루틴은 종 아이콘 + '알려 드려요' 배지(실행 버튼 없이도 의도가 보인다)", (tester) async {
      await _pump(tester, const RoutinesScreen(), width: 400, scale: 1.0);
      final row = find.byKey(const Key('routine-row-r-notify'));
      expect(row, findsOneWidget);
      expect(find.descendant(of: row, matching: findPlainText('알려 드려요')), findsOneWidget);
      expect(
          find.descendant(
              of: row,
              matching: find.byWidgetPredicate((w) => w is Icon && w.icon == Icons.notifications_none_rounded && w.size == 24)),
          findsOneWidget,
          reason: '줄 아이콘(24)이 종');
      expect(find.byKey(const Key('routine-run-r-notify')), findsNothing);
      // 부제는 언제만 — '알림만'을 배지와 겹쳐 말하지 않는다.
      expect(find.descendant(of: row, matching: findPlainText('세탁이 끝나면')), findsOneWidget);
    });
  });
}
