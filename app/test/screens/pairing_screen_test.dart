import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/pairing_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';
import 'package:simplelay/main.dart' show buildAppRouter;
import '../helpers/test_helpers.dart';

void main() {
  testWidgets('QR 딥링크가 연결 주소와 코드를 채워요', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final router = buildAppRouter(initialLocation: '/pair');
    await tester.pumpWidget(buildWithProviderState(
        child: MaterialApp.router(routerConfig: router)));
    router
        .go('simplelay://pair?host=http%3A%2F%2F192.0.2.10%3A8000&code=012345');
    await tester.pumpAndSettle();
    expect(find.byType(PairingScreen), findsOneWidget);
    expect(find.text('http://192.0.2.10:8000'), findsOneWidget);
    expect(find.text('012345'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    router.dispose();
  });

  for (final qr in [false, true]) {
    testWidgets('코드·QR 연결은 승인 후에만 키를 저장해요: $qr', (tester) async {
      SharedPreferences.setMockInitialValues({
        'rpi_api_key': 'old-test-key',
        'rpi_base_url': 'http://old.test:8000'
      });
      var approved = false;
      final client = MockClient((r) async {
        expect(r.headers.containsKey('x-api-key'), isFalse,
            reason: '연결 전 허브에 기존 키를 보내면 안 돼요');
        if (r.url.path == '/pair') {
          expect(r.url.host, '192.0.2.10');
          expect(jsonDecode(r.body)['code'], '012345');
          return http.Response(
              jsonEncode({
                'token': 'test-token',
                'request_id': 'abcdef-request',
                'expires_in': 300
              }),
              200);
        }
        return http.Response(
            jsonEncode(approved
                ? {'state': 'approved', 'api_key': 'new-test-key'}
                : {'state': 'pending'}),
            200);
      });
      await tester.pumpWidget(buildScreen(
          PairingScreen(
            host: 'http://192.0.2.10:8000',
            code: qr
                ? 'simplelay://pair?host=http%3A%2F%2F192.0.2.10%3A8000&code=012345'
                : '012345',
          ),
          overrides: [
            pairingApiFactoryProvider.overrideWithValue((host) =>
                RpiApiService(host, client: client, apiKey: 'must-not-send')),
            rpiServerOverride(RpiConnectionState.connected),
          ]));
      await tester.pumpAndSettle();
      await tester.tap(find.text('연결 요청하기'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      expect((await SharedPreferences.getInstance()).getString('rpi_api_key'),
          'old-test-key');
      expect(find.textContaining('abcdef'), findsOneWidget);
      approved = true;
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect((await SharedPreferences.getInstance()).getString('rpi_api_key'),
          'new-test-key');
      expect(find.text('허브와 연결했어요.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('만료 응답은 저장한 키를 그대로 두고 새 코드를 안내해요', (tester) async {
    SharedPreferences.setMockInitialValues({'rpi_api_key': 'kept-test-key'});
    final client = MockClient((r) async => r.url.path == '/pair'
        ? http.Response(
            jsonEncode({
              'token': 'test-token',
              'request_id': 'abcdef-request',
              'expires_in': 300
            }),
            200)
        : http.Response.bytes(
            utf8.encode(jsonEncode({'detail': '연결 시간이 지났어요. 새 코드를 받아 주세요.'})),
            410));
    await tester.pumpWidget(buildScreen(
        const PairingScreen(host: 'http://192.0.2.10:8000', code: '012345'),
        overrides: [
          pairingApiFactoryProvider
              .overrideWithValue((host) => RpiApiService(host, client: client)),
          rpiServerOverride(RpiConnectionState.connected),
        ]));
    await tester.pumpAndSettle();
    await tester.tap(find.text('연결 요청하기'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.textContaining('새 코드를 받아 주세요'), findsOneWidget);
    expect((await SharedPreferences.getInstance()).getString('rpi_api_key'),
        'kept-test-key');
  });
}
