// 검토 10/19(core5 2): 말로 보낸 요청이 본체 답 없이 실패해도(응답 받는 중 끊김 등) 블루투스로 같은 말을 또 보내지 않는다 —
// 본체가 이미 받아 눌렀으면 두 번 눌리거나 켠 것을 도로 끈다. 모름으로 두어 정지를 남긴다.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/execution_status.dart';
import 'package:simplelay/providers/appliance_provider.dart';
import 'package:simplelay/providers/ble_provider.dart';
import 'package:simplelay/providers/execution_status_provider.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/providers/voice_provider.dart';
import 'package:simplelay/screens/voice_screen.dart';
import 'package:simplelay/services/ble_service.dart';
import 'package:simplelay/services/rpi_api_service.dart';

import '../helpers/test_helpers.dart';

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
    utf8.encode(jsonEncode(body)), status,
    headers: {'content-type': 'application/json; charset=utf-8'});

/// 블루투스로 보낸 말을 센다.
class _CountingBle extends BleService {
  int sends = 0;
  @override
  Future<void> sendCommand(String text, {required String source}) async => sends++;
}

Future<void> _pumps(WidgetTester tester, [int n = 6]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('말', () {
    Widget screen(ProviderContainer container) => UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            routerConfig: GoRouter(routes: [
              GoRoute(path: '/', builder: (_, __) => const VoiceScreen()),
              GoRoute(path: '/status', builder: (_, __) => const Scaffold(body: Text('상태 화면'))),
            ]),
          ),
        );

    Future<(ProviderContainer, _CountingBle)> make(RpiApiService api) async {
      final ble = _CountingBle()..simulateConnected();
      addTearDown(ble.dispose);
      final container = ProviderContainer(overrides: [
        ...installedOverrides([kTestAppliance]),
        bleServiceProvider.overrideWithValue(ble),
        bleConnectionProvider.overrideWith((ref) => Stream.value(BleConnectionState.connected)),
        rpiApiServiceProvider.overrideWithValue(api),
      ]);
      addTearDown(container.dispose);
      container.listen(bleConnectionProvider, (_, __) {}); // 화면처럼 연결 상태를 듣고 있게
      await container.read(customAppliancesProvider.notifier).ensureLoaded();
      container.read(voiceTextProvider.notifier).state = '즉석밥 데워줘';
      return (container, ble);
    }

    testWidgets('본체가 답 없이 끊겨도 블루투스로 다시 보내지 않고 모름으로 두어 정지를 남긴다', (tester) async {
      var executes = 0;
      final api = RpiApiService('http://rpi5.local:8000', client: MockClient((req) async {
        if (req.url.path == '/execute') {
          executes++;
          throw http.ClientException('응답 받는 중 끊김');
        }
        return _json({'running': false});
      }));
      final (container, ble) = await make(api);
      await tester.pumpWidget(screen(container));
      await tester.pump();
      await tester.pump(); // 블루투스 연결 상태가 화면에 닿게
      await tester.tap(find.text('이대로 하기'));
      await _pumps(tester);

      expect(executes, 1);
      expect(ble.sends, 0, reason: '본체가 이미 받았을 수 있다 — 같은 말을 또 보내면 두 번 눌린다');
      expect(find.textContaining('블루투스로 보냈어요'), findsNothing);
      final status = container.read(executionStatusProvider);
      expect(status.phase, ExecutionPhase.unknown);
      expect(status.message, ExecutionStatusNotifier.submissionUnknownNotice);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 20)); // 복구 조회 타이머 소진
    });

    testWidgets('답을 기다리는 사이 보내는 중으로 정지를 남긴다', (tester) async {
      final reply = Completer<http.Response>();
      final api = RpiApiService('http://rpi5.local:8000', client: MockClient((req) async {
        if (req.url.path == '/execute') return reply.future;
        return _json({'running': false, 'last_job_id': 'job-1', 'last_status': 'succeeded'});
      }));
      final (container, _) = await make(api);
      await tester.pumpWidget(screen(container));
      await tester.pump();
      await tester.tap(find.text('이대로 하기'));
      await _pumps(tester);
      expect(container.read(executionStatusProvider).phase, ExecutionPhase.waiting);

      reply.complete(_json({'job_id': 'job-1', 'status': 'accepted'}));
      await _pumps(tester);
      expect(container.read(executionStatusProvider).sequenceId, 'job-1');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 3));
    });
  });
}
