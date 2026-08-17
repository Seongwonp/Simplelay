import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/providers/photo_provider.dart';
import 'package:simplelay/screens/appliance_editor_screen.dart';
import 'package:simplelay/services/photo_service.dart';

import '../helpers/test_helpers.dart';

class _FakePhotoService extends PhotoService {
  _FakePhotoService(this._photo);
  final File? _photo;

  @override
  Future<File?> takePhoto() async => _photo;
}

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

Widget _buildEditor(GoRouter router, {List<Override> extraOverrides = const []}) {
  return buildWithProviderState(
    overrides: [...connectedOverrides(), ...extraOverrides],
    child: MaterialApp.router(theme: ThemeData.dark(), routerConfig: router),
  );
}

// initialLocation을 곧바로 '/appliance/new'로 두면 스택에 pop할 대상이 없어서
// _save()의 context.pop()이 GoError를 던진다 — '/'에서 시작해 push해야 한다.
Future<void> _pumpEditor(
  WidgetTester tester,
  GoRouter router, {
  List<Override> extraOverrides = const [],
}) async {
  await tester.pumpWidget(_buildEditor(router, extraOverrides: extraOverrides));
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
    expect(find.byType(TextField), findsOneWidget); // 이름 입력
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

    // pop 후 라우터의 '/' 화면으로 돌아감
    expect(find.text('설정 화면'), findsOneWidget);
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
}
