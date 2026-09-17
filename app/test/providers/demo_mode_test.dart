/// 데모(가짜 센서) 주입은 명시적으로 켠 세션에서만 일어난다.
///
/// 예전에는 `kDebugMode`가 이 게이트였다. 그러면 **실기기에 물린 디버그
/// 빌드**에서도 가짜 센서가 섞인다 — 실제로는 버튼이 안 눌린 실행이 화면에서
/// 성공으로 끝난다. 폐루프의 존재 이유가 "눌림을 확인했는가"인데 그 확인을
/// 화면이 위조하게 되는 것이라, 테스트로 박아둔다.
///
/// 테스트는 항상 디버그 모드로 돈다. 그래서 아래 첫 테스트는 "디버그인데도
/// 주입되지 않는다"를 그대로 검증한다.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:simplelay/models/suggestion.dart';
import 'package:simplelay/providers/demo_provider.dart';
import 'package:simplelay/providers/ble_provider.dart';
import 'package:simplelay/screens/suggestion_screen.dart';
import 'package:simplelay/services/ble_service.dart';

import '../helpers/test_helpers.dart';

/// 주입 여부만 보면 되므로, 들어온 메시지를 세는 것으로 충분하다.
class _CountingBle extends BleService {
  int injected = 0;
  final List<bool> confirmations = [];

  @override
  void injectMessage(Map<String, dynamic> message) {
    injected++;
    super.injectMessage(message);
  }

  @override
  Future<void> sendConfirmation(String sequenceId, bool approved) async {
    confirmations.add(approved);
    return super.sendConfirmation(sequenceId, approved);
  }
}

const _bleSuggestion = Suggestion(
  sequenceId: 'demo-gate',
  label: '즉석밥 데워줘',
  steps: ['BT-08', 'BT-05'],
  // 제안은 자기 대상 가전을 설치 목록에서 찾는다. 대상을 못 찾으면 실행
  // 버튼 자체가 안 나오므로, 여기서는 대상을 가진 사용자를 만든다.
  applianceId: 'microwave',
);

Future<_CountingBle> _approve(WidgetTester tester, {required bool demo}) async {
  tester.view.physicalSize = const Size(400, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final ble = _CountingBle()..simulateConnected();
  late ProviderContainer container;
  // 승인은 /status로 이동한다 -- 라우터가 없으면 이동에서 터진다.
  final router = GoRouter(
    initialLocation: '/suggestion',
    routes: [
      GoRoute(
        path: '/suggestion',
        builder: (_, __) => const SuggestionScreen(sequenceId: 'demo-gate'),
      ),
      GoRoute(
        path: '/status',
        builder: (_, __) => const Scaffold(body: Text('상태 화면')),
      ),
    ],
  );
  await tester.pumpWidget(
    buildWithProviderState(
      suggestions: const [_bleSuggestion],
      overrides: [
        ...connectedOverrides(),
        ...installedOverrides([kTestAppliance]),
        bleServiceProvider.overrideWithValue(ble),
      ],
      onContainerReady: (c) => container = c,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();

  container.read(demoModeProvider.notifier).state = demo;
  await tester.pump();

  ble.injected = 0; // 화면을 세우는 동안의 메시지는 세지 않는다
  await tester.tap(find.text('지금 실행'));
  await tester.pump();
  // DemoService는 500ms부터 센서 프레임을 밀어 넣는다.
  await tester.pump(const Duration(milliseconds: 800));
  return ble;
}

void main() {
  testWidgets('데모 모드가 꺼져 있으면 디버그 빌드라도 가짜 센서를 넣지 않는다',
      (tester) async {
    final ble = await _approve(tester, demo: false);
    expect(ble.injected, 0);
    await tester.pump(const Duration(seconds: 5)); // 지연 주입까지 소진
  });

  testWidgets('데모 모드를 켜면 가짜 센서가 들어온다', (tester) async {
    final ble = await _approve(tester, demo: true);
    expect(ble.injected, greaterThan(0));
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('데모 모드에서는 BLE 승인 응답도 나가지 않는다', (tester) async {
    // HTTP만 막으면 BLE로 붙은 실기기가 실제로 움직이는데 화면은
    // "실제 조작이 아닙니다"라고 한다 -- 전송 경로 전부에서 갈라야 한다.
    final ble = await _approve(tester, demo: true);
    expect(ble.confirmations, isEmpty);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('데모가 꺼져 있으면 BLE 승인 응답이 나간다', (tester) async {
    final ble = await _approve(tester, demo: false);
    expect(ble.confirmations, [true]);
    await tester.pump(const Duration(seconds: 5));
  });

  test('기본값은 꺼짐 — 빌드 플래그로만 켜진다', () {
    // --dart-define=SIMPLELAY_DEMO=true 없이 빌드하면 false여야 한다.
    // 백엔드의 SIMPLELAY_* env 게이트와 같은 규칙(기본은 mock/꺼짐이 아니라,
    // 가짜 데이터는 명시적으로 켠 것만).
    expect(kDemoBuildDefault, isFalse);
  });
}
