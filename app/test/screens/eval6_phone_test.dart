// 평가 6차(2026-10-18, 종합 83·폰 83).
//
// A. 루틴 목록: '지금 하기'는 줄 오른쪽 단추 하나(홈 '지금 하기 >'와 같은 모양). 위 '다음: …' 한 줄은 없애고
//    다음에 할 루틴 줄에 '다음' 배지. 정해진 시각 줄도 왼쪽은 가전 아이콘 — 왼쪽 열이 맞는다.
// B. 끈 자동으로 하기: '지금은 안 해요' + '자동으로 하기를 꺼 두셨어요' 같은 말 두 번 → 한 줄.
// C. 조용한 시간이 꺼져 있으면 규칙 카드에 '켜면 …' 경고를 늘 굵게 두지 않는다(실제로 건너뛸 때만 눈에 띄게).
// D. 기록 배지: 같은 '됐어요'에 ✓와 ⓘ를 섞지 않는다(이미 그 설정도 같은 ✓, 차이는 펼친 문장에서).
// E. 낱말: '시험 이동' → '자리 확인', '가전 목록 새로 받기' → '가전 다시 불러오기'.
// F. 대비·높이: 보조 글씨 한 단계 진하게(실제 얹히는 면 위 7:1 이상), 홈에서 가전 두 줄(4개)이 한 화면에.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

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
import 'package:simplelay/models/hub.dart';
import 'package:simplelay/providers/care_events_provider.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/history_screen.dart';
import 'package:simplelay/screens/home_screen.dart';
import 'package:simplelay/screens/routines_screen.dart';
import 'package:simplelay/screens/settings_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';
import 'package:simplelay/theme/app_colors.dart';

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

Map<String, dynamic> _rule(String id, String name, {required bool enabled, String? reason, String? time}) => {
      'id': id,
      'scenario_id': 'cook_done_air',
      'name': name,
      'condition_text': time == null ? '전자레인지가 데우기를 멈추면' : '매일 밤 ${time.substring(0, 2)}시에',
      'action_text': '공기청정기 바람을 세게 해요',
      'action': 'set_wind_strength',
      'value': 'HIGH',
      'allowed_values': [
        {'value': 'LOW', 'label': '약'},
        {'value': 'HIGH', 'label': '강'},
      ],
      'enabled': enabled,
      'disabled_reason': reason,
      'fingerprint': 'fp-$id',
      if (time != null) 'condition_kind': 'time',
      if (time != null) 'condition_time': time,
    };

RpiApiService _api({required bool quietEnabled}) => RpiApiService(
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
              'routine_id': 'r-morn',
              'name': '아침 공기청정기 끄기',
              'at': '2026-10-19T07:00:00+09:00',
              'when': '매일 07:00',
              'day_label': '오늘',
              'mode': 'approve',
              'mode_label': '자동 실행',
              'auto': true,
            },
          ]);
        }
        if (path == '/routines/auto-rules') {
          return json([
            _rule('ar-on', '저녁 공기청정기 켜기', enabled: true, time: '22:00'),
            _rule('ar-off', '데우기 멈추면 공기청정기', enabled: false, reason: '자동으로 하기를 꺼 두셨어요.'),
          ]);
        }
        if (path == '/quiet-hours') {
          return json({'enabled': quietEnabled, 'start': '22:00', 'end': '07:00', 'active': false});
        }
        if (path == '/thinq/power') {
          return json({
            'execution_mode': 'real',
            'appliances': [
              {'appliance_id': 'air', 'power': 'on', 'age_s': 3},
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

class _SeededCare extends CareEventsNotifier {
  _SeededCare(super.ref, CareEventsState seed) {
    state = seed;
  }

  @override
  Future<void> refresh() async {}
}

Override _care(int unread) => careEventsProvider.overrideWith((ref) => _SeededCare(
    ref,
    CareEventsState(status: CareInboxStatus.ready, events: [
      for (var i = unread; i >= 1; i--)
        RpiCareEvent(id: i, kind: 'execution_failed', message: '실패 $i', occurredAt: DateTime(2026, 10, 18, 8, i)),
    ])));

Widget _app(Widget screen, {bool quietEnabled = false, int unread = 0, bool korean = false}) {
  final router = GoRouter(routes: [
    GoRoute(path: '/', builder: (_, __) => screen),
  ]);
  return buildWithProviderState(
    overrides: [
      ...connectedOverrides(),
      ...installedOverrides(_installed),
      rpiServerOverride(RpiConnectionState.connected),
      rpiApiServiceProvider.overrideWithValue(_api(quietEnabled: quietEnabled)),
      _care(unread),
    ],
    child: MaterialApp.router(
      theme: korean
          ? ThemeData.light().copyWith(textTheme: ThemeData.light().textTheme.apply(fontFamily: 'Malgun'))
          : ThemeData.light(),
      routerConfig: router,
    ),
  );
}

Future<void> _pump(WidgetTester tester, Widget screen,
    {Size size = const Size(400, 3000), bool quietEnabled = false, int unread = 0, bool korean = false}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_app(screen, quietEnabled: quietEnabled, unread: unread, korean: korean));
  for (var i = 0; i < 16; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _openRules(WidgetTester tester) async {
  await tester.tap(findPlainText('자동으로 하기'));
  for (var i = 0; i < 16; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// 시각 루틴에 붙은 규칙은 루틴 줄 '자동'을 눌러 연다(평가 14차 10/18 — '자동으로 하기' 탭에는 없다).
Future<void> _openRoutineRule(WidgetTester tester, String routineId) async {
  await tester.tap(find.byKey(Key('routine-auto-badge-$routineId')));
  for (var i = 0; i < 16; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

double _luminance(Color c) {
  double channel(double v) => v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
}

double _contrast(Color a, Color b) {
  final la = _luminance(a), lb = _luminance(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

// 높이는 실제 한글 글꼴로 잰다(시험 글꼴은 글자가 네모 한 칸씩이라 실제보다 넓고 높다).
final _koreanFont = File('C:/Windows/Fonts/malgun.ttf');
final _noKoreanFont = _koreanFont.existsSync() ? null : '맑은 고딕 글꼴이 없어 높이 검사를 건너뛰어요';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  setUpAll(() async {
    if (_noKoreanFont != null) return;
    final bytes = _koreanFont.readAsBytesSync();
    await (FontLoader('Malgun')..addFont(Future.value(ByteData.view(bytes.buffer)))).load();
  });

  group('A. 루틴 목록', () {
    testWidgets("위 '다음: …' 한 줄은 없고, 다음에 할 줄에 '다음' 배지", (tester) async {
      await _pump(tester, const RoutinesScreen());
      expect(find.byKey(const Key('routines-next')), findsNothing);
      expect(findPlainText('다음:', contains: true), findsNothing);
      final badge = find.byKey(const Key('routine-next-badge-r-morn'));
      expect(find.descendant(of: find.byKey(const Key('routine-row-r-morn')), matching: badge), findsOneWidget);
      expect(find.descendant(of: badge, matching: findPlainText('다음')), findsOneWidget);
      expect(find.byKey(const Key('routine-next-badge-r-eve')), findsNothing);
    });

    // 휴리스틱·보호자 과업 평가(10/18): 오른쪽 '지금 하기 >'는 줄 이동처럼 보여 줄 누르기가 겁났다 → '지금 하기'는 이름
    // 아래 따로 작은 단추(▶, 화살표 없음), 줄 오른쪽 >는 고치기. 결선 모의 평가(10/18): '고치기' 단추는 두지 않는다(줄 누르기만).
    testWidgets("'지금 하기'는 이름 아래 따로 작은 단추 — 줄 오른쪽 >는 고치기", (tester) async {
      await _pump(tester, const RoutinesScreen());
      final run = find.byKey(const Key('routine-run-r-heat'));
      expect(run, findsOneWidget);
      expect(find.descendant(of: run, matching: find.byIcon(Icons.chevron_right)), findsNothing);
      expect(find.descendant(of: run, matching: find.byIcon(Icons.play_arrow_rounded)), findsOneWidget);
      final name = findPlainText('30초 데우기');
      expect(tester.getTopLeft(run).dy, greaterThanOrEqualTo(tester.getBottomLeft(name).dy));
      expect(tester.getSize(run).height, greaterThanOrEqualTo(48));
      expect(find.descendant(of: find.byKey(const Key('routine-row-r-heat')), matching: findPlainText('고치기')), // 단추 없음
          findsNothing);
    });

    testWidgets('정해진 시각 줄에도 가전 아이콘 — 왼쪽 열이 맞는다', (tester) async {
      await _pump(tester, const RoutinesScreen());
      final morn = find.descendant(of: find.byKey(const Key('routine-row-r-morn')), matching: find.byIcon(Icons.air));
      expect(morn, findsOneWidget);
      final heat = find.descendant(
          of: find.byKey(const Key('routine-row-r-heat')),
          matching: find.byIcon(ApplianceCategory.parse('microwave').icon));
      expect(heat, findsOneWidget);
      expect(tester.getCenter(morn).dx, moreOrLessEquals(tester.getCenter(heat).dx, epsilon: 0.5));
      // 시각은 이름 아래 한 줄(평가 10차 10/18).
      expect(find.byKey(const Key('routine-line-r-morn')), findsOneWidget);
    });
  });

  group('B·C. 자동으로 하기 카드', () {
    // 평가 8차(10/18): 사용자가 끈 규칙은 스위치만 — '꺼 두셨어요' 배지도 두지 않는다(eval8_phone_test D).
    testWidgets("끈 규칙에 '지금은 안 해요'·'꺼 두셨어요'를 겹쳐 두지 않는다 — 스위치만", (tester) async {
      await _pump(tester, const RoutinesScreen());
      await _openRules(tester);
      final card = find.byKey(const Key('auto-rule-ar-off'));
      expect(find.descendant(of: card, matching: findPlainText('자동으로 하기를 꺼 두셨어요', contains: true)),
          findsNothing);
      expect(find.byKey(const Key('auto-rule-switch-ar-off')), findsOneWidget);
      expect(find.descendant(of: card, matching: findPlainText('지금은 안 해요', contains: true)), findsNothing);
    });

    testWidgets('조용한 시간이 꺼져 있으면 규칙 카드에 굵은 경고가 없다', (tester) async {
      await _pump(tester, const RoutinesScreen(), quietEnabled: false);
      await _openRoutineRule(tester, 'r-eve');
      expect(find.byKey(const Key('auto-rule-ar-on')), findsOneWidget);
      final card = find.byKey(const Key('auto-rule-ar-on'));
      expect(find.descendant(of: card, matching: findPlainText('조용한 시간', contains: true)), findsNothing);
    });

    testWidgets('조용한 시간이 켜져 실제로 건너뛰면 눈에 띄게(주의 색·굵게)', (tester) async {
      await _pump(tester, const RoutinesScreen(), quietEnabled: true);
      await _openRoutineRule(tester, 'r-eve');
      final note = find.descendant(
          of: find.byKey(const Key('auto-rule-ar-on')),
          matching: findPlainText('조용한 시간(오후 10:00~오전 7:00)이라 이때는 자동으로 안 해요'));
      expect(note, findsOneWidget);
      final style = tester.widget<Text>(note).style!;
      expect(style.color, AppColors.warningLight);
      expect(style.fontWeight, FontWeight.w600);
    });
  });

  group('D. 기록 배지 기호 하나', () {
    RpiHistoryEntry e(String confirmation) => RpiHistoryEntry.fromJson({
          'job_id': 'j',
          'finished_at': '2026-10-18T10:00:00',
          'status': 'succeeded',
          'retry_count': 0,
          'buttons': const [],
          'execution_mode': 'real',
          'route': 'thinq',
          'confirmation': confirmation,
        });

    test("'됐어요'는 늘 같은 ✓ — 이미 그 설정도 같은 아이콘·같은 말", () {
      final done = historyBadgeOf(e('state_confirmed'));
      final already = historyBadgeOf(e('already_at_target'));
      expect(already.label, '됐어요');
      expect(already.icon, done.icon);
      expect(already.tone, done.tone);
    });
  });

  group('E. 낱말', () {
    test("'시험 이동' 대신 '자리 확인'", () {
      final notes = [
        verifyPassLookupNote(const VerifyPassLookup.noRecord()),
        verifyPassLookupNote(const VerifyPassLookup.unknown()),
      ];
      expect(notes, ['아직 자리 확인을 안 했어요', '버튼 자리를 다시 맞춰 주세요']);
    });

    test("다시 보내기 단추 이름(평가 11차에 다시 바꿈)", () => expect(kResyncLabel, '본체 화면에 반영하기'));
  });

  group('F. 대비·높이', () {
    // 보조 글씨가 실제로 얹히는 면 — 바탕·흰 카드·눌린 면, 그리고 홈 '지금 우리 집'(옅은 회색)·'확인이 필요해요'(옅은 주황).
    Color over(Color top, Color base) => Color.alphaBlend(top, base);

    test('라이트 보조 글씨: 한 단계 진하게(흰 카드 9:1 이상), 얹히는 모든 면 7:1 이상', () {
      const muted = AppColors.onSurfaceMutedLight;
      const bg = AppColors.backgroundLight;
      expect(_contrast(muted, AppColors.surfaceLowLight), greaterThanOrEqualTo(9.0));
      for (final face in [
        bg,
        AppColors.surfaceLowLight,
        AppColors.surfaceHighLight,
        over(Colors.black.withValues(alpha: 0.04), bg),
        over(AppColors.warningLight.withValues(alpha: 0.08), bg),
        over(muted.withValues(alpha: 0.10), AppColors.surfaceLowLight),
      ]) {
        expect(_contrast(muted, face), greaterThanOrEqualTo(7.0), reason: '$face');
      }
    });

    test('다크 보조 글씨: 한 단계 밝게(카드 9:1 이상), 얹히는 모든 면 7:1 이상', () {
      const muted = AppColors.onSurfaceMuted;
      const bg = AppColors.background;
      expect(_contrast(muted, AppColors.surfaceLow), greaterThanOrEqualTo(9.0));
      for (final face in [
        bg,
        AppColors.surfaceLow,
        AppColors.surfaceHigh,
        over(Colors.white.withValues(alpha: 0.05), bg),
        over(AppColors.warning.withValues(alpha: 0.08), bg),
      ]) {
        expect(_contrast(muted, face), greaterThanOrEqualTo(7.0), reason: '$face');
      }
    });

    testWidgets('홈: 지금 우리 집 + 확인이 필요해요가 있어도 가전 두 줄(4개)이 첫 화면에', (tester) async {
      // 흔한 폰(412×915) — 상태 표시줄 24·아래 탭 80을 뺀 811 안.
      await _pump(tester, const HomeScreen(), size: const Size(412, 3000), unread: 4, korean: true);
      expect(find.byKey(const Key('home-now')), findsOneWidget);
      expect(find.byKey(const Key('home-failure')), findsOneWidget);
      final second = [
        for (final id in ['washer', 'door'])
          tester.getBottomLeft(find.byKey(Key('appliance-card-$id'))).dy,
      ];
      expect(second.reduce(math.max), lessThanOrEqualTo(811.0));
    }, skip: _noKoreanFont != null);
  });
}
