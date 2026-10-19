// 가전 추가 5단계(UI 확정 §2, 2026-09-30) — 가짜 사진·가짜 서버로 끝까지 간다.
//
// ① 사진 ② 모서리 4점 ③ 버튼 짚고 이름 ④ 정지 버튼·쉬는 자리 ⑤ 확인 주행.
// 서버에 보내는 것은 사진 크기와 짚은 좌표(px)뿐이고, 확인 주행이 모의면
// 모의라고 말하는지까지 본다.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/hub.dart';
import 'package:simplelay/providers/appliance_provider.dart';
import 'package:simplelay/providers/photo_provider.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/add_appliance_wizard_screen.dart';
import 'package:simplelay/services/photo_service.dart';
import 'package:simplelay/services/rpi_api_service.dart';

import '../helpers/test_helpers.dart';

/// 카메라 없이 사진 한 장을 돌려준다. 크기는 1000x800으로 정해 둔다.
class _FakePhoto extends PhotoService {
  @override
  Future<File?> takePhoto() async => File('panel.jpg');

  @override
  Future<Uint8List> readBytes(File file) async => Uint8List(0);

  @override
  Future<ui.Size?> imageSize(File file) async => const ui.Size(1000, 800);

  /// 문서 폴더로 옮긴 사진 이름(옮긴 순서대로).
  final persisted = <String>[];

  /// 옮기기를 실패시킨다.
  bool failPersist = false;

  @override
  Future<String?> persist(File photo, String id) async {
    if (failPersist) return null;
    persisted.add(id);
    return '/photos/$id.jpg';
  }
}

class _Server {
  final requests = <String>[];
  Map<String, dynamic>? registerBody;
  Map<String, dynamic>? mappingBody;
  bool frameKnown = true;
  int statusCalls = 0;

  /// 사진 매핑 저장을 이 문장으로 거절한다(422).
  String? rejectMapping;

  /// 확인 주행 시작을 이 상태·문장으로 거절한다.
  (int, String)? rejectPass;

  http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
        utf8.encode(jsonEncode(body)),
        status,
        headers: {'content-type': 'application/json'},
      );

  RpiApiService api() => RpiApiService(
        'http://rpi5.local:8000',
        client: MockClient((req) async {
          final path = req.url.path;
          requests.add('${req.method} $path');
          if (path.startsWith('/execute')) fail('가전 추가가 누르기를 보냈어요');
          if (path == '/mapping/frame') {
            return _json({
              'frame_w_mm': frameKnown ? 300.0 : null,
              'frame_h_mm': frameKnown ? 200.0 : null,
              'note': '사진 파일은 서버에 올리지 않아요.',
            });
          }
          if (req.method == 'PUT' && RegExp(r'^/appliances/[^/]+$').hasMatch(path)) {
            registerBody = jsonDecode(utf8.decode(req.bodyBytes)) as Map<String, dynamic>;
            return _json({'id': path.split('/').last, ...registerBody!, 'is_custom': true});
          }
          if (req.method == 'PUT' && path.endsWith('/mapping') && rejectMapping != null) {
            return _json({'detail': rejectMapping}, 422);
          }
          if (req.method == 'POST' && path.endsWith('/verify-pass') && rejectPass != null) {
            return _json({'detail': rejectPass!.$2}, rejectPass!.$1);
          }
          if (req.method == 'PUT' && path.endsWith('/mapping')) {
            mappingBody = jsonDecode(utf8.decode(req.bodyBytes)) as Map<String, dynamic>;
            final id = path.split('/')[2];
            return _json({
              'saved': true,
              'unmapped_buttons': <String>[],
              'stop_park_check': {
                'status': 'unverified',
                'notes': ['소프트 리밋이 없어 범위를 확인하지 못했어요'],
              },
              'appliance': {
                'id': id,
                ...registerBody!,
                'is_custom': true,
                'revision': 2,
                'stop_button': mappingBody!['stop_button'],
                'panel_mapping': {
                  'photo': {'width': 1000, 'height': 800},
                  'corners_px': mappingBody!['corners_px'],
                  'buttons_px': mappingBody!['buttons_px'],
                  'stop_px': null,
                  'park_px': mappingBody!['park_px'],
                },
              },
            });
          }
          if (path.endsWith('/verify-pass')) {
            final done = req.method == 'GET' && ++statusCalls >= 1;
            return _json({
              'state': done ? 'done' : 'running',
              'execution_mode': 'mock',
              'detail': done ? '모든 위치에 도착했다고 응답했어요 — 버튼 위였는지 확인해 주세요' : null,
              'steps': [
                {'button': '시작', 'kind': 'button', 'status': done ? 'reached' : 'pending'},
              ],
            }, req.method == 'POST' ? 202 : 200);
          }
          return _json({'detail': 'not found'}, 404);
        }),
      );
}

Widget _build(_Server server, {void Function(ProviderContainer)? onReady, _FakePhoto? photo}) {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (_, __) => const Scaffold(body: Text('홈')),
        routes: [
          GoRoute(
            path: 'appliance/add',
            builder: (_, __) => const AddApplianceWizardScreen(),
          ),
        ],
      ),
      GoRoute(
        path: '/appliance/new',
        builder: (_, __) => const Scaffold(body: Text('버튼판 편집기')),
      ),
    ],
  );
  return buildWithProviderState(
    overrides: [
      ...connectedOverrides(),
      ...installedOverrides(const []),
      photoServiceProvider.overrideWithValue(photo ?? _FakePhoto()),
      rpiApiServiceProvider.overrideWithValue(server.api()),
    ],
    onContainerReady: onReady,
    child: MaterialApp.router(theme: ThemeData.dark(), routerConfig: router),
  );
}

void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(500, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 16; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// 사진 패널 위 (fx, fy) 비율 자리를 짚는다.
Future<void> _tapPhoto(WidgetTester tester, double fx, double fy) async {
  final box = tester.getRect(find.byKey(const Key('wizard-photo')));
  await tester.tapAt(Offset(box.left + box.width * fx, box.top + box.height * fy));
  await tester.pump();
}

/// ①~③을 지나 ④(정지 버튼과 기다리는 자리)까지 간다. 버튼은 '시작' 하나.
Future<void> _walkToStopStep(WidgetTester tester, {String name = '전자레인지'}) async {
  await tester.tap(find.byKey(const Key('wizard-take-photo')));
  await _settle(tester);
  await _walkToStopStepFromPhoto(tester, name: name);
}

/// 사진을 찍은 ①에서 ④까지.
Future<void> _walkToStopStepFromPhoto(WidgetTester tester, {String name = '전자레인지'}) async {
  await tester.enterText(find.byKey(const Key('wizard-name')), name);
  await tester.pump();
  await tester.tap(find.byKey(const Key('wizard-next')));
  await _settle(tester);
  for (final p in const [(0.1, 0.1), (0.9, 0.1), (0.9, 0.9), (0.1, 0.9)]) {
    await _tapPhoto(tester, p.$1, p.$2);
  }
  await tester.tap(find.byKey(const Key('wizard-next')));
  await tester.pump();
  await _tapPhoto(tester, 0.3, 0.4);
  await _settle(tester);
  await tester.enterText(find.byKey(const Key('wizard-button-name')), '시작');
  await tester.tap(find.text('확인'));
  await _settle(tester);
  await tester.tap(find.byKey(const Key('wizard-next')));
  await tester.pump();
}

String _title(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('wizard-step-title'))).data!;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('다섯 단계를 이전/다음으로 오가며 등록하고 확인 주행까지 간다',
      (tester) async {
    final server = _Server();
    late ProviderContainer container;
    _tall(tester);
    await tester.pumpWidget(_build(server, onReady: (c) => container = c));
    await tester.pump();
    GoRouter.of(tester.element(find.text('홈'))).push('/appliance/add');
    await _settle(tester);

    // ① 사진 — 사진과 이름이 있어야 다음으로 간다.
    expect(_title(tester), '1. 조작부 사진');
    expect(find.byKey(const Key('wizard-back')), findsOneWidget);
    FilledButton next() =>
        tester.widget<FilledButton>(find.byKey(const Key('wizard-next')));
    expect(next().onPressed, isNull);
    await tester.tap(find.byKey(const Key('wizard-take-photo')));
    await _settle(tester);
    await tester.enterText(find.byKey(const Key('wizard-name')), '전자레인지');
    await tester.pump();
    expect(next().onPressed, isNotNull);
    await tester.tap(find.byKey(const Key('wizard-next')));
    await _settle(tester);

    // ② 모서리 4점 — 허브 프레임 치수를 읽는다.
    expect(_title(tester), '2. 버튼판 네 귀퉁이 고르기');
    expect(server.requests, contains('GET /mapping/frame'));
    expect(find.textContaining('가로 300mm'), findsOneWidget);
    expect(next().onPressed, isNull);
    await _tapPhoto(tester, 0.1, 0.1);
    await _tapPhoto(tester, 0.9, 0.1);
    await _tapPhoto(tester, 0.9, 0.9);
    expect(next().onPressed, isNull, reason: '세 점으로는 못 간다');
    await _tapPhoto(tester, 0.1, 0.9);
    expect(next().onPressed, isNotNull);

    // 이전으로 돌아가도 짚은 모서리는 남는다.
    await tester.tap(find.byKey(const Key('wizard-back')));
    await tester.pump();
    expect(_title(tester), '1. 조작부 사진');
    await tester.tap(find.byKey(const Key('wizard-next')));
    await tester.pump();
    expect(_title(tester), '2. 버튼판 네 귀퉁이 고르기');
    expect(next().onPressed, isNotNull);
    await tester.tap(find.byKey(const Key('wizard-next')));
    await tester.pump();

    // ③ 버튼 — 짚고 이름을 붙인다.
    expect(_title(tester), '3. 버튼 고르고 이름 붙이기');
    expect(next().onPressed, isNull);
    await _tapPhoto(tester, 0.3, 0.4);
    await _settle(tester);
    await tester.enterText(find.byKey(const Key('wizard-button-name')), '시작');
    await tester.tap(find.text('확인'));
    await _settle(tester);
    await _tapPhoto(tester, 0.6, 0.4);
    await _settle(tester);
    await tester.enterText(find.byKey(const Key('wizard-button-name')), '취소');
    await tester.tap(find.text('확인'));
    await _settle(tester);
    expect(find.widgetWithText(InputChip, '시작'), findsOneWidget);
    expect(find.widgetWithText(InputChip, '취소'), findsOneWidget);
    await tester.tap(find.byKey(const Key('wizard-next')));
    await tester.pump();

    // ④ 정지 버튼과 쉬는 자리.
    expect(_title(tester), '4. 정지 버튼과 기다리는 자리');
    expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '취소')).selected, isTrue);
    await tester.pump();
    await tester.tap(find.text('2번'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('wizard-park')));
    await tester.pump();
    await _tapPhoto(tester, 0.85, 0.85);
    expect(find.text('저장하고 다음'), findsOneWidget);
    await tester.tap(find.byKey(const Key('wizard-next')));
    await _settle(tester);

    // 저장: 가전 등록 → 사진 매핑. 사진 파일은 보내지 않는다.
    expect(server.requests, containsAllInOrder([
      matches(r'^PUT /appliances/custom_\d+$'),
      matches(r'^PUT /appliances/custom_\d+/mapping$'),
    ]));
    final mapping = server.mappingBody!;
    expect(mapping['photo_width'], 1000);
    expect(mapping['photo_height'], 800);
    expect((mapping['corners_px'] as List).length, 4);
    expect((mapping['buttons_px'] as Map).length, 2);
    expect(mapping['stop_presses'], 2);
    expect(mapping['stop_button'], isNotNull);
    expect(mapping['park_px'], isNotNull);
    expect(mapping.keys.any((k) => k.contains('image')), isFalse);
    // 이 폰에도 남는다(사진 위 자리 포함).
    final saved = container.read(customAppliancesProvider).single;
    expect(saved.name, '전자레인지');
    expect(saved.panelMapping, isA<PanelMapping>());
    expect(saved.panelMapping!.buttons.length, 2);

    // ⑤ 확인 주행 — 모의면 모의라고 말한다.
    expect(_title(tester), '5. 자리 확인');
    expect(find.textContaining('소프트 리밋이 없어'), findsOneWidget);
    await tester.tap(find.byKey(const Key('wizard-start-pass')));
    await _settle(tester);
    await tester.pump(const Duration(milliseconds: 900));
    await _settle(tester);
    expect(server.requests, contains(matches(r'^POST /appliances/custom_\d+/verify-pass$')));
    expect(find.byKey(const Key('wizard-pass-mock')), findsOneWidget);
    expect(find.text('도착했다고 알려 왔어요'), findsOneWidget);

    await tester.tap(find.byKey(const Key('wizard-finish')));
    await _settle(tester);
    expect(find.text('홈'), findsOneWidget);
  });

  testWidgets('허브에 프레임 치수가 없으면 적게 하고, 적기 전에는 못 넘어간다',
      (tester) async {
    final server = _Server()..frameKnown = false;
    _tall(tester);
    await tester.pumpWidget(_build(server));
    await tester.pump();
    GoRouter.of(tester.element(find.text('홈'))).push('/appliance/add');
    await _settle(tester);

    await tester.tap(find.byKey(const Key('wizard-take-photo')));
    await _settle(tester);
    await tester.enterText(find.byKey(const Key('wizard-name')), '세탁기');
    await tester.pump();
    await tester.tap(find.byKey(const Key('wizard-next')));
    await _settle(tester);

    for (final p in const [(0.1, 0.1), (0.9, 0.1), (0.9, 0.9), (0.1, 0.9)]) {
      await _tapPhoto(tester, p.$1, p.$2);
    }
    FilledButton next() =>
        tester.widget<FilledButton>(find.byKey(const Key('wizard-next')));
    expect(find.textContaining('버튼판 크기를 아직 몰라요'), findsOneWidget);
    expect(next().onPressed, isNull);
    await tester.enterText(find.byKey(const Key('wizard-frame-w')), '300');
    await tester.enterText(find.byKey(const Key('wizard-frame-h')), '200');
    await tester.pump();
    expect(next().onPressed, isNotNull);
  });

  test('짚은 자리를 버튼판 행·열로 옮긴다 — 같은 줄은 가로 순서대로', () {
    final grid = gridFromPoints([
      ('b', '30초', const PhotoPoint(500, 105)),
      ('a', '10초', const PhotoPoint(100, 100)),
      ('c', '시작', const PhotoPoint(300, 400)),
    ], rowTolerance: 48);
    expect(grid.rows, 2);
    expect(grid.cols, 2);
    final byId = {for (final b in grid.buttons) b.id: b};
    expect((byId['a']!.x, byId['a']!.y), (0, 0));
    expect((byId['b']!.x, byId['b']!.y), (1, 0));
    expect((byId['c']!.x, byId['c']!.y), (0, 1));
  });

  testWidgets('저장이 거절되면 그 문장이 단추 바로 위에 보인다 — 목록 맨 아래에 숨지 않는다(실화면 10/19)',
      (tester) async {
    final server = _Server()..rejectMapping = '기다리는 자리가 버튼판 밖이에요';
    _tall(tester);
    await tester.pumpWidget(_build(server));
    await tester.pump();
    GoRouter.of(tester.element(find.text('홈'))).push('/appliance/add');
    await _settle(tester);
    await _walkToStopStep(tester);
    expect(_title(tester), '4. 정지 버튼과 기다리는 자리');

    // 보통 폰 크기 — 사진과 설명으로 목록이 화면보다 길다.
    tester.view.physicalSize = const Size(400, 800);
    await tester.pump();
    await tester.tap(find.byKey(const Key('wizard-next')));
    await _settle(tester);

    expect(find.text('기다리는 자리가 버튼판 밖이에요').hitTestable(), findsOneWidget,
        reason: '스크롤하지 않아도 보여야 한다');
    final error = tester.getRect(find.byKey(const Key('wizard-error')));
    final next = tester.getRect(find.byKey(const Key('wizard-next')));
    expect(error.bottom, lessThanOrEqualTo(next.top));
    expect(_title(tester), '4. 정지 버튼과 기다리는 자리', reason: '거절되면 다음 단계로 가지 않는다');
  });

  testWidgets('사진은 찍자마자 이 폰 문서 폴더로 옮기고 그 경로로 등록한다 — 저장까지 캐시에 두지 않는다(실화면 10/19)',
      (tester) async {
    final server = _Server();
    final photo = _FakePhoto();
    late ProviderContainer container;
    _tall(tester);
    await tester.pumpWidget(_build(server, onReady: (c) => container = c, photo: photo));
    await tester.pump();
    GoRouter.of(tester.element(find.text('홈'))).push('/appliance/add');
    await _settle(tester);

    await tester.tap(find.byKey(const Key('wizard-take-photo')));
    await _settle(tester);
    expect(photo.persisted, hasLength(1), reason: '찍은 그 자리에서 옮긴다');
    expect(find.byKey(const Key('wizard-error')), findsNothing);

    // 같은 등록에서 다시 찍으면 새로 옮긴다.
    await tester.tap(find.text('다시 찍기'));
    await _settle(tester);
    expect(photo.persisted, hasLength(2));

    await _walkToStopStepFromPhoto(tester);
    await tester.tap(find.byKey(const Key('wizard-next')));
    await _settle(tester);
    expect(_title(tester), '5. 자리 확인');
    final saved = container.read(customAppliancesProvider).single;
    expect(saved.photoPath, '/photos/${photo.persisted.last}.jpg');
    expect(photo.persisted, hasLength(2), reason: '저장할 때 또 옮기지 않는다');
  });

  testWidgets('사진을 이 폰에 남기지 못하면 그렇다고 말한다', (tester) async {
    final server = _Server();
    final photo = _FakePhoto()..failPersist = true;
    _tall(tester);
    await tester.pumpWidget(_build(server, photo: photo));
    await tester.pump();
    GoRouter.of(tester.element(find.text('홈'))).push('/appliance/add');
    await _settle(tester);
    await tester.tap(find.byKey(const Key('wizard-take-photo')));
    await _settle(tester);
    expect(find.textContaining('사진을 이 폰에 남기지 못했어요'), findsOneWidget);
  });
}
