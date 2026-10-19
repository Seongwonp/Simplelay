// 검토 10/19(본체 pairing.py 계약): 허락된 뒤 본체는 받았음 알림(POST /pair/ack) 전까지 같은 키를 몇 번이고 돌려준다.
// 폰은 키와 주소를 이 폰에 저장한 **뒤에** 받았음을 알리고, 결과 응답을 잃으면 같은 토큰으로 다시 물어 키를 받는다.
// 옛 본체(받았음 알림 없음)는 그대로 연결된다.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/pairing_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';

import '../helpers/test_helpers.dart';

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
    utf8.encode(jsonEncode(body)), status,
    headers: {'content-type': 'application/json; charset=utf-8'});

final _pending = {'token': 'test-token', 'request_id': 'abcdef-request', 'expires_in': 300};
final _approved = {'state': 'approved', 'api_key': 'new-test-key'};

Future<void> _pairOnce(WidgetTester tester, MockClient client, {List<Override> extra = const []}) async {
  await tester.pumpWidget(buildScreen(
      const PairingScreen(host: 'http://192.0.2.10:8000', code: '012345'),
      overrides: [
        pairingApiFactoryProvider.overrideWithValue((host) => RpiApiService(host, client: client)),
        rpiServerOverride(RpiConnectionState.connected),
        ...extra,
      ]));
  await tester.pumpAndSettle();
  await tester.tap(find.text('연결 요청하기'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('키와 주소를 저장한 뒤 같은 토큰으로 받았음을 알려요', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final acks = <Map<String, dynamic>>[];
    String? keyAtAck;
    String? urlAtAck;
    final client = MockClient((r) async {
      if (r.url.path == '/pair') return _json(_pending);
      if (r.url.path == '/pair/result') return _json(_approved);
      if (r.url.path == '/pair/ack') {
        acks.add(jsonDecode(r.body) as Map<String, dynamic>);
        final prefs = await SharedPreferences.getInstance();
        keyAtAck = prefs.getString('rpi_api_key');
        urlAtAck = prefs.getString('rpi_base_url');
        return _json({'state': 'consumed'});
      }
      return _json({'detail': 'Not Found'}, 404);
    });
    await _pairOnce(tester, client);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(acks, [
      {'token': 'test-token'}
    ]);
    expect(keyAtAck, 'new-test-key', reason: '키를 저장한 뒤에만 받았음을 알린다');
    expect(urlAtAck, 'http://192.0.2.10:8000');
    expect(find.text('본체와 연결했어요.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('허락 결과 응답을 잃으면 같은 토큰으로 다시 물어 키를 받아요', (tester) async {
    SharedPreferences.setMockInitialValues({});
    var results = 0;
    var acks = 0;
    final client = MockClient((r) async {
      if (r.url.path == '/pair') return _json(_pending);
      if (r.url.path == '/pair/result') {
        expect(jsonDecode(r.body), {'token': 'test-token'});
        results++;
        if (results == 1) throw http.ClientException('응답을 잃음'); // 본체는 키를 보냈지만 폰은 못 받았다
        return _json(_approved);
      }
      if (r.url.path == '/pair/ack') {
        acks++;
        return _json({'state': 'consumed'});
      }
      return _json({'detail': 'Not Found'}, 404);
    });
    await _pairOnce(tester, client);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(acks, 0, reason: '키를 받기 전에는 알리지 않는다');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(results, 2);
    expect((await SharedPreferences.getInstance()).getString('rpi_api_key'), 'new-test-key');
    expect(acks, 1);
    expect(find.text('본체와 연결했어요.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('받았음 알림이 없는 옛 본체(404)도 그대로 연결돼요', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final client = MockClient((r) async {
      if (r.url.path == '/pair') return _json(_pending);
      if (r.url.path == '/pair/result') return _json(_approved);
      return _json({'detail': 'Not Found'}, 404);
    });
    await _pairOnce(tester, client);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect((await SharedPreferences.getInstance()).getString('rpi_api_key'), 'new-test-key');
    expect(find.text('본체와 연결했어요.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('키를 저장하지 못했으면 받았음을 알리지 않아요', (tester) async {
    SharedPreferences.setMockInitialValues({});
    var acks = 0;
    final client = MockClient((r) async {
      if (r.url.path == '/pair') return _json(_pending);
      if (r.url.path == '/pair/result') return _json(_approved);
      if (r.url.path == '/pair/ack') acks++;
      return _json({'state': 'consumed'});
    });
    await _pairOnce(tester, client, extra: [rpiApiKeyProvider.overrideWith((ref) => _FailingKeySave())]);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(acks, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

class _FailingKeySave extends RpiApiKeyNotifier {
  @override
  Future<void> save(String key) async => throw StateError('save failed');
}
