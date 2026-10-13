// 같은 주소·키로 허브가 꺼졌다 켜질 때 연결 상태가 따라오는가(외부 평가 2026-10-13 M2) — 실제 연결 provider.
//
// 주소·키가 그대로면 RpiConnectionNotifier는 처음·주소/키 변화·사용자 확인 때만 판정했다. 그래서 허브가 꺼졌다
// 켜져도 '연결됨'에 머물고, 연결을 듣는 확인 주행 조회(setupPassProvider)가 다시 묻지 않아 예전 결과가 남았다.
// 이제 기존 5초 /status 조회(estopProvider)의 통신 성공/실패가 연결 상태에 반영된다(연속 실패 → 닿지 않음,
// 다시 성공 → 연결됨). 새 화면·새 주기 조회는 없다.
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/hub.dart';
import 'package:simplelay/providers/estop_provider.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/widgets/appliance_setup_card.dart';

class _Hub {
  bool up = true;
  int statusCode = 200;
  int verifyCalls = 0;

  /// 있으면 /status가 이 본문을 200으로 돌려준다(형식이 틀린 응답).
  Object? statusBody;
  int statusCalls = 0;

  http.Client get client => MockClient((request) async {
        if (!up) throw http.ClientException('허브 꺼짐');
        if (request.url.path == '/status') {
          statusCalls++;
          return _json(
              statusBody ?? {'running': false, 'last_status': null}, statusCode);
        }
        if (request.url.path.endsWith('/verify-pass')) {
          verifyCalls++;
          return _json({'state': 'done', 'execution_mode': 'real'}, 200);
        }
        return _json({'detail': 'Not Found'}, 404);
      });
}

http.Response _json(Object body, int code) => http.Response.bytes(
    utf8.encode(jsonEncode(body)), code,
    headers: {'content-type': 'application/json; charset=utf-8'});

Future<void> _until(bool Function() cond, {int ms = 5000}) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (!cond()) {
    if (DateTime.now().isAfter(end)) fail('조건을 기다리다 기한이 지났다');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

ProviderContainer _container(_Hub hub) {
  final c = ProviderContainer(overrides: [
    rpiHttpClientProvider.overrideWithValue(hub.client),
    estopPollIntervalProvider.overrideWithValue(const Duration(milliseconds: 100)),
  ]);
  addTearDown(c.dispose);
  // 앱에서는 AppShell의 비상정지 배너·홈이 이 둘을 계속 구독한다.
  c.listen(rpiConnectionProvider, (_, __) {});
  c.listen(estopProvider, (_, __) {});
  return c;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues(
      {'rpi_base_url': 'http://10.0.0.5:8000'}));

  test('같은 주소·키: 허브가 꺼지면 닿지 않음, 다시 켜지면 연결됨 — 확인 주행을 다시 묻는다', () async {
    final hub = _Hub();
    final c = _container(hub);
    final pass = c.listen(setupPassProvider('m1'), (_, __) {});
    await _until(() => c.read(rpiConnectionProvider) == RpiConnectionState.connected);
    await _until(() => setupPassLookupOf(pass.read()).kind == VerifyPassLookupKind.found);
    expect(hub.verifyCalls, 1);

    hub.up = false; // 같은 주소·키로 허브 전원이 꺼졌다
    await _until(() => c.read(rpiConnectionProvider) == RpiConnectionState.unreachable);
    expect(setupPassLookupOf(pass.read()).kind, VerifyPassLookupKind.unknown);

    hub.up = true; // 다시 켜졌다 — 사용자가 재시도를 누르지 않아도
    await _until(() => c.read(rpiConnectionProvider) == RpiConnectionState.connected);
    await _until(() => hub.verifyCalls == 2);
    await _until(() => setupPassLookupOf(pass.read()).kind == VerifyPassLookupKind.found);
  });

  test('조회 한 번 실패로는 닿지 않음으로 바꾸지 않는다', () async {
    final hub = _Hub();
    final c = _container(hub);
    await _until(() => c.read(rpiConnectionProvider) == RpiConnectionState.connected);
    final notifier = c.read(rpiConnectionProvider.notifier);
    notifier.reportHubPoll(reachable: false);
    expect(c.read(rpiConnectionProvider), RpiConnectionState.connected);
    notifier.reportHubPoll(reachable: true);
    notifier.reportHubPoll(reachable: false);
    expect(c.read(rpiConnectionProvider), RpiConnectionState.connected);
  });

  test('허브가 답은 하지만 오류 코드(500)면 닿지 않음이 아니다', () async {
    final hub = _Hub();
    final c = _container(hub);
    await _until(() => c.read(rpiConnectionProvider) == RpiConnectionState.connected);
    hub.statusCode = 500;
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(c.read(rpiConnectionProvider), RpiConnectionState.connected);
  });

  // 2차 평가 L-N1: HTTP 200으로 답했지만 필드 타입이 틀린 응답(TypeError)은 해석 실패이지 통신 단절이 아니다.
  for (final (name, body) in <(String, Object)>[
    ('hold_state가 숫자', {'running': false, 'hold_state': 123}),
    ('본문이 목록', <Object>[1, 2]),
  ]) {
    test('허브가 200으로 답했지만 형식이 틀리면($name) 두 번 넘게 와도 닿지 않음이 아니다', () async {
      final hub = _Hub();
      final c = _container(hub);
      await _until(() => c.read(rpiConnectionProvider) == RpiConnectionState.connected);
      hub.statusBody = body;
      final before = hub.statusCalls;
      await _until(() => hub.statusCalls >= before + 3);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(c.read(rpiConnectionProvider), RpiConnectionState.connected);
    });
  }
}
