import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:simplelay/models/appliance.dart';
import 'package:simplelay/models/suggestion.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/home_screen.dart';

import '../helpers/test_helpers.dart';

/// 홈은 가전 그림·제안·연결 상세까지 세로로 길다. 기본 테스트 뷰포트
/// (800x600)로는 아래쪽 위젯의 Element가 만들어지지 않아 find가 "없음"으로
/// 잘못 판정한다 -- status/settings 테스트와 같은 문제다.
void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(400, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget _buildHome({
  List<Suggestion> suggestions = const [],
  bool connected = false,
  bool serverOnline = false,
  List<ApplianceMap>? installed,
}) {
  // disconnected + suggestions은 두 override를 개별로 합산
  final overrides = [
    ...(connected ? connectedOverrides() : disconnectedOverrides()),
    // 이 파일의 기본 상황은 '가전 한 대를 등록한 사용자'다. 0대인 홈은
    // 아래 별도 group에서 확인한다 -- 그쪽도 정상 상태다.
    ...installedOverrides(installed ?? [kTestAppliance]),
    if (serverOnline)
      rpiConnectionProvider.overrideWith((ref) => _OnlineRpi(ref)),
  ];
  return buildScreen(
    const HomeScreen(),
    overrides: overrides,
    suggestions: suggestions,
  );
}

/// 서버 확인이 끝나 연결된 상태로 시작하는 연결 상태.
class _OnlineRpi extends RpiConnectionNotifier {
  _OnlineRpi(super.ref) {
    state = RpiConnectionState.connected;
  }
}

void main() {
  group('HomeScreen — 연결 문제의 정도와 자리', () {
    testWidgets('예비 연결로만 닿으면 조작 가능과 연결 경고가 서로 어긋나지 않는다',
        (tester) async {
      // 예전에는 "조작 가능"과 "연결 설정이 필요해요"가 한 화면에 함께 떠서
      // 어느 쪽을 믿을지 알 수 없었다.
      _useTallViewport(tester);
      await tester.pumpWidget(_buildHome(connected: true));
      await tester.pump();

      expect(find.text('예비 연결로 조작할 수 있어요'), findsOneWidget);
      expect(find.text('조작할 수 있어요'), findsNothing);
      expect(find.text('제안·기록이 멈췄어요'), findsOneWidget);
      expect(find.text('연결 설정이 필요해요'), findsNothing);
    });

    testWidgets('기기에 닿지 않으면 연결 경고가 가전보다 먼저 나온다', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildHome());
      await tester.pump();

      final warning = tester.getTopLeft(find.text('연결 설정이 필요해요')).dy;
      final name = tester.getTopLeft(find.text(kTestAppliance.displayName)).dy;
      expect(warning, lessThan(name));
    });

    testWidgets('예비 연결만 꺼지면 경고가 아니라 아래의 조용한 안내다', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildHome(serverOnline: true));
      await tester.pump();

      expect(find.text('조작할 수 있어요'), findsOneWidget);
      expect(find.text('연결 설정이 필요해요'), findsNothing);
      expect(find.text('제안·기록이 멈췄어요'), findsNothing);
      final notice = tester.getTopLeft(find.text('예비 연결 꺼짐')).dy;
      final name = tester.getTopLeft(find.text(kTestAppliance.displayName)).dy;
      expect(notice, greaterThan(name));

      await tester.tap(find.text('확인하기'));
      await tester.pump();
      // 닿는 기기를 다시 "연결됐어요"로 말하지 않고, 꺼진 것만 보여 준다.
      expect(find.text('예비 연결이 꺼져 있어요'), findsOneWidget);
      expect(find.text('기기와 연결됐어요'), findsNothing);
    });

    testWidgets('서버와 예비 연결이 모두 되면 연결 줄 자체가 없다', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildHome(connected: true, serverOnline: true));
      await tester.pump();

      expect(find.text('조작할 수 있어요'), findsOneWidget);
      expect(find.text('확인하기'), findsNothing);
    });
  });

  group('HomeScreen — 연결 해제 상태', () {
    testWidgets('연결 문제는 한 줄로 알리고 눌러야 상세가 나온다', (tester) async {
      // 기술 정보(RPi 서버·주소 입력·재시도)가 홈 아래를 차지하고 있었다.
      // 기본은 무엇이 필요한지 한 줄이고, 자세한 것은 눌렀을 때만 나온다.
      _useTallViewport(tester);
      await tester.pumpWidget(_buildHome());
      await tester.pump();

      expect(find.text('연결 설정이 필요해요'), findsOneWidget);
      expect(find.text('예비 연결이 꺼져 있어요'), findsNothing);

      await tester.tap(find.text('확인하기'));
      await tester.pump();

      expect(find.text('예비 연결이 꺼져 있어요'), findsOneWidget);
      expect(find.text('연결해 두면 서버가 안 될 때도 조작할 수 있어요.'), findsOneWidget);
    });

    testWidgets('상세를 펼치면 복구 동선이 나온다', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildHome());
      await tester.pump();
      await tester.tap(find.text('확인하기'));
      await tester.pump();
      expect(find.text('연결'), findsOneWidget);
    });

    testWidgets('연결이 없으면 홈이 그 사실을 먼저 말한다', (tester) async {
      // 주 행동(말로 조작)은 탭바 가운데로 옮겼다. 예전에는 홈의 버튼을
      // 비활성화해서 알렸는데, 이제는 **가전 상태 한 줄**이 그 일을
      // 한다 -- 눌러 본 뒤에 알게 하지 않는 것이 요점이었고 그건 그대로다.
      _useTallViewport(tester);
      await tester.pumpWidget(_buildHome());
      await tester.pump();
      expect(find.text('기기와 연결되면 조작할 수 있어요'), findsOneWidget);
    });

    testWidgets('제안 없음 메시지 표시', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildHome());
      await tester.pump();
      expect(find.text('지금 확인할 제안이 없어요.'), findsOneWidget);
    });
  });

  group('HomeScreen — 연결 완료 상태', () {
    testWidgets('예비 연결 안내 카드가 사라짐', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildHome(connected: true));
      await tester.pump();
      expect(find.text('예비 연결이 꺼져 있어요'), findsNothing);
    });

    testWidgets('"연결" 버튼 사라짐', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildHome(connected: true));
      await tester.pump();
      // 연결됨 상태에서는 trailing TextButton 없음
      expect(find.text('연결'), findsNothing);
    });

    testWidgets('버튼 조작 경로가 홈에 항상 보인다', (tester) async {
      // 말이 잘 안 되거나 인식이 안 되는 사용자가 같은 시도를 반복하지
      // 않으려면, 다른 길이 화면에 함께 있어야 한다. 말하는 경로는
      // 탭바 가운데에 있고(app_shell_test), 버튼 경로는 여기 있다.
      _useTallViewport(tester);
      await tester.pumpWidget(_buildHome(connected: true));
      await tester.pump();
      expect(find.text('버튼으로 조작'), findsOneWidget);
    });

    testWidgets('연결되면 조작할 수 있다고 말한다', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildHome(connected: true, serverOnline: true));
      await tester.pump();
      expect(find.text('조작할 수 있어요'), findsOneWidget);
    });
  });

  group('HomeScreen — 제안 목록', () {
    const suggestion = Suggestion(
      sequenceId: 's1',
      label: '즉석밥 데우기',
      steps: ['BT-08', 'BT-03', 'BT-05'],
    );

    testWidgets('제안 카드 1개 표시', (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(
        _buildHome(connected: true, suggestions: const [suggestion]),
      );
      await tester.pump();
      // 홈의 행은 질문이 아니다 -- 무엇을 하는 것인지만 쓴다.
      expect(find.text('즉석밥 데우기'), findsOneWidget);
      // "3단계 동작"은 몇 번 움직이는지만 알려줬다 -- 맡길지 판단하려면
      // 무엇을 누르는지가 필요하다
      expect(find.text('즉석밥 → 1분 추가 → 시작'), findsOneWidget);
      expect(find.text('지금 확인할 제안이 없어요.'), findsNothing);
    });

    testWidgets('여러 제안 카드 모두 표시', (tester) async {
      const suggestions = [
        Suggestion(sequenceId: 'a', label: '30초 가열', steps: ['BT-02', 'BT-05']),
        Suggestion(sequenceId: 'b', label: '해동', steps: ['BT-07', 'BT-05']),
      ];
      _useTallViewport(tester);
      await tester.pumpWidget(
        _buildHome(connected: true, suggestions: suggestions),
      );
      await tester.pump();
      expect(find.text('30초 가열'), findsOneWidget);
      expect(find.text('해동'), findsOneWidget);
    });

    testWidgets('제안 탭 시 /suggestion/:id 로 이동', (tester) async {
      String? pushedRoute;

      final router = GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(
            path: '/',
            builder: (_, __) => const HomeScreen(),
          ),
          GoRoute(
            path: '/suggestion/:id',
            builder: (context, state) {
              pushedRoute = state.pathParameters['id'];
              return const Scaffold(body: Text('제안 화면'));
            },
          ),
        ],
      );

      _useTallViewport(tester);
      await tester.pumpWidget(
        ProviderScopeWrapper(
          overrides: connectedOverrides(),
          suggestions: const [suggestion],
          child: MaterialApp.router(
            theme: ThemeData.dark(),
            routerConfig: router,
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('즉석밥 데우기'));
      await tester.pumpAndSettle();

      expect(pushedRoute, 's1');
    });
  });
}

// GoRouter 테스트를 위한 ProviderScope 래퍼
class ProviderScopeWrapper extends StatelessWidget {
  const ProviderScopeWrapper({
    required this.overrides,
    required this.suggestions,
    required this.child,
    super.key,
  });
  final List<Override> overrides;
  final List<Suggestion> suggestions;
  final Widget child;

  @override
  Widget build(BuildContext context) => buildWithProviderState(
        overrides: overrides,
        suggestions: suggestions,
        child: child,
      );
}
