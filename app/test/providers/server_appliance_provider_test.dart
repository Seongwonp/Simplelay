/// 서버 내장 가전의 조회·선택 정책 (2026-09-27).
///
/// 계약:
/// - 서버 `/appliances`의 내장(is_custom=false)과 사용자 등록(is_custom=true)을
///   가른다. 내장은 서버 출처 목록에만 있고, 기기 저장소·PUT/DELETE 대기열에
///   들어가지 않는다.
/// - 서버 주소가 바뀌면 이전 서버의 목록과 선택이 남지 않는다. 이전 요청의
///   늦은 응답이 새 서버의 목록을 덮지 않는다.
/// - 목록에 있다는 것과 실행할 수 있다는 것은 다르다 -- 서버가 준 준비 상태를
///   그대로 든다.
/// - 실제 빈 목록·조회 실패·명시적 앱 데모 모드를 구분한다.
/// - 사용자 등록 가전의 등록·편집·삭제·동기화·사진은 종전과 같다.
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
import 'package:simplelay/providers/demo_provider.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/providers/server_appliance_provider.dart';

const _serverA = 'http://10.0.0.1:8000';
const _serverB = 'http://10.0.0.2:8000';

Map<String, dynamic> _builtin(
  String id, {
  bool canExecute = true,
  String readiness = 'operable',
  List<String> reasons = const [],
}) =>
    {
      'id': id,
      'name': id == 'microwave' ? '전자레인지' : id,
      'category': id == 'microwave' ? 'microwave' : 'other',
      'icon': 'microwave',
      'rows': 1,
      'cols': 2,
      'is_custom': false,
      'revision': 3,
      'can_execute': canExecute,
      'readiness': readiness,
      'readiness_reasons': reasons,
      'buttons': [
        {'id': '$id-1', 'label': '즉석밥', 'x': 0, 'y': 0},
        {'id': '$id-2', 'label': '시작', 'x': 1, 'y': 0},
      ],
    };

Map<String, dynamic> _custom(String id) => {
      'id': id,
      'name': '선풍기 $id',
      'category': 'other',
      'icon': 'custom',
      'rows': 1,
      'cols': 1,
      'is_custom': true,
      'revision': 1,
      'buttons': [
        {'id': '$id-1', 'label': '전원', 'x': 0, 'y': 0},
      ],
    };

/// 주소(host)별로 다른 목록을 주는 가짜 서버. 응답을 붙잡아 둘 수 있고,
/// 들어온 PUT/DELETE를 기록한다.
class _FakeServers {
  final Map<String, List<Map<String, dynamic>>> lists = {};
  final Map<String, int> statusCodes = {};
  final Map<String, Completer<void>> gates = {};
  final List<String> writes = [];
  int gets = 0;

  http.Client client() => MockClient((request) async {
        final host = request.url.host;
        final path = request.url.path;
        if (path == '/health') return http.Response('{"status":"ok"}', 200);
        if (path == '/appliances' && request.method == 'GET') {
          gets++;
          final gate = gates[host];
          if (gate != null) await gate.future;
          final code = statusCodes[host] ?? 200;
          if (code != 200) return http.Response('boom', code);
          return _json(lists[host] ?? const []);
        }
        if (path.startsWith('/appliances/')) {
          writes.add('${request.method} ${path.split('/').last}');
          return _json({..._custom(path.split('/').last), 'revision': 2});
        }
        return http.Response('not found', 404);
      });
}

/// 한글이 든 JSON은 UTF-8 바이트로 돌려준다 -- `http.Response(String)`의
/// 기본 인코딩(latin1)은 한글을 실을 수 없어 클라이언트 쪽에서 예외가 된다.
http.Response _json(Object body) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

ProviderContainer _container(_FakeServers servers) {
  final c = ProviderContainer(overrides: [
    rpiHttpClientProvider.overrideWithValue(servers.client()),
  ]);
  addTearDown(c.dispose);
  // 프레임이 없는 단위 테스트라 첫 프레임 콜백이 오지 않는다 -- 직접 시작한다.
  c.read(serverApplianceCatalogProvider.notifier).start();
  return c;
}

/// 저장소·서버 주소·첫 조회까지 끝난 컨테이너.
Future<ProviderContainer> _ready(
  _FakeServers servers, {
  Map<String, Object> prefs = const {},
}) async {
  SharedPreferences.setMockInitialValues({'rpi_base_url': _serverA, ...prefs});
  final c = _container(servers);
  await c.read(applianceStartupProvider.future);
  await c.read(rpiUrlProvider.notifier).ensureLoaded();
  await _settle(c);
  return c;
}

/// 서버 목록 상태가 loading을 벗어날 때까지.
Future<void> _settle(ProviderContainer c) async {
  for (var i = 0; i < 50; i++) {
    await Future<void>.delayed(Duration.zero);
    if (!c.read(serverApplianceCatalogProvider).isLoading) return;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('내장과 사용자 등록을 가른다', () {
    test('서버 목록에는 내장만 남고, 사용자 등록 가전은 등록 목록에 섞이지 않는다',
        () async {
      final servers = _FakeServers()
        ..lists[Uri.parse(_serverA).host] = [_builtin('microwave'), _custom('fan')];
      final c = await _ready(servers);

      final catalog = c.read(serverApplianceCatalogProvider);
      expect(catalog.isLoaded, isTrue);
      expect(catalog.baseUrl, _serverA);
      expect(catalog.appliances.map((a) => a.id), ['microwave']);
      expect(catalog.appliances.single.isServerBuiltin, isTrue);
      expect(catalog.appliances.single.isCustom, isFalse);
      // 서버에만 있는 사용자 가전은 조회만으로 이 폰에 등록되지 않는다 --
      // 그것은 동기화 병합이 맡는다.
      expect(c.read(customAppliancesProvider), isEmpty);
      expect(c.read(installedAppliancesProvider).map((a) => a.id), ['microwave']);
    });

    test('내장 가전은 기기 저장소에 남지 않는다', () async {
      final servers = _FakeServers()
        ..lists[Uri.parse(_serverA).host] = [_builtin('microwave')];
      final c = await _ready(servers);
      expect(c.read(installedAppliancesProvider), isNotEmpty);

      // 어떤 경로로든 등록 목록에 넣으려 해도 거절된다.
      final builtin = c.read(serverApplianceCatalogProvider).appliances.single;
      await c.read(customAppliancesProvider.notifier).add(builtin);
      await c.read(customAppliancesProvider.notifier).replace(builtin);
      expect(c.read(customAppliancesProvider), isEmpty);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('custom_appliances') ?? const [], isEmpty);
    });

    test('내장 가전은 PUT/DELETE 대기열에 들어가지 않는다', () async {
      final servers = _FakeServers()
        ..lists[Uri.parse(_serverA).host] = [_builtin('microwave')];
      final c = await _ready(servers);
      final builtin = c.read(serverApplianceCatalogProvider).appliances.single;
      final sync = c.read(applianceSyncProvider.notifier);

      await sync.saveAppliance(builtin);
      await sync.deleteAppliance('microwave');
      await sync.resendAll();

      expect(c.read(applianceSyncProvider).pending, isEmpty);
      expect(servers.writes, isEmpty);
      // 서버 목록도 그대로다.
      expect(c.read(installedAppliancesProvider).map((a) => a.id), ['microwave']);
    });

    test('사용자 가전 등록·동기화·사진은 종전과 같다', () async {
      final servers = _FakeServers()
        ..lists[Uri.parse(_serverA).host] = [_builtin('microwave')];
      final c = await _ready(servers);
      final mine = ApplianceMap(
        id: 'custom_1',
        name: '그릴',
        category: ApplianceCategory.other,
        rows: 1,
        cols: 1,
        isCustom: true,
        photoPath: '/phone/photo.jpg',
        buttons: const [ApplianceButton(id: 'g1', label: '전원', x: 0, y: 0)],
      );

      final result = await c.read(applianceSyncProvider.notifier).saveAppliance(mine);

      expect(result.sent, 1);
      expect(servers.writes, ['PUT custom_1']);
      // 내장이 앞, 내 것이 뒤 -- 둘 다 고를 수 있다.
      expect(c.read(installedAppliancesProvider).map((a) => a.id),
          ['microwave', 'custom_1']);
      // 사진은 이 폰의 데이터라 살아 있다.
      expect(c.read(customAppliancesProvider).single.photoPath, '/phone/photo.jpg');

      await c.read(applianceSyncProvider.notifier).deleteAppliance('custom_1');
      expect(servers.writes, ['PUT custom_1', 'DELETE custom_1']);
      expect(c.read(installedAppliancesProvider).map((a) => a.id), ['microwave']);
    });
  });

  group('준비 상태', () {
    test('목록에 있다는 것만으로 실행 가능이라고 보지 않는다', () async {
      final servers = _FakeServers()
        ..lists[Uri.parse(_serverA).host] = [
          _builtin('microwave',
              canExecute: false,
              readiness: 'needs_setup',
              reasons: ['좌표를 아직 맞추지 않았어요']),
        ];
      final c = await _ready(servers);

      final mw = c.read(installedAppliancesProvider).single;
      expect(mw.readinessKnown, isTrue);
      expect(mw.canExecute, isFalse);
      expect(mw.readiness, 'needs_setup');
      expect(mw.readinessReasons, ['좌표를 아직 맞추지 않았어요']);
      expect(mw.mayDispatchWithoutServer, isFalse);
    });
  });

  group('서버 변경', () {
    test('주소가 바뀌면 이전 서버의 목록과 선택이 즉시 사라진다', () async {
      final hostB = Uri.parse(_serverB).host;
      final servers = _FakeServers()
        ..lists[Uri.parse(_serverA).host] = [_builtin('microwave')]
        ..lists[hostB] = [_builtin('induction')]
        ..gates[hostB] = Completer<void>();
      final c = await _ready(servers);
      expect(c.read(selectedApplianceProvider)?.id, 'microwave');

      await c.read(rpiUrlProvider.notifier).save(_serverB);
      await Future<void>.delayed(Duration.zero);

      // B의 응답이 오기 전인데도 A의 가전은 이미 없다.
      final during = c.read(serverApplianceCatalogProvider);
      expect(during.isLoading, isTrue);
      expect(during.baseUrl, _serverB);
      expect(during.appliances, isEmpty);
      expect(c.read(installedAppliancesProvider), isEmpty);
      expect(c.read(selectedApplianceProvider), isNull);

      servers.gates[hostB]!.complete();
      await _settle(c);

      expect(c.read(serverApplianceCatalogProvider).appliances.map((a) => a.id),
          ['induction']);
      expect(c.read(selectedApplianceProvider)?.id, 'induction');
    });

    test('이전 서버의 늦은 응답이 새 서버 목록을 덮지 않는다', () async {
      final hostA = Uri.parse(_serverA).host;
      final servers = _FakeServers()
        ..lists[hostA] = [_builtin('microwave')]
        ..lists[Uri.parse(_serverB).host] = [_builtin('induction')]
        ..gates[hostA] = Completer<void>();
      SharedPreferences.setMockInitialValues({'rpi_base_url': _serverA});
      final c = _container(servers);
      await c.read(applianceStartupProvider.future);
      await c.read(rpiUrlProvider.notifier).ensureLoaded();
      await Future<void>.delayed(Duration.zero);
      expect(c.read(serverApplianceCatalogProvider).isLoading, isTrue);

      // A가 응답하기 전에 B로 바꾼다. B는 바로 응답한다.
      await c.read(rpiUrlProvider.notifier).save(_serverB);
      await _settle(c);
      expect(c.read(serverApplianceCatalogProvider).appliances.map((a) => a.id),
          ['induction']);

      // 이제야 A의 응답이 도착한다.
      servers.gates[hostA]!.complete();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      final catalog = c.read(serverApplianceCatalogProvider);
      expect(catalog.baseUrl, _serverB);
      expect(catalog.appliances.map((a) => a.id), ['induction']);
      expect(c.read(selectedApplianceProvider)?.id, 'induction');
    });

    test('서버가 바뀌어도 사용자 등록 가전은 남고 선택은 그리로 내려간다', () async {
      final servers = _FakeServers()
        ..lists[Uri.parse(_serverA).host] = [_builtin('microwave')]
        ..lists[Uri.parse(_serverB).host] = [];
      final mine = ApplianceMap.fromJson(_custom('custom_1'));
      final c = await _ready(servers, prefs: {
        'custom_appliances': [jsonEncode(mine.toJson())],
        'selected_appliance': 'microwave',
      });
      expect(c.read(selectedApplianceProvider)?.id, 'microwave');

      await c.read(rpiUrlProvider.notifier).save(_serverB);
      await _settle(c);

      expect(c.read(installedAppliancesProvider).map((a) => a.id), ['custom_1']);
      expect(c.read(selectedApplianceProvider)?.id, 'custom_1');
    });
  });

  group('선택 복원', () {
    test('저장된 선택이 서버 내장 가전이면 목록이 늦게 와도 그리로 돌아간다', () async {
      final hostA = Uri.parse(_serverA).host;
      final servers = _FakeServers()
        ..lists[hostA] = [_builtin('microwave')]
        ..gates[hostA] = Completer<void>();
      final mine = ApplianceMap.fromJson(_custom('custom_1'));
      SharedPreferences.setMockInitialValues({
        'rpi_base_url': _serverA,
        'custom_appliances': [jsonEncode(mine.toJson())],
        'selected_appliance': 'microwave',
      });
      final c = _container(servers);
      await c.read(applianceStartupProvider.future);
      await c.read(rpiUrlProvider.notifier).ensureLoaded();
      await Future<void>.delayed(Duration.zero);

      // 서버가 아직이라 내 가전으로 잠시 내려간다. 이 임시 선택을 저장하면
      // 서버가 와도 돌아갈 수 없다.
      expect(c.read(selectedApplianceProvider)?.id, 'custom_1');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('selected_appliance'), 'microwave');

      servers.gates[hostA]!.complete();
      await _settle(c);

      expect(c.read(selectedApplianceProvider)?.id, 'microwave');
    });

    test('사용자가 직접 고른 가전은 서버 목록이 와도 바뀌지 않는다', () async {
      final hostA = Uri.parse(_serverA).host;
      final servers = _FakeServers()
        ..lists[hostA] = [_builtin('microwave')]
        ..gates[hostA] = Completer<void>();
      final mine = ApplianceMap.fromJson(_custom('custom_1'));
      SharedPreferences.setMockInitialValues({
        'rpi_base_url': _serverA,
        'custom_appliances': [jsonEncode(mine.toJson())],
        'selected_appliance': 'microwave',
      });
      final c = _container(servers);
      await c.read(applianceStartupProvider.future);
      await c.read(rpiUrlProvider.notifier).ensureLoaded();

      await c.read(selectedApplianceProvider.notifier).select(mine);
      servers.gates[hostA]!.complete();
      await _settle(c);

      expect(c.read(selectedApplianceProvider)?.id, 'custom_1');
    });
  });

  group('같은 서버 재조회', () {
    test('조회 중에는 선택이 비지만, 응답이 오면 고른 가전으로 돌아간다', () async {
      // 일시적 로딩을 '삭제'로 보고 저장된 선택을 지우면, 응답 뒤 첫 번째
      // 가전으로 바뀐다 -- 사용자가 고른 두 번째 가전이 조용히 사라진다.
      final hostA = Uri.parse(_serverA).host;
      final servers = _FakeServers()
        ..lists[hostA] = [_builtin('microwave'), _builtin('induction')];
      final c = await _ready(servers);
      final induction = c.read(installedAppliancesProvider).last;
      await c.read(selectedApplianceProvider.notifier).select(induction);

      final gate = Completer<void>();
      servers.gates[hostA] = gate;
      final refresh = c.read(serverApplianceCatalogProvider.notifier).refresh();
      await Future<void>.delayed(Duration.zero);
      expect(c.read(selectedApplianceProvider), isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('selected_appliance'), 'induction');

      gate.complete();
      await refresh;
      expect(c.read(selectedApplianceProvider)?.id, 'induction');
    });

    test('조회 실패도 일시적이다 -- 다음 성공에서 고른 가전으로 돌아간다', () async {
      final hostA = Uri.parse(_serverA).host;
      final servers = _FakeServers()
        ..lists[hostA] = [_builtin('microwave'), _builtin('induction')];
      final c = await _ready(servers);
      await c.read(selectedApplianceProvider.notifier)
          .select(c.read(installedAppliancesProvider).last);

      servers.statusCodes[hostA] = 500;
      await c.read(serverApplianceCatalogProvider.notifier).refresh();
      expect(c.read(serverApplianceCatalogProvider).isFailed, isTrue);
      expect(c.read(selectedApplianceProvider), isNull);

      servers.statusCodes.remove(hostA);
      await c.read(serverApplianceCatalogProvider.notifier).refresh();
      expect(c.read(selectedApplianceProvider)?.id, 'induction');
    });

    test('확정된 목록에 고른 가전이 없으면 선택을 잊는다', () async {
      final hostA = Uri.parse(_serverA).host;
      final servers = _FakeServers()
        ..lists[hostA] = [_builtin('microwave'), _builtin('induction')];
      final c = await _ready(servers);
      await c.read(selectedApplianceProvider.notifier)
          .select(c.read(installedAppliancesProvider).last);

      servers.lists[hostA] = [_builtin('microwave')];
      await c.read(serverApplianceCatalogProvider.notifier).refresh();

      expect(c.read(selectedApplianceProvider)?.id, 'microwave');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('selected_appliance'), isNull);
    });

    test('연결이 끊겼다 돌아오면 성공했던 목록도 다시 받아 준비 상태를 갱신한다', () async {
      final hostA = Uri.parse(_serverA).host;
      final servers = _FakeServers()..lists[hostA] = [_builtin('microwave')];
      final c = await _ready(servers);
      expect(c.read(installedAppliancesProvider).single.canExecute, isTrue);
      final before = servers.gets;

      servers.lists[hostA] = [_builtin('microwave', canExecute: false)];
      c.read(rpiConnectionProvider.notifier).state = RpiConnectionState.unreachable;
      c.read(rpiConnectionProvider.notifier).state = RpiConnectionState.connected;
      await _settle(c);
      await Future<void>.delayed(Duration.zero);

      expect(servers.gets, greaterThan(before));
      expect(c.read(installedAppliancesProvider).single.canExecute, isFalse);
      // 같은 가전을 계속 가리킨다.
      expect(c.read(selectedApplianceProvider)?.id, 'microwave');
    });
  });

  group('빈 목록·조회 실패·데모를 가른다', () {
    test('빈 응답은 성공이고 목록은 정말 비어 있다', () async {
      final servers = _FakeServers()..lists[Uri.parse(_serverA).host] = [];
      final c = await _ready(servers);

      final catalog = c.read(serverApplianceCatalogProvider);
      expect(catalog.isLoaded, isTrue);
      expect(catalog.appliances, isEmpty);
      expect(c.read(installedAppliancesProvider), isEmpty);
      expect(c.read(selectedApplianceProvider), isNull);
    });

    test('조회 실패는 빈 목록이 아니라 실패다', () async {
      final servers = _FakeServers()..statusCodes[Uri.parse(_serverA).host] = 500;
      final c = await _ready(servers);

      final catalog = c.read(serverApplianceCatalogProvider);
      expect(catalog.isFailed, isTrue);
      expect(catalog.appliances, isEmpty);
      expect(c.read(installedAppliancesProvider), isEmpty);
    });

    test('데모 모드는 서버 가전도 등록 가전도 없을 때만 표본을 세운다', () async {
      final servers = _FakeServers()..statusCodes[Uri.parse(_serverA).host] = 500;
      final c = await _ready(servers);
      expect(c.read(installedAppliancesProvider), isEmpty);

      c.read(demoModeProvider.notifier).state = true;
      await _settle(c);

      final installed = c.read(installedAppliancesProvider);
      expect(installed.map((a) => a.isDemo), everyElement(isTrue));
      // 표본은 서버 목록이 아니다.
      expect(c.read(serverApplianceCatalogProvider).appliances, isEmpty);
    });

    test('서버 내장 가전이 있으면 데모를 켜도 표본을 섞지 않는다', () async {
      final servers = _FakeServers()
        ..lists[Uri.parse(_serverA).host] = [_builtin('microwave')];
      final c = await _ready(servers);

      c.read(demoModeProvider.notifier).state = true;
      await _settle(c);

      expect(c.read(installedAppliancesProvider).map((a) => a.id), ['microwave']);
    });

    test('주소가 없으면 조회하지 않는다', () async {
      final servers = _FakeServers();
      SharedPreferences.setMockInitialValues({'rpi_base_url': ''});
      final c = _container(servers);
      await c.read(applianceStartupProvider.future);
      await c.read(rpiUrlProvider.notifier).ensureLoaded();
      await _settle(c);

      expect(c.read(serverApplianceCatalogProvider).status,
          ServerCatalogStatus.unconfigured);
      expect(servers.gets, 0);
    });
  });
}
