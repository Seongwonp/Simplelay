import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/screens/onboarding_screen.dart';

void main() {
  testWidgets('첫 안내는 허브 연결과 실제 탭을 설명해요', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: OnboardingScreen()));
    expect(find.text('본체 연결'), findsOneWidget);
    expect(find.text('내 루틴'), findsOneWidget);
    expect(find.textContaining('RPi5'), findsNothing);
    expect(find.textContaining('자동 접속'), findsNothing);
    expect(find.text('본체 연결하기'), findsOneWidget);
    expect(find.text('나중에 연결할게요'), findsOneWidget);
  });

  // 첫 사용 검토 10/19: 첫 화면이 '본체 연결'을 말하면서 단추('시작하기')는 연결 없이 홈으로만 갔다.
  group('첫 화면의 단추는 연결 화면을 열고, 연결을 마쳐야 홈으로 가요', () {
    late bool pairResult;

    Future<GoRouter> pump(WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      final router = GoRouter(initialLocation: '/onboarding', routes: [
        GoRoute(path: '/', builder: (_, __) => const Scaffold(body: Text('홈'))),
        GoRoute(path: '/onboarding', builder: (_, __) => const OnboardingScreen()),
        GoRoute(
          path: '/pair',
          builder: (context, __) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).pop(pairResult),
              child: const Text('연결 화면 닫기'),
            ),
          ),
        ),
      ]);
      addTearDown(router.dispose);
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();
      return router;
    }

    Future<bool?> done() async => (await SharedPreferences.getInstance()).getBool('onboarding_done');

    testWidgets('연결을 마치면 첫 안내를 끝내고 홈으로', (tester) async {
      pairResult = true;
      await pump(tester);
      await tester.tap(find.byKey(const Key('onboarding-pair')));
      await tester.pumpAndSettle();
      expect(find.text('연결 화면 닫기'), findsOneWidget, reason: '연결 화면이 열려야 한다');
      await tester.tap(find.text('연결 화면 닫기'));
      await tester.pumpAndSettle();
      expect(find.text('홈'), findsOneWidget);
      expect(await done(), isTrue);
    });

    testWidgets('연결하지 않고 돌아오면 첫 안내에 남아요', (tester) async {
      pairResult = false;
      await pump(tester);
      await tester.tap(find.byKey(const Key('onboarding-pair')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('연결 화면 닫기'));
      await tester.pumpAndSettle();
      expect(find.byType(OnboardingScreen), findsOneWidget);
      expect(await done(), isNull);
    });

    testWidgets("'나중에 연결할게요'는 종전처럼 홈으로", (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const Key('onboarding-later')));
      await tester.pumpAndSettle();
      expect(find.text('홈'), findsOneWidget);
      expect(await done(), isTrue);
    });
  });
}
