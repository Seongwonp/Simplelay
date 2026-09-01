// 보호자 알림함 — 목록 표시·읽음 처리·홈 배지 계약.
//
// 실패·위험소리·안부 신호가 키오스크에만 뜨면 보호자는 모른다. 이 화면과
// 홈의 종 배지가 그 소식을 폰으로 옮기는 경로다.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/providers/care_events_provider.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/care_events_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';

http.Response _json(Object body) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

RpiApiService _apiWith(List<Map<String, dynamic>> events) =>
    RpiApiService('http://rpi5.local:8000',
        client: MockClient((request) async {
      if (request.url.path == '/care-events') return _json(events);
      return _json([]);
    }));

const _sampleEvents = [
  {
    'id': 3,
    'kind': 'quiet_routine',
    'message': "평소 저녁 시간대의 '우유 데워줘' 사용이 오늘은 없었어요. 안부 전화 한번 어떨까요?",
    'purpose': '우유 데워줘',
    'occurred_at': '2026-09-01T21:05:00+09:00',
  },
  {
    'id': 2,
    'kind': 'danger_sound',
    'message': '위험할 수 있는 신호음이 감지되었어요. 안부를 확인해 주세요.',
    'purpose': null,
    'occurred_at': '2026-09-01T14:20:00+09:00',
  },
  {
    'id': 1,
    'kind': 'execution_failed',
    'message': "'우유 데워줘' 실행이 완료되지 못했어요. 가전을 확인해 주세요.",
    'purpose': '우유 데워줘',
    'occurred_at': '2026-09-01T09:00:00+09:00',
  },
];

// 컨테이너와 정리 함수를 함께 돌려준다 — 알림 프로바이더의 45초 폴링
// 타이머는 dispose로만 멈추는데, 위젯 테스트는 본문이 끝난 직후 남은
// 타이머를 검사하므로 각 테스트가 끝에서 직접 정리해야 한다.
typedef _Harness = (ProviderContainer, void Function());

Future<_Harness> _pump(
  WidgetTester tester,
  List<Map<String, dynamic>> events,
) async {
  final container = ProviderContainer(overrides: [
    rpiApiServiceProvider.overrideWithValue(_apiWith(events)),
  ]);
  var disposed = false;
  void disposeOnce() {
    if (disposed) return;
    disposed = true;
    container.dispose();
  }

  addTearDown(disposeOnce); // 단정 실패로 본문이 중단돼도 정리
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: CareEventsScreen()),
    ),
  );
  await tester.pump(); // _init: prefs + 첫 refresh
  await tester.pump();
  return (container, disposeOnce);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('알림을 종류 라벨과 함께 최신순으로 보여준다', (tester) async {
    final (_, dispose) = await _pump(tester, _sampleEvents);

    expect(find.text('안부 신호'), findsOneWidget);
    expect(find.text('위험 신호음'), findsOneWidget);
    expect(find.text('실행 실패'), findsOneWidget);
    expect(find.textContaining('안부 전화 한번 어떨까요'), findsOneWidget);

    // 최신(안부 신호)이 맨 위
    final quietY = tester.getTopLeft(find.text('안부 신호')).dy;
    final failY = tester.getTopLeft(find.text('실행 실패')).dy;
    expect(quietY, lessThan(failY));
    dispose();
  });

  testWidgets('알림이 없으면 빈 상태 안내를 보여준다', (tester) async {
    final (_, dispose) = await _pump(tester, const []);

    expect(find.text('아직 알림이 없어요'), findsOneWidget);
    dispose();
  });

  testWidgets('화면을 열면 전부 읽음 처리되어 배지 수가 0이 된다', (tester) async {
    final (container, dispose) = await _pump(tester, _sampleEvents);
    await tester.pump(); // postFrame markAllSeen 반영

    expect(container.read(careEventsProvider).unreadCount, 0);

    // 읽음 기준이 기기에 저장된다 — 재시작(새 컨테이너) 후에도 유지
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('care_events_last_seen_id'), 3);
    dispose();
  });

  test('안 읽은 개수는 마지막 읽음 id 이후의 이벤트 수다', () {
    final events = _sampleEvents
        .map((e) => RpiCareEvent.fromJson(e))
        .toList(growable: false);

    expect(
      CareEventsState(events: events, lastSeenId: 1).unreadCount,
      2, // id 2, 3
    );
    expect(
      CareEventsState(events: events, lastSeenId: 3).unreadCount,
      0,
    );
  });

  test('careEvents API가 목록을 파싱한다 (실패 시 빈 목록)', () async {
    final events = await _apiWith(_sampleEvents).careEvents();
    expect(events.length, 3);
    expect(events.first.kind, 'quiet_routine');
    expect(events.first.purpose, '우유 데워줘');

    final broken = RpiApiService('http://rpi5.local:8000',
        client: MockClient((_) async => http.Response('down', 500)));
    expect(await broken.careEvents(), isEmpty);
  });
}
