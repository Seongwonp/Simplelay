import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simplelay/providers/clock_provider.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/history_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';
import 'package:simplelay/theme/app_icons.dart';

import '../helpers/test_helpers.dart';

RpiApiService _apiWithHistory(List<Map<String, dynamic>> entries) {
  final client = MockClient((request) async {
    return http.Response.bytes(
      utf8.encode(jsonEncode(entries)),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  });
  return RpiApiService('http://rpi5.local:8000', client: client);
}

Widget _build(RpiApiService api) => ProviderScope(
      overrides: [rpiApiServiceProvider.overrideWithValue(api)],
      child: const MaterialApp(home: HistoryScreen()),
    );

/// 기록 행은 두 줄만 보이고 결과 문장·다음 할 일은 눌러서 펼친다(2026-10-18) — 모두 펼친다.
Future<void> _expandAll(WidgetTester tester) async {
  final rows = find.byWidgetPredicate(
      (w) => w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith('history-tap-'));
  for (final e in rows.evaluate().toList()) {
    await tester.tap(find.byKey(e.widget.key!));
    await tester.pump();
  }
}

void main() {
  testWidgets('이력이 없으면 안내 문구를 보여준다', (tester) async {
    await tester.pumpWidget(_build(_apiWithHistory(const [])));
    await tester.pump();
    await tester.pump();

    expect(findPlainText('아직 기록이 없어요', contains: true), findsOneWidget);
  });

  testWidgets('이력 항목과 재시도 회복 배지를 보여준다', (tester) async {
    final api = _apiWithHistory([
      {
        'job_id': 'job-1',
        'finished_at': '2026-08-23T19:30:00+09:00',
        'purpose': '즉석밥 데워줘',
        'status': 'succeeded',
        'retry_count': 2,
        'buttons': [
          {'button': '해동', 'success': true, 'attempts': 3},
          {'button': '시작', 'success': true, 'attempts': 1},
        ],
      },
      {
        'job_id': 'job-2',
        'finished_at': '2026-08-23T18:00:00+09:00',
        'purpose': null,
        'status': 'safety_stopped',
        'retry_count': 0,
        'buttons': [
          {'button': '전원', 'success': false, 'attempts': 3},
        ],
      },
    ]);
    await tester.pumpWidget(_build(api));
    await tester.pump();
    await tester.pump();
    await _expandAll(tester);

    // 목적 있는 실행은 목적으로, 없는 실행은 버튼 라벨 + '버튼 누르기'으로 표시
    expect(findPlainText('즉석밥 데우기'), findsOneWidget);
    expect(findPlainText('전원 버튼 누르기'), findsOneWidget);
    // 끝이 안 좋았던 실행은 단계 목록에 버튼이 나온다
    expect(findPlainText('전원'), findsOneWidget);
    // 폐루프 회복 배지 — 이 화면의 존재 이유
    // '됐어요'이라 말하지 않는다 — 다시 누른 사실만(UI 평가 5차 10/17: '확인 못 함'과 모순처럼 읽혔다).
    expect(findPlainText('2번 더 눌러 마쳤어요'), findsOneWidget);
    expect(findPlainText('후 성공', contains: true), findsNothing);
    // 안전 정지 상태 표기
    expect(findPlainText('스스로 멈췄어요', contains: true), findsOneWidget);
  });

  testWidgets('서버가 센 재시도 1회(버튼 attempts 2)를 배지로 그대로 보여준다',
      (tester) async {
    // G1(2026-09-29) 이후 서버가 성공한 실행에서도 재시도를 센다.
    // 시뮬레이터 실측과 같은 모양: 즉석밥 2회 시도 → retry_count 1.
    final api = _apiWithHistory([
      {
        'job_id': 'job-g1',
        'finished_at': '2026-08-23T19:30:00+09:00',
        'purpose': '즉석밥 데워줘',
        'status': 'succeeded',
        'outcome': 'success',
        'execution_mode': 'mock',
        'route': 'physical',
        'retry_count': 1,
        'buttons': [
          {'button': '즉석밥', 'success': true, 'attempts': 2},
          {'button': '시작', 'success': true, 'attempts': 1},
        ],
      },
    ]);
    await tester.pumpWidget(_build(api));
    await tester.pump();
    await tester.pump();
    await _expandAll(tester);

    expect(findPlainText('1번 더 눌러 마쳤어요'), findsOneWidget);
  });

  testWidgets('모의 실행 기록은 버튼 조작을 마쳤다·누름 장치가 응답했다고 말하지 않는다',
      (tester) async {
    // 10/6 S11: "모의 실행 · 03:06 · 버튼 조작을 마쳤어요"는 실제 조작으로 읽혔다.
    final api = _apiWithHistory([
      {
        'job_id': 'job-mock',
        'finished_at': '2026-08-23T19:30:00+09:00',
        'purpose': '아침 데우기',
        'status': 'succeeded',
        'outcome': 'success',
        'execution_mode': 'mock',
        'route': 'physical',
        'receipt': 'accepted',
        'confirmation': 'reported',
        'retry_count': 0,
        'buttons': [
          {'button': '즉석밥', 'success': true, 'attempts': 1},
        ],
      },
    ]);
    await tester.pumpWidget(_build(api));
    await tester.pump();
    await tester.pump();
    await _expandAll(tester);

    // 모의 여부는 사람 말로 한 줄 — mock 기록에만, 한 번만(2026-10-14 UX).
    expect(findPlainText('연습이라 실제로 누르지 않았어요'), findsOneWidget);
    expect(findPlainText('모의 버튼 누르기', contains: true), findsNothing);
    expect(findPlainText('받았어요', contains: true), findsNothing);
    // 시스템 용어를 앞에 내지 않는다(2026-10-13).
    expect(findPlainText('모의 실행기 응답', contains: true), findsNothing);
    expect(findPlainText('물리 버튼', contains: true), findsNothing);
    // 모의 성공에는 실제 가전 확인을 부탁하지 않는다.
    expect(findPlainText('직접 확인해 주세요', contains: true), findsNothing);
    // 연습 성공에 성공 체크를 붙이지 않는다 — 실제로 한 일이 아니다(외부 평가 10/16 p03).
    expect(find.byIcon(Icons.check_circle), findsNothing);
    expect(find.byIcon(Icons.science_outlined), findsOneWidget);
  });

  testWidgets('끝이 안 좋았던 실행만 어디서 멈췄는지와 다음 할 일을 보여준다',
      (tester) async {
    // 실패 기록에는 버튼별 확인 결과가 이미 들어 있는데 화면이 버리고 있었다.
    // 가전 앞에서 무엇을 이어서 해야 하는지가 여기서 갈린다.
    final api = _apiWithHistory([
      {
        'job_id': 'job-ok',
        'finished_at': '2026-08-23T19:30:00+09:00',
        'purpose': '즉석밥 데워줘',
        'status': 'succeeded',
        'retry_count': 0,
        'buttons': [
          {'button': '즉석밥', 'success': true, 'attempts': 1},
        ],
      },
      {
        'job_id': 'job-bad',
        'finished_at': '2026-08-23T18:00:00+09:00',
        'purpose': '에어컨 켜줘',
        'status': 'failed',
        'retry_count': 3,
        'buttons': [
          {'button': '전원', 'success': true, 'attempts': 2},
          {'button': '냉방', 'success': false, 'attempts': 3},
        ],
      },
    ]);
    await tester.pumpWidget(_build(api));
    await tester.pump();
    await tester.pump();
    await _expandAll(tester);

    // 실패한 쪽만 단계를 펼친다 -- 성공한 이력까지 늘어놓으면 목록이
    // 다시 개발 도구처럼 보인다.
    expect(findPlainText('2번 만에 눌렸어요'), findsOneWidget);
    expect(findPlainText('눌렸는지 몰라요'), findsOneWidget);
    expect(findPlainText('버튼판에서 직접 누르기'), findsOneWidget);
    // 성공한 실행은 그대로 한 줄이다
    expect(findPlainText('눌렸어요'), findsNothing);
  });

  testWidgets('날짜는 구획 제목으로만 쓰고, 한 건은 무엇·결과가 먼저다', (tester) async {
    final api = _apiWithHistory([
      {
        'job_id': 'job-a',
        'finished_at': '2026-09-09T08:10:00+09:00',
        'purpose': '즉석밥 데워줘',
        'status': 'succeeded',
        'retry_count': 0,
        'buttons': [
          {'button': '즉석밥', 'success': true, 'attempts': 1},
        ],
      },
      {
        'job_id': 'job-b',
        'finished_at': '2026-09-08T19:00:00+09:00',
        'purpose': '즉석밥 데워줘',
        'status': 'succeeded',
        'retry_count': 0,
        'buttons': [
          {'button': '시작', 'success': true, 'attempts': 1},
        ],
      },
      {
        'job_id': 'job-c',
        'finished_at': '2026-09-06T12:00:00+09:00',
        'purpose': '해동',
        'status': 'succeeded',
        'retry_count': 0,
        'buttons': [
          {'button': '해동', 'success': true, 'attempts': 1},
        ],
      },
    ]);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        rpiApiServiceProvider.overrideWithValue(api),
        // 골든과 같은 이유: '오늘'이 실행 시각을 타면 어제 만든 테스트가
        // 오늘 깨진다.
        nowProvider.overrideWithValue(() => DateTime(2026, 9, 9, 9)),
      ],
      child: const MaterialApp(home: HistoryScreen()),
    ));
    await tester.pump();
    await tester.pump();
    await _expandAll(tester);

    expect(findPlainText('오늘'), findsOneWidget);
    expect(findPlainText('어제'), findsOneWidget);
    expect(findPlainText('9월 6일'), findsOneWidget);
    // 결과는 문장으로. 시각은 구획 안에서 시:분만, 따로 한 줄. '봐 주세요' 줄은 그 까닭 한 줄로(평가 10차 10/18).
    expect(findPlainText('버튼은 다 눌렀어요, 움직이는지 봐 주세요'), findsNWidgets(3));
    // 동작을 확인하지 못한 물리 기록은 성공 체크가 아니라 중립 아이콘(UI 평가 5차 10/17 — 체크 바로 아래
    // '확인하지 못했어요'가 와서 신호가 섞였다).
    expect(find.byIcon(Icons.check_circle), findsNothing);
    expect(find.byIcon(Icons.help_outline), findsNWidgets(3));
    expect(findPlainText('오전 8:10 · 바로 실행'), findsOneWidget);
    expect(findPlainText('실행 환경 미확인', contains: true), findsNothing);
    // 카드로 감싸지 않는다.
    expect(find.byType(Card), findsNothing);
    // 보고만 받은 버튼 기록은 '봐 주세요' — 초록 '됐어요'가 아니다(확인 수준을 높여 보이지 않는다, 평가 5차 10/18 배지 넷).
    expect(findPlainText('봐 주세요'), findsNWidgets(3));
    expect(findPlainText('됐어요'), findsNothing);
  });

  testWidgets('사용자가 멈춘 것과 안전 정지를 종료 사유가 있을 때만 나눈다',
      (tester) async {
    final api = _apiWithHistory([
      {
        'job_id': 'job-u',
        'finished_at': '2026-09-09T08:10:00+09:00',
        'purpose': '냉동식품',
        'status': 'safety_stopped',
        'retry_count': 0,
        'termination': 'stopped_by_user',
        'buttons': [
          {'button': '냉동식품', 'success': false, 'attempts': 1},
        ],
      },
      {
        'job_id': 'job-x',
        'finished_at': '2026-09-09T08:00:00+09:00',
        'purpose': '라면',
        'status': 'failed',
        'retry_count': 3,
        'termination': 'retries_exhausted',
        'buttons': [
          {'button': '라면', 'success': false, 'attempts': 3},
        ],
      },
    ]);
    await tester.pumpWidget(_build(api));
    await tester.pump();
    await tester.pump();
    await _expandAll(tester);

    expect(findPlainText('직접 멈췄어요', contains: true), findsOneWidget);
    expect(findPlainText('다시 눌러도 눌렸는지 몰라요', contains: true), findsOneWidget);
  });

  testWidgets('어느 가전이었는지 알 때만 말한다', (tester) async {
    final api = _apiWithHistory([
      {
        'job_id': 'job-k',
        'finished_at': '2026-09-09T08:10:00+09:00',
        'purpose': '즉석밥 데워줘',
        'status': 'succeeded',
        'retry_count': 0,
        'appliance_id': 'microwave',
        'buttons': [
          {'button': '즉석밥', 'success': true, 'attempts': 1},
        ],
      },
      {
        'job_id': 'job-old',
        'finished_at': '2026-09-09T07:00:00+09:00',
        'purpose': '옛 기록',
        'status': 'succeeded',
        'retry_count': 0,
        'buttons': [
          {'button': '시작', 'success': true, 'attempts': 1},
        ],
      },
    ]);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        rpiApiServiceProvider.overrideWithValue(api),
        ...installedOverrides([kTestAppliance]),
      ],
      child: const MaterialApp(home: HistoryScreen()),
    ));
    await tester.pump();
    await tester.pump();

    expect(findPlainText('· 전자레인지', contains: true), findsOneWidget);
  });

  testWidgets('기록은 실행할 때의 가전 이름을 쓴다 — 지금 이름·모드로 바꾸지 않는다(2026-10-16 결함 ②)',
      (tester) async {
    final api = _apiWithHistory([
      {
        'job_id': 'job-then',
        'finished_at': '2026-09-09T08:10:00+09:00',
        'purpose': '데워줘',
        'status': 'succeeded',
        'retry_count': 0,
        'appliance_id': 'microwave',
        'appliance_name': '주방 전자레인지',
        'buttons': [
          {'button': '시작', 'success': true, 'attempts': 1},
        ],
      },
    ]);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        rpiApiServiceProvider.overrideWithValue(api),
        ...installedOverrides([kTestAppliance]),
      ],
      child: const MaterialApp(home: HistoryScreen()),
    ));
    await tester.pump();
    await tester.pump();

    expect(findPlainText('· 주방 전자레인지', contains: true), findsOneWidget);
    expect(findPlainText('· 전자레인지', contains: true), findsNothing);
  });

  testWidgets('제목은 한 일, 출처(자동 실행·루틴)는 시각 줄에(외부 평가 10/16 2차 p03)', (tester) async {
    final api = _apiWithHistory([
      {
        'job_id': 'job-auto',
        'finished_at': '2026-09-09T22:00:00+09:00',
        'purpose': '자동 실행 · 공기청정기 전원 켜기',
        'status': 'succeeded',
        'retry_count': 0,
        'appliance_id': 'air_purifier',
        'appliance_name': '공기청정기',
        'route': 'thinq',
        'buttons': [],
      },
    ]);
    await tester.pumpWidget(_build(api));
    await tester.pump();
    await tester.pump();

    expect(findPlainText('공기청정기 켜기'), findsOneWidget);
    expect(findPlainText('오후 10:00 · 자동', contains: true), findsOneWidget);
    expect(findPlainText('자동 실행 · 공기청정기', contains: true), findsNothing);
  });

  testWidgets('탭 제목은 홈(우리 집)과 같은 굵은 큰 제목(UI 평가 10/17)', (tester) async {
    await tester.pumpWidget(_build(_apiWithHistory(const [])));
    await tester.pump();
    final title = tester.widget<Text>(findPlainText('기록'));
    expect(title.style?.fontWeight, FontWeight.w700);
    expect(title.style?.fontSize, 24);
  });

  testWidgets('이미 목표값 기록은 한 번만 말하고 "됐어요"와 같은 ✓(UI 평가 10/17, 평가 6차 10/18 기호 하나)', (tester) async {
    final api = _apiWithHistory([
      {
        'job_id': 'job-same',
        'finished_at': '2026-09-09T21:51:00+09:00',
        'purpose': "'저녁 공기청정기 켜기' 루틴을 실행할까요?",
        'status': 'succeeded',
        'retry_count': 0,
        'appliance_id': 'air_purifier',
        'route': 'thinq',
        'execution_mode': 'real',
        'receipt': 'not_dispatched',
        'confirmation': 'already_at_target',
        'dispatch': 'state_only',
        'buttons': [],
      },
    ]);
    await tester.pumpWidget(_build(api));
    await tester.pump();
    await tester.pump();
    await _expandAll(tester);

    expect(findPlainText('이미 그 설정이라', contains: true), findsOneWidget);
    // 평가 6차(10/18): '됐어요'는 기호도 하나 — ✓와 ⓘ를 섞지 않는다. 보내지 않았다는 차이는 펼친 문장이 말한다.
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(find.byIcon(Icons.info_outline), findsNothing);
  });

  // ── 2026-10-13 B안: 읽는 순서·제목·다음 행동 ─────────────────────────────

  Future<void> pumpWith(WidgetTester tester, List<Map<String, dynamic>> entries,
      {bool expand = true}) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        rpiApiServiceProvider.overrideWithValue(_apiWithHistory(entries)),
        ...installedOverrides([kTestAppliance]),
        nowProvider.overrideWithValue(() => DateTime(2026, 9, 9, 9)),
      ],
      child: const MaterialApp(home: HistoryScreen()),
    ));
    await tester.pump();
    await tester.pump();
    if (expand) await _expandAll(tester);
  }

  testWidgets('한 건의 시각적 배치 순서: 날짜 → 제목 → 시각 → (펼침) 결과 → 모의 여부 → 직접 누르기',
      (tester) async {
    await pumpWith(tester, [
      {
        'job_id': 'job-o',
        'finished_at': '2026-09-09T08:10:00+09:00',
        'purpose': '아침 데우기',
        'status': 'failed',
        'outcome': 'failed',
        'execution_mode': 'mock',
        'route': 'physical',
        'termination': 'retries_exhausted',
        'retry_count': 3,
        'appliance_id': 'microwave',
        'buttons': [
          {'button': '즉석밥', 'success': false, 'attempts': 3},
        ],
      },
    ]);
    double y(Finder f) => tester.getTopLeft(f).dy;
    final order = [
      findPlainText('오늘'),
      findPlainText('아침 데우기'),
      findPlainText('오전 8:10 · 바로 실행 · 전자레인지'),
      findPlainText('다시 눌러도 눌렸는지 몰라요'),
      findPlainText('연습이라 실제로 누르지 않았어요'),
      findPlainText('버튼판에서 직접 누르기'),
    ];
    for (final f in order) {
      expect(f, findsOneWidget);
    }
    // 모의 기록에는 다음 행동 줄이 없다 — 연습은 한 줄로만 말한다(2026-10-14 UX).
    expect(findPlainText('연습 결과를 확인해 주세요'), findsNothing);
    for (var i = 1; i < order.length; i++) {
      expect(y(order[i]), greaterThan(y(order[i - 1])), reason: '순서 $i');
    }
  });

  testWidgets('목적이 없으면 등록 이름 + 버튼 라벨, 빈 목적도 같다 — 목적을 지어내지 않는다',
      (tester) async {
    await pumpWith(tester, [
      {
        'job_id': 'job-e',
        'finished_at': '2026-09-09T08:10:00+09:00',
        'purpose': '',
        'status': 'succeeded',
        'outcome': 'success',
        'execution_mode': 'real',
        'route': 'physical',
        'confirmation': 'reported',
        'retry_count': 0,
        'appliance_id': 'microwave',
        'buttons': [
          {'button': '즉석밥', 'success': true, 'attempts': 1},
        ],
      },
      {
        'job_id': 'job-n',
        'finished_at': '2026-09-09T08:00:00+09:00',
        'status': 'succeeded',
        'retry_count': 0,
        'buttons': [],
      },
    ]);
    expect(findPlainText('전자레인지 즉석밥 버튼 누르기'), findsOneWidget);
    // 제목이 이미 이름을 말하면 시각 줄에서 되풀이하지 않는다. 목적 없는 실행은 수동 조작 화면에서 고른 것(평가 13차).
    expect(findPlainText('오전 8:10 · 화면에서 골라 누름'), findsOneWidget);
    expect(findPlainText('버튼은 다 눌렀어요, 움직이는지 봐 주세요'), findsNWidgets(2)); // 평가 12차: 볼 것은 이 한 줄이 함께 말한다
    expect(findPlainText('버튼 누르기'), findsOneWidget);
  });

  // 평가 14차(10/18): 연달아 같은 일·같은 결과는 한 줄로 묶는다 — 회차(jobId)는 펼치면 하나씩 남는다.
  testWidgets('jobId가 다른 같은 일·같은 결과는 한 줄에 묶이고 펼치면 회차마다', (tester) async {
    Map<String, dynamic> e(String id) => {
          'job_id': id,
          'finished_at': '2026-09-09T08:10:00+09:00',
          'purpose': '즉석밥 데워줘',
          'status': 'succeeded',
          'retry_count': 0,
          'buttons': [],
        };
    await pumpWith(tester, [e('job-1'), e('job-2')]);
    expect(findPlainText('즉석밥 데우기'), findsOneWidget);
    expect(find.byKey(const ValueKey('history-job-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('history-job-2')), findsNothing);
    expect(findPlainText('2번 봐 주세요'), findsOneWidget);
    expect(find.byKey(const Key('history-sub-job-1')), findsOneWidget);
    expect(find.byKey(const Key('history-sub-job-2')), findsOneWidget);
  });

  testWidgets('서버 오류 시 사용자 언어 안내를 보여준다', (tester) async {
    final client = MockClient(
        (_) async => http.Response('{"detail": "boom"}', 500));
    final api = RpiApiService('http://rpi5.local:8000', client: client);
    await tester.pumpWidget(_build(api));
    await tester.pump();
    await tester.pump();

    expect(findPlainText('기록을 불러오지 못했어요', contains: true), findsOneWidget);
  });

  testWidgets('모션 장치가 걸려 멈춘 단계는 "누르지 않았어요" — "확인 못 함"이 아니다(2026-10-14)',
      (tester) async {
    await pumpWith(tester, [
      {
        'job_id': 'job-stall',
        'finished_at': '2026-09-09T08:10:00+09:00',
        'purpose': '아침 데우기',
        'status': 'safety_stopped',
        'outcome': 'safety_stop',
        'abort_reason': 'motion_alarm: stall',
        'execution_mode': 'real',
        'route': 'physical',
        'retry_count': 0,
        'buttons': [
          {'button': '즉석밥', 'success': true, 'attempts': 1},
          {'button': '시작', 'success': false, 'attempts': 1},
        ],
      },
    ]);
    expect(findPlainText('누르지 않았어요'), findsOneWidget);
    expect(findPlainText('눌렸는지 몰라요'), findsNothing);
    expect(findPlainText('눌렸어요'), findsOneWidget);
  });

  // ── 2026-10-18 기록 행 두 줄 · 출처 아이콘 · 결과 배지 ─────────────────────────────

  testWidgets('행은 두 줄 — 왼쪽 출처 아이콘(손·루틴·자동), 오른쪽 결과 배지, 결과 문장은 눌러야 펼친다', (tester) async {
    await pumpWith(tester, [
      {
        'job_id': 'j-auto',
        'finished_at': '2026-09-09T08:30:00+09:00',
        'purpose': '자동 실행 · 공기청정기 전원 켜기',
        'status': 'succeeded',
        'outcome': 'success',
        'execution_mode': 'real',
        'route': 'thinq',
        'receipt': 'accepted',
        'confirmation': 'state_confirmed',
        'retry_count': 0,
        'appliance_id': 'air_purifier',
        'appliance_name': '공기청정기',
        'buttons': [],
      },
      {
        'job_id': 'j-routine',
        'finished_at': '2026-09-09T08:20:00+09:00',
        'purpose': "'아침 데우기' 루틴",
        'status': 'failed',
        'outcome': 'failed',
        'execution_mode': 'real',
        'route': 'physical',
        'termination': 'retries_exhausted',
        'retry_count': 3,
        'appliance_id': 'microwave',
        'buttons': [
          {'button': '시작', 'success': false, 'attempts': 3},
        ],
      },
      {
        'job_id': 'j-hand',
        'finished_at': '2026-09-09T08:10:00+09:00',
        'purpose': '즉석밥 데워줘',
        'status': 'succeeded',
        'outcome': 'success',
        'execution_mode': 'real',
        'route': 'physical',
        'confirmation': 'reported',
        'retry_count': 0,
        'appliance_id': 'microwave',
        'buttons': [
          {'button': '즉석밥', 'success': true, 'attempts': 1},
        ],
      },
    ], expand: false);

    // LG 가전 자동 실행은 자동 아이콘 대신 가전 아이콘(평가 13차 10/18 — eval13_phone_test 2).
    expect(find.byIcon(AppIcons.auto), findsNothing);
    expect(findPlainText('오전 8:30 · 자동 · LG 가전'), findsOneWidget);
    expect(find.byIcon(AppIcons.routine), findsOneWidget);
    expect(find.byIcon(AppIcons.manual), findsOneWidget);
    // 상태를 다시 읽어 확인한 것만 초록 '됐어요' — 무엇을 확인했는지 짧게('켜짐 확인', 평가 14차 10/18).
    expect(findPlainText('켜짐 확인'), findsOneWidget);
    expect(findPlainText('못 했어요'), findsOneWidget);
    expect(findPlainText('봐 주세요'), findsOneWidget);
    // 배지는 행 오른쪽.
    expect(tester.getCenter(findPlainText('켜짐 확인')).dx,
        greaterThan(tester.getCenter(findPlainText('공기청정기 켜기')).dx));
    // 결과 문장·버튼판 길은 접혀 있다.
    expect(findPlainText('버튼판에서 직접 누르기'), findsNothing);
    await tester.tap(find.byKey(const Key('history-tap-j-routine')));
    await tester.pump();
    expect(findPlainText('버튼판에서 직접 누르기'), findsOneWidget);
  });

  testWidgets('연습·실제 모를 기록은 됐어요가 아니다 — 확인 수준을 높여 보이지 않는다', (tester) async {
    await pumpWith(tester, [
      {
        'job_id': 'j-mock',
        'finished_at': '2026-09-09T08:30:00+09:00',
        'purpose': '공기청정기 전원 켜기',
        'status': 'succeeded',
        'outcome': 'success',
        'execution_mode': 'mock',
        'route': 'thinq',
        'confirmation': 'state_confirmed',
        'retry_count': 0,
        'buttons': [],
      },
      {
        'job_id': 'j-old',
        'finished_at': '2026-09-09T08:20:00+09:00',
        'purpose': '즉석밥 데워줘',
        'status': 'succeeded',
        'confirmation': 'operation_confirmed',
        'retry_count': 0,
        'buttons': [],
      },
    ], expand: false);
    expect(findPlainText('됐어요'), findsNothing);
    expect(findPlainText('연습'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsNothing);
  });

  testWidgets('눌렸는지 모르는 일은 날짜 머리에 한 번 — 행마다 되풀이하지 않는다', (tester) async {
    Map<String, dynamic> unknown(String id, String at) => {
          'job_id': id,
          'finished_at': at,
          'purpose': '즉석밥 데워줘',
          'status': 'succeeded',
          'outcome': 'unconfirmed',
          'execution_mode': 'real',
          'route': 'physical',
          'confirmation': 'none',
          'retry_count': 0,
          'buttons': [
            {'button': '즉석밥', 'success': false, 'attempts': 1},
          ],
        };
    await pumpWith(tester, [
      unknown('u1', '2026-09-09T08:30:00+09:00'),
      unknown('u2', '2026-09-09T08:20:00+09:00'),
      unknown('u3', '2026-09-08T08:20:00+09:00'),
    ], expand: false);
    expect(findPlainText('눌렸는지 모르는 일 2건. 가전을 봐 주세요'), findsOneWidget);
    expect(findPlainText('눌렸는지 모르는 일 1건. 가전을 봐 주세요'), findsOneWidget);
    // 같은 날 연달아 같은 일·같은 결과(u1·u2)는 한 줄 '2번 봐 주세요'(평가 14차 10/18).
    expect(findPlainText('2번 봐 주세요'), findsOneWidget);
    expect(findPlainText('봐 주세요'), findsOneWidget);
    // 머리는 그 날짜 제목 바로 아래.
    expect(tester.getTopLeft(findPlainText('눌렸는지 모르는 일 2건. 가전을 봐 주세요')).dy,
        greaterThan(tester.getTopLeft(findPlainText('오늘')).dy));
    expect(tester.getTopLeft(findPlainText('눌렸는지 모르는 일 2건. 가전을 봐 주세요')).dy,
        lessThan(tester.getTopLeft(find.byKey(const Key('history-tap-u1'))).dy));
  });
}
