// 서버에만 등록된 사용자 가전도 홈에 보인다 (2026-10-07 에뮬레이터 결함).
//
// 실제 RPi5의 GET /appliances는 5대(시험용 전자레인지·Phone-MW·전자레인지·
// 세탁기·인터폰)를 돌려주는데, 홈에는 이 폰이 등록한 2대만 보였다. 나머지
// 3대는 PUT /appliances/<id>로 서버에 바로 올린 사용자 가전(is_custom=true)이라
// 내장 목록에서 걸러지고, 동기화 병합(저장·다시 보내기 때만 돈다)도 오지 않았다.
// 위치를 맞추지 않은 가전도 숨기지 않는다 -- 상태로 말할 뿐이다.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/appliance.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/home_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';

import '../helpers/test_helpers.dart';

Map<String, dynamic> _serverAppliance(
  String id,
  String name,
  String category, {
  bool canExecute = false,
}) =>
    {
      'id': id,
      'name': name,
      'category': category,
      'rows': 1,
      'cols': 2,
      'is_custom': true,
      'revision': 1,
      'can_execute': canExecute,
      'readiness': canExecute ? 'operable' : 'needs_setup',
      'readiness_reasons': canExecute ? <String>[] : ['좌표를 아직 맞추지 않았어요'],
      'buttons': [
        {'id': '$id-1', 'label': '전원', 'x': 0, 'y': 0},
        {'id': '$id-2', 'label': '시작', 'x': 1, 'y': 0},
      ],
    };

/// 2026-10-07 RPi5가 돌려준 목록과 같은 모양.
final kServerFive = [
  _serverAppliance('test_microwave', '시험용 전자레인지', 'microwave'),
  _serverAppliance('custom_1790777692424', 'Phone-MW', 'microwave'),
  _serverAppliance('home_mw', '전자레인지', 'microwave'),
  _serverAppliance('washer', '세탁기', 'washing_machine'),
  _serverAppliance('intercom', '인터폰', 'intercom'),
];

RpiApiService serverWithAppliances(List<Map<String, dynamic>> list) =>
    RpiApiService(
      'http://rpi5.local:8000',
      client: MockClient((req) async {
        if (req.method == 'GET' && req.url.path == '/appliances') {
          return http.Response.bytes(
            utf8.encode(jsonEncode(list)),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('{"detail":"not found"}', 404);
      }),
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('서버의 가전 5대가 홈에 모두 보인다 -- 이 폰이 등록한 2대만이 아니다',
      (tester) async {
    tester.view.physicalSize = const Size(400, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 이 폰에는 두 대만 저장돼 있다(예전에 병합으로 받았거나 직접 등록).
    final own = [
      ApplianceMap.fromJson(kServerFive[0]),
      ApplianceMap.fromJson(kServerFive[1]),
    ];
    await tester.pumpWidget(buildScreen(
      const HomeScreen(),
      overrides: [
        ...connectedOverrides(),
        ...installedOverrides(own),
        rpiServerOverride(RpiConnectionState.connected),
        rpiApiServiceProvider.overrideWithValue(
            serverWithAppliances(kServerFive)),
      ],
    ));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    for (final a in kServerFive) {
      expect(find.byKey(Key('appliance-card-${a['id']}')), findsOneWidget,
          reason: '${a['name']} 카드가 홈에 있어야 한다');
    }
    expect(find.byKey(const Key('appliance-add-card')), findsOneWidget);
    // 숨기지 않되, 준비가 안 됐다는 사실은 글자로 말한다. 위치를 아직 맞추지
    // 않은 사용자 가전은 '설정이 필요해요'(2026-10-13 타일 상태).
    expect(find.text('설정이 필요해요'), findsNWidgets(5));
  });

  setupSummaryTests();
}

// 설정이 남은 가전이 여럿이면 홈에 카드 한 장으로 묶는다 (2026-10-07 에뮬레이터).
//
// 한 대마다 '설정이 2개 남았어요' 카드를 쌓았더니 5대에서 '가전' 묶음이 첫
// 화면 밖으로 밀렸다. 1080x2400 @2.625(약 411x914) 폰 화면 기준.
//
// 홈은 실제로 상태 표시줄(위 24dp) 아래, 하단 탭(NavigationBar 80dp) 위에
// 그려진다. 이 테스트는 홈만 띄우므로 위는 view padding으로 주고, 아래는
// 탭 높이만큼 뺀 선을 '첫 화면'의 끝으로 본다.
const double _kStatusBar = 24;
const double _kBottomTabs = 80;
const double _kLogicalHeight = 2400 / 2.625; // ≈ 914
const double _kFirstScreenBottom = _kLogicalHeight - _kBottomTabs;

void _phoneViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.625;
  tester.view.padding =
      const FakeViewPadding(top: _kStatusBar * 2.625);
  tester.view.viewPadding =
      const FakeViewPadding(top: _kStatusBar * 2.625);
  addTearDown(tester.view.reset);
}

RpiApiService _countingServer(
  List<Map<String, dynamic>> list,
  List<Uri> verifyCalls,
) =>
    RpiApiService(
      'http://rpi5.local:8000',
      client: MockClient((req) async {
        if (req.method == 'GET' && req.url.path == '/appliances') {
          return http.Response.bytes(
            utf8.encode(jsonEncode(list)),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (req.url.path.endsWith('/verify-pass')) verifyCalls.add(req.url);
        return http.Response('{"detail":"not found"}', 404);
      }),
    );

Future<void> _pumpHome(
  WidgetTester tester,
  List<Map<String, dynamic>> server,
  List<Uri> verifyCalls,
) async {
  await tester.pumpWidget(buildScreen(
    const HomeScreen(),
    overrides: [
      ...connectedOverrides(),
      ...installedOverrides(const []),
      rpiServerOverride(RpiConnectionState.connected),
      rpiApiServiceProvider
          .overrideWithValue(_countingServer(server, verifyCalls)),
    ],
  ));
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void setupSummaryTests() {
  testWidgets('설정이 남은 가전 5대는 요약 카드 한 장 -- 가전 묶음이 첫 화면에 보인다',
      (tester) async {
    _phoneViewport(tester);
    final verifyCalls = <Uri>[];
    await _pumpHome(tester, kServerFive, verifyCalls);

    expect(find.byKey(const Key('setup-summary-card')), findsOneWidget);
    expect(find.text('설정이 남은 가전 5개'), findsOneWidget);
    expect(find.text('시험용 전자레인지, Phone-MW, 전자레인지 외 2개'), findsOneWidget);
    expect(find.text('설정 이어하기'), findsOneWidget);
    expect(find.textContaining('설정이 2개 남았어요'), findsNothing,
        reason: '가전마다 카드를 쌓지 않는다');

    final header = find.text('가전');
    expect(header, findsOneWidget, reason: '가전 묶음 제목이 그려져야 한다');
    expect(tester.getRect(header).bottom,
        lessThanOrEqualTo(_kFirstScreenBottom),
        reason: '가전 묶음 제목이 첫 화면 안에 있어야 한다');
    // 제목만이 아니라 가전 카드 첫 줄까지 첫 화면에 보여야 한다.
    final firstCard = find.byKey(const Key('appliance-card-test_microwave'));
    expect(firstCard, findsOneWidget);
    expect(tester.getRect(firstCard).bottom,
        lessThanOrEqualTo(_kFirstScreenBottom),
        reason: '가전 카드 첫 줄이 첫 화면 안에 있어야 한다');

    // 위치를 아직 안 맞춘 가전은 확인 주행 상태를 물을 필요가 없다.
    expect(verifyCalls, isEmpty);
  });

  testWidgets('설정 이어하기를 누르면 가전마다 위치 맞추기가 있는 목록이 열린다',
      (tester) async {
    _phoneViewport(tester);
    await _pumpHome(tester, kServerFive.take(2).toList(), <Uri>[]);

    expect(find.text('설정이 남은 가전 2개'), findsOneWidget);
    expect(find.text('시험용 전자레인지, Phone-MW'), findsOneWidget);
    await tester.tap(find.text('설정 이어하기'));
    await tester.pumpAndSettle();

    expect(find.text('시험용 전자레인지 · 설정이 2개 남았어요'), findsOneWidget);
    expect(find.text('Phone-MW · 설정이 2개 남았어요'), findsOneWidget);
    expect(find.text('위치 맞추기'), findsNWidgets(2));
  });

  testWidgets('설정이 남은 가전이 한 대면 지금처럼 그 가전 카드를 그대로 보인다',
      (tester) async {
    _phoneViewport(tester);
    await _pumpHome(tester, [kServerFive[3]], <Uri>[]);

    expect(find.byKey(const Key('setup-summary-card')), findsNothing);
    expect(find.text('세탁기 · 설정이 2개 남았어요'), findsOneWidget);
    expect(find.text('위치 맞추기'), findsOneWidget);
  });
}
