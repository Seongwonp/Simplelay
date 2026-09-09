// 시작 화면은 이름을 한 번 보여주고, 준비가 끝나면 **한 번만** 결정한다.
//
// 이 화면이 필요한 이유는 연출이 아니라 깜빡임이다. 예전에는 온보딩 여부를
// main()이 미리 읽고 홈은 가전 목록이 올라오기 전에 그려져서, 가전을 가진
// 사람도 '아직 등록한 가전이 없어요'를 한 프레임 보고 나서 화면이 바뀌었다.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/appliance.dart';
import 'package:simplelay/providers/appliance_provider.dart';
import 'package:simplelay/screens/splash_screen.dart';

import '../helpers/test_helpers.dart';

/// 실제 앱과 같은 모양: '/splash'에서 시작해 결정 하나로 옮겨간다.
Widget _app({List<Override> overrides = const []}) => buildWithProviderState(
      overrides: overrides,
      child: MaterialApp.router(
        theme: ThemeData.dark(),
        routerConfig: GoRouter(
          initialLocation: '/splash',
          routes: [
            GoRoute(path: '/splash', builder: (_, __) => const SplashScreen()),
            GoRoute(
              path: '/',
              builder: (_, __) => const Scaffold(body: Text('홈')),
            ),
            GoRoute(
              path: '/onboarding',
              builder: (_, __) => const Scaffold(body: Text('온보딩')),
            ),
          ],
        ),
      ),
    );

void main() {
  testWidgets('이름과 한 줄 설명만 보여준다', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(_app());
    await tester.pump();

    expect(find.text('SimpleLay'), findsOneWidget);
    expect(find.text('복잡한 가전을 더 간단하게'), findsOneWidget);
    // 기다리게 만드는 연출은 기다림을 짧게 만들지 않는다.
    expect(find.byType(CircularProgressIndicator), findsNothing);

    await tester.pumpAndSettle();
  });

  testWidgets('온보딩을 마쳤으면 홈으로 간다', (tester) async {
    SharedPreferences.setMockInitialValues({'onboarding_done': true});
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    expect(find.text('홈'), findsOneWidget);
    // 시작 화면은 스택에 남지 않는다 -- 뒤로 가기로 돌아올 자리가 아니다.
    expect(find.text('SimpleLay'), findsNothing);
  });

  testWidgets('처음 켠 사람은 온보딩으로 간다', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    expect(find.text('온보딩'), findsOneWidget);
  });

  testWidgets('가전 목록이 올라온 뒤에 홈을 그린다 — 빈 상태를 먼저 보여주지 않는다',
      (tester) async {
    // 가전을 가진 사람이 '아직 등록한 가전이 없어요'를 한 프레임이라도 보면,
    // 앱이 자기 데이터를 잃어버린 것처럼 보인다.
    final mine = ApplianceMap(
      id: 'a1',
      name: '에어컨',
      location: '거실',
      category: ApplianceCategory.airConditioner,
      rows: 1,
      cols: 1,
      buttons: const [ApplianceButton(id: 'b1', label: '전원', x: 0, y: 0)],
      isCustom: true,
    );
    SharedPreferences.setMockInitialValues({
      'onboarding_done': true,
      'custom_appliances': [applianceJsonString(mine)],
      'selected_appliance': 'a1',
    });

    late ProviderContainer container;
    await tester.pumpWidget(buildWithProviderState(
      onContainerReady: (c) => container = c,
      child: MaterialApp.router(
        theme: ThemeData.dark(),
        routerConfig: GoRouter(
          initialLocation: '/splash',
          routes: [
            GoRoute(path: '/splash', builder: (_, __) => const SplashScreen()),
            GoRoute(
              path: '/',
              builder: (_, __) => const Scaffold(body: Text('홈')),
            ),
          ],
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('홈'), findsOneWidget);
    // 홈이 그려지는 시점에 선택 가전은 이미 정해져 있다.
    expect(container.read(selectedApplianceProvider)?.id, 'a1');
  });
}
