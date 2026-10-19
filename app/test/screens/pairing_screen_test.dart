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
    // QR로 받았으면 주소·코드 칸은 접어 두고 할 일만 말한다(첫 사용 검토 10/19).
    expect(find.text('본체의 QR을 읽었어요. 아래 "연결 요청하기"를 눌러 주세요.'), findsOneWidget);
    expect(find.text('연결 요청하기'), findsOneWidget);
    expect(find.text('http://192.0.2.10:8000'), findsNothing);
    await tester.tap(find.byKey(const Key('pair-manual')));
    await tester.pumpAndSettle();
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
      expect(find.text('본체와 연결했어요.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  // 첫 사용 검토 10/19: 본체 주소와 '코드 또는 QR 연결 주소'를 한꺼번에 물어 처음 쓰는 사람이 무엇을 적을지 몰랐다.
  testWidgets('QR 없이 열면 QR 찍기부터 말하고, 주소·코드 칸은 누르면 펼쳐요', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(buildScreen(const PairingScreen(),
        overrides: [rpiServerOverride(RpiConnectionState.unconfigured)]));
    await tester.pumpAndSettle();
    expect(find.text('본체의 QR을 휴대폰 카메라로 찍어 주세요.'), findsOneWidget);
    expect(find.text('본체 주소'), findsNothing);
    expect(find.text('여섯 자리 숫자'), findsNothing);
    expect(find.text('연결 요청하기'), findsNothing, reason: '보낼 코드가 없다');
    await tester.tap(find.text('QR 없이 주소와 숫자로 연결하기'));
    await tester.pumpAndSettle();
    expect(find.text('본체 주소'), findsOneWidget);
    expect(find.text('여섯 자리 숫자'), findsOneWidget);
    await tester.tap(find.text('연결 요청하기'));
    await tester.pumpAndSettle();
    expect(find.text('본체 주소와 여섯 자리 숫자를 봐 주세요.'), findsOneWidget);
  });

  testWidgets('QR로 받은 주소에 닿지 않으면 주소·코드 칸을 펼쳐 고칠 곳을 보여요', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final client = MockClient((r) async => throw http.ClientException('닿지 않음'));
    await tester.pumpWidget(buildScreen(
        const PairingScreen(host: 'http://192.0.2.10:8000', code: '012345'),
        overrides: [
          pairingApiFactoryProvider
              .overrideWithValue((host) => RpiApiService(host, client: client)),
          rpiServerOverride(RpiConnectionState.unconfigured),
        ]));
    await tester.pumpAndSettle();
    expect(find.text('본체 주소'), findsNothing);
    await tester.tap(find.text('연결 요청하기'));
    await tester.pumpAndSettle();
    expect(find.textContaining('주소가 맞는지 봐 주세요'), findsOneWidget);
    expect(find.text('본체 주소'), findsOneWidget);
  });

  testWidgets("연결을 마치고 '확인'을 누르면 연결했다고 알리며 닫혀요 — 첫 안내가 이 값으로 홈으로 가요", (tester) async {
    SharedPreferences.setMockInitialValues({});
    final client = MockClient((r) async => r.url.path == '/pair'
        ? http.Response(jsonEncode({'token': 't', 'request_id': 'abcdef-request', 'expires_in': 300}), 200)
        : http.Response(jsonEncode({'state': 'approved', 'api_key': 'new-test-key'}), 200));
    Object? result = 'not popped';
    await tester.pumpWidget(buildScreen(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await Navigator.of(context).push(MaterialPageRoute<bool>(
                builder: (_) => const PairingScreen(host: 'http://192.0.2.10:8000', code: '012345'))),
            child: const Text('열기'),
          ),
        ),
        overrides: [
          pairingApiFactoryProvider
              .overrideWithValue((host) => RpiApiService(host, client: client)),
          rpiServerOverride(RpiConnectionState.connected),
        ]));
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('연결 요청하기'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    await tester.tap(find.text('확인'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

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

  // 검토 10/19(core6 8): 승인 뒤 저장·연결 확인 중 하나라도 던지면 기다림이 끝나지 않아(_busy 그대로, 타이머는 이미 멈춤)
  // 다시 하기·입력이 모두 막혔다. 던져도 기다림을 끝내고 무엇이 됐는지 말한다.
  testWidgets('승인 뒤 키 저장이 실패해도 기다림을 끝내고 다시 연결할 수 있어요', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final client = MockClient((r) async => r.url.path == '/pair'
        ? http.Response(jsonEncode({'token': 't', 'request_id': 'abcdef-request', 'expires_in': 300}), 200)
        : http.Response(jsonEncode({'state': 'approved', 'api_key': 'new-test-key'}), 200));
    await tester.pumpWidget(buildScreen(
        const PairingScreen(host: 'http://192.0.2.10:8000', code: '012345'),
        overrides: [
          pairingApiFactoryProvider.overrideWithValue((host) => RpiApiService(host, client: client)),
          rpiApiKeyProvider.overrideWith((ref) => _FailingKeySave()),
          rpiServerOverride(RpiConnectionState.connected),
        ]));
    await tester.pumpAndSettle();
    await tester.tap(find.text('연결 요청하기'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text('연결 허락은 받았는데 이 폰에 저장하지 못했어요. 본체 화면에서 새 코드를 받아 다시 연결해 주세요.'),
        findsOneWidget);
    final request = tester.widget<ButtonStyleButton>(
        find.ancestor(of: find.text('연결 요청하기'), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton)));
    expect(request.onPressed, isNotNull, reason: '새 코드로 다시 요청할 수 있다');
  });
}

class _FailingKeySave extends RpiApiKeyNotifier {
  @override
  Future<void> save(String key) async => throw StateError('save failed');
}
