// 자동 실행 허용 규칙(2026-10-13, 시연 v4) — 조리 완료 → 공기청정기 카드의 세 갈래와 확인 시트,
// 루틴 목록의 '자동 실행 켜짐/꺼짐'·끄기·다시 허용·설정값 바꾸기. 가짜 서버로만 본다(실가전 아님).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/routines_screen.dart';
import 'package:simplelay/screens/suggestion_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';

import '../helpers/test_helpers.dart';

const _offer = {
  'condition_text': '전자레인지가 멈추면',
  'action_text': '거실 공기청정기 풍량 강으로',
  'fingerprint': 'fp-offer-1',
};

Map<String, dynamic> _card({bool offer = true, Map<String, dynamic>? offerJson}) => {
      'id': 'sug-1',
      'purpose': '공기청정기 강풍으로 바꿀까요?',
      'time_band': '시나리오',
      'occurrences': 0,
      'steps': <String>[],
      'reason': '전자레인지 조리 완료를 콘센트 전력(CT)으로 확인했어요',
      'appliance_id': 'air_purifier',
      'is_demo': true,
      'scenario_id': 'cook_done_air',
      'commands': [
        {
          'target_id': 'air_purifier',
          'route': 'thinq',
          'action': 'set_wind_strength',
          'args': {'wind_strength': 'HIGH'},
          'buttons': <String>[],
          'summary': '거실 공기청정기 풍량 강',
        },
      ],
      if (offer) 'auto_rule_offer': offerJson ?? _offer,
    };

Map<String, dynamic> _rule({
  bool enabled = true,
  String value = 'HIGH',
  String fingerprint = 'fp-rule-high',
  String? reason,
}) =>
    {
      'id': 'ar-1',
      'scenario_id': 'cook_done_air',
      'name': '조리 완료 → 공기청정기',
      'condition_text': '전자레인지가 멈추면',
      'action_text': '거실 공기청정기 풍량 ${value == 'MID' ? '중' : '강'}으로',
      'action': 'set_wind_strength',
      'value': value,
      'allowed_values': [
        {'value': 'LOW', 'label': '약'},
        {'value': 'MID', 'label': '중'},
        {'value': 'HIGH', 'label': '강'},
      ],
      'enabled': enabled,
      'status_label': enabled ? '자동 실행 켜짐' : '자동 실행 꺼짐',
      'disabled_reason': reason,
      'fingerprint': fingerprint,
      'last_run': {
        'notices': ['데우기가 끝났어요 (콘센트 전력으로 확인)', '거실 공기청정기 풍량을 바꿨어요 (상태 재조회로 확인)'],
      },
    };

class _Server {
  _Server({this.offer = true, this.allowReply, this.offerJson});

  final bool offer;
  final Map<String, dynamic>? offerJson;
  final (int, Map<String, dynamic>)? allowReply;
  final requests = <String>[];
  final bodies = <String, Map<String, dynamic>>{};
  Map<String, dynamic> rule = _rule();

  /// GET /quiet-hours — null이면 404(옛 시험과 같게).
  Map<String, dynamic>? quiet;

  http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
        utf8.encode(jsonEncode(body)),
        status,
        headers: {'content-type': 'application/json'},
      );

  RpiApiService api() => RpiApiService(
        'http://rpi5.local:8000',
        client: MockClient((req) async {
          final path = req.url.path;
          requests.add('${req.method} $path');
          if (req.bodyBytes.isNotEmpty) {
            bodies['${req.method} $path'] =
                jsonDecode(utf8.decode(req.bodyBytes)) as Map<String, dynamic>;
          }
          if (path == '/suggestions') return _json([_card(offer: offer, offerJson: offerJson)]);
          if (path == '/scenarios') {
            return _json([
              {'scenario_id': 'cook_done_air', 'name': '조리 완료 → 공기청정기'},
            ]);
          }
          if (path == '/readiness/air_purifier') {
            return _json({
              'appliance_id': 'air_purifier',
              'route': 'thinq',
              'state': 'operable',
              'can_execute': true,
              'reasons': <String>[],
            });
          }
          if (path == '/suggestions/sug-1/approve') return _json({'job_id': 'job-1'});
          if (path == '/suggestions/sug-1/approve-and-allow') {
            final reply = allowReply;
            if (reply != null) return _json(reply.$2, reply.$1);
            return _json({'job_id': 'job-2', 'rule': rule});
          }
          if (req.method == 'GET' && path == '/routines') return _json(<dynamic>[]);
          if (req.method == 'GET' && path == '/routines/auto-rules') return _json([rule]);
          if (req.method == 'GET' && path == '/quiet-hours' && quiet != null) return _json(quiet!);
          if (req.method == 'POST' && path == '/routines/auto-rules/ar-1/enable') {
            final body = bodies['POST $path']!;
            if (body['enabled'] == false) {
              rule = _rule(enabled: false, reason: '직접 자동 실행을 껐어요.');
            } else if (body['fingerprint'] == rule['fingerprint']) {
              rule = _rule(value: rule['value'] as String, fingerprint: rule['fingerprint'] as String);
            } else {
              return _json({'detail': '허용할 내용이 바뀌었어요'}, 409);
            }
            return _json(rule);
          }
          if (req.method == 'PUT' && path == '/routines/auto-rules/ar-1') {
            final value = bodies['PUT $path']!['value'] as String;
            rule = _rule(
                enabled: false, value: value, fingerprint: 'fp-rule-$value', reason: '설정값을 바꿔 다시 허용이 필요해요');
            return _json(rule);
          }
          if (path.startsWith('/execute')) fail('실행 경로를 불렀어요: $path');
          return _json({'detail': 'not found'}, 404);
        }),
      );
}

Widget _cardApp(_Server server) {
  final router = GoRouter(
    initialLocation: '/suggestion/sug-1',
    routes: [
      GoRoute(path: '/', builder: (_, __) => const Scaffold(body: Text('홈'))),
      GoRoute(
        path: '/suggestion/:id',
        builder: (_, state) => SuggestionScreen(sequenceId: state.pathParameters['id']!),
      ),
      GoRoute(path: '/status', builder: (_, __) => const Scaffold(body: Text('상태 화면'))),
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

Widget _list(_Server server) {
  final router = GoRouter(
    initialLocation: '/routines',
    routes: [GoRoute(path: '/routines', builder: (_, __) => const RoutinesScreen())],
  );
  return buildWithProviderState(
    overrides: [
      ...connectedOverrides(),
      ...installedOverrides([kTestAppliance]),
      rpiApiServiceProvider.overrideWithValue(server.api()),
    ],
    child: MaterialApp.router(theme: ThemeData.dark(), routerConfig: router),
  );
}

void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(900, 2200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('조리 완료 → 공기청정기 카드', () {
    testWidgets('세 갈래: 이번만 실행 · 다음부터도 자동으로 · 안 할래요', (tester) async {
      _tall(tester);
      await tester.pumpWidget(_cardApp(_Server()));
      await _settle(tester);

      expect(find.text('이번만 하기'), findsOneWidget);
      expect(find.text('다음부터도 자동으로'), findsOneWidget);
      expect(find.text('이번엔 안 할게요'), findsOneWidget);
      expect(find.text('지금 하기'), findsNothing);
      // 자동 허용은 보조 버튼(외곽선)이다 — 이번만 실행(채움)과 같은 무게로 떠밀지 않는다(외부 평가 10/16 p05).
      expect(
          find.ancestor(
              of: find.text('다음부터도 자동으로'),
              matching: find.byWidgetPredicate((w) => w is OutlinedButton)),
          findsOneWidget);
    });

    testWidgets('세 갈래는 아래 고정 영역에 그대로, 동작 바꾸기 등은 더 보기로 — 자동 허용은 더 보기에 없다',
        (tester) async {
      _tall(tester);
      await tester.pumpWidget(_cardApp(_Server()));
      await _settle(tester);

      final bar = find.byKey(const Key('suggestion-action-bar'));
      final barButtons = find.descendant(
          of: bar, matching: find.byWidgetPredicate((w) => w is ButtonStyleButton));
      expect(barButtons, findsNWidgets(3));
      for (final text in ['이번만 하기', '다음부터도 자동으로', '이번엔 안 할게요']) {
        expect(find.descendant(of: bar, matching: find.text(text)), findsOneWidget, reason: text);
      }
      expect(find.text('이번 동작 바꾸기'), findsNothing);
      await tester.tap(find.byKey(const Key('suggestion-more')));
      await _settle(tester);
      // 더 보기 안에는 관리 선택지만 — 자동 허용·실행은 고정 영역에만 있다.
      final sheet = find.byType(BottomSheet);
      expect(find.descendant(of: sheet, matching: find.text('이번 동작 바꾸기')), findsOneWidget);
      expect(find.descendant(of: sheet, matching: find.textContaining('자동')), findsNothing);
      expect(find.descendant(of: sheet, matching: find.textContaining('실행')), findsNothing);
    });

    testWidgets('시각 규칙(2026-10-16): 서버 caveat 문장을 그대로 보이고 조리 문장은 보이지 않는다', (tester) async {
      _tall(tester);
      const timeCaveat = '그 시각에 허브가 꺼져 있었거나 조용한 시간이면 하지 않고, 늦게 알아차리면 카드로 물어봐요.';
      await tester.pumpWidget(_cardApp(_Server(offerJson: {
        'condition_text': '매일 23:00이 되면',
        'action_text': '공기청정기 전원 켜기',
        'fingerprint': 'fp-time-1',
        'caveat': timeCaveat,
      })));
      await _settle(tester);
      await tester.tap(find.text('다음부터도 자동으로'));
      await _settle(tester);
      expect(find.text('언제: 매일 23:00이 되면'), findsOneWidget);
      expect(find.text(timeCaveat), findsOneWidget);
      expect(find.textContaining('요리가 다 된 건 아닐 수 있어요'), findsNothing);
    });

    testWidgets('caveat가 null이면 한계 문장 줄을 보이지 않는다(옛 서버처럼 칸이 없으면 지금 문장)', (tester) async {
      _tall(tester);
      await tester.pumpWidget(_cardApp(_Server(offerJson: {
        'condition_text': '매일 07:00이 되면',
        'action_text': '공기청정기 전원 켜기',
        'fingerprint': 'fp-time-2',
        'caveat': null,
      })));
      await _settle(tester);
      await tester.tap(find.text('다음부터도 자동으로'));
      await _settle(tester);
      expect(find.byKey(const Key('auto-rule-caveat')), findsNothing);
    });

    testWidgets('다음부터도 자동으로 → 조건·동작 확인 시트, 취소면 아무것도 보내지 않는다', (tester) async {
      _tall(tester);
      final server = _Server();
      await tester.pumpWidget(_cardApp(server));
      await _settle(tester);

      await tester.tap(find.text('다음부터도 자동으로'));
      await _settle(tester);
      expect(find.text('이번에 실행하고\n다음부터 자동으로 할까요?'), findsOneWidget);
      expect(find.text('언제: 전자레인지가 멈추면'), findsOneWidget);
      expect(find.text('무엇을: 거실 공기청정기 풍량 강으로'), findsOneWidget);
      // 짧아진 조건 문장의 한계(조리 완료가 아닐 수 있음)는 허용하는 이 시트에서 말한다(2026-10-14).
      expect(find.byKey(const Key('auto-rule-caveat')), findsOneWidget);
      expect(find.textContaining('요리가 다 된 건 아닐 수 있어요'), findsOneWidget);
      expect(find.text('허락하고 이번에도 하기'), findsOneWidget);

      await tester.tap(find.byKey(const Key('auto-rule-cancel')));
      await _settle(tester);
      expect(server.requests.where((r) => r.contains('approve')), isEmpty);
      expect(find.text('상태 화면'), findsNothing);
    });

    testWidgets('허용하고 이번에도 실행 → 확인한 내용의 지문으로 한 번에 승인·저장하고 실행 상태로', (tester) async {
      _tall(tester);
      final server = _Server();
      await tester.pumpWidget(_cardApp(server));
      await _settle(tester);

      await tester.tap(find.text('다음부터도 자동으로'));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('auto-rule-allow')));
      await _settle(tester);

      expect(server.requests, contains('POST /suggestions/sug-1/approve-and-allow'));
      expect(server.requests, isNot(contains('POST /suggestions/sug-1/approve')));
      expect(server.bodies['POST /suggestions/sug-1/approve-and-allow'],
          {'offer_fingerprint': 'fp-offer-1'});
      expect(find.text('상태 화면'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('이번 실행은 접수됐지만 자동 허용이 저장되지 않으면(정지가 끼어듦) 그 사실을 따로 알린다', (tester) async {
      _tall(tester);
      const reason = '허용을 저장하는 사이 전체 정지가 들어와 다음부터 자동 실행은 켜지 않았어요 — '
          '다시 켜려면 조건·동작을 확인하고 허용해 주세요';
      final server = _Server(allowReply: (200, {
        'job_id': 'job-2',
        'rule': null,
        'auto_allow': {'ok': false, 'reason': reason},
      }));
      await tester.pumpWidget(_cardApp(server));
      await _settle(tester);

      await tester.tap(find.text('다음부터도 자동으로'));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('auto-rule-allow')));
      await _settle(tester);
      expect(find.text('상태 화면'), findsOneWidget); // 이번 실행은 실행 상태로 따라간다
      expect(find.text(reason), findsOneWidget); // 자동 허용 실패는 따로
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('이번만 실행은 종전 승인 하나뿐(규칙 저장 없음)', (tester) async {
      _tall(tester);
      final server = _Server();
      await tester.pumpWidget(_cardApp(server));
      await _settle(tester);

      await tester.tap(find.text('이번만 하기'));
      await _settle(tester);
      expect(server.requests, contains('POST /suggestions/sug-1/approve'));
      expect(server.requests.where((r) => r.contains('approve-and-allow')), isEmpty);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('허용 내용이 서버와 달라지면(409) 실행 상태로 가지 않고 다시 확인하게 한다', (tester) async {
      _tall(tester);
      final server = _Server(allowReply: (409, {'detail': '허용할 내용이 바뀌었어요 — 다시 확인하고 승인해 주세요'}));
      await tester.pumpWidget(_cardApp(server));
      await _settle(tester);

      await tester.tap(find.text('다음부터도 자동으로'));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('auto-rule-allow')));
      await _settle(tester);
      expect(find.text(approvalChangedMessage), findsOneWidget);
      expect(find.text('상태 화면'), findsNothing);
    });

    testWidgets('서버가 허용 내용을 주지 않은 카드(물리 누름 등)에는 자동 버튼이 없다', (tester) async {
      _tall(tester);
      await tester.pumpWidget(_cardApp(_Server(offer: false)));
      await _settle(tester);

      expect(find.text('다음부터도 자동으로'), findsNothing);
      expect(find.text('지금 하기'), findsOneWidget);
    });
  });

  group('루틴 목록의 자동 실행', () {
    // UI 평가 7차 10/17: 조용한 시간과 겹치는 시각 규칙이 설정 화면에서만 경고됐다 — 규칙 카드에서도 말한다.
    for (final (enabled, line) in [
      (false, '조용한 시간(22:00~07:00)을 켜면 이 자동 실행은 건너뛰어요'),
      (true, '조용한 시간(22:00~07:00)이라 이 자동 실행은 건너뛰어요'),
    ]) {
      testWidgets('시각 규칙이 조용한 시간과 겹치면 규칙 카드에 한 줄(조용한 시간 ${enabled ? '켜짐' : '꺼짐'})', (tester) async {
        _tall(tester);
        final server = _Server()
          ..rule = {..._rule(), 'condition_kind': 'time', 'condition_time': '22:00', 'name': '저녁 공기청정기 켜기'}
          ..quiet = {'enabled': enabled, 'start': '22:00', 'end': '07:00', 'active': false};
        await tester.pumpWidget(_list(server));
        await _settle(tester);
        expect(findPlainText(line), findsOneWidget);
      });
    }

    testWidgets('겹치지 않는 시각(끝 시각 07:00)이면 규칙 카드에 조용한 시간 말이 없다', (tester) async {
      _tall(tester);
      final server = _Server()
        ..rule = {..._rule(), 'condition_kind': 'time', 'condition_time': '07:00'}
        ..quiet = {'enabled': true, 'start': '22:00', 'end': '07:00', 'active': false};
      await tester.pumpWidget(_list(server));
      await _settle(tester);
      expect(findPlainText('조용한 시간', contains: true), findsNothing);
    });

    testWidgets('자동 실행 켜짐과 조건·동작·마지막 결과를 보이고 끄면 꺼짐', (tester) async {
      _tall(tester);
      final server = _Server();
      await tester.pumpWidget(_list(server));
      await _settle(tester);

      expect(find.text('조리 완료 → 공기청정기'), findsOneWidget);
      // 규칙은 한 문장(2026-10-14 UX) — "조건:/동작:" 표가 아니다.
      expect(find.text('전자레인지가 멈추면 → 거실 공기청정기 풍량 강으로'), findsOneWidget);
      expect(find.textContaining('조건:'), findsNothing);
      // 값 바꾸기·지우기는 ⋮ 메뉴 안(2026-10-18 버튼 위계) — 카드에 버튼을 늘어놓지 않는다.
      expect(find.byKey(const Key('auto-rule-delete-ar-1')), findsNothing);
      await tester.tap(find.byKey(const Key('auto-rule-menu-ar-1')));
      await _settle(tester);
      expect(find.text('바람 세기 바꾸기'), findsOneWidget);
      expect(find.text('세기 바꾸기'), findsNothing);
      expect(find.byKey(const Key('auto-rule-delete-ar-1')), findsOneWidget);
      await tester.tapAt(const Offset(5, 5));
      await _settle(tester);
      expect(find.text('자동 실행 켜짐'), findsOneWidget);
      expect(find.textContaining('상태 재조회로 확인'), findsOneWidget);
      expect(find.textContaining('깨끗'), findsNothing);
      // 자동 실행 규칙과 루틴 목록을 머리말로 나눈다 — 같은 이름이 두 번 나와 헷갈렸다(외부 평가 10/16 3차).
      expect(find.text('자동으로 하기'), findsOneWidget);
      expect(find.text('내 루틴 목록'), findsOneWidget);

      await tester.tap(find.byKey(const Key('auto-rule-off-ar-1')));
      await _settle(tester);
      expect(server.bodies['POST /routines/auto-rules/ar-1/enable'], {'enabled': false});
      expect(find.text('자동 실행 꺼짐'), findsOneWidget);
      expect(find.text('직접 자동 실행을 껐어요.'), findsOneWidget);
    });

    testWidgets('다시 허용은 확인 시트를 거쳐 목록의 지문으로만 켠다', (tester) async {
      _tall(tester);
      final server = _Server()..rule = _rule(enabled: false, reason: '비상정지로 자동 실행을 껐어요');
      await tester.pumpWidget(_list(server));
      await _settle(tester);

      await tester.tap(find.byKey(const Key('auto-rule-on-ar-1')));
      await _settle(tester);
      expect(find.text('다음부터 자동으로 할까요?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('auto-rule-allow')));
      await _settle(tester);
      expect(server.bodies['POST /routines/auto-rules/ar-1/enable'],
          {'enabled': true, 'fingerprint': 'fp-rule-high'});
      expect(find.text('자동 실행 켜짐'), findsOneWidget);
    });

    testWidgets('설정값을 바꾸면 바뀐 내용으로 다시 허용을 묻는다', (tester) async {
      _tall(tester);
      final server = _Server();
      await tester.pumpWidget(_list(server));
      await _settle(tester);

      await tester.tap(find.byKey(const Key('auto-rule-menu-ar-1')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('auto-rule-edit-ar-1')));
      await _settle(tester);
      await tester.tap(find.text('중'));
      await _settle(tester);
      expect(server.bodies['PUT /routines/auto-rules/ar-1'], {'value': 'MID'});
      expect(find.text('무엇을: 거실 공기청정기 풍량 중으로'), findsWidgets);
      await tester.tap(find.byKey(const Key('auto-rule-allow')));
      await _settle(tester);
      expect(server.bodies['POST /routines/auto-rules/ar-1/enable'],
          {'enabled': true, 'fingerprint': 'fp-rule-MID'});
      expect(find.text('자동 실행 켜짐'), findsOneWidget);
    });
  });
}
