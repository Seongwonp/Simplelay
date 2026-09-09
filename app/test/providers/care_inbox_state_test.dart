/// R4 — 알림함의 '못 불러왔다'와 '없다'를 구분한다.
///
/// 목록을 한 번도 못 받은 화면이 **"아직 알림이 없어요"** 라고 단언했다.
/// 이 알림함이 다루는 것은 실행 실패·위험 신호음·안부 신호다 — 통신이
/// 끊겨서 못 본 것을 "아무 일 없다"로 읽으면, 이 기능이 존재하는 이유가
/// 그대로 무너진다.
///
/// 함께 고정하는 것:
///   - 실패해도 **보고 있던 목록은 유지**하고 다시 시도할 수 있어야 한다.
///   - 겹쳐 부른 새로고침은 **진행 중인 요청의 완료를 기다린다.** 기다리지
///     않으면 읽음 처리가 아직 비어 있는 목록 위에서 돌아 아무것도 안 된다.
///   - 서버 DB가 새로 만들어져 id가 1부터 다시 시작하면, 예전 lastSeenId가
///     새 알림들을 **영구히 읽음으로** 만들어버린다.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/providers/care_events_provider.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';

class _FakeInbox {
  List<Map<String, dynamic>> events = [];
  bool down = false;
  int calls = 0;

  /// 응답을 붙잡아 둔다 — 겹쳐 부른 새로고침의 순서를 검증하기 위해.
  Completer<void>? gate;

  http.Client client() => MockClient((request) async {
        if (request.url.path != '/care-events') return _json([]);
        calls++;
        if (gate != null) await gate!.future;
        if (down) return http.Response('{"detail":"boom"}', 500);
        return _json(events);
      });
}

Map<String, dynamic> _event(int id) => {
      'id': id,
      'kind': 'execution_failed',
      'message': '실행에 실패했어요 ($id)',
      'occurred_at': '2026-09-09T19:00:00+09:00',
    };

http.Response _json(Object body) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

Future<ProviderContainer> _phone(
  _FakeInbox inbox, {
  Map<String, Object> prefs = const {},
}) async {
  SharedPreferences.setMockInitialValues({
    'rpi_base_url': 'http://rpi5.local:8000',
    ...prefs,
  });
  final container = ProviderContainer(
    overrides: [rpiHttpClientProvider.overrideWithValue(inbox.client())],
  );
  addTearDown(container.dispose);
  container.read(rpiUrlProvider);
  await Future<void>.delayed(Duration.zero);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('못 불러온 것과 없는 것', () {
    test('조회에 실패하면 실패로 남는다 — 빈 목록이라고 하지 않는다', () async {
      final inbox = _FakeInbox()..down = true;
      final container = await _phone(inbox);

      await container.read(careEventsProvider.notifier).refresh();

      final state = container.read(careEventsProvider);
      expect(state.status, CareInboxStatus.failed);
      expect(state.events, isEmpty);
      expect(state.lastLoadedAt, isNull, reason: '한 번도 성공하지 못했다');
    });

    test('실제로 0건이면 성공이고, 확인 시각이 남는다', () async {
      final inbox = _FakeInbox();
      final container = await _phone(inbox);

      await container.read(careEventsProvider.notifier).refresh();

      final state = container.read(careEventsProvider);
      expect(state.status, CareInboxStatus.ready);
      expect(state.events, isEmpty);
      expect(state.lastLoadedAt, isNotNull);
    });

    test('성공한 뒤 실패하면 보고 있던 목록을 유지한 채 실패만 알린다', () async {
      final inbox = _FakeInbox()..events = [_event(2), _event(1)];
      final container = await _phone(inbox);
      await container.read(careEventsProvider.notifier).refresh();
      final seenAt = container.read(careEventsProvider).lastLoadedAt;

      inbox.down = true;
      await container.read(careEventsProvider.notifier).refresh();

      final state = container.read(careEventsProvider);
      expect(state.status, CareInboxStatus.failed);
      expect(state.events.length, 2, reason: '보던 알림이 사라지면 안 된다');
      expect(state.lastLoadedAt, seenAt, reason: '마지막 성공 시각은 그대로다');
    });

    test('서버 주소가 없으면 실패가 아니다 — 물어볼 곳이 없는 것이다', () async {
      final inbox = _FakeInbox();
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer(
        overrides: [rpiHttpClientProvider.overrideWithValue(inbox.client())],
      );
      addTearDown(container.dispose);

      await container.read(careEventsProvider.notifier).refresh();

      expect(container.read(careEventsProvider).status,
          CareInboxStatus.unconfigured);
    });
  });

  group('겹쳐 부른 새로고침', () {
    test('진행 중인 요청의 완료를 기다린다', () async {
      // 45초 타이머 새로고침이 도는 사이 화면이 열리면, 예전에는 화면의
      // refresh가 즉시 반환해 읽음 처리가 빈 목록 위에서 돌았다.
      final inbox = _FakeInbox()
        ..events = [_event(5)]
        ..gate = Completer<void>();
      final container = await _phone(inbox);
      final notifier = container.read(careEventsProvider.notifier);

      final first = notifier.refresh();
      final second = notifier.refresh(); // 겹친 호출
      inbox.gate!.complete();
      await Future.wait([first, second]);

      expect(inbox.calls, 1, reason: '요청은 한 번만 나간다');
      // 기다렸으므로 이 시점에 목록이 채워져 있고 읽음 처리가 성립한다
      await notifier.markAllSeen();
      expect(container.read(careEventsProvider).unreadCount, 0);
    });
  });

  group('서버가 새로 만들어졌을 때', () {
    test('id가 되감기면 읽음 기준도 되감는다', () async {
      // DB를 새로 만들면 id가 1부터 다시 시작한다. 예전 lastSeenId(=50)를
      // 그대로 두면 새 알림 전부가 영구히 '읽음'이 된다.
      final inbox = _FakeInbox()..events = [_event(2), _event(1)];
      final container = await _phone(
        inbox,
        prefs: {'care_events_last_seen_id': 50},
      );

      await container.read(careEventsProvider.notifier).refresh();

      final state = container.read(careEventsProvider);
      expect(state.lastSeenId, 0);
      expect(state.unreadCount, 2, reason: '새 알림은 안 읽은 것이다');
    });

    test('정상적으로 이어지는 id는 건드리지 않는다', () async {
      final inbox = _FakeInbox()..events = [_event(52), _event(51)];
      final container = await _phone(
        inbox,
        prefs: {'care_events_last_seen_id': 50},
      );

      await container.read(careEventsProvider.notifier).refresh();

      final state = container.read(careEventsProvider);
      expect(state.lastSeenId, 50);
      expect(state.unreadCount, 2);
    });
  });
}
