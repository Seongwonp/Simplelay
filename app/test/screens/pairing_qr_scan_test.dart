// 시연에서 카메라 앱을 따로 열거나 주소를 적어야 연결되는 것이 불편했다. 앱 안에서 QR을 찍으면 바로 연결을 요청하고,
// 카메라를 못 쓰면 코드로 이어 가며, 주소는 본체를 찾지 못했을 때만 묻는다. 실제 카메라는 시험하지 못하므로 경계만 바꾼다.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/pairing_screen.dart';
import 'package:simplelay/services/mdns_resolver.dart';
import 'package:simplelay/services/pairing_qr.dart';
import 'package:simplelay/services/rpi_api_service.dart';
import 'package:simplelay/widgets/qr_camera_view.dart';

import '../helpers/test_helpers.dart';

const _validQr =
    'simplelay://pair?host=http%3A%2F%2F192.0.2.10%3A8000&code=012345';

class _FakeCamera {
  late ValueChanged<String> onCode;
  late ValueChanged<QrCameraProblem> onProblem;

  Widget build({
    required ValueChanged<String> onCode,
    required ValueChanged<QrCameraProblem> onProblem,
  }) {
    this.onCode = onCode;
    this.onProblem = onProblem;
    return const SizedBox.expand(key: Key('fake-camera'));
  }
}

class _FakeMdns implements MdnsResolver {
  _FakeMdns(this.ip);
  final String? ip;
  final asked = <String>[];
  @override
  Future<String?> resolveIPv4(String host,
      {Duration timeout = const Duration(seconds: 3)}) async {
    asked.add(host);
    return ip;
  }
}

/// 받은 요청의 주소와 코드를 모으고, 허락을 기다리는 본체처럼 답한다.
class _Hub {
  final hosts = <String>[];
  final codes = <String>[];
  bool reachable = true;

  late final client = MockClient((r) async {
    if (!reachable) throw http.ClientException('닿지 않음');
    if (r.url.path == '/pair') {
      hosts.add(r.url.host);
      codes.add(jsonDecode(r.body)['code'] as String);
      return http.Response(
          jsonEncode({
            'token': 'test-token',
            'request_id': 'abcdef-request',
            'expires_in': 300
          }),
          200);
    }
    return http.Response(jsonEncode({'state': 'pending'}), 200);
  });
}

Future<void> _open(WidgetTester tester, _Hub hub,
    {_FakeCamera? camera, _FakeMdns? mdns}) async {
  await tester.pumpWidget(buildScreen(const PairingScreen(), overrides: [
    pairingApiFactoryProvider
        .overrideWithValue((host) => RpiApiService(host, client: hub.client)),
    rpiServerOverride(RpiConnectionState.unconfigured),
    if (camera != null) qrCameraViewProvider.overrideWithValue(camera.build),
    if (mdns != null) mdnsResolverProvider.overrideWithValue(mdns),
  ]));
  await tester.pumpAndSettle();
}

Future<void> _openScanner(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('pair-scan')));
  await tester.pumpAndSettle();
  expect(find.byKey(const Key('fake-camera')), findsOneWidget);
}

/// 기다리기 타이머를 남기지 않고 끝낸다.
Future<void> _close(WidgetTester tester) =>
    tester.pumpWidget(const SizedBox.shrink());

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('맞는 QR을 찍으면 더 누르지 않아도 그 본체에 연결을 요청해요', (tester) async {
    final hub = _Hub();
    final camera = _FakeCamera();
    await _open(tester, hub, camera: camera);
    await _openScanner(tester);

    camera.onCode(_validQr);
    camera.onCode(_validQr); // 닫히는 동안 또 읽혀도 요청은 한 번
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('fake-camera')), findsNothing);
    expect(hub.hosts, ['192.0.2.10']);
    expect(hub.codes, ['012345']);
    expect(find.text('본체 화면에서 이 폰 연결을 허락해 주세요.'), findsOneWidget);
    expect(find.textContaining('abcdef'), findsOneWidget, reason: '두 화면 대조는 그대로');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('rpi_api_key'), isNull, reason: '본체가 허락하기 전에는 키가 없다');
    await _close(tester);
  });

  for (final wrong in [
    'https://example.com/pair?host=192.0.2.10&code=012345',
    'simplelay://other?host=192.0.2.10&code=012345',
    'simplelay://pair?host=http%3A%2F%2F192.0.2.10%3A8000&code=12',
    'simplelay://pair?code=012345',
    'simplelay://pair?host=http%3A%2F%2Fuser%40192.0.2.10%3A8000&code=012345',
    '012345',
  ]) {
    testWidgets('다른 QR은 쉬운 말로 거절하고 계속 찍어요: $wrong', (tester) async {
      final hub = _Hub();
      final camera = _FakeCamera();
      await _open(tester, hub, camera: camera);
      await _openScanner(tester);

      camera.onCode(wrong);
      await tester.pumpAndSettle();
      expect(find.text(kNotPairingQrMessage), findsOneWidget);
      expect(find.byKey(const Key('fake-camera')), findsOneWidget);
      expect(hub.hosts, isEmpty);

      camera.onCode(_validQr);
      await tester.pumpAndSettle();
      expect(hub.codes, ['012345'], reason: '거절 뒤에도 맞는 QR을 읽는다');
      await _close(tester);
    });
  }

  for (final (problem, expected) in [
    (QrCameraProblem.permissionDenied, '카메라를 쓸 수 있게 허락되지 않았어요'),
    (QrCameraProblem.unavailable, '이 폰에서는 카메라를 쓸 수 없어요'),
  ]) {
    testWidgets('카메라를 못 쓰면 코드로 이어 가요: $problem', (tester) async {
      final hub = _Hub();
      final camera = _FakeCamera();
      await _open(tester, hub, camera: camera);
      await _openScanner(tester);

      camera.onProblem(problem);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('fake-camera')), findsNothing);
      expect(find.textContaining(expected), findsOneWidget);
      expect(find.text('여섯 자리 숫자'), findsOneWidget);
      expect(find.text('본체 주소'), findsNothing);
      expect(find.text('연결 요청하기'), findsOneWidget);
      await _close(tester);
    });
  }

  testWidgets('뒤로 나오면 연결 요청 없이 처음 화면이에요', (tester) async {
    final hub = _Hub();
    final camera = _FakeCamera();
    await _open(tester, hub, camera: camera);
    await _openScanner(tester);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(hub.hosts, isEmpty);
    expect(find.text('여섯 자리 숫자'), findsNothing);
    expect(find.byKey(const Key('pair-message')), findsNothing);
  });

  testWidgets('코드만 적어도 simplelay.local을 찾아 연결하고 주소는 묻지 않아요', (tester) async {
    final hub = _Hub();
    final mdns = _FakeMdns('192.0.2.20');
    await _open(tester, hub, mdns: mdns);
    await tester.tap(find.text('코드로 연결하기'));
    await tester.pumpAndSettle();
    expect(find.text('본체 주소'), findsNothing);

    await tester.enterText(find.widgetWithText(TextField, '여섯 자리 숫자'), '012345');
    await tester.tap(find.text('연결 요청하기'));
    await tester.pumpAndSettle();

    expect(mdns.asked, ['simplelay.local']);
    expect(hub.hosts, ['192.0.2.20']);
    expect(find.text('본체 주소'), findsNothing);
    await _close(tester);
  });

  testWidgets('저장된 주소가 있으면 코드만 적어 그 주소로 연결해요', (tester) async {
    SharedPreferences.setMockInitialValues(
        {'rpi_base_url': 'http://192.0.2.30:8000'});
    final hub = _Hub();
    await _open(tester, hub);
    await tester.tap(find.text('코드로 연결하기'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '여섯 자리 숫자'), '012345');
    await tester.tap(find.text('연결 요청하기'));
    await tester.pumpAndSettle();
    expect(hub.hosts, ['192.0.2.30']);
    expect(find.text('본체 주소'), findsNothing);
    await _close(tester);
  });

  testWidgets('본체를 찾지 못하면 그때 주소 칸을 보여 주고, 고쳐서 다시 연결해요', (tester) async {
    final hub = _Hub()..reachable = false;
    await _open(tester, hub, mdns: _FakeMdns(null));
    await tester.tap(find.text('코드로 연결하기'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '여섯 자리 숫자'), '012345');
    await tester.tap(find.text('연결 요청하기'));
    await tester.pumpAndSettle();

    expect(find.textContaining('주소가 맞는지 봐 주세요'), findsOneWidget);
    final address = find.widgetWithText(TextField, '본체 주소');
    expect(address, findsOneWidget);

    hub.reachable = true;
    await tester.enterText(address, '192.0.2.40');
    await tester.tap(find.text('연결 요청하기'));
    await tester.pumpAndSettle();
    expect(hub.hosts, ['192.0.2.40']);
    await _close(tester);
  });

  group('QR 내용 판단', () {
    test('주소를 정규화해요', () {
      final qr = PairingQr.tryParse(_validQr)!;
      expect(qr.host, 'http://192.0.2.10:8000');
      expect(qr.code, '012345');
    });

    test('본체가 만든 형식을 그대로 받아요', () {
      // rpi/api/pairing.py의 urlencode 결과와 같은 모양.
      final qr = PairingQr.tryParse(
          'simplelay://pair?host=http%3A%2F%2Fsimplelay.local%3A8000&code=123456');
      expect(qr?.host, 'http://simplelay.local:8000');
    });
  });
}
