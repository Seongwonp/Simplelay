// 공개 /health 축소(2026-10-14 보안 점검) — 폰은 잠시 쉬기·준비 상태를 인증 경로 /health/detail에서 받고,
// 받지 못하면 '준비됨'이나 '꺼짐'으로 덮지 않는다.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/services/rpi_api_service.dart';

void main() {
  test('health()는 /health/detail을 키와 함께 부르고, 빠진 준비 상태는 준비 안 됨으로 읽는다', () async {
    final seen = <String, String?>{};
    final api = RpiApiService('http://hub:8000', apiKey: 'k-123', client: MockClient((r) async {
      seen[r.url.path] = r.headers['X-API-Key'];
      if (r.url.path == '/health/detail') return http.Response(jsonEncode({'ok': true}), 200);
      return http.Response(jsonEncode({'ok': true, 'version': '0.1.0'}), 200);
    }));
    final health = await api.health();
    expect(seen.keys, ['/health/detail']);
    expect(seen['/health/detail'], 'k-123');
    expect(health!.actuatorReady, isFalse);
  });

  // 배포 전 확인(2026-10-14 인계 4번) — 실패 네 종류 모두 '받지 못함'(null)이지 준비됨·꺼짐이 아니다.
  // 타임아웃은 8초를 실제로 기다리지 않고 .timeout()이 던지는 TimeoutException을 그대로 흉내 낸다.
  final failures = <String, Future<http.Response> Function()>{
    '401': () async => http.Response('{"detail":"invalid or missing API key"}', 401),
    '연결 실패': () async => throw const SocketException('connection refused'),
    '타임아웃': () async => throw TimeoutException('health/detail'),
    '해석 실패': () async => http.Response('<html>proxy error</html>', 200),
  };
  for (final entry in failures.entries) {
    test('health(): ${entry.key}면 null — 준비됨으로 읽지 않고, 잠시 쉬기 마지막 값을 지킨다', () async {
      final until = DateTime.utc(2026, 10, 14, 23, 30);
      var fail = false;
      final api = RpiApiService('http://hub:8000', client: MockClient((r) async {
        if (fail) return entry.value();
        return http.Response(
            jsonEncode({'ok': true, 'actuator_ready': true, 'dnd_until': until.toIso8601String()}), 200);
      }));
      final container = ProviderContainer(overrides: [rpiApiServiceProvider.overrideWithValue(api)]);
      addTearDown(container.dispose);
      await container.read(dndProvider.notifier).refresh();
      fail = true;
      expect(await api.health(), isNull);
      await container.read(dndProvider.notifier).refresh();
      expect(container.read(dndProvider), until);
    });
  }

  test('잠시 쉬기: 상세를 받지 못하면 마지막 값을 지키고 꺼짐으로 덮지 않는다', () async {
    final until = DateTime.utc(2026, 10, 14, 23, 30);
    var fail = false;
    final api = RpiApiService('http://hub:8000', client: MockClient((r) async {
      if (fail) return http.Response('{"detail":"invalid or missing API key"}', 401);
      if (r.url.path != '/health/detail') return http.Response('not found', 404);
      return http.Response(jsonEncode({'ok': true, 'actuator_ready': true, 'dnd_until': until.toIso8601String()}), 200);
    }));
    final container = ProviderContainer(overrides: [rpiApiServiceProvider.overrideWithValue(api)]);
    addTearDown(container.dispose);
    await container.read(dndProvider.notifier).refresh();
    expect(container.read(dndProvider), until);
    fail = true;
    await container.read(dndProvider.notifier).refresh();
    expect(container.read(dndProvider), until);
  });
}
