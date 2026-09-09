/// F2 — 실패한 동기화를 사용자가 다시 살릴 수 있게.
///
/// R3에서 **삭제**는 기기에 남겨 두었다가 다시 보내게 했다. 그런데 **업로드
/// 실패는 스낵바에서 끝난다.** 서버가 꺼져 있을 때 등록한 가전은 사용자가
/// '다시 동기화'를 기억해서 눌러 줘야만 올라간다 — 기억 못 하면 폰에만 있는
/// 가전이 되고, 키오스크는 영영 모른다.
///
/// 그리고 대기열이 `Set<String>`(id만)이라 **로컬에서 지운 뒤의 재전송을
/// 복구할 수 없다.** 보낼 내용이 남아 있지 않기 때문이다.
///
/// 여기서 고정하는 이음매:
///   1. outbox 로딩 전에 눌러도 저장된 작업이 유실되지 않는다
///   2. 실패한 upsert는 **payload째** 남아 재시작 후에도 재전송된다
///   3. 같은 id의 upsert→delete / delete→upsert 순서가 뒤집히지 않는다
///   4. 부분 성공은 성공한 것만 대기열에서 뺀다
///   5. 연타해도 중복 실행·순서 역전이 없다 (single-flight)
///   6. 재전송이 멱등이다 — 이미 지워진 항목의 404는 성공으로 본다
///   7. 병합이 로컬 사진 경로를 덮거나 올려보내지 않는다
///   8. 충돌을 조용히 덮어쓰지 않는다
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/appliance.dart';
import 'package:simplelay/providers/appliance_provider.dart';
import 'package:simplelay/providers/appliance_sync_provider.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';

/// 서버 흉내 — 커스텀 가전 목록을 들고 PUT/DELETE를 반영하고, 무엇이
/// 어떤 순서로 들어왔는지 기록한다.
class _FakeServer {
  _FakeServer([Iterable<String> customIds = const []]) {
    for (final id in customIds) {
      customs[id] = _def(id);
    }
  }

  final Map<String, Map<String, dynamic>> customs = {};

  /// 들어온 순서대로 'PUT fan' / 'DELETE fan'.
  final List<String> calls = [];

  /// 마지막으로 받은 PUT 본문 — 사진 경로가 새어 나가는지 본다.
  final List<Map<String, dynamic>> putBodies = [];

  Set<String> refusePut = {};
  Set<String> refuseDelete = {};

  /// 응답을 붙잡아 둔다 — single-flight 검증용.
  Completer<void>? gate;

  static Map<String, dynamic> _def(String id) => {
        'id': id,
        'name': id,
        'icon': 'custom',
        'rows': 1,
        'cols': 1,
        'is_custom': true,
        'revision': 1,
        'buttons': [
          {'id': '$id-1', 'label': '전원', 'x': 0, 'y': 0},
        ],
      };

  http.Client client() => MockClient((request) async {
        final path = request.url.path;
        if (path == '/appliances' && request.method == 'GET') {
          if (gate != null) await gate!.future;
          return _json([
            {..._def('microwave'), 'is_custom': false},
            ...customs.values,
          ]);
        }
        if (path.startsWith('/appliances/')) {
          final id = path.substring('/appliances/'.length);
          if (request.method == 'PUT') {
            calls.add('PUT $id');
            putBodies.add(jsonDecode(request.body) as Map<String, dynamic>);
            if (gate != null) await gate!.future;
            if (refusePut.contains(id)) {
              return http.Response('{"detail":"boom"}', 500);
            }
            customs[id] = _def(id);
            return _json(customs[id]!);
          }
          if (request.method == 'DELETE') {
            calls.add('DELETE $id');
            if (gate != null) await gate!.future;
            if (refuseDelete.contains(id)) {
              return http.Response('{"detail":"boom"}', 500);
            }
            if (!customs.containsKey(id)) {
              // 이미 없다 — 서버는 사실대로 404를 돌려준다.
              return http.Response('{"detail":"not found"}', 404);
            }
            customs.remove(id);
            return _json({'ok': true});
          }
        }
        return _json({});
      });
}

http.Response _json(Object body) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

ApplianceMap _local(String id) => ApplianceMap(
      id: id,
      name: id,
      icon: Icons.widgets_outlined,
      rows: 1,
      cols: 1,
      isCustom: true,
      photoPath: '/phone/$id.jpg',
      buttons: [ApplianceButton(id: '$id-1', label: '전원', x: 0, y: 0)],
    );

Future<ProviderContainer> _phone(
  _FakeServer server, {
  List<String> localCustoms = const [],
  Map<String, Object> prefs = const {},
  bool settle = true,
}) async {
  SharedPreferences.setMockInitialValues({
    'rpi_base_url': 'http://rpi5.local:8000',
    'custom_appliances': [
      for (final id in localCustoms) jsonEncode(_local(id).toJson()),
    ],
    ...prefs,
  });
  final container = ProviderContainer(
    overrides: [rpiHttpClientProvider.overrideWithValue(server.client())],
  );
  addTearDown(container.dispose);
  if (settle) {
    await container.read(customAppliancesProvider.notifier).ensureLoaded();
    container.read(rpiUrlProvider);
    container.read(applianceSyncProvider);
    await Future<void>.delayed(Duration.zero);
  }
  return container;
}

List<String> _localIds(ProviderContainer c) =>
    c.read(customAppliancesProvider).map((a) => a.id).toList()..sort();

/// 기기에 남은 대기열을 그대로 읽는다 — 재시작을 흉내내기 위해.
Future<List<String>> _storedOps() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getStringList('appliance_sync_outbox') ?? const [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('1. 로딩 전에 눌러도 잃지 않는다', () {
    test('outbox를 읽기 전에 동기화해도 저장된 작업이 나간다', () async {
      // 앱을 열자마자 누르는 경우다. 대기열이 아직 기기에서 안 올라왔는데
      // 그대로 진행하면 "보낼 게 없다"고 판단하고 대기열을 덮어쓴다.
      final server = _FakeServer(['fan']);
      final container = await _phone(
        server,
        settle: false,
        prefs: {
          'appliance_sync_outbox': [
            jsonEncode({
              'op_id': 'op-1',
              'appliance_id': 'fan',
              'kind': 'delete',
              'created_at': '2026-09-09T19:00:00+09:00',
            }),
          ],
        },
      );

      await container.read(applianceSyncProvider.notifier).sync();

      expect(server.calls, contains('DELETE fan'));
    });
  });

  group('2. 업로드 실패는 payload째 남는다', () {
    test('실패한 upsert가 기기에 남고, 재시작 후 다시 나간다', () async {
      final server = _FakeServer()..refusePut = {'fan'};
      final container = await _phone(server);

      await container
          .read(applianceSyncProvider.notifier)
          .saveAppliance(_local('fan'));
      expect(container.read(applianceSyncProvider).pendingCount, 1);

      // 보낼 내용이 남아 있어야 한다 — id만 남기면 로컬에서 지운 뒤
      // 복구할 수 없다.
      final stored = await _storedOps();
      expect(stored, hasLength(1));
      final op = jsonDecode(stored.first) as Map<String, dynamic>;
      expect(op['kind'], 'upsert');
      expect(op['payload'], isNotNull);
      expect((op['payload'] as Map)['name'], 'fan');

      // 앱을 다시 연다 (새 컨테이너, 같은 저장소)
      server.refusePut = {};
      final restarted = ProviderContainer(
        overrides: [rpiHttpClientProvider.overrideWithValue(server.client())],
      );
      addTearDown(restarted.dispose);
      restarted.read(rpiUrlProvider);
      restarted.read(applianceSyncProvider);
      await Future<void>.delayed(Duration.zero);

      await restarted.read(applianceSyncProvider.notifier).sync();

      expect(server.customs.keys, contains('fan'));
      expect(restarted.read(applianceSyncProvider).pendingCount, 0);
    });

    test('로컬에서 지워도 남은 upsert는 보낼 내용을 잃지 않는다', () async {
      // payload 스냅샷이 없으면 여기서 복구가 불가능하다.
      final server = _FakeServer()..refusePut = {'fan'};
      final container = await _phone(server);
      await container
          .read(applianceSyncProvider.notifier)
          .saveAppliance(_local('fan'));

      await container.read(customAppliancesProvider.notifier).remove('fan');

      final stored = await _storedOps();
      final op = jsonDecode(stored.first) as Map<String, dynamic>;
      expect((op['payload'] as Map)['name'], 'fan');
    });
  });

  group('3. 순서가 뒤집히지 않는다', () {
    test('upsert 뒤의 delete가 먼저 나가지 않는다', () async {
      final server = _FakeServer();
      final container = await _phone(server);
      final sync = container.read(applianceSyncProvider.notifier);

      await sync.saveAppliance(_local('fan'));
      await sync.deleteAppliance('fan');

      expect(server.calls, ['PUT fan', 'DELETE fan']);
      expect(server.customs.containsKey('fan'), isFalse);
    });

    test('delete 뒤의 upsert가 먼저 나가지 않는다', () async {
      // 지웠다가 같은 이름으로 다시 만드는 경우다. 순서가 뒤집히면
      // 방금 만든 가전이 사라진다.
      final server = _FakeServer(['fan']);
      final container = await _phone(server, localCustoms: ['fan']);
      final sync = container.read(applianceSyncProvider.notifier);

      await sync.deleteAppliance('fan');
      await sync.saveAppliance(_local('fan'));

      expect(server.calls, ['DELETE fan', 'PUT fan']);
      expect(server.customs.containsKey('fan'), isTrue);
    });

    test('오프라인에서 쌓인 순서도 그대로 나간다', () async {
      final server = _FakeServer()
        ..refusePut = {'fan'}
        ..refuseDelete = {'fan'};
      final container = await _phone(server);
      final sync = container.read(applianceSyncProvider.notifier);

      await sync.saveAppliance(_local('fan'));
      await sync.deleteAppliance('fan');
      await sync.saveAppliance(_local('fan'));
      server.calls.clear();

      server.refusePut = {};
      server.refuseDelete = {};
      await sync.sync();

      expect(server.calls, ['PUT fan', 'DELETE fan', 'PUT fan']);
    });
  });

  group('4. 부분 성공', () {
    test('성공한 것만 빠지고 실패한 것은 남는다', () async {
      final server = _FakeServer()..refusePut = {'humidifier'};
      final container = await _phone(server);
      final sync = container.read(applianceSyncProvider.notifier);

      await sync.saveAppliance(_local('fan'));
      await sync.saveAppliance(_local('humidifier'));

      expect(server.customs.keys, contains('fan'));
      expect(container.read(applianceSyncProvider).pendingCount, 1);
      final stored = await _storedOps();
      expect(
        (jsonDecode(stored.single) as Map)['appliance_id'],
        'humidifier',
      );
    });
  });

  group('5. 연타 (single-flight)', () {
    test('겹쳐 불러도 한 번만 나가고 순서가 유지된다', () async {
      // 대기열을 기기에 미리 심어 두고(네트워크 없이) 응답을 붙잡은 채
      // 두 번 부른다.
      final server = _FakeServer();
      final container = await _phone(
        server,
        prefs: {
          'appliance_sync_outbox': [
            jsonEncode({
              'op_id': 'op-1',
              'appliance_id': 'fan',
              'kind': 'upsert',
              'created_at': '2026-09-09T19:00:00+09:00',
              'payload': _local('fan').toJson(),
            }),
          ],
        },
      );
      final sync = container.read(applianceSyncProvider.notifier);
      server.gate = Completer<void>();

      final first = sync.sync();
      final second = sync.sync();
      server.gate!.complete();
      await Future.wait([first, second]);

      expect(
        server.calls.where((c) => c == 'PUT fan').length,
        1,
        reason: '같은 작업이 두 번 나가면 안 된다',
      );
      expect(container.read(applianceSyncProvider).pendingCount, 0);
    });
  });

  group('6. 재전송은 멱등이다', () {
    test('이미 지워진 항목의 삭제는 성공으로 본다', () async {
      // 되돌려 놓으려던 상태(그 가전이 없음)는 이미 성립했다. 실패로
      // 취급하면 대기열에서 영영 안 빠진다.
      final server = _FakeServer();
      final container = await _phone(
        server,
        prefs: {
          'appliance_sync_outbox': [
            jsonEncode({
              'op_id': 'op-1',
              'appliance_id': 'ghost',
              'kind': 'delete',
              'created_at': '2026-09-09T19:00:00+09:00',
            }),
          ],
        },
      );

      await container.read(applianceSyncProvider.notifier).sync();

      expect(container.read(applianceSyncProvider).pendingCount, 0);
      expect(await _storedOps(), isEmpty);
    });

    test('같은 upsert를 두 번 보내도 결과가 같다', () async {
      final server = _FakeServer();
      final container = await _phone(server, localCustoms: ['fan']);

      await container.read(applianceSyncProvider.notifier).resendAll();
      await container.read(applianceSyncProvider.notifier).resendAll();

      expect(server.customs.keys.where((k) => k == 'fan'), hasLength(1));
      expect(container.read(applianceSyncProvider).pendingCount, 0);
    });
  });

  group('7. 병합이 로컬 사진을 건드리지 않는다', () {
    test('서버에서 받아와도 내 사진 경로가 남는다', () async {
      final server = _FakeServer(['fan']);
      final container = await _phone(server, localCustoms: ['fan']);

      await container.read(applianceSyncProvider.notifier).sync();

      final fan = container
          .read(customAppliancesProvider)
          .firstWhere((a) => a.id == 'fan');
      expect(fan.photoPath, '/phone/fan.jpg');
    });

    test('사진 경로를 서버로 올려보내지 않는다', () async {
      final server = _FakeServer();
      final container = await _phone(server, localCustoms: ['fan']);

      await container.read(applianceSyncProvider.notifier).resendAll();

      expect(server.putBodies, isNotEmpty);
      for (final body in server.putBodies) {
        expect(body.containsKey('photo_path'), isFalse);
        expect(jsonEncode(body), isNot(contains('/phone/')));
      }
    });

    test('다른 폰이 등록한 가전은 지우지 않고 받아온다', () async {
      final server = _FakeServer(['fan', 'humidifier']);
      final container = await _phone(server, localCustoms: ['fan']);

      await container.read(applianceSyncProvider.notifier).sync();

      expect(server.customs.keys, containsAll(['fan', 'humidifier']));
      expect(_localIds(container), ['fan', 'humidifier']);
    });
  });

  group('지운 것이 되살아나지 않는다', () {
    test('아직 못 지운 가전은 병합이 도로 내려받지 않는다', () async {
      // 지운 가전이 동기화 때마다 되살아나면 지운 것이 아니다.
      final server = _FakeServer(['fan'])..refuseDelete = {'fan'};
      final container = await _phone(server, localCustoms: ['fan']);

      await container
          .read(applianceSyncProvider.notifier)
          .deleteAppliance('fan');

      expect(_localIds(container), isEmpty);
      expect(container.read(applianceSyncProvider).pendingCount, 1);
    });

    test('가전이 하나도 없어도 밀린 변경이 있으면 동기화할 것이 있다', () async {
      // 마지막 가전을 지우다 실패하면, 예전에는 동기화 버튼이 뜨는
      // 조건(커스텀 가전 존재)까지 함께 사라져 복구할 길이 없었다.
      final server = _FakeServer(['fan'])..refuseDelete = {'fan'};
      final container = await _phone(server, localCustoms: ['fan']);

      await container
          .read(applianceSyncProvider.notifier)
          .deleteAppliance('fan');

      expect(container.read(customAppliancesProvider), isEmpty);
      expect(container.read(hasPendingSyncProvider), isTrue);
    });
  });

  group('8. 충돌을 조용히 덮어쓰지 않는다', () {
    test('다른 기기가 먼저 바꿨으면 서버 내용을 가져오고 알린다', () async {
      // 서버가 409로 거절한다 (다른 기기가 먼저 바꿈)
      final conflicting = MockClient((request) async {
        if (request.url.path == '/appliances' && request.method == 'GET') {
          return _json([
            {
              ..._FakeServer._def('fan'),
              'name': '다른 폰이 바꾼 이름',
              'revision': 5,
            },
          ]);
        }
        if (request.method == 'PUT') {
          // 실제 서버처럼 utf-8로 보낸다. http.Response(String, ...)는 기본
          // latin-1이라 한글에서 던지고, 그러면 409가 통신 실패로 둔갑한다.
          return http.Response.bytes(
            utf8.encode('{"detail":"다른 기기에서 먼저 변경되었어요"}'),
            409,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        return _json({});
      });
      SharedPreferences.setMockInitialValues({
        'rpi_base_url': 'http://rpi5.local:8000',
        'custom_appliances': [jsonEncode(_local('fan').toJson())],
      });
      final container = ProviderContainer(
        overrides: [rpiHttpClientProvider.overrideWithValue(conflicting)],
      );
      addTearDown(container.dispose);
      await container.read(customAppliancesProvider.notifier).ensureLoaded();
      container.read(rpiUrlProvider);
      container.read(applianceSyncProvider);
      await Future<void>.delayed(Duration.zero);

      final result =
          await container.read(applianceSyncProvider.notifier).resendAll();

      // 자동 last-write-wins 금지 — 서버 내용이 남는다
      expect(result.conflicts, 1);
      final fan = container
          .read(customAppliancesProvider)
          .firstWhere((a) => a.id == 'fan');
      expect(fan.name, '다른 폰이 바꾼 이름');
      // 그리고 그 작업은 대기열에 계속 남아 재시도되지 않는다 — 다시 보내면
      // 같은 충돌이 반복된다.
      // 대기열에서는 빠진다 — 다시 보내도 같은 충돌이 반복될 뿐이다.
      expect(container.read(applianceSyncProvider).pendingCount, 0);
    });
  });
}
