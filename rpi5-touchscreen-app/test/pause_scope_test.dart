// 잠시 쉬기 범위 문구(2026-10-14 마감 2번) — 서버 /health/detail `dnd_scope`대로 실제 범위만 말한다.
// 업데이트 전 서버에서 켠 잠시 쉬기를 이어받은 동안은 새 제안만 쉰다(자동 실행은 그대로).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/dnd_overlay.dart';

Future<void> _overlay(WidgetTester tester, String? scope) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: DndOverlay(
        dndUntil: DateTime(2026, 10, 14, 23, 30),
        dndScope: scope,
        onSet: (_) {},
        onClear: () {},
        onDismiss: () {},
      ),
    ),
  ));
}

void main() {
  test('health/detail의 dnd_scope를 읽는다(없으면 null)', () {
    final carried = HealthStatus.fromJson({
      'ok': true, 'actuator_ready': true,
      'dnd_until': '2026-10-14T23:30:00+09:00', 'dnd_scope': 'suggestions_only',
    });
    expect(carried.dndScope, 'suggestions_only');
    expect(HealthStatus.fromJson({'ok': true, 'actuator_ready': true}).dndScope, isNull);
  });

  testWidgets('이어받은 잠시 쉬기(옛 범위): 새 제안만 쉬고 자동 실행은 그대로라고 말한다', (tester) async {
    await _overlay(tester, 'suggestions_only');
    expect(find.text('오후 11시 30분까지 새 제안만 띄우지 않아요. 자동 실행은 그대로 해요.'), findsOneWidget);
    expect(find.textContaining('새 제안과 자동 실행을'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('업데이트 뒤 켠 잠시 쉬기(새 범위): 새 제안과 자동 실행을 쉰다고 말한다', (tester) async {
    await _overlay(tester, 'suggestions_and_auto');
    expect(find.text('오후 11시 30분까지 새 제안을 띄우지 않고 자동 실행도 하지 않아요. 직접 누르기와 정지는 그대로 쓸 수 있어요.'), findsOneWidget);
  });
}
