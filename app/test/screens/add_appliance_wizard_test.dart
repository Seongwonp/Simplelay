// 가전 추가 5단계(UI 확정 §2, 2026-09-30) — 가짜 사진·가짜 서버로 끝까지 간다.
//
// ① 사진 ② 누름 장치 칸 맞추기(mm를 적지 않는다, 10/26) ③ 버튼 짚고 이름 ④ 정지 버튼·기다리는 자리 ⑤ 확인 주행.
// 서버에 보내는 것은 사진 크기와 짚은 좌표(px)뿐이고, 확인 주행이 모의면
// 모의라고 말하는지까지 본다.
import 'dart:convert';
import 'dart:io';
import 'dart:math' show min;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/appliance.dart';
import 'package:simplelay/models/display_status.dart' show nameTakenMessage;
import 'package:simplelay/models/hub.dart';
import 'package:simplelay/providers/appliance_provider.dart';
import 'package:simplelay/providers/photo_provider.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/add_appliance_wizard_screen.dart';
import 'package:simplelay/services/photo_service.dart';
import 'package:simplelay/services/rpi_api_service.dart';
import 'package:simplelay/widgets/panel_photo_view.dart';

import '../helpers/test_helpers.dart';

/// 시험 중에 본체 연결 상태를 바꿀 수 있는 연결 상태.
class _SwitchableConnection extends FixedRpiConnection {
  _SwitchableConnection(super.ref, super.fixed);
  void set(RpiConnectionState next) => state = next;
}

/// 카메라 없이 사진 한 장을 돌려준다. 크기는 1000x800으로 정해 둔다.
class _FakePhoto extends PhotoService {
  /// 마지막 사진을 사진첩에서 골랐나(10/25).
  bool? fromGallery;

  @override
  Future<File?> takePhoto({bool fromGallery = false}) async {
    this.fromGallery = fromGallery;
    return File('panel.jpg');
  }

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

  /// 옛 본체처럼 `workspace` 없이 `frame_w_mm`만 준다.
  bool legacyFrame = false;
  int statusCalls = 0;

  /// 사진 매핑 저장을 이 문장으로 거절한다([rejectMappingStatus], 기본 422).
  String? rejectMapping;
  int rejectMappingStatus = 422;

  /// 등록(PUT /appliances/{id})이 돌려주는 판 번호.
  int registerRevision = 1;

  /// 지우기(DELETE /appliances/{id}) 요청의 쿼리. [deleteFails]면 500으로 답한다.
  final deletes = <Map<String, String>>[];
  bool deleteFails = false;

  /// 다시 맞추기에서 본체가 이미 아는 정의(등록 PUT 없이 매핑만 저장할 때 응답에 싣는다).
  Map<String, dynamic>? existing;

  /// 확인 주행 시작을 이 상태·문장으로 거절한다.
  (int, String)? rejectPass;

  /// 자리 확인 상태 조회(GET)마다 (지연, 끝남) — 마지막 것이 이어진다. 없으면 첫 조회부터 끝남.
  List<(Duration, bool)>? passScript;

  /// 본체에 닿지 않는다(연결 오류).
  bool unreachable = false;

  /// `GET /kit` 응답. 기본은 찾았고 맡은 가전 없음.
  Map<String, dynamic> kit = {
    'found': true, 'kit_id': 'kit-a', 'motion': 'serial', 'motion_present': true, 'outlet': 'real',
    'outlet_present': true, 'homed': true, 'bound_appliance': null, 'name': null, 'verified': false,
  };

  /// 받은 `POST /kit/bind` 본문.
  final bindBodies = <Map<String, dynamic>>[];

  /// 있으면 세트 연결을 이 문장으로 거절한다.
  String? bindReject;

  /// 등록·자리 저장을 본체가 해 놓고 답만 잃는다(검토 10/19). [mappingLostSaved]가 false면 자리 저장은 하지 않고 답을 잃는다.
  bool registerAnswerLost = false;
  bool mappingAnswerLost = false;
  bool mappingLostSaved = true;

  /// 본체 목록(GET /appliances)에 보이는 이 가전 — 등록·자리 저장이 고친다.
  Map<String, dynamic>? stored;

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
          if (unreachable) throw const SocketException('본체에 닿지 않음');
          if (path.startsWith('/execute')) fail('가전 추가가 누르기를 보냈어요');
          if (path == '/kit') return _json(kit);
          if (path == '/kit/bind') {
            bindBodies.add(jsonDecode(utf8.decode(req.bodyBytes)) as Map<String, dynamic>);
            if (bindReject != null) return _json({'detail': bindReject}, 409);
            return _json({...kit, 'bound_appliance': bindBodies.last['appliance_id'], 'verified': false});
          }
          if (path == '/mapping/frame') {
            return _json({
              'frame_w_mm': frameKnown ? 300.0 : null,
              'frame_h_mm': frameKnown ? 200.0 : null,
              'y_up': true,
              if (!legacyFrame)
                'workspace': frameKnown
                    ? {'w_mm': 300.0, 'h_mm': 200.0, 'origin_x_mm': 0, 'origin_y_mm': 0, 'y_up': true,
                       'source': 'workspace'}
                    : null,
              'note': '사진 파일은 서버에 올리지 않아요.',
            });
          }
          if (req.method == 'DELETE' && RegExp(r'^/appliances/[^/]+$').hasMatch(path)) {
            deletes.add(req.url.queryParameters);
            return deleteFails ? _json({'detail': 'db error'}, 500) : _json({'ok': true});
          }
          if (req.method == 'GET' && path == '/appliances') {
            return _json([if (stored != null) stored]);
          }
          if (req.method == 'PUT' && RegExp(r'^/appliances/[^/]+$').hasMatch(path)) {
            registerBody = jsonDecode(utf8.decode(req.bodyBytes)) as Map<String, dynamic>;
            stored = {
              'id': path.split('/').last,
              ...registerBody!,
              'is_custom': true,
              'revision': registerRevision,
            };
            if (registerAnswerLost) throw http.ClientException('응답 받는 중 끊김');
            return _json(stored!);
          }
          if (req.method == 'PUT' && path.endsWith('/mapping') && rejectMapping != null) {
            mappingBody = jsonDecode(utf8.decode(req.bodyBytes)) as Map<String, dynamic>;
            return _json({'detail': rejectMapping}, rejectMappingStatus);
          }
          if (req.method == 'POST' && path.endsWith('/verify-pass') && rejectPass != null) {
            return _json({'detail': rejectPass!.$2}, rejectPass!.$1);
          }
          if (req.method == 'PUT' && path.endsWith('/mapping')) {
            mappingBody = jsonDecode(utf8.decode(req.bodyBytes)) as Map<String, dynamic>;
            if (mappingAnswerLost && !mappingLostSaved) throw http.ClientException('응답 받는 중 끊김');
            final id = path.split('/')[2];
            final appliance = {
              'id': id,
              ...?(registerBody ?? existing),
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
            };
            stored = appliance;
            if (mappingAnswerLost) throw http.ClientException('응답 받는 중 끊김');
            return _json({
              'saved': true,
              'unmapped_buttons': <String>[],
              'stop_park_check': {
                'status': 'unverified',
                'notes': ['소프트 리밋이 없어 범위를 확인하지 못했어요'],
              },
              'appliance': appliance,
            });
          }
          if (path.endsWith('/verify-pass')) {
            final script = passScript;
            final call = req.method == 'GET' ? ++statusCalls : 0;
            if (script != null && call > 0) await Future<void>.delayed(script[min(call, script.length) - 1].$1);
            final done = call >= 1 && (script == null || script[min(call, script.length) - 1].$2);
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

Widget _build(_Server server,
    {void Function(ProviderContainer)? onReady,
    _FakePhoto? photo,
    List<ApplianceMap> installed = const [],
    RpiConnectionState hub = RpiConnectionState.connected,
    Override? connection}) {
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
          GoRoute(
            path: 'appliance/setup',
            builder: (_, state) => AddApplianceWizardScreen(initial: state.extra as ApplianceMap),
          ),
        ],
      ),
      GoRoute(
        path: '/appliance/new',
        builder: (_, __) => const Scaffold(body: Text('버튼판 편집기')),
      ),
      GoRoute(
        path: '/settings/hub',
        builder: (_, __) => const Scaffold(body: Text('본체 연결 화면')),
      ),
    ],
  );
  return buildWithProviderState(
    overrides: [
      ...connectedOverrides(),
      connection ?? rpiServerOverride(hub),
      ...installedOverrides(installed),
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

/// ① 누름 장치 찾기를 지난다(세트를 찾은 본체일 때).
Future<void> _passKit(WidgetTester tester) async {
  final next = find.byKey(const Key('wizard-next'));
  if (next.evaluate().isEmpty || tester.widget<FilledButton>(next).onPressed == null) return;
  await tester.tap(next);
  await _settle(tester);
}

/// 사진 패널 위 (fx, fy) 비율 자리를 짚는다.
Future<void> _tapPhoto(WidgetTester tester, double fx, double fy) async {
  final box = tester.getRect(find.byKey(const Key('wizard-photo')));
  await tester.tapAt(Offset(box.left + box.width * fx, box.top + box.height * fy));
  await tester.pump();
}

/// ①~③을 지나 ④(정지 버튼과 기다리는 자리)까지 간다. 버튼은 '시작' 하나. [stop]이면 그 버튼을 정지로,
/// 기다리는 자리도 골라 둔다(안 고르면 저장 전에 묻는다).
Future<void> _walkToStopStep(WidgetTester tester, {String name = '전자레인지', bool stop = true}) async {
  await tester.tap(find.byKey(const Key('wizard-take-photo')));
  await _settle(tester);
  await _walkToStopStepFromPhoto(tester, name: name);
  if (!stop) return;
  await tester.tap(find.byKey(const Key('wizard-stop-B01')));
  await tester.pump();
  await tester.tap(find.byKey(const Key('wizard-park')));
  await tester.pump();
  await _tapPhoto(tester, 0.8, 0.8);
}

/// 정지 버튼·기다리는 자리 없이 저장하느냐고 물으면 '이대로 저장'.
Future<void> _saveWithoutStop(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('wizard-save-without-stop')));
  await _settle(tester);
}

/// 사진을 찍은 ①에서 ④까지.
Future<void> _walkToStopStepFromPhoto(WidgetTester tester, {String name = '전자레인지'}) async {
  await tester.enterText(find.byKey(const Key('wizard-name')), name);
  await tester.pump();
  await tester.tap(find.byKey(const Key('wizard-next')));
  await _settle(tester);
  // ② 누름 장치 칸은 범위 비율로 가운데에 그려져 있다 — 그대로 다음.
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

/// 사진 위 누름 장치 칸.
PanelArea _areaOf(WidgetTester tester) =>
    tester.widget<PanelPhotoView>(find.byKey(const Key('wizard-photo'))).area!;

/// 사진 패널 안에서 [key] 이름표의 가운데 자리(비율).
Offset _tagAt(WidgetTester tester, String key) {
  final box = tester.getRect(find.byKey(const Key('wizard-photo')));
  final c = tester.getCenter(find.byKey(Key(key)));
  return Offset((c.dx - box.left) / box.width, (c.dy - box.top) / box.height);
}

const _areaTitle = '3. 누름 장치 칸 맞추기';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  // 세트: 찾기 → 자리 저장 뒤 연결 → 자리 확인 전까지 준비됐다고 말하지 않는다.
  group('누름 장치 찾기', () {
    Future<void> open(WidgetTester tester, _Server server) async {
      _tall(tester);
      await tester.pumpWidget(_build(server));
      await tester.pump();
      GoRouter.of(tester.element(find.text('홈'))).push('/appliance/add');
      await _settle(tester);
    }

    FilledButton next(WidgetTester tester) => tester.widget<FilledButton>(find.byKey(const Key('wizard-next')));

    testWidgets('찾으면 모션·콘센트를 보여 주고 다음으로 간다', (tester) async {
      await open(tester, _Server());
      expect(_title(tester), '1. 누름 장치 찾기');
      expect(find.byKey(const Key('wizard-kit-found')), findsOneWidget);
      expect(find.text('누름 장치: 연결됨'), findsOneWidget);
      expect(find.text('전기 플러그(전력 확인): 연결됨'), findsOneWidget);
      await tester.tap(find.byKey(const Key('wizard-next')));
      await _settle(tester);
      expect(_title(tester), '2. 버튼판 사진');
    });

    testWidgets('못 찾으면 안내와 다시 찾기만 있고 다음으로 가지 못한다', (tester) async {
      final server = _Server()..kit = {'found': false, 'reason': '세트를 찾지 못했어요. 전원을 확인해 주세요.'};
      await open(tester, server);
      expect(find.text('세트를 찾지 못했어요. 전원을 확인해 주세요.'), findsOneWidget);
      expect(next(tester).onPressed, isNull);
      expect(find.byKey(const Key('wizard-next-why')), findsOneWidget);
      server.kit = {'found': true, 'kit_id': 'kit-a', 'motion_present': true};
      await tester.tap(find.byKey(const Key('wizard-kit-retry')));
      await _settle(tester);
      expect(next(tester).onPressed, isNotNull);
    });

    testWidgets('본체에 닿지 않아도 못 찾음으로 막는다', (tester) async {
      await open(tester, _Server()..unreachable = true);
      expect(find.byKey(const Key('wizard-kit-missing')), findsOneWidget);
      expect(next(tester).onPressed, isNull);
    });

    testWidgets('다른 가전이 쓰면 확인 창을 거쳐야 하고 저장 뒤에 연결한다', (tester) async {
      final server = _Server()
        ..kit = {'found': true, 'kit_id': 'kit-a', 'motion_present': true, 'bound_appliance': 'microwave', 'name': '전자레인지'};
      await open(tester, server);
      expect(find.text('이 세트는 전자레인지에 연결돼 있어요'), findsOneWidget);
      expect(next(tester).onPressed, isNull);
      await tester.tap(find.text('전자레인지 연결 해제 후 새 가전에 연결'));
      await _settle(tester);
      expect(find.textContaining('버튼 자리는 그대로 남지만, 다시 연결할 때까지 쓸 수 없어요'), findsOneWidget);
      await tester.tap(find.text('취소'));
      await _settle(tester);
      expect(_title(tester), '1. 누름 장치 찾기', reason: '취소하면 넘어가지 않는다');
      await tester.tap(find.text('전자레인지 연결 해제 후 새 가전에 연결'));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('kit-release-confirm')));
      await _settle(tester);
      expect(_title(tester), '2. 버튼판 사진');
      expect(server.bindBodies, isEmpty, reason: '자리를 저장하기 전에는 지금 가전을 건드리지 않는다');

      await _walkToStopStep(tester);
      await tester.tap(find.byKey(const Key('wizard-next')));
      await _settle(tester);
      expect(_title(tester), '6. 자리 확인');
      expect(server.bindBodies.single['confirm_release'], isTrue);
      expect(server.bindBodies.single['appliance_id'], startsWith('custom_'));
      expect(server.requests.indexOf('POST /kit/bind'),
          greaterThan(server.requests.indexWhere((r) => r.endsWith('/mapping'))));
    });

    testWidgets('연결이 거절되면 이유를 보이고 자리 확인을 막으며 다시 할 수 있다', (tester) async {
      final server = _Server()..bindReject = '누름 장치가 일하는 중이에요. 끝난 뒤 다시 해 주세요.';
      await open(tester, server);
      await tester.tap(find.byKey(const Key('wizard-next')));
      await _settle(tester);
      await _walkToStopStep(tester);
      await tester.tap(find.byKey(const Key('wizard-next')));
      await _settle(tester);
      expect(find.textContaining('누름 장치가 일하는 중이에요'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(const Key('wizard-start-pass'))).onPressed, isNull);
      server.bindReject = null;
      await tester.tap(find.byKey(const Key('wizard-bind-retry')));
      await _settle(tester);
      expect(find.byKey(const Key('wizard-bind-error')), findsNothing);
      expect(tester.widget<FilledButton>(find.byKey(const Key('wizard-start-pass'))).onPressed, isNotNull);
    });

    testWidgets('자리 확인 없이 끝내면 자리 확인 전으로 남는다고 말한다', (tester) async {
      await open(tester, _Server());
      await tester.tap(find.byKey(const Key('wizard-next')));
      await _settle(tester);
      await _walkToStopStep(tester);
      await tester.tap(find.byKey(const Key('wizard-next')));
      await _settle(tester);
      expect(find.text(kPassSkipNote), findsOneWidget);
      expect(find.textContaining('지켜봐'), findsNothing, reason: '확인 없이 눌러도 된다는 뜻으로 읽히면 안 된다');
    });

    testWidgets('자리를 다시 맞출 때는 세트를 찾지 않는다', (tester) async {
      final server = _Server();
      _tall(tester);
      await tester.pumpWidget(_build(server));
      await tester.pump();
      GoRouter.of(tester.element(find.text('홈'))).push('/appliance/setup', extra: const ApplianceMap(
        id: 'custom_1', name: '선풍기', category: ApplianceCategory.other, rows: 1, cols: 1, isCustom: true,
        buttons: [ApplianceButton(id: 'b1', label: '전원', x: 0, y: 0)],
      ));
      await _settle(tester);
      expect(server.requests.where((r) => r.contains('/kit')), isEmpty);
      expect(_title(tester), '2. 버튼판 사진');
    });
  });

  // 10/25: 미리 찍어 둔 버튼판 사진을 쓴다(카메라 없는 기기·다시 맞추기) — 사진첩에서 골라도 같은 단계로 간다.
  testWidgets('사진첩에서 고른 사진으로도 시작한다', (tester) async {
    final server = _Server();
    final photo = _FakePhoto();
    _tall(tester);
    await tester.pumpWidget(_build(server, photo: photo));
    await tester.pump();
    GoRouter.of(tester.element(find.text('홈'))).push('/appliance/add');
    await _settle(tester);
    await _passKit(tester);
    await tester.tap(find.byKey(const Key('wizard-pick-photo')));
    await _settle(tester);
    expect(photo.fromGallery, isTrue);
    expect(find.byKey(const Key('wizard-photo')), findsOneWidget);
  });

  testWidgets('다섯 단계를 이전/다음으로 오가며 등록하고 확인 주행까지 간다',
      (tester) async {
    final server = _Server();
    late ProviderContainer container;
    _tall(tester);
    await tester.pumpWidget(_build(server, onReady: (c) => container = c));
    await tester.pump();
    GoRouter.of(tester.element(find.text('홈'))).push('/appliance/add');
    await _settle(tester);
    await _passKit(tester);

    // ① 사진 — 사진과 이름이 있어야 다음으로 간다.
    expect(_title(tester), '2. 버튼판 사진');
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

    // ② 누름 장치 칸 — 본체가 아는 범위로 그린다. mm를 적는 칸이 없다.
    expect(_title(tester), _areaTitle);
    expect(server.requests, contains('GET /mapping/frame'));
    expect(find.text(kAreaHint), findsOneWidget);
    expect(find.textContaining('가로 300mm'), findsOneWidget);
    expect(find.byType(TextField), findsNothing, reason: '자가 없는 사람에게 mm를 묻지 않는다');
    expect(_areaOf(tester).corners, hasLength(4));
    expect(find.text(kAreaOriginLabel), findsOneWidget);
    expect(next().onPressed, isNotNull);
    final drawn = List.of(_areaOf(tester).corners);

    // 이전으로 돌아가도 칸은 남는다.
    await tester.tap(find.byKey(const Key('wizard-back')));
    await tester.pump();
    expect(_title(tester), '2. 버튼판 사진');
    await tester.tap(find.byKey(const Key('wizard-next')));
    await tester.pump();
    expect(_title(tester), _areaTitle);
    expect(_areaOf(tester).corners, drawn);
    expect(next().onPressed, isNotNull);
    await tester.tap(find.byKey(const Key('wizard-next')));
    await tester.pump();

    // ③ 버튼 — 짚고 이름을 붙인다.
    expect(_title(tester), '4. 버튼 고르고 이름 붙이기');
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
    expect(_title(tester), '5. 정지 버튼과 기다리는 자리');
    expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '취소')).selected, isTrue);
    await tester.pump();
    await tester.tap(find.text('2번'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('wizard-park')));
    await tester.pump();
    await _tapPhoto(tester, 0.8, 0.8);
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
    // mm는 보내지 않고 방향만 — 본체가 범위로 계산한다.
    expect(mapping.containsKey('frame_w_mm'), isFalse);
    expect(mapping.containsKey('frame_h_mm'), isFalse);
    expect(mapping['orientation'], {'rotation': 0, 'flipped': false});
    // 이 폰에도 남는다(사진 위 자리 포함).
    final saved = container.read(customAppliancesProvider).single;
    expect(saved.name, '전자레인지');
    expect(saved.panelMapping, isA<PanelMapping>());
    expect(saved.panelMapping!.buttons.length, 2);

    // ⑤ 확인 주행 — 모의면 모의라고 말한다.
    expect(_title(tester), '6. 자리 확인');
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

  testWidgets('본체가 누름 장치 범위를 모르면 적으라고 하지 않고, 설치하는 분께 부탁하라며 못 넘어간다',
      (tester) async {
    final server = _Server()..frameKnown = false;
    _tall(tester);
    await tester.pumpWidget(_build(server));
    await tester.pump();
    GoRouter.of(tester.element(find.text('홈'))).push('/appliance/add');
    await _settle(tester);
    await _passKit(tester);

    await tester.tap(find.byKey(const Key('wizard-take-photo')));
    await _settle(tester);
    await tester.enterText(find.byKey(const Key('wizard-name')), '세탁기');
    await tester.pump();
    await tester.tap(find.byKey(const Key('wizard-next')));
    await _settle(tester);

    FilledButton next() =>
        tester.widget<FilledButton>(find.byKey(const Key('wizard-next')));
    expect(find.text(kNoWorkspaceMessage), findsOneWidget);
    expect(find.byType(TextField), findsNothing, reason: 'mm 칸은 없다');
    expect(next().onPressed, isNull);
    expect(tester.widget<Text>(find.byKey(const Key('wizard-next-why'))).data, contains('범위'));

    // 본체에 범위가 생기면 '다시 받기'로 이어 간다.
    server.frameKnown = true;
    await tester.tap(find.text('다시 받기'));
    await _settle(tester);
    expect(find.text(kNoWorkspaceMessage), findsNothing);
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
    await _passKit(tester);
    await _walkToStopStep(tester);
    expect(_title(tester), '5. 정지 버튼과 기다리는 자리');
    // 기다리는 자리는 누름 장치 칸 안쪽이어야 한다 — 칸을 그려 둔다(끌 수는 없다).
    final area = _areaOf(tester);
    expect(area.corners, hasLength(4));
    expect(area.onCornerMoved, isNull);
    // 기다리는 자리는 진한 '대기' 표시로 보인다(실사용 10/26: 흐린 점선이 안 보였다).
    final park = tester.widget<PanelPhotoView>(find.byKey(const Key('wizard-photo'))).marks
        .where((m) => m.kind == PanelMarkKind.park);
    expect(park, hasLength(1));
    expect(find.descendant(of: find.byKey(const Key('mark-park')), matching: find.text('대기')), findsOneWidget);

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
    expect(_title(tester), '5. 정지 버튼과 기다리는 자리', reason: '거절되면 다음 단계로 가지 않는다');
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
    await _passKit(tester);

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
    await _saveWithoutStop(tester);
    expect(_title(tester), '6. 자리 확인');
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
    await _passKit(tester);
    await tester.tap(find.byKey(const Key('wizard-take-photo')));
    await _settle(tester);
    expect(find.textContaining('사진을 이 폰에 남기지 못했어요'), findsOneWidget);
  });

  testWidgets('이름과 방이 모두 같은 가전이 이미 있으면 다음으로 가지 않고 이름 칸 아래에 말한다(실화면 10/19)',
      (tester) async {
    const existing = ApplianceMap(
      id: 'custom_washer',
      name: '세탁기',
      category: ApplianceCategory.washingMachine,
      rows: 1,
      cols: 1,
      buttons: [ApplianceButton(id: 'b1', label: '전원', x: 0, y: 0)],
      isCustom: true,
    );
    _tall(tester);
    await tester.pumpWidget(_build(_Server(), installed: const [existing]));
    await tester.pump();
    GoRouter.of(tester.element(find.text('홈'))).push('/appliance/add');
    await _settle(tester);
    await _passKit(tester);
    await tester.tap(find.byKey(const Key('wizard-take-photo')));
    await _settle(tester);
    FilledButton next() => tester.widget<FilledButton>(find.byKey(const Key('wizard-next')));

    // 종류 '세탁기'를 고르면 이름도 '세탁기'가 된다 — 이미 있는 이름.
    // 가전 그림 통일(10/24): 종류는 ChoiceChip 대신 그림 카드('kind-<value>')로 고른다.
    await tester.tap(find.byKey(Key('kind-${ApplianceCategory.washingMachine.value}')));
    await tester.pump();
    expect(find.byKey(Key('kind-selected-${ApplianceCategory.washingMachine.value}')), findsOneWidget);
    expect(find.text(nameTakenMessage('세탁기')), findsOneWidget);
    expect(next().onPressed, isNull);

    await tester.enterText(find.byKey(const Key('wizard-name')), '세탁기 2');
    await tester.pump();
    expect(find.textContaining('같은 이름의 가전이 이미 있어요'), findsNothing);
    expect(next().onPressed, isNotNull);
  });

  testWidgets('처음 채워 두는 이름(전자레인지)이 이미 있으면 비워 두고 경고부터 띄우지 않는다', (tester) async {
    const microwave = ApplianceMap(
      id: 'microwave',
      name: '전자레인지',
      category: ApplianceCategory.microwave,
      rows: 1,
      cols: 1,
      buttons: [ApplianceButton(id: 'b1', label: '시작', x: 0, y: 0)],
    );
    _tall(tester);
    await tester.pumpWidget(_build(_Server(), installed: const [microwave]));
    await tester.pump();
    GoRouter.of(tester.element(find.text('홈'))).push('/appliance/add');
    await _settle(tester);
    await _passKit(tester);
    expect(tester.widget<TextField>(find.byKey(const Key('wizard-name'))).controller!.text, isEmpty);
    expect(find.textContaining('같은 이름의 가전이 이미 있어요'), findsNothing);
    // 손대지 않고 닫으면 묻지 않는다.
    await tester.tap(find.byTooltip('닫기'));
    await _settle(tester);
    expect(find.text('홈'), findsOneWidget);
  });

  testWidgets('등록된 가전의 자리를 다시 맞출 때는 제목이 다르고, 이름·방·종류 칸이 없고, 안 바꾸고 닫으면 묻지 않는다(실화면 10/19)',
      (tester) async {
    const mapped = ApplianceMap(
      id: 'custom_washer',
      name: '세탁기',
      category: ApplianceCategory.washingMachine,
      rows: 1,
      cols: 1,
      buttons: [ApplianceButton(id: 'B01', label: '시작', x: 0, y: 0)],
      isCustom: true,
      photoPath: '/photos/custom_washer.jpg',
      panelMapping: PanelMapping(
        photoWidth: 1000,
        photoHeight: 800,
        corners: [PhotoPoint(100, 80), PhotoPoint(900, 80), PhotoPoint(900, 720), PhotoPoint(100, 720)],
        buttons: {'B01': PhotoPoint(300, 300)},
      ),
    );
    _tall(tester);
    await tester.pumpWidget(_build(_Server(), installed: const [mapped]));
    await tester.pump();
    GoRouter.of(tester.element(find.text('홈'))).push('/appliance/setup', extra: mapped);
    await _settle(tester);

    expect(find.text('버튼 자리 맞추기'), findsOneWidget);
    expect(find.text('가전 추가'), findsNothing);
    expect(_title(tester), _areaTitle);
    await tester.tap(find.byKey(const Key('wizard-back')));
    await tester.pump();
    expect(_title(tester), '2. 버튼판 사진');
    expect(find.byKey(const Key('wizard-name')), findsNothing, reason: '여기서 바꿔도 저장되지 않는 칸은 두지 않는다');
    expect(find.text('사진 없이 버튼판으로 등록하기'), findsNothing);
    expect(find.text('가전: 세탁기'), findsOneWidget);
    expect(find.text('다시 찍기'), findsOneWidget, reason: '등록할 때 찍은 사진에서 시작한다');

    await tester.tap(find.byTooltip('닫기'));
    await _settle(tester);
    expect(find.text('저장하지 않고 나가기'), findsNothing, reason: '아무것도 안 바꿨다');
    expect(find.text('홈'), findsOneWidget);
  });

  testWidgets('시스템 뒤로 가기는 한 단계 앞으로, X는 물어보고 등록을 닫는다(실화면 10/19)', (tester) async {
    _tall(tester);
    await tester.pumpWidget(_build(_Server()));
    await tester.pump();
    GoRouter.of(tester.element(find.text('홈'))).push('/appliance/add');
    await _settle(tester);
    await _passKit(tester);
    await tester.tap(find.byKey(const Key('wizard-take-photo')));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('wizard-next')));
    await _settle(tester);
    expect(_title(tester), _areaTitle);

    await tester.binding.handlePopRoute();
    await _settle(tester);
    expect(_title(tester), '2. 버튼판 사진');
    expect(find.text('저장하지 않고 나가기'), findsNothing);

    // 1단계에서 뒤로 가기는 닫기 — 찍은 사진이 있으니 묻는다.
    await tester.binding.handlePopRoute();
    await _settle(tester);
    expect(find.text('저장하지 않고 나가기'), findsOneWidget);
    await tester.tap(find.text('계속 고치기'));
    await _settle(tester);

    // X는 몇 단계에 있든 등록을 닫는다(물어본 뒤).
    await tester.tap(find.byKey(const Key('wizard-next')));
    await _settle(tester);
    await tester.tap(find.byTooltip('닫기'));
    await _settle(tester);
    await tester.tap(find.text('저장하지 않고 나가기'));
    await _settle(tester);
    expect(find.text('홈'), findsOneWidget);
  });

  // 검토 10/19(core6 7): 0.8초마다 묻되 답을 기다리지 않아 요청이 겹쳤고, 늦게 온 앞 답('하는 중')이 끝남을 덮어
  // '끝내기'가 영영 막혔다(타이머는 이미 멈춤). 한 번에 하나만 묻고, 멈춘 뒤 온 답은 받지 않는다.
  testWidgets('자리 확인 상태의 늦은 앞 답이 끝남을 덮지 않는다', (tester) async {
    final server = _Server()
      ..passScript = [
        (const Duration(milliseconds: 2000), false),
        (Duration.zero, true),
      ];
    _tall(tester);
    await tester.pumpWidget(_build(server));
    await tester.pump();
    GoRouter.of(tester.element(find.text('홈'))).push('/appliance/add');
    await _settle(tester);
    await _passKit(tester);
    await _walkToStopStep(tester);
    await tester.tap(find.byKey(const Key('wizard-next')));
    await _settle(tester);
    expect(_title(tester), '6. 자리 확인');
    await tester.tap(find.byKey(const Key('wizard-start-pass')));
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('도착했다고 알려 왔어요'), findsOneWidget);
    final finish = tester.widget<ButtonStyleButton>(find.byKey(const Key('wizard-finish')));
    expect(finish.onPressed, isNotNull, reason: '끝난 자리 확인 뒤에는 끝낼 수 있다');
    final polls = server.requests.where((r) => r.startsWith('GET ') && r.endsWith('/verify-pass')).length;
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(server.requests.where((r) => r.startsWith('GET ') && r.endsWith('/verify-pass')).length, polls,
        reason: '끝난 뒤에는 더 묻지 않는다');
  });

  testWidgets('본체가 자리 확인을 받지 않으면 쉬운 말과 다음 할 일로 — 다른 일 중이면 서버 문장 그대로(실화면 10/19)',
      (tester) async {
    final server = _Server()..rejectPass = (409, '이 가전은 이 허브의 갠트리에 연결되지 않았어요');
    _tall(tester);
    await tester.pumpWidget(_build(server));
    await tester.pump();
    GoRouter.of(tester.element(find.text('홈'))).push('/appliance/add');
    await _settle(tester);
    await _passKit(tester);
    await _walkToStopStep(tester);
    await tester.tap(find.byKey(const Key('wizard-next')));
    await _settle(tester);
    expect(_title(tester), '6. 자리 확인');
    await tester.tap(find.byKey(const Key('wizard-start-pass')));
    await _settle(tester);
    // 누를 장치가 없다는 거절은 자리 확인만이 아니라 누르기도 안 된다고 말한다(검토 10/19).
    expect(find.text(kPassNoPressDeviceMessage), findsOneWidget);
    expect(find.textContaining('갠트리'), findsNothing);

    // 지금 본체의 문장(10/19 쉬운 말)도 같다.
    server.rejectPass = (409, '이 가전 위에는 누름 장치가 없어 자리 확인을 할 수 없어요 — 누름 장치를 이 가전에 올린 뒤 다시 해 주세요');
    await tester.tap(find.byKey(const Key('wizard-start-pass')));
    await _settle(tester);
    expect(find.text(kPassNoPressDeviceMessage), findsOneWidget);

    server.rejectPass = (409, '확인 주행을 지금 할 수 없어요');
    await tester.tap(find.byKey(const Key('wizard-start-pass')));
    await _settle(tester);
    expect(find.text(kPassUnavailableMessage), findsOneWidget);

    server.rejectPass = (409, '다른 일을 하는 중이에요. 끝난 뒤 다시 해 주세요.');
    await tester.tap(find.byKey(const Key('wizard-start-pass')));
    await _settle(tester);
    expect(find.text('다른 일을 하는 중이에요. 끝난 뒤 다시 해 주세요.'), findsOneWidget);
  });

  // 첫 사용 평가 4차(10/24): '다음'이 흐려져 있는데 왜인지 말이 없었다 — 단추 아래에 빠진 것을 말한다.
  testWidgets("'다음'이 안 눌리면 단추 아래에 빠진 것(사진·이름·귀퉁이)을 말한다", (tester) async {
    final server = _Server();
    _tall(tester);
    await tester.pumpWidget(_build(server));
    await tester.pump();
    GoRouter.of(tester.element(find.text('홈'))).push('/appliance/add');
    await _settle(tester);
    await _passKit(tester);
    String why() => tester.widget<Text>(find.byKey(const Key('wizard-next-why'))).data!;
    expect(tester.widget<FilledButton>(find.byKey(const Key('wizard-next'))).onPressed, isNull);
    expect(why(), contains('사진'));
    await tester.tap(find.byKey(const Key('wizard-take-photo')));
    await _settle(tester);
    await tester.enterText(find.byKey(const Key('wizard-name')), '');
    await tester.pump();
    expect(why(), contains('이름'));
    expect(why(), isNot(contains('사진')));
    await tester.enterText(find.byKey(const Key('wizard-name')), '전자레인지');
    await tester.pump();
    expect(find.byKey(const Key('wizard-next-why')), findsNothing);
    await tester.tap(find.byKey(const Key('wizard-next')));
    await _settle(tester);
    expect(find.byKey(const Key('wizard-next-why')), findsNothing, reason: '칸은 그려져 있어 바로 갈 수 있다');
    await tester.tap(find.byKey(const Key('wizard-next')));
    await tester.pump();
    expect(why(), contains('버튼'));
  });

  testWidgets('옛 본체(범위를 frame_w_mm로만 줌)여도 칸을 그린다', (tester) async {
    final server = _Server()..legacyFrame = true;
    _tall(tester);
    await tester.pumpWidget(_build(server));
    await tester.pump();
    GoRouter.of(tester.element(find.text('홈'))).push('/appliance/add');
    await _settle(tester);
    await _passKit(tester);
    await tester.tap(find.byKey(const Key('wizard-take-photo')));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('wizard-next')));
    await _settle(tester);
    expect(_areaOf(tester).corners, hasLength(4));
    expect(_areaOf(tester).orientation, const AreaOrientation(), reason: 'y_up이면 원점 왼쪽 아래');
  });

  testWidgets('누름 장치 칸 귀퉁이를 끌어 옮기면 그 자리가 저장에 실린다', (tester) async {
    final server = _Server();
    _tall(tester);
    await tester.pumpWidget(_build(server));
    await tester.pump();
    GoRouter.of(tester.element(find.text('홈'))).push('/appliance/add');
    await _settle(tester);
    await _passKit(tester);
    await tester.tap(find.byKey(const Key('wizard-take-photo')));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('wizard-next')));
    await _settle(tester);
    // 기본(y_up): 원점은 칸의 왼쪽 아래, X 화살표는 오른쪽, Y · 모터 쪽은 위.
    final before = List.of(_areaOf(tester).corners);
    expect(_tagAt(tester, 'area-origin-label').dy, greaterThan(0.75));
    expect(_tagAt(tester, 'area-x-label').dx, greaterThan(_tagAt(tester, 'area-y-label').dx));
    expect(_tagAt(tester, 'area-y-label').dy, lessThan(_tagAt(tester, 'area-x-label').dy));
    expect(find.text(kAreaYLabel), findsOneWidget);

    final scrollBefore = tester.state<ScrollableState>(find.byType(Scrollable).first).position.pixels;
    await tester.drag(find.byKey(const Key('area-corner-2')), const Offset(-40, -60));
    await _settle(tester);
    final after = _areaOf(tester).corners;
    final box = tester.getRect(find.byKey(const Key('wizard-photo')));
    final scale = 1000 / box.width;
    expect(after[2].x, closeTo(before[2].x - 40 * scale, 1));
    expect(after[2].y, closeTo(before[2].y - 60 * scale, 1));
    expect(after[0], before[0], reason: '끈 귀퉁이만 움직인다');
    expect(tester.state<ScrollableState>(find.byType(Scrollable).first).position.pixels, scrollBefore,
        reason: '귀퉁이를 끌면 목록이 스크롤되지 않는다');

    await tester.tap(find.byKey(const Key('wizard-next')));
    await tester.pump();
    await _tapPhoto(tester, 0.3, 0.4);
    await _settle(tester);
    await tester.tap(find.text('확인'));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('wizard-next')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('wizard-next')));
    await _settle(tester);
    await _saveWithoutStop(tester);
    final sent = (server.mappingBody!['corners_px'] as List).cast<List<dynamic>>();
    expect(sent[2][0], closeTo(after[2].x, 0.01));
    expect(sent[2][1], closeTo(after[2].y, 0.01));
  });

  testWidgets('돌리기·뒤집기로 원점과 축 방향을 장치에 맞추고, 그 방향을 저장에 싣는다', (tester) async {
    final server = _Server();
    _tall(tester);
    await tester.pumpWidget(_build(server));
    await tester.pump();
    GoRouter.of(tester.element(find.text('홈'))).push('/appliance/add');
    await _settle(tester);
    await _passKit(tester);
    await tester.tap(find.byKey(const Key('wizard-take-photo')));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('wizard-next')));
    await _settle(tester);
    double w(List<PhotoPoint> c) => c[1].x - c[0].x;
    double h(List<PhotoPoint> c) => c[3].y - c[0].y;
    final flat = List.of(_areaOf(tester).corners);
    expect(w(flat), greaterThan(h(flat)), reason: '300×200 범위는 가로로 긴 칸');

    // 돌리기 90°: 손대지 않은 칸은 비율도 돌아 세로로 길어지고, 원점은 왼쪽 위·X는 아래·Y는 오른쪽.
    await tester.tap(find.byKey(const Key('wizard-area-rotate')));
    await tester.pump();
    expect(find.text('돌리기 (90°)'), findsOneWidget);
    final tall = _areaOf(tester).corners;
    expect(h(tall), greaterThan(w(tall)));
    expect(_areaOf(tester).orientation.cornerOrder, [0, 3, 2, 1]);
    expect(_tagAt(tester, 'area-origin-label').dy, lessThan(0.25));
    expect(_tagAt(tester, 'area-x-label').dy, greaterThan(_tagAt(tester, 'area-origin-label').dy));
    expect(_tagAt(tester, 'area-y-label').dx, greaterThan(_tagAt(tester, 'area-x-label').dx));

    // 뒤집기: 같은 칸, 원점이 왼쪽 아래로(+X 위, +Y 오른쪽).
    await tester.tap(find.byKey(const Key('wizard-area-flip')));
    await tester.pump();
    expect(_areaOf(tester).corners, tall, reason: '뒤집기는 칸을 다시 그리지 않는다');
    expect(_areaOf(tester).orientation, const AreaOrientation(rotation: 90, flipped: true));
    expect(_tagAt(tester, 'area-origin-label').dy, greaterThan(0.75));

    await tester.tap(find.byKey(const Key('wizard-next')));
    await tester.pump();
    await _tapPhoto(tester, 0.5, 0.5);
    await _settle(tester);
    await tester.tap(find.text('확인'));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('wizard-next')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('wizard-next')));
    await _settle(tester);
    await _saveWithoutStop(tester);
    expect(server.mappingBody!['orientation'], {'rotation': 90, 'flipped': true});
  });

  test('장치 방향 표는 본체(device_corner_order)와 같다', () {
    expect(const AreaOrientation().cornerOrder, [3, 2, 1, 0]);
    expect(const AreaOrientation(rotation: 90).cornerOrder, [0, 3, 2, 1]);
    expect(const AreaOrientation(flipped: true).cornerOrder, [2, 3, 0, 1]);
    expect(const AreaOrientation(rotation: 180, flipped: true).cornerOrder, [0, 1, 2, 3]);
    final all = {
      for (final r in [0, 90, 180, 270])
        for (final f in [false, true]) AreaOrientation(rotation: r, flipped: f).cornerOrder.join()
    };
    expect(all, hasLength(8));
    expect(pointInArea(const [PhotoPoint(0, 0), PhotoPoint(10, 0), PhotoPoint(10, 10), PhotoPoint(0, 10)],
        const PhotoPoint(5, 5)), isTrue);
    expect(pointInArea(const [PhotoPoint(0, 10), PhotoPoint(10, 10), PhotoPoint(10, 0), PhotoPoint(0, 0)],
        const PhotoPoint(11, 5)), isFalse, reason: '어느 방향으로 돌아도');
  });

  testWidgets('누름 장치 칸 밖을 누르면 바로 닿지 않는다고 말하고 버튼을 받지 않는다', (tester) async {
    final server = _Server();
    _tall(tester);
    await tester.pumpWidget(_build(server));
    await tester.pump();
    GoRouter.of(tester.element(find.text('홈'))).push('/appliance/add');
    await _settle(tester);
    await _passKit(tester);
    await tester.tap(find.byKey(const Key('wizard-take-photo')));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('wizard-next')));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('wizard-next')));
    await tester.pump();
    expect(find.text(kStopTapHint), findsOneWidget);

    await _tapPhoto(tester, 0.03, 0.03);
    await _settle(tester);
    expect(find.text(kOutsideAreaMessage), findsOneWidget);
    expect(find.byKey(const Key('wizard-button-name')), findsNothing, reason: '이름을 묻지 않는다');
    expect(find.byType(InputChip), findsNothing);

    await _tapPhoto(tester, 0.5, 0.5);
    await _settle(tester);
    await tester.tap(find.text('확인'));
    await _settle(tester);
    expect(find.byType(InputChip), findsOneWidget);
    expect(find.text(kOutsideAreaMessage), findsNothing, reason: '안쪽을 누르면 말이 사라진다');
  });

  testWidgets("종류 '기타'는 이름으로 채우지 않는다, 미리 채운 버튼 이름은 골라 둔다", (tester) async {
    _tall(tester);
    await tester.pumpWidget(_build(_Server()));
    await tester.pump();
    GoRouter.of(tester.element(find.text('홈'))).push('/appliance/add');
    await _settle(tester);
    await _passKit(tester);
    // 가전 그림 통일(10/24): 종류는 ChoiceChip 대신 그림 카드('kind-<value>')로 고른다.
    await tester.tap(find.byKey(Key('kind-${ApplianceCategory.other.value}')));
    await tester.pump();
    expect(find.byKey(Key('kind-selected-${ApplianceCategory.other.value}')), findsOneWidget);
    String name() => tester.widget<TextField>(find.byKey(const Key('wizard-name'))).controller!.text;
    expect(name(), isEmpty);
    await tester.tap(find.byKey(Key('kind-${ApplianceCategory.riceCooker.value}')));
    await tester.pump();
    expect(find.byKey(Key('kind-selected-${ApplianceCategory.riceCooker.value}')), findsOneWidget);
    expect(find.byKey(Key('kind-selected-${ApplianceCategory.other.value}')), findsNothing);
    expect(name(), '밥솥');

    await tester.tap(find.byKey(const Key('wizard-take-photo')));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('wizard-next')));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('wizard-next')));
    await tester.pump();
    await _tapPhoto(tester, 0.3, 0.4);
    await _settle(tester);
    final field = tester.widget<TextField>(find.byKey(const Key('wizard-button-name')));
    expect(field.controller!.selection, const TextSelection(baseOffset: 0, extentOffset: 4));
  });

  // 첫 사용 검토 10/19: 연결이 없다는 말만 하고 다음으로 가게 둬, 사진·귀퉁이·버튼을 다 고른 뒤 저장에서야 막혔다.
  testWidgets('본체와 연결되지 않았으면 첫 단계에서 말하고 다음으로 가지 않으며, 연결하고 돌아오면 이어서 간다',
      (tester) async {
    late _SwitchableConnection hub;
    _tall(tester);
    await tester.pumpWidget(_build(_Server(),
        connection: rpiConnectionProvider.overrideWith(
            (ref) => hub = _SwitchableConnection(ref, RpiConnectionState.unreachable))));
    await tester.pump();
    GoRouter.of(tester.element(find.text('홈'))).push('/appliance/add');
    await _settle(tester);
    FilledButton next() => tester.widget<FilledButton>(find.byKey(const Key('wizard-next')));
    // 세트 찾기부터 막힌다 — 연결하고 돌아오면 다시 찾는다.
    expect(find.byKey(const Key('wizard-kit-offline')), findsOneWidget);
    expect(next().onPressed, isNull);
    await tester.tap(find.text('본체 연결하기'));
    await _settle(tester);
    hub.set(RpiConnectionState.connected);
    GoRouter.of(tester.element(find.text('본체 연결 화면'))).pop();
    await _settle(tester);
    expect(find.byKey(const Key('wizard-kit-offline')), findsNothing);
    await tester.tap(find.byKey(const Key('wizard-next')));
    await _settle(tester);

    // 고르는 중에 끊겨도 같다.
    hub.set(RpiConnectionState.unreachable);
    await _settle(tester);
    expect(find.byKey(const Key('wizard-offline')), findsOneWidget);
    await tester.tap(find.byKey(const Key('wizard-take-photo')));
    await _settle(tester);
    await tester.enterText(find.byKey(const Key('wizard-name')), '전자레인지');
    await tester.pump();
    expect(next().onPressed, isNull, reason: '연결 없이 끝까지 고르고 저장에서 막히지 않게');

    await tester.tap(find.text('본체 연결하기'));
    await _settle(tester);
    expect(find.text('본체 연결 화면'), findsOneWidget);
    hub.set(RpiConnectionState.connected);
    GoRouter.of(tester.element(find.text('본체 연결 화면'))).pop();
    await _settle(tester);
    expect(find.byKey(const Key('wizard-offline')), findsNothing);
    expect(tester.widget<TextField>(find.byKey(const Key('wizard-name'))).controller!.text, '전자레인지');
    expect(next().onPressed, isNotNull);
  });

  testWidgets('본체에 닿지 못해 저장하지 못하면 다시 누를 단추와 남아 있는 것을 말한다', (tester) async {
    final server = _Server();
    _tall(tester);
    await tester.pumpWidget(_build(server));
    await tester.pump();
    GoRouter.of(tester.element(find.text('홈'))).push('/appliance/add');
    await _settle(tester);
    await _passKit(tester);
    expect(find.byKey(const Key('wizard-offline')), findsNothing);
    await _walkToStopStep(tester);
    server.unreachable = true;
    await tester.tap(find.byKey(const Key('wizard-next')));
    await _settle(tester);
    // 등록이 본체에 닿았는지 모르고(목록도 못 받음) 되돌리기도 못 했다 — 남았을 수 있다고 함께 말한다(검토 10/19).
    expect(find.text('$kSaveOfflineMessage $kSaveOrphanNote'), findsOneWidget);
  });

  // 검토 10/19: 등록·자리 저장의 답만 잃으면(본체는 해 놓음) 실패로 알리고 정리도 건너뛰어, 본체에만 자리 없는 가전이 남거나
  // 자리를 저장한 가전을 이 폰이 받지 않았다. 이제 본체 목록에서 이 가전을 찾아 맞춘 뒤에 알린다.
  testWidgets('등록의 답을 잃어도 본체에 올라가 있으면 이어서 자리를 저장하고 끝낸다', (tester) async {
    final server = _Server()
      ..registerAnswerLost = true
      ..registerRevision = 4;
    _tall(tester);
    await tester.pumpWidget(_build(server));
    await tester.pump();
    GoRouter.of(tester.element(find.text('홈'))).push('/appliance/add');
    await _settle(tester);
    await _passKit(tester);
    await _walkToStopStep(tester);
    await tester.tap(find.byKey(const Key('wizard-next')));
    await _settle(tester);
    expect(server.requests, contains('GET /appliances'));
    expect(server.mappingBody?['expected_revision'], 4, reason: '본체 목록에서 본 판을 싣는다');
    expect(server.deletes, isEmpty);
    expect(_title(tester), '6. 자리 확인');
  });

  testWidgets('자리 저장의 답을 잃어도 본체에 저장돼 있으면 그 정의를 받아 끝낸다', (tester) async {
    final server = _Server()..mappingAnswerLost = true;
    ProviderContainer? container;
    _tall(tester);
    await tester.pumpWidget(_build(server, onReady: (c) => container = c));
    await tester.pump();
    GoRouter.of(tester.element(find.text('홈'))).push('/appliance/add');
    await _settle(tester);
    await _passKit(tester);
    await _walkToStopStep(tester);
    await tester.tap(find.byKey(const Key('wizard-next')));
    await _settle(tester);
    expect(server.deletes, isEmpty, reason: '저장된 가전을 지우지 않는다');
    expect(find.textContaining(kSaveOfflineMessage), findsNothing);
    expect(_title(tester), '6. 자리 확인');
    final saved = container!.read(customAppliancesProvider).single;
    expect(saved.revision, 2);
    expect(saved.panelMapping, isNotNull);
  });

  testWidgets('자리 저장의 답을 잃고 본체에도 자리가 없으면 본 판으로 등록을 되돌린 뒤 알린다', (tester) async {
    final server = _Server()
      ..mappingAnswerLost = true
      ..mappingLostSaved = false
      ..registerRevision = 3;
    _tall(tester);
    await tester.pumpWidget(_build(server));
    await tester.pump();
    GoRouter.of(tester.element(find.text('홈'))).push('/appliance/add');
    await _settle(tester);
    await _passKit(tester);
    await _walkToStopStep(tester);
    await tester.tap(find.byKey(const Key('wizard-next')));
    await _settle(tester);
    expect(server.requests, containsAllInOrder([
      matches(r'^PUT /appliances/custom_\d+/mapping$'),
      'GET /appliances',
      matches(r'^DELETE /appliances/custom_\d+$'),
    ]));
    expect(server.deletes.single, {'expected_revision': '3'});
    expect(find.text(kSaveOfflineMessage), findsOneWidget, reason: '되돌렸으면 남았다는 말은 붙이지 않는다');
  });

  // 검토 10/19: 매핑 저장이 판 번호를 싣지 않아 본체의 충돌 보호(409)를 건너뛰었다.
  testWidgets('새 가전의 버튼 자리 저장은 방금 등록이 돌려준 판 번호를 싣는다', (tester) async {
    final server = _Server()..registerRevision = 5;
    _tall(tester);
    await tester.pumpWidget(_build(server));
    await tester.pump();
    GoRouter.of(tester.element(find.text('홈'))).push('/appliance/add');
    await _settle(tester);
    await _passKit(tester);
    await _walkToStopStep(tester);
    await tester.tap(find.byKey(const Key('wizard-next')));
    await _settle(tester);
    expect(_title(tester), '6. 자리 확인');
    expect(server.mappingBody!['expected_revision'], 5);
  });

  testWidgets('다시 맞출 때는 연 가전의 판 번호를 싣고, 그사이 바뀌어 거절되면 다음 할 일을 말한다', (tester) async {
    const mapped = ApplianceMap(
      id: 'custom_washer',
      name: '세탁기',
      category: ApplianceCategory.washingMachine,
      rows: 1,
      cols: 1,
      buttons: [ApplianceButton(id: 'B01', label: '시작', x: 0, y: 0)],
      isCustom: true,
      revision: 7,
      photoPath: '/photos/custom_washer.jpg',
      panelMapping: PanelMapping(
        photoWidth: 1000,
        photoHeight: 800,
        corners: [PhotoPoint(100, 80), PhotoPoint(900, 80), PhotoPoint(900, 720), PhotoPoint(100, 720)],
        buttons: {'B01': PhotoPoint(300, 300)},
      ),
    );
    final server = _Server()
      ..rejectMapping = '다른 기기에서 먼저 변경되었어요'
      ..rejectMappingStatus = 409;
    _tall(tester);
    await tester.pumpWidget(_build(server, installed: const [mapped]));
    await tester.pump();
    GoRouter.of(tester.element(find.text('홈'))).push('/appliance/setup', extra: mapped);
    await _settle(tester);
    expect(_title(tester), _areaTitle);
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.byKey(const Key('wizard-next')));
      await _settle(tester);
    }
    await _saveWithoutStop(tester);
    expect(server.requests.where((r) => r == 'PUT /appliances/custom_washer'), isEmpty,
        reason: '다시 맞추기는 등록을 다시 올리지 않는다');
    expect(server.mappingBody!['expected_revision'], 7);
    expect(find.text(kSaveConflictMessage), findsOneWidget);
    expect(find.textContaining('다른 기기'), findsNothing, reason: '다른 기기가 없을 때도 나오는 말이다');
    expect(_title(tester), '5. 정지 버튼과 기다리는 자리');
  });

  // 검토 10/19(core6 6): 다시 맞추기의 답을 잃었을 때 판이 오르고 자리가 있기만 하면 다른 폰이 그사이 저장한 자리를 이 폰의
  // 저장으로 받아 '저장했어요'로 넘어갔다. 본체의 자리가 보낸 것과 같을 때만 저장된 것으로 본다.
  testWidgets('다시 맞추기의 답을 잃고 본체에 다른 폰의 자리가 있으면 내 저장으로 받지 않는다', (tester) async {
    const mapped = ApplianceMap(
      id: 'custom_washer',
      name: '세탁기',
      category: ApplianceCategory.washingMachine,
      rows: 1,
      cols: 1,
      buttons: [ApplianceButton(id: 'B01', label: '시작', x: 0, y: 0)],
      isCustom: true,
      revision: 7,
      photoPath: '/photos/custom_washer.jpg',
      panelMapping: PanelMapping(
        photoWidth: 1000,
        photoHeight: 800,
        corners: [PhotoPoint(100, 80), PhotoPoint(900, 80), PhotoPoint(900, 720), PhotoPoint(100, 720)],
        buttons: {'B01': PhotoPoint(300, 300)},
      ),
    );
    final server = _Server()
      ..mappingAnswerLost = true
      ..mappingLostSaved = false
      // 다른 폰이 그사이 저장한 자리(판 8, 귀퉁이·버튼 자리가 다르다).
      ..stored = {
        'id': 'custom_washer',
        'name': '세탁기',
        'icon': 'washer',
        'rows': 1,
        'cols': 1,
        'is_custom': true,
        'revision': 8,
        'buttons': [
          {'id': 'B01', 'label': '시작', 'x': 0, 'y': 0},
        ],
        'panel_mapping': {
          'photo': {'width': 1000, 'height': 800},
          'corners_px': [[50, 40], [950, 40], [950, 760], [50, 760]],
          'buttons_px': {'B01': [500, 500]},
          'stop_px': null,
          'park_px': null,
        },
      };
    ProviderContainer? container;
    _tall(tester);
    await tester.pumpWidget(_build(server, installed: const [mapped], onReady: (c) => container = c));
    await tester.pump();
    GoRouter.of(tester.element(find.text('홈'))).push('/appliance/setup', extra: mapped);
    await _settle(tester);
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.byKey(const Key('wizard-next')));
      await _settle(tester);
    }
    await _saveWithoutStop(tester);
    expect(server.requests, contains('GET /appliances'));
    expect(_title(tester), '5. 정지 버튼과 기다리는 자리', reason: '남의 저장을 내 저장으로 알리지 않는다');
    expect(find.text(kSaveOfflineMessage), findsOneWidget);
    final local = container!.read(customAppliancesProvider).where((a) => a.id == 'custom_washer');
    expect(local.every((a) => a.revision == 7), isTrue, reason: '남의 정의를 이 폰에 받아 두지 않는다');
  });

  // 검토 10/19: 등록은 됐는데 버튼 자리 저장이 거절되면 자리 없는 가전이 본체에 남았다.
  testWidgets('새 가전의 버튼 자리 저장이 거절되면 방금 올린 등록을 그 판으로 되돌린다', (tester) async {
    final server = _Server()
      ..rejectMapping = '기다리는 자리가 버튼판 밖이에요'
      ..registerRevision = 3;
    _tall(tester);
    await tester.pumpWidget(_build(server));
    await tester.pump();
    GoRouter.of(tester.element(find.text('홈'))).push('/appliance/add');
    await _settle(tester);
    await _passKit(tester);
    await _walkToStopStep(tester);
    await tester.tap(find.byKey(const Key('wizard-next')));
    await _settle(tester);
    expect(server.requests, containsAllInOrder([
      matches(r'^PUT /appliances/custom_\d+$'),
      matches(r'^PUT /appliances/custom_\d+/mapping$'),
      matches(r'^DELETE /appliances/custom_\d+$'),
    ]));
    expect(server.deletes.single, {'expected_revision': '3'});
    expect(find.text('기다리는 자리가 버튼판 밖이에요'), findsOneWidget, reason: '되돌렸으면 남았다는 말은 붙이지 않는다');
  });

  testWidgets('되돌리기도 못 하면 본체에 남았을 수 있다고 말하고 할 일을 준다', (tester) async {
    final server = _Server()
      ..rejectMapping = '기다리는 자리가 버튼판 밖이에요'
      ..deleteFails = true;
    _tall(tester);
    await tester.pumpWidget(_build(server));
    await tester.pump();
    GoRouter.of(tester.element(find.text('홈'))).push('/appliance/add');
    await _settle(tester);
    await _passKit(tester);
    await _walkToStopStep(tester);
    await tester.tap(find.byKey(const Key('wizard-next')));
    await _settle(tester);
    expect(find.text('기다리는 자리가 버튼판 밖이에요 $kSaveOrphanNote'), findsOneWidget);
  });

  testWidgets('다시 맞추기에서 거절되면 원래 있던 가전을 지우지 않는다', (tester) async {
    const mapped = ApplianceMap(
      id: 'custom_washer',
      name: '세탁기',
      category: ApplianceCategory.washingMachine,
      rows: 1,
      cols: 1,
      buttons: [ApplianceButton(id: 'B01', label: '시작', x: 0, y: 0)],
      isCustom: true,
      revision: 7,
      photoPath: '/photos/custom_washer.jpg',
      panelMapping: PanelMapping(
        photoWidth: 1000,
        photoHeight: 800,
        corners: [PhotoPoint(100, 80), PhotoPoint(900, 80), PhotoPoint(900, 720), PhotoPoint(100, 720)],
        buttons: {'B01': PhotoPoint(300, 300)},
      ),
    );
    final server = _Server()..rejectMapping = '기다리는 자리가 버튼판 밖이에요';
    _tall(tester);
    await tester.pumpWidget(_build(server, installed: const [mapped]));
    await tester.pump();
    GoRouter.of(tester.element(find.text('홈'))).push('/appliance/setup', extra: mapped);
    await _settle(tester);
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.byKey(const Key('wizard-next')));
      await _settle(tester);
    }
    await _saveWithoutStop(tester);
    expect(server.mappingBody, isNotNull);
    expect(server.deletes, isEmpty);
    expect(find.text('기다리는 자리가 버튼판 밖이에요'), findsOneWidget);
  });

  // 첫 사용 검토 10/19: '나중에 정해도 돼요'라고 안심시켜 처음 쓰는 사람이 정지 버튼·기다리는 자리를 건너뛰고, 가전이 도는
  // 중에 멈출 때에야 가전의 정지 버튼을 누를 수 없다는 것을 알았다.
  testWidgets('정지 버튼·기다리는 자리 없이 저장하려 하면 생기는 일을 말하고 묻는다 — 돌아가면 저장하지 않는다', (tester) async {
    final server = _Server();
    _tall(tester);
    await tester.pumpWidget(_build(server));
    await tester.pump();
    GoRouter.of(tester.element(find.text('홈'))).push('/appliance/add');
    await _settle(tester);
    await _passKit(tester);
    await _walkToStopStep(tester, stop: false);
    expect(_title(tester), '5. 정지 버튼과 기다리는 자리');
    expect(find.textContaining('나중에 정해도'), findsNothing);
    expect(find.textContaining('중간에 안전하게 멈추려면'), findsOneWidget);

    await tester.tap(find.byKey(const Key('wizard-next')));
    await _settle(tester);
    expect(find.text('정지 버튼 없이 저장할까요?'), findsOneWidget);
    expect(find.text(kNoStopConsequence), findsOneWidget);
    await tester.tap(find.text('돌아가서 정하기'));
    await _settle(tester);
    expect(server.mappingBody, isNull, reason: '돌아가면 저장하지 않는다');
    expect(_title(tester), '5. 정지 버튼과 기다리는 자리');

    // 정지 버튼만 고르고 기다리는 자리가 없어도 묻는다(둘 다 있어야 기다린다).
    await tester.tap(find.byKey(const Key('wizard-stop-B01')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('wizard-next')));
    await _settle(tester);
    expect(find.text('정지 버튼 없이 저장할까요?'), findsOneWidget);
    await _saveWithoutStop(tester);
    expect(server.mappingBody, isNotNull, reason: '그래도 저장할 수는 있다 — 켜고 끄는 버튼 하나뿐인 가전');
    expect(_title(tester), '6. 자리 확인');
  });

  testWidgets('정지 버튼과 기다리는 자리를 다 정했으면 묻지 않고 저장한다', (tester) async {
    final server = _Server();
    _tall(tester);
    await tester.pumpWidget(_build(server));
    await tester.pump();
    GoRouter.of(tester.element(find.text('홈'))).push('/appliance/add');
    await _settle(tester);
    await _passKit(tester);
    await _walkToStopStep(tester);
    expect(find.byKey(const Key('wizard-stop-missing')), findsNothing);
    await tester.tap(find.byKey(const Key('wizard-next')));
    await _settle(tester);
    expect(find.text('정지 버튼 없이 저장할까요?'), findsNothing);
    expect(server.mappingBody!['stop_button'], 'B01');
    expect(server.mappingBody!['park_px'], isNotNull);
  });

  // 실사용 10/26: ③에서 정지 버튼을 안 찍으면 ④에서 고를 수 없었다.
  testWidgets('정지 버튼 단계에서 사진을 누르면 그 자리가 정지 버튼이 되고, 칸 밖은 받지 않는다', (tester) async {
    final server = _Server();
    _tall(tester);
    await tester.pumpWidget(_build(server));
    await tester.pump();
    GoRouter.of(tester.element(find.text('홈'))).push('/appliance/add');
    await _settle(tester);
    await _passKit(tester);
    await _walkToStopStep(tester, stop: false);
    expect(_title(tester), '5. 정지 버튼과 기다리는 자리');
    expect(find.byKey(const Key('wizard-stop-photo-hint')), findsOneWidget);

    await _tapPhoto(tester, 0.03, 0.5);
    expect(find.text(kOutsideAreaMessage), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, '정지'), findsNothing);

    await _tapPhoto(tester, 0.6, 0.6);
    await tester.pump();
    expect(find.text(kOutsideAreaMessage), findsNothing);
    expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '정지')).selected, isTrue);
    // 다시 누르면 새로 만들지 않고 그 정지 버튼 자리만 옮긴다.
    await _tapPhoto(tester, 0.72, 0.6);
    await tester.pump();
    expect(find.widgetWithText(ChoiceChip, '정지'), findsOneWidget);

    await tester.tap(find.byKey(const Key('wizard-park')));
    await tester.pump();
    await _tapPhoto(tester, 0.8, 0.8);
    await tester.tap(find.byKey(const Key('wizard-next')));
    await _settle(tester);
    expect(find.text('정지 버튼 없이 저장할까요?'), findsNothing);
    final buttons = server.mappingBody!['buttons_px'] as Map<String, dynamic>;
    expect(buttons, hasLength(2));
    final stopId = server.mappingBody!['stop_button'] as String;
    expect((buttons[stopId] as List)[0], closeTo(720, 1));
    final names = [for (final b in server.registerBody!['buttons'] as List) (b as Map)['label']];
    expect(names, containsAll(['시작', '정지']));
  });

  testWidgets('이미 찍은 버튼을 사진에서 누르면 정지 버튼으로 고른다', (tester) async {
    _tall(tester);
    await tester.pumpWidget(_build(_Server()));
    await tester.pump();
    GoRouter.of(tester.element(find.text('홈'))).push('/appliance/add');
    await _settle(tester);
    await _passKit(tester);
    await _walkToStopStep(tester, stop: false);
    await tester.tap(find.byKey(const Key('mark-B01')));
    await tester.pump();
    expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '시작')).selected, isTrue);
    expect(find.byType(ChoiceChip), findsOneWidget, reason: '새 정지 버튼을 만들지 않는다');
  });

  testWidgets('단계 제목 번호와 진행 막대가 늘 같다', (tester) async {
    final handle = tester.ensureSemantics();
    _tall(tester);
    await tester.pumpWidget(_build(_Server()));
    await tester.pump();
    GoRouter.of(tester.element(find.text('홈'))).push('/appliance/add');
    await _settle(tester);
    await _passKit(tester);
    await tester.tap(find.byKey(const Key('wizard-take-photo')));
    await _settle(tester);
    final seen = <String>[];
    for (var i = 2; i <= 5; i++) {
      expect(_title(tester), startsWith('$i. '));
      expect(find.bySemanticsLabel('6개 중 $i번째'), findsOneWidget);
      seen.add(_title(tester));
      if (i == 4) {
        await _tapPhoto(tester, 0.5, 0.5);
        await _settle(tester);
        await tester.tap(find.text('확인'));
        await _settle(tester);
      }
      if (i < 5) {
        await tester.tap(find.byKey(const Key('wizard-next')));
        await _settle(tester);
      }
    }
    expect(seen, ['2. 버튼판 사진', _areaTitle, '4. 버튼 고르고 이름 붙이기', '5. 정지 버튼과 기다리는 자리']);
    handle.dispose();
  });

  test('같은 이름 경고의 예시는 적은 그 이름으로 든다', () {
    expect(nameTakenMessage(' 인덕션 '), contains('(예: 인덕션 2)'));
  });
}
