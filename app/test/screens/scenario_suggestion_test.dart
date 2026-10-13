// 시나리오 카드(2026-09-29): 서버가 고정한 명령(대상·경로·동작)·근거·준비 상태를
// 보여 주고, 승인 재검사 실패(409)면 실행하지 않고 다시 확인하게 한다.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/providers/execution_status_provider.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/suggestion_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';

import '../helpers/test_helpers.dart';

const _card = {
  'id': 'sug-1',
  'purpose': '저녁 휴식 — 공기청정기를 켜고 선풍기를 약풍으로 켤까요?',
  'time_band': '시나리오',
  'occurrences': 0,
  'steps': <String>[],
  'reason': '시연: 합성 이력 — 실제 사용 기록이 아니에요',
  'appliance_id': 'air_purifier',
  'is_demo': true,
  'scenario_id': 'evening_rest',
  'commands': [
    {
      'target_id': 'air_purifier',
      'route': 'thinq',
      'action': 'set_power',
      'args': {'power': 'POWER_ON'},
      'buttons': <String>[],
      'summary': '공기청정기 전원 켜기',
    },
    {
      'target_id': 'fan',
      'route': 'physical',
      'action': null,
      'args': <String, dynamic>{},
      'buttons': ['전원', '약풍'],
      'summary': '선풍기 전원 → 약풍',
    },
  ],
};

/// 세탁 완료 → 제습기(G3). 폰이 모르는 가전 종류·대상이다.
const _washCard = {
  'id': 'sug-1',
  'purpose': '세탁이 끝났어요. 실내 건조를 위해 제습기를 켤까요?',
  'time_band': '시나리오',
  'occurrences': 0,
  'steps': <String>[],
  'reason': '세탁기가 세탁 완료를 알렸어요 — 빨래를 실내에 널면 습도가 올라가요',
  'appliance_id': 'dehumidifier',
  'is_demo': true,
  'scenario_id': 'wash_then_dry',
  'commands': [
    {
      'target_id': 'dehumidifier',
      'route': 'thinq',
      'action': 'set_power',
      'args': {'power': 'POWER_ON'},
      'buttons': <String>[],
      'summary': '제습기 전원 켜기',
    },
  ],
};

/// 루틴이 만든 카드(2026-10-07 에뮬레이터 결함). 서버 `purpose`는 질문이다.
const _routineCard = {
  'id': 'sug-1',
  'purpose': "'아침 데우기' 루틴을 실행할까요?",
  'time_band': '루틴',
  'occurrences': 0,
  'steps': <String>[],
  'reason': "루틴 '아침 데우기' · 평일 07:30 시각이에요",
  'appliance_id': 'microwave',
  'is_demo': false,
  'routine_id': 'rt-1',
  'routine_name': '아침 데우기',
  'commands': [
    {
      'target_id': 'microwave',
      'route': 'physical',
      'action': null,
      'args': <String, dynamic>{},
      'buttons': ['즉석밥', '시작'],
      'summary': '전자레인지 즉석밥 → 시작',
    },
  ],
};

class _Server {
  _Server({
    this.purifierReady = true,
    this.approveDetail = _mismatch,
    this.approveOk = false,
  });

  /// 승인이 받아들여지는 서버(job 접수).
  final bool approveOk;

  /// 세탁 완료 → 제습기 카드를 주는 서버.
  factory _Server.washThenDry() => _Server()
    ..card = _washCard
    ..scenarios = const [
      {'scenario_id': 'wash_then_dry', 'name': '세탁 후 건조'},
    ];

  /// 이 서버가 주는 제안 카드. 기본은 저녁 휴식.
  Map<String, dynamic> card = _card;
  List<Map<String, String>> scenarios = const [
    {'scenario_id': 'evening_rest', 'name': '저녁 휴식'},
  ];

  static const _mismatch = '승인한 내용과 지금 실행할 내용이 달라졌어요 — '
      '다시 확인하고 승인해 주세요 (승인한 명령과 실행할 명령의 지문이 달라요)';

  final bool purifierReady;
  final String approveDetail;
  int approveCalls = 0;
  bool retired = false;

  http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
        utf8.encode(jsonEncode(body)),
        status,
        headers: {'content-type': 'application/json'},
      );

  RpiApiService api() => RpiApiService(
        'http://rpi5.local:8000',
        client: MockClient((req) async {
          final path = req.url.path;
          if (path == '/suggestions') return _json(retired ? [] : [card]);
          if (path == '/scenarios') return _json(scenarios);
          if (path == '/readiness/dehumidifier') {
            return _json({
              'appliance_id': 'dehumidifier',
              'route': 'thinq',
              'state': 'operable',
              'can_execute': true,
              'reasons': <String>[],
            });
          }
          if (path == '/readiness/air_purifier') {
            return _json({
              'appliance_id': 'air_purifier',
              'route': 'thinq',
              'state': purifierReady ? 'operable' : 'disconnected',
              'can_execute': purifierReady,
              'reasons': purifierReady ? [] : ['가전이 오프라인이에요'],
            });
          }
          if (path == '/readiness/microwave') {
            return _json({
              'appliance_id': 'microwave',
              'route': 'physical',
              'state': 'operable',
              'can_execute': true,
              'reasons': <String>[],
            });
          }
          if (path == '/readiness/fan') {
            return _json({
              'appliance_id': 'fan',
              'route': 'physical',
              'state': 'disconnected',
              'can_execute': true,
              'reasons': [],
            });
          }
          if (path == '/suggestions/sug-1/approve') {
            approveCalls++;
            if (approveOk) return _json({'job_id': 'job-1'});
            // 승인 오류면 서버가 카드를 내린다(_fail_approval retire).
            retired = approveDetail.contains('승인');
            return _json({'detail': approveDetail}, 409);
          }
          return _json({'detail': 'not found'}, 404);
        }),
      );
}

Widget _build(_Server server) {
  final router = GoRouter(
    initialLocation: '/suggestion/sug-1',
    routes: [
      GoRoute(path: '/', builder: (_, __) => const Scaffold(body: Text('홈'))),
      GoRoute(
        path: '/suggestion/:id',
        builder: (context, state) =>
            SuggestionScreen(sequenceId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/status',
        // 실행 상태 화면이 제목으로 쓰는 값(status.label)을 그대로 보인다.
        builder: (_, __) => Scaffold(
          body: Consumer(
            builder: (_, ref, __) => Column(children: [
              const Text('상태 화면'),
              Text('라벨: ${ref.watch(executionStatusProvider).label}'),
            ]),
          ),
        ),
      ),
    ],
  );
  return buildWithProviderState(
    overrides: [
      ...connectedOverrides(),
      rpiApiServiceProvider.overrideWithValue(server.api()),
    ],
    child: MaterialApp.router(theme: ThemeData.dark(), routerConfig: router),
  );
}

void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(900, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('시나리오 이름·근거·고정 명령(가전·경로·동작)을 보여 준다', (tester) async {
    _tall(tester);
    await tester.pumpWidget(_build(_Server()));
    await _settle(tester);

    expect(find.text('시나리오 · 저녁 휴식'), findsOneWidget);
    expect(find.textContaining('근거: 시연'), findsOneWidget);
    expect(find.text('공기청정기 전원 켜기'), findsOneWidget);
    expect(find.text('선풍기 전원 → 약풍'), findsOneWidget);
    expect(find.text('ThinQ'), findsOneWidget);
    expect(find.text('버튼을 대신 눌러요'), findsOneWidget);
    // ThinQ 가전은 폰 가전 목록에 없어도 '대상을 찾지 못함'이 아니다.
    expect(find.text('대상 가전 정보를 확인해 주세요.'), findsNothing);
    final run = tester.widget<FilledButton>(
        find.ancestor(of: find.text('지금 실행'), matching: find.byWidgetPredicate((w) => w is FilledButton)));
    expect(run.onPressed, isNotNull);
  });

  testWidgets('409(승인 내용 변경)면 실행하지 않고 다시 확인하라고 한 뒤 카드를 새로 받는다',
      (tester) async {
    _tall(tester);
    final server = _Server();
    await tester.pumpWidget(_build(server));
    await _settle(tester);

    await tester.tap(find.text('지금 실행'));
    await _settle(tester);

    expect(server.approveCalls, 1);
    expect(find.text('제안 내용이 바뀌어 다시 확인이 필요해요'), findsOneWidget);
    expect(find.text('상태 화면'), findsNothing);
    // 서버가 내린 카드는 목록에서도 사라졌다(재조회).
    expect(find.text('제안을 찾을 수 없어요.'), findsOneWidget);
  });

  testWidgets('다른 작업 실행 중(409, 승인 문장 아님)은 종전 안내', (tester) async {
    _tall(tester);
    final server =
        _Server(approveDetail: 'an execution is already in progress');
    await tester.pumpWidget(_build(server));
    await _settle(tester);

    await tester.tap(find.text('지금 실행'));
    await _settle(tester);

    expect(find.textContaining('다른 작업이 실행 중이에요'), findsOneWidget);
    expect(find.text('제안 내용이 바뀌어 다시 확인이 필요해요'), findsNothing);
  });

  testWidgets('세탁 완료 → 제습기(wash_then_dry) 카드도 그대로 보여 준다',
      (tester) async {
    // 제습기는 폰이 아는 가전 종류 표에 없다(서버 구성 가전, category other).
    // 모르는 대상이라고 카드가 깨지거나 '대상을 찾지 못함'으로 빠지면 안 된다.
    _tall(tester);
    await tester.pumpWidget(_build(_Server.washThenDry()));
    await _settle(tester);

    expect(find.text('시나리오 · 세탁 후 건조'), findsOneWidget);
    expect(find.textContaining('세탁이 끝났어요'), findsOneWidget);
    expect(find.text('제습기 전원 켜기'), findsOneWidget);
    expect(find.text('ThinQ'), findsOneWidget);
    expect(find.text('대상 가전 정보를 확인해 주세요.'), findsNothing);
    final run = tester.widget<FilledButton>(find.ancestor(
        of: find.text('지금 실행'),
        matching: find.byWidgetPredicate((w) => w is FilledButton)));
    expect(run.onPressed, isNotNull);
  });

  // 2026-10-07 에뮬레이터: 루틴 제안을 승인하면 실행 상태 화면 제목이 제안의
  // 질문("'아침 데우기' 루틴을 실행할까요?")으로 남았다. 키오스크(15ac5b6)와
  // 같은 규칙 — 끝난 일의 이름은 질문이 아니라 루틴·시나리오 이름이다.
  testWidgets('루틴 제안을 승인하면 실행 상태 제목은 질문이 아니라 루틴 이름',
      (tester) async {
    _tall(tester);
    final server = _Server(approveOk: true)..card = _routineCard;
    await tester.pumpWidget(_build(server));
    await _settle(tester);

    await tester.tap(find.text('지금 실행'));
    await _settle(tester);

    expect(server.approveCalls, 1);
    expect(find.text('상태 화면'), findsOneWidget);
    expect(find.text("라벨: '아침 데우기' 루틴"), findsOneWidget);
    expect(find.textContaining('실행할까요?'), findsNothing);
    // 폴링 타이머를 정리한다(위젯 트리를 내리면 provider가 정리된다).
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('시나리오 제안(질문)을 승인하면 실행 상태 제목은 시나리오 이름',
      (tester) async {
    _tall(tester);
    final server = _Server(approveOk: true);
    await tester.pumpWidget(_build(server));
    await _settle(tester);

    await tester.tap(find.text('지금 실행'));
    await _settle(tester);

    expect(find.text('라벨: 저녁 휴식'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('ThinQ 대상이 준비 안 됐으면 실행을 막고 이유(412 사유)를 말한다',
      (tester) async {
    _tall(tester);
    await tester.pumpWidget(_build(_Server(purifierReady: false)));
    await _settle(tester);

    expect(find.textContaining('가전이 오프라인이에요'), findsWidgets);
    final run = tester.widget<FilledButton>(
        find.ancestor(of: find.text('지금 실행'), matching: find.byWidgetPredicate((w) => w is FilledButton)));
    expect(run.onPressed, isNull);
  });

  // ── 2026-10-14 보드 날 발견 4: 글꼴 2.0·360×780에서 아래 고정 영역 ───────────────────────────
  testWidgets('글꼴 2.0·360×780: 아래 고정 영역은 실행·다음에만 — 할 일 줄이 첫 화면에 보이고 보조 행동은 본문 끝',
      (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final handle = tester.ensureSemantics();
    final server = _Server()..card = _routineCard;
    await tester.pumpWidget(_build(server));
    await _settle(tester);

    final bar = find.byKey(const Key('suggestion-action-bar'));
    expect(bar, findsOneWidget);
    final barTop = tester.getTopLeft(bar).dy;
    expect(780 - barTop, lessThan(780 * 0.35), reason: '고정 영역이 화면의 35% 이상을 차지한다');
    // 본문(무엇을 승인하는지)이 화면의 절반 넘게 남는다. 시험 글꼴은 실제 글꼴보다 넓어 할 일 줄이 첫 화면 아래일 수
    // 있다 — 스크롤하면 고정 영역에 가리지 않고 닿는다.
    final row = find.text('전자레인지 즉석밥 → 시작');
    await tester.ensureVisible(row);
    await tester.pump();
    expect(tester.getBottomLeft(row).dy, lessThanOrEqualTo(barTop));
    expect(row.hitTestable(), findsOneWidget);
    // 실행·다음에는 고정 영역에 남아 언제든 닿는다.
    expect(find.descendant(of: bar, matching: find.text('지금 실행')).hitTestable(), findsOneWidget);
    expect(find.descendant(of: bar, matching: find.text('다음에')).hitTestable(), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('지금 실행')), findsWidgets);
    // 보조 행동은 고정 영역에서 빠져 본문 끝으로 — 스크롤하면 닿는다.
    for (final text in ['이 제안 30분 쉬기', '이 제안 다시 받지 않기']) {
      expect(find.descendant(of: bar, matching: find.text(text)), findsNothing, reason: text);
    }
    await tester.scrollUntilVisible(find.text('이 제안 다시 받지 않기'), 120,
        scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(find.text('이 제안 다시 받지 않기'));
    await tester.pump();
    expect(find.text('이 제안 다시 받지 않기').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    handle.dispose();
  });

  testWidgets('기본 글꼴에서는 보조 행동도 아래 고정 영역에 그대로', (tester) async {
    _tall(tester);
    final server = _Server()..card = _routineCard;
    await tester.pumpWidget(_build(server));
    await _settle(tester);
    final bar = find.byKey(const Key('suggestion-action-bar'));
    expect(find.descendant(of: bar, matching: find.text('이 제안 다시 받지 않기')), findsOneWidget);
  });
}
