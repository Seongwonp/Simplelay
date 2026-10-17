// 'LG 가전 연결' 화면 첫 문장과 설정 줄 부제 (2026-10-15 외부 검토 M3).
//
// 확인 중·확인 실패를 'ThinQ 계정이 연결되지 않았어요'로 말하지 않는다. 그 말은 허브가
// ThinQ를 껐다고 답했을 때(GET /thinq/devices 404)만 한다. 조회 실패는 null이 아니라
// 오류로 올라온다(RpiApiService.thinqOverview).
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/providers/ble_provider.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/settings_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';

import '../helpers/test_helpers.dart';

const _off = '본체에 LG 계정이 아직 연결되지 않았어요. 설치하는 분이 연결해요.';
const _failed = 'LG 가전이 연결됐는지 몰라요. 본체 연결을 봐 주세요.';
const _loading = '연결을 알아보는 중이에요.';

RpiApiService _api() => RpiApiService('http://rpi5.local:8000',
    client: MockClient((_) async => http.Response('{"detail":"not found"}', 404)));

Widget _settings(FutureOr<RpiThinqOverview?> Function() overview,
        {RpiApiService? api}) =>
    buildScreen(
      const SettingsScreen(),
      overrides: [
        scanResultsProvider.overrideWith((ref) => Stream.value(const [])),
        ...installedOverrides([kTestAppliance]),
        rpiServerOverride(RpiConnectionState.connected),
        rpiApiServiceProvider.overrideWithValue(api ?? _api()),
        thinqOverviewProvider.overrideWith((ref) async => overview()),
      ],
    );

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _openThinq(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(ListTile, 'LG 가전 연결'));
  await _settle(tester);
}

String _headline(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('thinq-link-headline'))).data!;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  void tall(WidgetTester tester) {
    tester.view.physicalSize = const Size(400, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('확인 중이면 "확인하는 중" — 연결 안 됨이라 하지 않는다', (tester) async {
    tall(tester);
    final never = Completer<RpiThinqOverview?>();
    await tester.pumpWidget(_settings(() => never.future));
    await _settle(tester);
    expect(findPlainText('알아보고 있어요'), findsOneWidget);
    expect(find.text('아직 연결 전이에요'), findsNothing);

    await _openThinq(tester);
    expect(_headline(tester), _loading);
    expect(find.textContaining('연결되지 않았어요'), findsNothing);
  });

  testWidgets('조회 실패면 "확인하지 못했어요" — 연결 안 됨이라 하지 않는다', (tester) async {
    tall(tester);
    await tester.pumpWidget(
        _settings(() => throw http.ClientException('hub unreachable')));
    await _settle(tester);
    expect(findPlainText('연결됐는지 몰라요'), findsOneWidget);
    expect(find.text('아직 연결 전이에요'), findsNothing);

    await _openThinq(tester);
    expect(_headline(tester), _failed);
    expect(find.textContaining('연결되지 않았어요'), findsNothing);
  });

  testWidgets('허브가 ThinQ를 껐다고 답하면(null) 그때만 "아직 연결되지 않았어요"', (tester) async {
    tall(tester);
    await tester.pumpWidget(_settings(() => null));
    await _settle(tester);
    expect(findPlainText('아직 연결 전이에요'), findsOneWidget);

    await _openThinq(tester);
    expect(_headline(tester), _off);
  });

  testWidgets('가전이 있으면 가전 상세에서 보고 바꿀 수 있다고 말한다(누를 버튼이 없어 말로만 X)',
      (tester) async {
    tall(tester);
    await tester.pumpWidget(_settings(() => const RpiThinqOverview(
          mode: 'real',
          executionMode: 'real',
          appliances: [
            RpiThinqAppliance(
                applianceId: 'air_purifier', name: '공기청정기', state: 'operable', canExecute: true),
          ],
        )));
    await _settle(tester);
    await _openThinq(tester);
    expect(_headline(tester), contains('가전 화면에서 지금 상태를 보고 바꿀 수 있어요'));
    expect(_headline(tester), contains('루틴에도 넣을 수 있어요'));
    expect(find.textContaining('목적(말)과 루틴으로 맡겨요'), findsNothing);
  });

  group('RpiApiService.thinqOverview', () {
    RpiApiService serving(Future<http.Response> Function() respond) =>
        RpiApiService('http://rpi5.local:8000',
            client: MockClient((_) => respond()));

    test('404(허브가 ThinQ를 끔)만 null', () async {
      expect(
          await serving(() async => http.Response('{"detail":"off"}', 404))
              .thinqOverview(),
          isNull);
    });

    test('그 밖의 오류 응답은 예외 — null(연결 안 됨)로 뭉개지 않는다', () async {
      await expectLater(
          serving(() async => http.Response('{"detail":"boom"}', 500))
              .thinqOverview(),
          throwsA(isA<RpiApiException>()));
    });

    test('연결 오류도 예외', () async {
      await expectLater(
          serving(() async => throw http.ClientException('down')).thinqOverview(),
          throwsA(isA<http.ClientException>()));
    });

    test('200은 목록', () async {
      final o = await serving(() async => http.Response.bytes(
              utf8.encode(jsonEncode({
                'mode': 'mock',
                'execution_mode': 'mock',
                'appliances': [
                  {'appliance_id': 'air_purifier', 'name': '공기청정기'}
                ],
              })),
              200))
          .thinqOverview();
      expect(o!.appliances.single.applianceId, 'air_purifier');
    });
  });
}
