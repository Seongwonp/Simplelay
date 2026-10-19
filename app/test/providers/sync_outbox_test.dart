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


import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/appliance.dart';
import 'package:simplelay/providers/appliance_provider.dart';
import 'package:simplelay/providers/appliance_sync_provider.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/providers/server_appliance_provider.dart';

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

  /// 이 id의 PUT은 409(다른 기기가 먼저 바꿈)로 거절한다.
  Set<String> refusePutWith409 = {};

  /// PUT의 expected_revision이 지금 판과 다르면 409(본체와 같은 규칙). 켜면 받은 PUT은 판을 하나 올린다.
  bool checkPutRevision = false;

  /// 응답을 붙잡아 둔다 — single-flight 검증용.
  Completer<void>? gate;

  /// PUT 응답만 붙잡아 둔다 — 보내는 사이 새 변경이 쌓이는 것을 흉내낸다.
  Completer<void>? putGate;

  /// 목록 조회(GET /appliances)만 실패시킨다.
  bool failList = false;

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
          if (failList) return http.Response('{"detail":"boom"}', 500);
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
            if (putGate != null) await putGate!.future;
            if (refusePutWith409.contains(id)) {
              return http.Response.bytes(
                utf8.encode('{"detail":"다른 기기에서 먼저 변경되었어요"}'),
                409,
                headers: {'content-type': 'application/json; charset=utf-8'},
              );
            }
            if (refusePut.contains(id)) {
              return http.Response('{"detail":"boom"}', 500);
            }
            if (checkPutRevision) {
              final expected = putBodies.last['expected_revision'];
              final current = customs[id]?['revision'] as int?;
              if (expected != null && current != null && expected != current) {
                return http.Response.bytes(
                  utf8.encode('{"detail":"다른 기기에서 먼저 변경되었어요"}'),
                  409,
                  headers: {'content-type': 'application/json; charset=utf-8'},
                );
              }
              customs[id] = {..._def(id), 'revision': (current ?? 0) + 1};
              return _json(customs[id]!);
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
            // 판이 어긋나면 지우지 않는다 — 오래된 삭제가 남의 수정을
            // 덮어쓰는 것을 막는 자리다.
            final expected = request.url.queryParameters['expected_revision'];
            if (expected != null &&
                int.tryParse(expected) != customs[id]!['revision']) {
              return http.Response.bytes(
                utf8.encode('{"detail":"다른 기기에서 먼저 변경되었어요"}'),
                409,
                headers: {'content-type': 'application/json; charset=utf-8'},
              );
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
      category: ApplianceCategory.other,
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

/// 본체와 한 번 맞춘 가전 — 본체가 매긴 판 번호를 들고 있다.
Map<String, dynamic> _syncedJson(String id, {int revision = 1}) =>
    {..._local(id).toJson(), 'revision': revision};

List<String> _localIds(ProviderContainer c) =>
    c.read(customAppliancesProvider).map((a) => a.id).toList()..sort();

/// 기기에 남은 대기열을 그대로 읽는다 — 재시작을 흉내내기 위해.
Future<List<String>> _storedOps() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getStringList('appliance_sync_outbox') ?? const [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  _auditTests();

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

  // 검토 10/19(6): 동기화가 앞 작업의 응답을 기다리는 사이 저장한 변경이, 동기화가 끝날 때 처음 본 목록으로
  // 대기열을 통째로 바꿔 써 메모리와 기기 저장에서 함께 사라졌다.
  group('5-1. 보내는 사이 쌓인 변경', () {
    test('동기화 중에 저장한 변경을 잃지 않는다', () async {
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
      server.putGate = Completer<void>();

      final first = sync.sync();
      for (var i = 0; i < 50 && !server.calls.contains('PUT fan'); i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(server.calls, contains('PUT fan'));
      final saved = sync.saveAppliance(_local('lamp'));
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      server.putGate!.complete();
      await Future.wait([first, saved]);

      final stored = await _storedOps();
      expect(
        server.calls.contains('PUT lamp') ||
            stored.any((line) => line.contains('"appliance_id":"lamp"')),
        isTrue,
        reason: '동기화 중에 저장한 변경은 보내졌거나 대기열에 남아 있어야 한다',
      );
      expect(stored.any((line) => line.contains('"appliance_id":"fan"')), isFalse);
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
      // 대기 상태로 남는다 — 조용히 버리면 사용자는 자기 변경이 사라진
      // 것도 모른다. 화면이 "보내지 못했어요"로 알린다.
      expect(container.read(applianceSyncProvider).pendingCount, 1);
    });
  });

  group('9. 본체에서 지운 가전은 폰에서도 빠진다', () {
    // 본체 API로 세탁기·인터폰을 지웠는데 폰에는 '가전 2대 설정이 남았어요'·'본체에 보낼 것 3건'이 영영 남았다(10/19).
    // 남은 고치기는 본체 판 0과 어긋나 409로 매번 거절됐다. 본체가 본 적 있는 가전(판 번호가 있다)은 본체가 진실원천이다.
    test('본체가 본 적 있는 가전이 본체 목록에 없으면 폰에서 빼고 대기 작업도 버린다', () async {
      // 본체는 없는 가전에 판을 밝힌 고치기를 409로 거절한다(판 0과 어긋남).
      final server = _FakeServer(['fan'])..refusePutWith409 = {'washer', 'intercom'};
      final container = await _phone(server, prefs: {
        'custom_appliances': [
          jsonEncode(_syncedJson('fan')),
          jsonEncode(_syncedJson('washer', revision: 3)),
          jsonEncode(_syncedJson('intercom', revision: 2)),
        ],
        'appliance_sync_outbox': [
          jsonEncode({
            'op_id': 'op-1',
            'appliance_id': 'washer',
            'kind': 'upsert',
            'created_at': '2026-10-19T19:00:00+09:00',
            'payload': _syncedJson('washer', revision: 3),
          }),
          jsonEncode({
            'op_id': 'op-2',
            'appliance_id': 'intercom',
            'kind': 'upsert',
            'created_at': '2026-10-19T19:01:00+09:00',
            'payload': _syncedJson('intercom', revision: 2),
          }),
          jsonEncode({
            'op_id': 'op-3',
            'appliance_id': 'intercom',
            'kind': 'delete',
            'created_at': '2026-10-19T19:02:00+09:00',
            'revision': 2,
          }),
        ],
      });

      final result =
          await container.read(applianceSyncProvider.notifier).sync();

      expect(_localIds(container), ['fan']);
      expect(container.read(applianceSyncProvider).pendingCount, 0);
      expect(await _storedOps(), isEmpty);
      expect(server.calls.where((c) => c.startsWith('PUT')), isEmpty);
      expect(result.conflicts, 0);
      expect(result.allDone, isTrue);
    });

    test('이 폰에서만 만들고 아직 못 보낸 가전(판 0)은 빼지 않고 보낸다', () async {
      final server = _FakeServer(['fan']);
      final container = await _phone(server, prefs: {
        'custom_appliances': [
          jsonEncode(_syncedJson('fan')),
          jsonEncode(_local('humidifier').toJson()),
        ],
        'appliance_sync_outbox': [
          jsonEncode({
            'op_id': 'op-1',
            'appliance_id': 'humidifier',
            'kind': 'upsert',
            'created_at': '2026-10-19T19:00:00+09:00',
            'payload': _local('humidifier').toJson(),
          }),
        ],
      });

      await container.read(applianceSyncProvider.notifier).sync();

      expect(_localIds(container), ['fan', 'humidifier']);
      expect(server.calls, ['PUT humidifier']);
      expect(server.customs.keys, contains('humidifier'));
    });

    test('다른 본체로 주소를 바꾼 것 같으면(맞춘 가전이 하나도 없고 주소도 다름) 빼지 않는다', () async {
      final server = _FakeServer(['other-hub-fan']);
      final container = await _phone(server, prefs: {
        'appliance_sync_hub_url': 'http://old-hub.local:8000',
        'custom_appliances': [jsonEncode(_syncedJson('washer'))],
      });

      await container.read(applianceSyncProvider.notifier).sync();
      // 검토 10/19(6): 첫 맞춤이 받아 온 그 본체 가전(other-hub-fan)이 다음 맞춤에서 '겹침'으로 잡혀 옛 가전을 지웠다.
      await container.read(applianceSyncProvider.notifier).sync();

      expect(_localIds(container), contains('washer'));
    });

    // 검토 10/19(6): 지난 본체 주소 기록이 없으면 같은 본체로 쳐, 새(빈) 본체에 붙자마자 맞춰 둔 가전과 대기 작업을 모두 지웠다.
    test('지난 본체를 모르고 맞춘 가전이 하나도 이 본체에 없으면 지우지 않고 대기 작업도 남긴다', () async {
      final server = _FakeServer(['other-hub-fan'])..refusePutWith409 = {'washer'};
      final container = await _phone(server, prefs: {
        'custom_appliances': [
          jsonEncode(_syncedJson('washer', revision: 3)),
          jsonEncode(_syncedJson('intercom', revision: 2)),
        ],
        'appliance_sync_outbox': [
          jsonEncode({
            'op_id': 'op-1',
            'appliance_id': 'washer',
            'kind': 'upsert',
            'created_at': '2026-10-19T19:00:00+09:00',
            'payload': _syncedJson('washer', revision: 3),
          }),
        ],
      });

      await container.read(applianceSyncProvider.notifier).sync();
      await container.read(applianceSyncProvider.notifier).sync();

      expect(_localIds(container), containsAll(['washer', 'intercom']));
      expect((await _storedOps()).length, 1);
    });

    test('본체 목록에서 맞춘 가전이 빠진 걸 보면 누르지 않아도 맞춘다', () async {
      final server = _FakeServer(['fan']);
      SharedPreferences.setMockInitialValues({
        'rpi_base_url': 'http://rpi5.local:8000',
        'custom_appliances': [
          jsonEncode(_syncedJson('fan')),
          jsonEncode(_syncedJson('washer')),
        ],
      });
      final container = ProviderContainer(
        overrides: [
          rpiHttpClientProvider.overrideWithValue(server.client()),
          serverApplianceCatalogProvider.overrideWith(
            (ref) => ServerApplianceNotifier.seeded(
              ref,
              ServerApplianceCatalog(
                status: ServerCatalogStatus.loaded,
                baseUrl: 'http://rpi5.local:8000',
                customAppliances: [ApplianceMap.fromJson(_syncedJson('fan'))],
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(customAppliancesProvider.notifier).ensureLoaded();
      container.read(rpiUrlProvider);
      container.read(applianceSyncProvider);
      for (var i = 0; i < 40 && _localIds(container).contains('washer'); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      expect(_localIds(container), ['fan']);
    });
  });
}

// ── F2 마감 감사 ───────────────────────────────────────────────────────────

void _auditTests() {
  group('감사 1. 구버전 대기열 이어받기', () {
    test('업데이트해도 미전송 삭제가 사라지지 않는다', () async {
      // 예전 버전은 삭제 대기를 pending_appliance_deletes(id 집합)에 남겼다.
      // 새 대기열만 읽으면, 업데이트하는 순간 아직 못 보낸 삭제가 조용히
      // 사라진다 — 서버에는 유령 가전이 남고 아무도 모른다.
      final server = _FakeServer(['fan']);
      final container = await _phone(
        server,
        prefs: {
          'pending_appliance_deletes': ['fan'],
        },
      );

      expect(container.read(applianceSyncProvider).pendingCount, 1);
      await container.read(applianceSyncProvider.notifier).sync();
      expect(server.calls, contains('DELETE fan'));
    });

    test('새 대기열에 저장된 뒤에만 옛 키를 지운다', () async {
      final server = _FakeServer(['fan']);
      final container = await _phone(
        server,
        prefs: {
          'pending_appliance_deletes': ['fan'],
        },
      );
      await container.read(applianceSyncProvider.notifier).sync();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('pending_appliance_deletes'), isNull);
    });

    test('새 대기열이 이미 있으면 옛 키를 덧붙이지 않는다', () async {
      // 이미 옮겨온 뒤라면 같은 삭제가 두 번 들어가면 안 된다.
      final server = _FakeServer(['fan']);
      final container = await _phone(
        server,
        prefs: {
          'pending_appliance_deletes': ['fan'],
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

      expect(container.read(applianceSyncProvider).pendingCount, 1);
    });
  });

  group('감사 2. 오래된 삭제가 남의 수정을 지우지 않는다', () {
    test('내가 본 판 이후에 바뀌었으면 삭제도 거절된다', () async {
      // "충돌은 서버 내용 유지"가 upsert에만 걸려 있으면, 폰 A의 오래된
      // 삭제가 폰 B의 방금 수정을 무조건 지운다.
      final server = _FakeServer(['fan']);
      server.customs['fan']!['revision'] = 2; // B가 먼저 고쳤다
      server.customs['fan']!['name'] = '거실 선풍기';
      final container = await _phone(server, localCustoms: ['fan']);

      // A는 판 1을 보고 지운다
      await container
          .read(applianceSyncProvider.notifier)
          .deleteAppliance('fan', expectedRevision: 1);

      expect(server.customs.containsKey('fan'), isTrue, reason: '지워지면 안 된다');
      expect(container.read(applianceSyncProvider).pendingCount, 1);
    });

    test('판이 맞으면 그대로 지운다', () async {
      final server = _FakeServer(['fan']);
      final container = await _phone(server, localCustoms: ['fan']);

      await container
          .read(applianceSyncProvider.notifier)
          .deleteAppliance('fan', expectedRevision: 1);

      expect(server.customs.containsKey('fan'), isFalse);
      expect(container.read(applianceSyncProvider).pendingCount, 0);
    });

    test('내용이 같아도 본체 판 번호를 받아 둔다 — 다시 보내기 뒤 지우기가 옛 판으로 거절되지 않는다(실화면 10/19)',
        () async {
      // 이 폰이 다시 보내서 본체 판이 3으로 올랐다. 내용은 같다.
      final server = _FakeServer(['fan']);
      server.customs['fan']!['revision'] = 3;
      final container = await _phone(server, prefs: {
        'custom_appliances': [
          jsonEncode({..._local('fan').toJson(), 'revision': 1}),
        ],
      });

      await container.read(applianceSyncProvider.notifier).sync();
      expect(container.read(customAppliancesProvider).single.revision, 3);
      expect(container.read(customAppliancesProvider).single.photoPath, '/phone/fan.jpg',
          reason: '판 번호만 바꾸고 이 폰의 사진은 그대로');

      await container.read(applianceSyncProvider.notifier).deleteAppliance('fan');
      expect(server.customs.containsKey('fan'), isFalse, reason: '본체에서도 지워져야 한다');
      expect(container.read(applianceSyncProvider).pendingCount, 0);
    });

    test('본체 판만 올랐고 내용이 그대로면 그 판으로 다시 보내 지운다 — 다시 하기가 끝나지 않던 것(실화면 10/19)',
        () async {
      final server = _FakeServer(['fan']);
      server.customs['fan']!['revision'] = 2; // 내 다시 보내기가 판만 올렸다
      final container = await _phone(server, localCustoms: ['fan']);

      await container
          .read(applianceSyncProvider.notifier)
          .deleteAppliance('fan', expectedRevision: 1);

      expect(server.customs.containsKey('fan'), isFalse);
      expect(container.read(applianceSyncProvider).pendingCount, 0);
    });

    test('판만 어긋난 다시 보내기(upsert)도 본체 판으로 한 번 더 보내 끝낸다', () async {
      final server = _FakeServer(['fan']);
      server.customs['fan']!['revision'] = 5;
      final container = await _phone(server, prefs: {
        'custom_appliances': [
          jsonEncode({..._local('fan').toJson(), 'revision': 1}),
        ],
      });
      server.checkPutRevision = true;
      final result = await container.read(applianceSyncProvider.notifier).resendAll();
      expect(result.conflicts, 0);
      expect(container.read(applianceSyncProvider).pendingCount, 0);
      expect(server.putBodies.map((b) => b['expected_revision']).toList(), [1, 5]);
      expect(server.customs['fan']!['revision'], 6);
    });

    // 검토 10/19(7): 판만 어긋났는지 가를 때 이름·격자·버튼만 봐서, 다른 기기가 바꾼 놓인 곳(방)·목적 등을
    // '판만 다름'으로 보고 옛 내용을 새 판으로 다시 보내 덮었다. 병합도 판만 받고 옛 화면을 그대로 두었다.
    test('다른 기기가 놓인 곳만 바꿨으면 판만 받지 않고 본체 내용을 가져온다', () async {
      final server = _FakeServer(['fan']);
      server.customs['fan']!
        ..['revision'] = 2
        ..['location'] = '안방';
      final container = await _phone(server, prefs: {
        'custom_appliances': [
          jsonEncode({..._local('fan').toJson(), 'revision': 1, 'location': '거실'}),
        ],
      });

      await container.read(applianceSyncProvider.notifier).sync();

      final fan = container.read(customAppliancesProvider).single;
      expect(fan.location, '안방');
      expect(fan.revision, 2);
      expect(fan.photoPath, '/phone/fan.jpg');
    });

    test('다른 기기가 목적을 바꿨으면 판만 바꿔 다시 보내지 않는다(충돌로 남긴다)', () async {
      final server = _FakeServer(['fan']);
      server.customs['fan']!
        ..['revision'] = 2
        ..['functions'] = {
          'power_on': ['전원'],
        };
      final container = await _phone(server, prefs: {
        'appliance_sync_outbox': [
          jsonEncode({
            'op_id': 'op-1',
            'appliance_id': 'fan',
            'kind': 'upsert',
            'created_at': '2026-09-09T19:00:00+09:00',
            'payload': {..._local('fan').toJson(), 'revision': 1},
          }),
        ],
      });
      server.checkPutRevision = true;

      final result = await container.read(applianceSyncProvider.notifier).sync();

      expect(result.conflicts, 1);
      expect(server.putBodies.map((b) => b['expected_revision']).toList(), [1],
          reason: '본체 판으로 바꿔 다시 보내면 다른 기기가 정한 목적을 지운다');
    });

    // 검토 10/19(9): 고치기(PUT)가 성공해 본체가 새 판을 돌려줘도 버렸다. 이어진 목록 조회가 실패하면 이 폰은
    // 옛 판을 들고 있어, 다음 고치기가 방금 자기가 한 고치기와 충돌했다.
    test('고치기가 성공하면 돌려받은 판을 받아 둔다 — 목록 조회가 실패해도 다음 고치기가 충돌하지 않는다', () async {
      final server = _FakeServer(['fan']);
      final container = await _phone(server, prefs: {
        'custom_appliances': [jsonEncode(_syncedJson('fan'))],
      });
      server.checkPutRevision = true;
      server.failList = true;
      final sync = container.read(applianceSyncProvider.notifier);

      await sync.saveAppliance(ApplianceMap.fromJson(_syncedJson('fan')));
      expect(container.read(customAppliancesProvider).single.revision, 2);

      final again = await sync.saveAppliance(container.read(customAppliancesProvider).single);
      expect(again.conflicts, 0);
      expect(server.putBodies.map((b) => b['expected_revision']).toList(), [1, 2]);
      expect(container.read(applianceSyncProvider).pendingCount, 0);
    });

    test('이미 지워진 가전의 삭제는 여전히 멱등 성공이다', () async {
      final server = _FakeServer();
      final container = await _phone(server);

      await container
          .read(applianceSyncProvider.notifier)
          .deleteAppliance('ghost', expectedRevision: 3);

      expect(container.read(applianceSyncProvider).pendingCount, 0);
    });
  });

  group('감사 3. 충돌 뒤 작업을 같은 패스에서 보내지 않는다', () {
    /// 오프라인에서 upsert → delete가 쌓인 상태.
    Future<ProviderContainer> queuedUpsertThenDelete(_FakeServer server) =>
        _phone(
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
              jsonEncode({
                'op_id': 'op-2',
                'appliance_id': 'fan',
                'kind': 'delete',
                'created_at': '2026-09-09T19:01:00+09:00',
              }),
            ],
          },
        );

    test('upsert가 409면 이어지는 delete가 서버 가전을 지우지 않는다', () async {
      // 이게 가장 나쁜 조합이다. 내 수정은 거절됐는데(= 서버에 내가 못 본
      // 내용이 있다) 그 뒤의 삭제가 그걸 그대로 지워버린다.
      final server = _FakeServer(['fan'])..refusePutWith409 = {'fan'};
      final container = await queuedUpsertThenDelete(server);

      await container.read(applianceSyncProvider.notifier).sync();

      expect(server.customs.containsKey('fan'), isTrue,
          reason: '충돌 뒤 작업이 서버 내용을 지우면 안 된다');
      expect(server.calls, isNot(contains('DELETE fan')));
    });

    test('충돌 뒤 작업은 대기 상태로 남는다 — 조용히 버리지 않는다', () async {
      final server = _FakeServer(['fan'])..refusePutWith409 = {'fan'};
      final container = await queuedUpsertThenDelete(server);

      final result =
          await container.read(applianceSyncProvider.notifier).sync();

      // 충돌한 작업도, 그 뒤의 작업도 남는다. 자동 재기준화·삭제는 하지
      // 않는다 — 사용자가 모르는 사이에 의도가 바뀌면 안 된다.
      expect(result.conflicts, 1);
      expect(container.read(applianceSyncProvider).pendingCount, 2);
    });

    test('다른 가전은 충돌에 막히지 않는다', () async {
      // 한 가전의 충돌이 대기열 전체를 세우면 안 된다.
      final server = _FakeServer(['fan'])..refusePutWith409 = {'fan'};
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
            jsonEncode({
              'op_id': 'op-2',
              'appliance_id': 'humidifier',
              'kind': 'upsert',
              'created_at': '2026-09-09T19:01:00+09:00',
              'payload': _local('humidifier').toJson(),
            }),
          ],
        },
      );

      await container.read(applianceSyncProvider.notifier).sync();

      expect(server.customs.keys, contains('humidifier'));
      expect(container.read(applianceSyncProvider).pendingCount, 1);
    });
  });
}
