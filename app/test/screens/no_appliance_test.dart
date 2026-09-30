// 설치한 가전이 0대일 때 각 화면이 하는 일.
//
// 이건 예외 처리가 아니라 **정상 제품 상태**다 -- 앱을 처음 켠 사람은 반드시
// 여기를 지난다. 그래서 화면마다 같은 문구를 붙이지 않는다. 화면이 못 하게
// 된 일이 서로 다르므로, 그 일을 가리켜 말해야 한다.
//
// - 홈: 0대를 정상으로 보여주고 추가로 안내한다(오류색·오류문구 없음)
// - 음성: 마이크를 아예 내주지 않는다
// - 수동 조작: 빈 조작판 대신 추가로 안내한다
// - 어느 화면도 전자레인지로 대체하거나 크래시하지 않는다

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:simplelay/screens/home_screen.dart';
import 'package:simplelay/screens/manual_control_screen.dart';
import 'package:simplelay/screens/voice_screen.dart';

import '../helpers/test_helpers.dart';

void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(400, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// '가전 추가'가 실제로 어디론가 가는지까지 본다 -- 버튼만 있고 길이 없으면
/// 안내가 아니라 막다른 길이다.
Widget _screen(Widget screen) => buildWithProviderState(
      overrides: [
        ...connectedOverrides(),
        ...installedOverrides(const []), // 아무것도 등록하지 않은 사용자
      ],
      child: MaterialApp.router(
        theme: ThemeData.dark(),
        routerConfig: GoRouter(
          initialLocation: '/',
          routes: [
            GoRoute(path: '/', builder: (_, __) => screen),
            GoRoute(
              path: '/appliance/new',
              builder: (_, __) => const Scaffold(body: Text('가전 추가 화면')),
            ),
            // 2026-09-30부터 홈의 가전 추가는 5단계 등록으로 간다.
            GoRoute(
              path: '/appliance/add',
              builder: (_, __) => const Scaffold(body: Text('가전 추가 5단계')),
            ),
            GoRoute(
              path: '/manual-control',
              builder: (_, __) => const ManualControlScreen(),
            ),
            GoRoute(
              path: '/history',
              builder: (_, __) => const Scaffold(body: Text('기록')),
            ),
          ],
        ),
      ),
    );

void main() {
  group('홈 — 0대는 고장이 아니라 시작점이다', () {
    testWidgets('없다고 말하고 추가로 데려간다', (tester) async {
      _tall(tester);
      await tester.pumpWidget(_screen(const HomeScreen()));
      await tester.pump();

      expect(find.text('아직 등록한 가전이 없어요'), findsOneWidget);
      // 가진 적 없는 가전을 세우지 않는다.
      expect(find.text('전자레인지'), findsNothing);

      await tester.tap(find.widgetWithText(FilledButton, '가전 추가'));
      await tester.pumpAndSettle();

      expect(find.text('가전 추가 5단계'), findsOneWidget);
    });

    testWidgets('조작 버튼을 내걸지 않는다 — 누를 대상이 없다', (tester) async {
      _tall(tester);
      await tester.pumpWidget(_screen(const HomeScreen()));
      await tester.pump();

      expect(find.text('버튼으로 조작'), findsNothing);
    });
  });

  group('음성 — 말할 대상이 없으면 마이크를 내주지 않는다', () {
    testWidgets('마이크 대신 무엇이 없는지 말한다', (tester) async {
      // 말하게 두고 전송에서 실패시키면, 사용자는 자기 발음이 문제라고
      // 생각하게 된다.
      _tall(tester);
      await tester.pumpWidget(_screen(const VoiceScreen()));
      await tester.pump();

      expect(find.text('사용할 가전을 먼저 추가해 주세요'), findsOneWidget);
      expect(find.byIcon(Icons.mic), findsNothing);
      expect(find.text('이대로 실행'), findsNothing);
    });

    testWidgets('추가 화면으로 가는 길이 같이 있다', (tester) async {
      _tall(tester);
      await tester.pumpWidget(_screen(const VoiceScreen()));
      await tester.pump();

      await tester.tap(find.widgetWithText(FilledButton, '가전 추가'));
      await tester.pumpAndSettle();

      expect(find.text('가전 추가 5단계'), findsOneWidget);
    });
  });

  group('수동 조작 — 빈 조작판을 그리지 않는다', () {
    testWidgets('버튼 0개짜리 격자 대신 안내를 둔다', (tester) async {
      // 빈 격자는 '고장 났다'로 읽힌다.
      _tall(tester);
      await tester.pumpWidget(_screen(const ManualControlScreen()));
      await tester.pump();

      expect(find.text('조작할 가전이 아직 없어요'), findsOneWidget);
      expect(find.text('버튼을 탭하면 실제 가전 버튼이 눌립니다.'), findsNothing);
    });

    testWidgets('제목이 없는 가전 이름을 지어내지 않는다', (tester) async {
      _tall(tester);
      await tester.pumpWidget(_screen(const ManualControlScreen()));
      await tester.pump();

      expect(find.text('버튼 조작'), findsOneWidget);
      expect(find.textContaining('전자레인지'), findsNothing);
    });
  });
}
