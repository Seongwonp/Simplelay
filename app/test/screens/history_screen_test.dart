import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/history_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';

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

void main() {
  testWidgets('이력이 없으면 안내 문구를 보여준다', (tester) async {
    await tester.pumpWidget(_build(_apiWithHistory(const [])));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('아직 실행 기록이 없어요'), findsOneWidget);
  });

  testWidgets('이력 항목과 재시도 회복 배지를 보여준다', (tester) async {
    final api = _apiWithHistory([
      {
        'job_id': 'job-1',
        'finished_at': '2026-08-23T19:30:00+09:00',
        'purpose': '우유 데워줘',
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

    // 목적 있는 실행은 목적으로, 없는 실행은 버튼 라벨로 표시
    expect(find.text('우유 데워줘'), findsOneWidget);
    // 끝이 안 좋았던 실행은 제목과 단계 목록 두 곳에 버튼이 나온다
    expect(find.text('전원'), findsNWidgets(2));
    // 폐루프 회복 배지 — 이 화면의 존재 이유
    expect(find.text('재시도 2회 후 성공'), findsOneWidget);
    // 안전 정지 상태 표기
    expect(find.textContaining('안전 정지'), findsOneWidget);
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

    // 실패한 쪽만 단계를 펼친다 -- 성공한 이력까지 늘어놓으면 목록이
    // 다시 개발 도구처럼 보인다.
    expect(find.text('2번 만에 확인'), findsOneWidget);
    expect(find.text('확인 못 함'), findsOneWidget);
    expect(find.text('버튼으로 직접 조작'), findsOneWidget);
    // 성공한 실행은 그대로 한 줄이다
    expect(find.text('확인됨'), findsNothing);
  });

  testWidgets('서버 오류 시 사용자 언어 안내를 보여준다', (tester) async {
    final client = MockClient(
        (_) async => http.Response('{"detail": "boom"}', 500));
    final api = RpiApiService('http://rpi5.local:8000', client: client);
    await tester.pumpWidget(_build(api));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('기록을 불러오지 못했어요'), findsOneWidget);
  });
}
