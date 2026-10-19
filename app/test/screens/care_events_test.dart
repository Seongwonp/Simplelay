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

RpiApiService _apiWith(
  List<Map<String, dynamic>> events, {
  Map<String, dynamic>? wellnessPause,
}) =>
    RpiApiService('http://rpi5.local:8000',
        client: MockClient((request) async {
      if (request.url.path == '/care-events') return _json(events);
      if (request.url.path == '/wellness-pause') {
        return _json(wellnessPause ?? {'paused': false, 'until': null});
      }
      return _json([]);
    }));

/// 알림 조회가 실패하는 서버.
RpiApiService _apiDown() =>
    RpiApiService('http://rpi5.local:8000',
        client: MockClient((request) async {
      if (request.url.path == '/care-events') {
        return http.Response('{"detail":"boom"}', 500);
      }
      return _json([]);
    }));

const _sampleEvents = [
  {
    'id': 3,
    'kind': 'quiet_routine',
    'message': "평소 저녁 시간대의 '즉석밥 데워줘' 사용이 오늘은 없었어요. 안부 전화 한번 어떨까요?",
    'purpose': '즉석밥 데워줘',
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
    'message': "'즉석밥 데워줘' 실행이 완료되지 못했어요. 가전을 확인해 주세요.",
    'purpose': '즉석밥 데워줘',
    'occurred_at': '2026-09-01T09:00:00+09:00',
  },
];

// 컨테이너와 정리 함수를 함께 돌려준다 — 알림 프로바이더의 45초 폴링
// 타이머는 dispose로만 멈추는데, 위젯 테스트는 본문이 끝난 직후 남은
// 타이머를 검사하므로 각 테스트가 끝에서 직접 정리해야 한다.
typedef _Harness = (ProviderContainer, void Function());

Future<_Harness> _pump(
  WidgetTester tester,
  List<Map<String, dynamic>> events, {
  RpiApiService? api,
}) async {
  final container = ProviderContainer(overrides: [
    rpiApiServiceProvider.overrideWithValue(api ?? _apiWith(events)),
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
    expect(find.text('위험 소리'), findsOneWidget);
    expect(find.text('못 한 일'), findsOneWidget);
    expect(find.textContaining('안부 전화 한번 어떨까요'), findsOneWidget);

    // 최신(안부 신호)이 맨 위
    final quietY = tester.getTopLeft(find.text('안부 신호')).dy;
    final failY = tester.getTopLeft(find.text('못 한 일')).dy;
    expect(quietY, lessThan(failY));
    dispose();
  });

  testWidgets('알림이 없으면 빈 상태 안내를 보여준다', (tester) async {
    final (_, dispose) = await _pump(tester, const []);

    expect(find.text('아직 알림이 없어요'), findsOneWidget);
    dispose();
  });

  testWidgets('조회에 실패하면 "알림이 없다"고 하지 않는다', (tester) async {
    // 이 알림함이 다루는 것은 실행 실패·위험 신호음·안부 신호다. 통신이
    // 끊겨 못 본 것을 "아무 일 없다"로 읽게 두면 기능의 이유가 무너진다.
    final (_, dispose) = await _pump(tester, const [], api: _apiDown());

    expect(find.text('알림을 불러오지 못했어요.'), findsOneWidget);
    expect(find.text('다시 불러오기'), findsOneWidget);
    expect(find.text('아직 알림이 없어요'), findsNothing);
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

  test('careEvents API가 목록을 파싱한다 (실패는 null — 0건과 구분)', () async {
    final events = await _apiWith(_sampleEvents).careEvents();
    expect(events, isNotNull);
    expect(events!.length, 3);
    expect(events.first.kind, 'quiet_routine');
    expect(events.first.purpose, '즉석밥 데워줘');

    // 실패를 빈 목록으로 표현하면 일시적 통신 실패가 "알림이 다 사라짐"
    // 으로 보인다 (교차 리뷰 #13)
    final broken = RpiApiService('http://rpi5.local:8000',
        client: MockClient((_) async => http.Response('down', 500)));
    expect(await broken.careEvents(), isNull);
  });

  testWidgets('통신 실패 폴링은 보고 있던 알림을 지우지 않는다', (tester) async {
    // 목록 3건을 보여준 뒤 서버가 죽는다 — 다음 새로고침이 실패해도
    // 알림과 배지는 유지되어야 한다 (교차 리뷰 #13)
    var failNow = false;
    final api = RpiApiService('http://rpi5.local:8000',
        client: MockClient((request) async {
      if (failNow) return http.Response('down', 500);
      if (request.url.path == '/care-events') return _json(_sampleEvents);
      return _json([]);
    }));
    final container = ProviderContainer(overrides: [
      rpiApiServiceProvider.overrideWithValue(api),
    ]);
    var disposed = false;
    void disposeOnce() {
      if (disposed) return;
      disposed = true;
      container.dispose();
    }

    addTearDown(disposeOnce);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: CareEventsScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(container.read(careEventsProvider).events.length, 3);

    failNow = true;
    await container.read(careEventsProvider.notifier).refresh();
    await tester.pump();

    expect(container.read(careEventsProvider).events.length, 3); // 유지
    disposeOnce();
  });

  testWidgets('안부 확인을 쉬는 중이면 알림함이 그 사실을 말한다', (tester) async {
    // 말하지 않으면 조용한 알림함이 "정말 아무 일 없었다"로 읽히는데,
    // 사실은 보호자가 직접 꺼둔 것이다 -- 통신이 끊겼을 때와 같은 오해이고,
    // 이 알림함이 없애려던 바로 그 오해다.
    final (_, dispose) = await _pump(
      tester,
      const [],
      api: _apiWith(
        const [],
        wellnessPause: {'paused': true, 'until': '2026-07-30'},
      ),
    );
    await tester.pump(); // postFrame의 일시 중지 조회 반영

    expect(
      find.textContaining('7월 30일까지 안부 확인을 쉬고 있어요'),
      findsOneWidget,
    );
    // 쉬어도 꺼지지 않는 것을 같이 말한다.
    expect(find.textContaining('실패나 위험 신호음은 그대로'), findsOneWidget);
    dispose();
  });

  testWidgets('쉬지 않을 때는 알림함에 그 배너가 없다', (tester) async {
    final (_, dispose) = await _pump(tester, const []);
    await tester.pump();

    expect(find.textContaining('안부 확인을 쉬고 있어요'), findsNothing);
    dispose();
  });

  testWidgets('이미 끝난 일시 중지를 "쉬는 중"으로 표시하지 않는다', (tester) async {
    // 서버가 paused=false로 답했는데 날짜만 보고 판단하면, 화면은
    // "7월 23일까지 쉬어요"라고 말하는데 서버는 이미 안부 신호를 다시
    // 보내고 있는 상태가 된다.
    final (_, dispose) = await _pump(
      tester,
      const [],
      api: _apiWith(
        const [],
        wellnessPause: {'paused': false, 'until': '2026-07-23'},
      ),
    );
    await tester.pump();

    expect(find.textContaining('안부 확인을 쉬고 있어요'), findsNothing);
    dispose();
  });
}
