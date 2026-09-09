/// R3 — 동기화는 **이 폰이 명시적으로 지운 것만** 지운다.
///
/// 예전 '키오스크와 다시 동기화'는 "폰이 원본"이라는 가정 위에 있었다:
/// 서버에 있는데 이 폰에 없는 커스텀 가전은 전부 유령으로 보고 지웠다.
/// 폰이 한 대일 때는 맞지만, 보호자 폰이 둘이면 —
///
///     폰 A에 선풍기 등록, 폰 B에 가습기 등록
///     → A에서 '다시 동기화'
///     → **B가 등록한 가습기와 그 노드 등록이 사라진다**
///
/// 서버 목록에만 있다는 것은 "지워도 된다"는 뜻이 아니라 "아직 못 받았다"는
/// 뜻이다. 지워도 되는 것은 **이 폰에서 사용자가 지운다고 말한 것**뿐이고,
/// 그건 서버 전송이 실패했더라도 기억해 두었다가 다시 보내야 한다.
library;

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

/// 서버를 흉내낸다 — 커스텀 가전 목록을 들고 PUT/DELETE를 반영한다.
class _FakeServer {
  _FakeServer(Iterable<String> customIds) {
    for (final id in customIds) {
      customs[id] = _def(id);
    }
  }

  final Map<String, Map<String, dynamic>> customs = {};
  final List<String> deleted = [];
  final List<String> upserted = [];

  /// 이 id들의 DELETE는 실패한다 — 서버가 잠깐 꺼져 있던 상황.
  Set<String> refuseDelete = {};

  static Map<String, dynamic> _def(String id) => {
        'id': id,
        'name': id,
        'icon': 'custom',
        'rows': 1,
        'cols': 1,
        'is_custom': true,
        'buttons': [
          {'id': '$id-1', 'label': '전원', 'x': 0, 'y': 0},
        ],
      };

  http.Client client() => MockClient((request) async {
        final path = request.url.path;
        if (path == '/appliances' && request.method == 'GET') {
          return _json([
            {..._def('microwave'), 'is_custom': false},
            ...customs.values,
          ]);
        }
        if (path.startsWith('/appliances/')) {
          final id = path.substring('/appliances/'.length);
          if (request.method == 'PUT') {
            upserted.add(id);
            customs[id] = _def(id);
            return _json(customs[id]!);
          }
          if (request.method == 'DELETE') {
            if (refuseDelete.contains(id)) {
              return http.Response('{"detail":"boom"}', 500);
            }
            deleted.add(id);
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
  await container.read(customAppliancesProvider.notifier).ensureLoaded();
  // 주소·삭제 대기열도 기기에서 비동기로 읽힌다 — 실제 앱과 같은 경로다.
  container.read(rpiUrlProvider);
  container.read(applianceSyncProvider);
  await Future<void>.delayed(Duration.zero);
  return container;
}

List<String> _localIds(ProviderContainer c) =>
    c.read(customAppliancesProvider).map((a) => a.id).toList()..sort();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('다른 폰의 가전을 지우지 않는다', () {
    test('서버에만 있는 가전은 삭제 대상이 아니라 내려받을 대상이다', () async {
      // 폰 A(선풍기)가 동기화한다. 가습기는 폰 B가 등록한 것이다.
      final server = _FakeServer(['fan', 'humidifier']);
      final container = await _phone(server, localCustoms: ['fan']);

      await container.read(applianceSyncProvider.notifier).sync();

      expect(server.deleted, isEmpty, reason: '다른 폰의 등록을 지우면 안 된다');
      expect(server.customs.keys, containsAll(['fan', 'humidifier']));
      // 그리고 이 폰도 그 가전을 알게 된다
      expect(_localIds(container), ['fan', 'humidifier']);
    });

    test('내려받은 가전이 내 사진 경로를 덮어쓰지 않는다', () async {
      // 사진은 이 폰에만 있는 로컬 데이터다 — 서버는 모른다.
      final server = _FakeServer(['fan']);
      final container = await _phone(server, localCustoms: ['fan']);

      await container.read(applianceSyncProvider.notifier).sync();

      final fan =
          container.read(customAppliancesProvider).firstWhere((a) => a.id == 'fan');
      expect(fan.photoPath, '/phone/fan.jpg');
    });

    test('로컬 가전은 서버로 올린다', () async {
      final server = _FakeServer([]);
      final container = await _phone(server, localCustoms: ['fan']);

      final result = await container.read(applianceSyncProvider.notifier).sync();

      expect(server.upserted, ['fan']);
      expect(result.uploaded, 1);
    });
  });

  group('내가 지운 것만, 성공할 때까지', () {
    test('서버 삭제에 실패하면 기억해 두었다가 다음 동기화에서 다시 보낸다', () async {
      final server = _FakeServer(['fan'])..refuseDelete = {'fan'};
      final container = await _phone(server, localCustoms: ['fan']);

      // 사용자가 폰에서 삭제 — 서버 전송은 실패한다
      await container
          .read(applianceSyncProvider.notifier)
          .deleteAppliance('fan');
      expect(_localIds(container), isEmpty, reason: '폰에서는 지워진다');
      expect(
        container.read(applianceSyncProvider),
        {'fan'},
        reason: '서버에 못 지웠다는 사실이 남아야 한다',
      );

      // 서버가 돌아온 뒤 다시 동기화
      server.refuseDelete = {};
      await container.read(applianceSyncProvider.notifier).sync();

      expect(server.deleted, ['fan']);
      expect(container.read(applianceSyncProvider), isEmpty);
      // 지운 가전을 동기화가 도로 내려받으면 안 된다
      expect(_localIds(container), isEmpty);
    });

    test('아직 못 지운 가전은 동기화가 내려받지 않는다', () async {
      final server = _FakeServer(['fan'])..refuseDelete = {'fan'};
      final container = await _phone(server, localCustoms: ['fan']);

      await container
          .read(applianceSyncProvider.notifier)
          .deleteAppliance('fan');
      await container.read(applianceSyncProvider.notifier).sync();

      expect(_localIds(container), isEmpty, reason: '지운 것이 되살아나면 안 된다');
      expect(container.read(applianceSyncProvider), {'fan'});
    });

    test('삭제 대기는 앱을 다시 열어도 남는다', () async {
      final server = _FakeServer(['fan']);
      final container = await _phone(
        server,
        prefs: {
          'pending_appliance_deletes': ['fan'],
        },
      );

      expect(container.read(applianceSyncProvider), {'fan'});

      await container.read(applianceSyncProvider.notifier).sync();
      expect(server.deleted, ['fan']);
    });

    test('가전이 하나도 없어도 밀린 삭제가 있으면 동기화할 것이 있다', () async {
      // 마지막 커스텀 가전을 지우다 실패하면, 예전에는 동기화 버튼이 뜨는
      // 조건(커스텀 가전 존재)까지 함께 사라져 복구할 길이 없었다.
      final server = _FakeServer(['fan']);
      final container = await _phone(
        server,
        prefs: {
          'pending_appliance_deletes': ['fan'],
        },
      );

      expect(container.read(hasPendingSyncProvider), isTrue);
    });
  });
}
