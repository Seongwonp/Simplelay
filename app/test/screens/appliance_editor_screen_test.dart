import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/providers/appliance_provider.dart';
import 'package:simplelay/providers/photo_provider.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/appliance_editor_screen.dart';
import 'package:simplelay/services/photo_service.dart';
import 'package:simplelay/services/rpi_api_service.dart';

import '../helpers/test_helpers.dart';

const _fakePhotoBytes = [0x89, 0x50, 0x4E, 0x47];

class _FakePhotoService extends PhotoService {
  _FakePhotoService(this._photo);
  final File? _photo;

  @override
  Future<File?> takePhoto() async => _photo;

  // 실제 파일 입출력은 위젯 테스트의 가짜 시계에서 끝나지 않는다.
  @override
  Future<Uint8List> readBytes(File file) async =>
      Uint8List.fromList(_fakePhotoBytes);
}

/// 사진 인식만 가짜로 — 서버·인식 서비스·크레딧 없이 화면 흐름을 본다.
class _FakeScanApi extends RpiApiService {
  _FakeScanApi({this.draft, this.error}) : super('http://rpi5.local:8000');

  final PanelScanDraft? draft;
  final RpiApiException? error;
  int calls = 0;
  List<int>? sentBytes;

  @override
  Future<PanelScanDraft> scanPanel(List<int> imageBytes) async {
    calls++;
    sentBytes = imageBytes;
    final failure = error;
    if (failure != null) throw failure;
    return draft!;
  }
}

PanelScanDraft _scanDraft({int rows = 2, int cols = 3}) => PanelScanDraft(
      rows: rows,
      cols: cols,
      buttons: const [
        PanelScanButton(
            id: 'B-01', label: '해동', x: 0, y: 0, kind: 'button', labelFromModel: true),
        PanelScanButton(
            id: 'B-02', label: '시간', x: 1, y: 0, kind: 'button', labelFromModel: true),
        PanelScanButton(
            id: 'B-03', label: '버튼 3', x: 2, y: 0, kind: 'button', labelFromModel: false),
        PanelScanButton(
            id: 'B-04', label: '출력', x: 0, y: 1, kind: 'dial', labelFromModel: true),
        PanelScanButton(
            id: 'B-05', label: '시작', x: 2, y: 1, kind: 'button', labelFromModel: true),
      ],
      dropped: const ["7번 항목: 알 수 없는 종류('lever')라 뺐어요"],
    );

// Image.file()이 실제 파일 바이트를 디코드하면서 프레임을 계속 다시 예약해
// pumpAndSettle()이 끝나지 않는다 — 상태 반영만 확인하면 되므로 고정 횟수만
// pump한다.
Future<void> _pumpAFew(WidgetTester tester, [int times = 6]) async {
  for (var i = 0; i < times; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

// 실제로 디코드 가능한 이미지 파일을 만들어서 Image.file()에 물리면, 이 환경의
// flutter_test 코덱 파이프라인이 pump()를 영영 반환 안 함(runAsync로 감싸도
// 마찬가지) — Flutter 위젯 테스트에서 흔한 함정. 우리가 검증하려는 건 "사진이
// 있으면 그리드가 그 위에 겹쳐지고 상태가 바뀐다"이지 실제 픽셀 디코딩이
// 아니므로, 존재하지 않는 경로의 File로 충분하다(Image 위젯은 여전히 빌드되고
// find.byType(Image)로 잡히지만, 디코드 실패는 위젯 트리 밖 비동기 에러로
// 처리돼 pump를 막지 않는다).
File _fakePhotoFile() => File('${Directory.systemTemp.path}/simplelay_test_nonexistent.png');

GoRouter _buildRouter() => GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (_, __) => const Scaffold(body: Text('설정 화면'))),
        GoRoute(
          path: '/appliance/new',
          builder: (_, __) => const ApplianceEditorScreen(),
        ),
      ],
    );

Widget _buildEditor(
  GoRouter router, {
  List<Override> extraOverrides = const [],
  void Function(ProviderContainer)? onContainerReady,
}) {
  return buildWithProviderState(
    overrides: [...connectedOverrides(), ...extraOverrides],
    onContainerReady: onContainerReady,
    child: MaterialApp.router(theme: ThemeData.dark(), routerConfig: router),
  );
}

// initialLocation을 곧바로 '/appliance/new'로 두면 스택에 pop할 대상이 없어서
// _save()의 context.pop()이 GoError를 던진다 — '/'에서 시작해 push해야 한다.
Future<void> _pumpEditor(
  WidgetTester tester,
  GoRouter router, {
  List<Override> extraOverrides = const [],
  void Function(ProviderContainer)? onContainerReady,
}) async {
  await tester.pumpWidget(_buildEditor(
    router,
    extraOverrides: extraOverrides,
    onContainerReady: onContainerReady,
  ));
  await tester.pump();
  router.push('/appliance/new');
  await tester.pumpAndSettle();
}

// 이 화면도 ListView라, 그리드+설명문구+저장 버튼까지 합치면 기본 테스트
// 뷰포트(800x600)보다 콘텐츠가 길어져서 저장 버튼의 Element가 안 만들어진다.
void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(400, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('기본 3x3 그리드와 이름 입력 필드가 뜬다', (tester) async {
    _useTallViewport(tester);
    await _pumpEditor(tester, _buildRouter());

    expect(find.text('새 가전 추가'), findsOneWidget);
    // 이름과 위치 -- 같은 종류를 여러 대 등록할 수 있어서 위치를 묻는다.
    expect(find.byType(TextField), findsNWidgets(2));
    expect(find.text('어디에 있나요?'), findsOneWidget);
    expect(find.byIcon(Icons.add), findsNWidgets(9)); // 3x3 빈 칸
  });

  testWidgets('빈 칸을 탭하면 버튼 이름 입력 다이얼로그가 뜬다', (tester) async {
    _useTallViewport(tester);
    await _pumpEditor(tester, _buildRouter());

    await tester.tap(find.byIcon(Icons.add).first);
    await tester.pumpAndSettle();

    expect(find.text('버튼 추가'), findsOneWidget);
  });

  testWidgets('버튼 이름을 입력하고 확인하면 그리드에 반영된다', (tester) async {
    _useTallViewport(tester);
    await _pumpEditor(tester, _buildRouter());

    await tester.tap(find.byIcon(Icons.add).first);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).last, '시작');
    await tester.tap(find.widgetWithText(FilledButton, '확인'));
    await tester.pumpAndSettle();

    expect(find.text('시작'), findsOneWidget);
    expect(find.byIcon(Icons.add), findsNWidgets(8)); // 채워진 칸 1개 제외
  });

  testWidgets('이름 없이 저장하면 스낵바 경고, 저장 안 됨', (tester) async {
    _useTallViewport(tester);
    await _pumpEditor(tester, _buildRouter());

    await tester.tap(find.widgetWithText(FilledButton, '저장'));
    await tester.pump();

    expect(find.text('가전 이름을 입력하세요.'), findsOneWidget);
    expect(find.text('새 가전 추가'), findsOneWidget); // 화면 안 넘어감
  });

  testWidgets('버튼 없이 저장하면 스낵바 경고, 저장 안 됨', (tester) async {
    _useTallViewport(tester);
    await _pumpEditor(tester, _buildRouter());

    await tester.enterText(find.byType(TextField).first, '식기세척기');
    await tester.tap(find.widgetWithText(FilledButton, '저장'));
    await tester.pump();

    expect(find.text('버튼을 하나 이상 추가하세요.'), findsOneWidget);
  });

  testWidgets('이름+버튼 있으면 저장 후 목록에 추가되고 선택되고 화면이 닫힌다',
      (tester) async {
    _useTallViewport(tester);
    await _pumpEditor(tester, _buildRouter());

    await tester.enterText(find.byType(TextField).first, '식기세척기');
    await tester.tap(find.byIcon(Icons.add).first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '전원');
    await tester.tap(find.widgetWithText(FilledButton, '확인'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, '저장'));
    await tester.pumpAndSettle();

    // 저장했다고 바로 닫지 않는다. 등록된 것과 조작할 수 있는 것은 다르고,
    // 남은 일을 여기서 말하지 않으면 사용자는 홈에서 '아직 연결되지
    // 않았어요'를 만나 원인을 자기 가전에서 찾는다.
    expect(find.text("'식기세척기'을 등록했어요"), findsOneWidget);
    expect(find.text('기기 연결'), findsOneWidget);
    expect(find.text('버튼 위치 보정'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, '다음에'));
    await tester.pumpAndSettle();

    // pop 후 라우터의 '/' 화면으로 돌아감
    expect(find.text('설정 화면'), findsOneWidget);
  });

  testWidgets('위치를 적으면 목록에 위치까지 함께 남는다', (tester) async {
    _useTallViewport(tester);
    late ProviderContainer container;
    await _pumpEditor(
      tester,
      _buildRouter(),
      onContainerReady: (c) => container = c,
    );

    await tester.enterText(find.byType(TextField).first, '에어컨');
    await tester.enterText(find.byType(TextField).at(1), '거실');
    await tester.tap(find.byIcon(Icons.add).first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '전원');
    await tester.tap(find.widgetWithText(FilledButton, '확인'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, '저장'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '다음에'));
    await tester.pumpAndSettle();

    final saved = container.read(customAppliancesProvider).single;
    expect(saved.location, '거실');
    // '에어컨'이 두 대일 때 이름만으로는 어느 쪽인지 알 수 없다.
    expect(saved.displayName, '거실 에어컨');
  });

  testWidgets('행/열 스테퍼로 그리드 크기를 바꿀 수 있다', (tester) async {
    _useTallViewport(tester);
    await _pumpEditor(tester, _buildRouter());

    expect(find.byIcon(Icons.add), findsNWidgets(9)); // 3x3

    final addRowButton = find.byIcon(Icons.add_circle_outline).first;
    await tester.tap(addRowButton);
    await tester.pump();

    expect(find.byIcon(Icons.add), findsNWidgets(12)); // 4x3
  });

  group('버튼 패널 사진', () {
    testWidgets('사진 찍기 전엔 "사진 찍기" 버튼만 보인다', (tester) async {
      _useTallViewport(tester);
      await _pumpEditor(
        tester,
        _buildRouter(),
        extraOverrides: [
          photoServiceProvider.overrideWithValue(_FakePhotoService(null)),
        ],
      );

      expect(find.text('버튼 패널 사진 찍기'), findsOneWidget);
      expect(find.text('다시 찍기'), findsNothing);
    });

    testWidgets('사진을 찍으면 그리드 위에 겹쳐 보이고 "다시 찍기"로 바뀐다',
        (tester) async {
      _useTallViewport(tester);
      final photo = _fakePhotoFile();
      await _pumpEditor(
        tester,
        _buildRouter(),
        extraOverrides: [
          photoServiceProvider.overrideWithValue(_FakePhotoService(photo)),
        ],
      );

      await tester.tap(find.text('버튼 패널 사진 찍기'));
      await _pumpAFew(tester);

      expect(find.text('다시 찍기'), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
      // 격자 탭 기능은 사진 위에서도 그대로 동작해야 한다.
      expect(find.byIcon(Icons.add), findsNothing); // 빈 칸은 사진 위에선 + 아이콘 안 씀
    });

    testWidgets('사진을 찍은 뒤에도 빈 칸을 탭하면 버튼을 추가할 수 있다', (tester) async {
      _useTallViewport(tester);
      final photo = _fakePhotoFile();
      await _pumpEditor(
        tester,
        _buildRouter(),
        extraOverrides: [
          photoServiceProvider.overrideWithValue(_FakePhotoService(photo)),
        ],
      );

      await tester.tap(find.text('버튼 패널 사진 찍기'));
      await _pumpAFew(tester);

      // 빈 칸(격자 (0,0) 셀)을 탭 — translucent 모드라 아이콘이 없어서 키로 찾는다.
      await tester.tap(find.byKey(const ValueKey('grid_cell_0_0')));
      await _pumpAFew(tester);

      expect(find.text('버튼 추가'), findsOneWidget);
    });

    testWidgets('X 버튼으로 사진을 제거하면 다시 "사진 찍기" 버튼으로 돌아간다', (tester) async {
      _useTallViewport(tester);
      final photo = _fakePhotoFile();
      await _pumpEditor(
        tester,
        _buildRouter(),
        extraOverrides: [
          photoServiceProvider.overrideWithValue(_FakePhotoService(photo)),
        ],
      );

      await tester.tap(find.text('버튼 패널 사진 찍기'));
      await _pumpAFew(tester);
      expect(find.text('다시 찍기'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close));
      await _pumpAFew(tester);

      expect(find.text('버튼 패널 사진 찍기'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });
  });

  group('사진으로 버튼 채우기', () {
    Future<void> pumpWithPhoto(WidgetTester tester, _FakeScanApi api) async {
      _useTallViewport(tester);
      await _pumpEditor(
        tester,
        _buildRouter(),
        extraOverrides: [
          photoServiceProvider
              .overrideWithValue(_FakePhotoService(_fakePhotoFile())),
          rpiApiServiceProvider.overrideWithValue(api),
        ],
      );
      await tester.tap(find.text('버튼 패널 사진 찍기'));
      await _pumpAFew(tester);
    }

    const scanButton = ValueKey('panel_scan_button');

    /// 사진 전송은 매번 동의를 받는다 — 확인까지 해야 요청이 나간다.
    Future<void> sendPhoto(WidgetTester tester) async {
      await tester.tap(find.byKey(scanButton));
      await _pumpAFew(tester);
      await tester.tap(find.widgetWithText(FilledButton, '보내기'));
      await _pumpAFew(tester);
    }

    testWidgets('사진을 찍기 전에는 채우기 버튼이 없고, 찍으면 전송 안내와 함께 나온다',
        (tester) async {
      _useTallViewport(tester);
      await _pumpEditor(
        tester,
        _buildRouter(),
        extraOverrides: [
          photoServiceProvider
              .overrideWithValue(_FakePhotoService(_fakePhotoFile())),
          rpiApiServiceProvider.overrideWithValue(_FakeScanApi(draft: _scanDraft())),
        ],
      );
      expect(find.byKey(scanButton), findsNothing);

      await tester.tap(find.text('버튼 패널 사진 찍기'));
      await _pumpAFew(tester);

      expect(find.byKey(scanButton), findsOneWidget);
      // 사진이 기기 밖으로 나가는 경로라 누르기 전에 알린다.
      expect(find.textContaining('인식 서비스로 보내져요'), findsOneWidget);
    });

    testWidgets('초안으로 격자를 채우고, 다이얼·이름 못 읽은 버튼을 알린다', (tester) async {
      final api = _FakeScanApi(draft: _scanDraft());
      await pumpWithPhoto(tester, api);

      await sendPhoto(tester);

      expect(api.calls, 1);
      expect(api.sentBytes, _fakePhotoBytes);
      // 다이얼(출력)은 누르는 버튼으로 저장되면 안 되므로 넣지 않는다.
      expect(find.text('버튼 4개를 채웠어요'), findsOneWidget);
      expect(find.textContaining('버튼 3 — 칸을 눌러 이름을 고쳐 주세요'), findsOneWidget);
      expect(find.textContaining('다이얼이라 넣지 않았어요'), findsOneWidget);
      expect(find.textContaining('lever'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, '확인'));
      await _pumpAFew(tester);

      expect(find.text('해동'), findsOneWidget);
      expect(find.text('시작'), findsOneWidget);
      expect(find.text('출력'), findsNothing);
      // 격자도 초안 크기(2행 3열)로 바뀐다.
      expect(find.byKey(const ValueKey('grid_cell_2_1')), findsOneWidget);
      expect(find.byKey(const ValueKey('grid_cell_0_2')), findsNothing);
    });

    testWidgets('적어 둔 버튼이 있으면 바뀐다는 것까지 알리고, 취소하면 보내지도 바꾸지도 않는다',
        (tester) async {
      final api = _FakeScanApi(draft: _scanDraft());
      await pumpWithPhoto(tester, api);

      await tester.tap(find.byKey(const ValueKey('grid_cell_0_0')));
      await _pumpAFew(tester);
      await tester.enterText(find.byType(TextField).last, '전원');
      await tester.tap(find.widgetWithText(FilledButton, '확인'));
      await _pumpAFew(tester);

      await tester.tap(find.byKey(scanButton));
      await _pumpAFew(tester);
      expect(find.text('사진을 외부 인식 서비스로 보낼까요?'), findsOneWidget);
      expect(find.textContaining('인터넷의 외부 인식 서비스로 전송'), findsOneWidget);
      expect(find.textContaining('버튼 1개가 인식 결과로 바뀌어요'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, '취소'));
      await _pumpAFew(tester);

      expect(api.calls, 0);
      expect(find.text('전원'), findsOneWidget);
    });

    testWidgets('서버가 거절하면 그 문장을 보여주고 격자는 그대로 둔다', (tester) async {
      final api = _FakeScanApi(
        error: RpiApiException(503, '사진 인식이 꺼져 있어요 — 서버에 인식 서비스 설정이 필요해요'),
      );
      await pumpWithPhoto(tester, api);

      await sendPhoto(tester);

      expect(find.text('사진으로 채우지 못했어요'), findsOneWidget);
      expect(find.textContaining('꺼져 있어요'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, '확인'));
      await _pumpAFew(tester);

      expect(find.byKey(const ValueKey('grid_cell_2_2')), findsOneWidget); // 3x3 유지
      // 실패 뒤에도 다시 시도할 수 있다.
      final button = tester.widget<ButtonStyleButton>(find.byKey(scanButton));
      expect(button.onPressed, isNotNull);
    });

    testWidgets('버튼이 하나도 없어도 전송 전에 묻고, 취소하면 보내지 않는다', (tester) async {
      // 사진이 인터넷 밖으로 나가는 경로다. 새 가전이라 바뀔 배치가 없어도
      // 전송 자체에 대한 동의는 받아야 한다.
      final api = _FakeScanApi(draft: _scanDraft());
      await pumpWithPhoto(tester, api);

      await tester.tap(find.byKey(scanButton));
      await _pumpAFew(tester);

      expect(find.text('사진을 외부 인식 서비스로 보낼까요?'), findsOneWidget);
      expect(find.textContaining('인터넷의 외부 인식 서비스로 전송'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, '취소'));
      await _pumpAFew(tester);

      expect(api.calls, 0);
    });

    testWidgets('앱 격자(6x6)보다 큰 초안은 넣지 않고 직접 배치를 안내한다', (tester) async {
      final api = _FakeScanApi(draft: _scanDraft(rows: 7, cols: 3));
      await pumpWithPhoto(tester, api);

      await sendPhoto(tester);

      expect(find.textContaining('최대 6 × 6'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '확인'));
      await _pumpAFew(tester);
      expect(find.byKey(const ValueKey('grid_cell_2_2')), findsOneWidget);
    });
  });
}
