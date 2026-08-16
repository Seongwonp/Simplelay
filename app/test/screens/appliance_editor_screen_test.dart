import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/screens/appliance_editor_screen.dart';

import '../helpers/test_helpers.dart';

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

Widget _buildEditor(GoRouter router) {
  return buildWithProviderState(
    overrides: connectedOverrides(),
    child: MaterialApp.router(theme: ThemeData.dark(), routerConfig: router),
  );
}

// initialLocation을 곧바로 '/appliance/new'로 두면 스택에 pop할 대상이 없어서
// _save()의 context.pop()이 GoError를 던진다 — '/'에서 시작해 push해야 한다.
Future<void> _pumpEditor(WidgetTester tester, GoRouter router) async {
  await tester.pumpWidget(_buildEditor(router));
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
}
