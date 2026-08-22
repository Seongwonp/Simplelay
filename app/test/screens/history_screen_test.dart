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
    expect(find.text('전원'), findsOneWidget);
    // 폐루프 회복 배지 — 이 화면의 존재 이유
    expect(find.text('재시도 2회 후 성공'), findsOneWidget);
    // 안전 정지 상태 표기
    expect(find.textContaining('안전 정지'), findsOneWidget);
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
