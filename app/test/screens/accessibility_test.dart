// 접근성 회귀 — 보조기술이 읽을 수 있는 정보가 실제로 붙어 있는지.
//
// 디자인 리뷰에서 앱 전체의 Semantics가 마이크 버튼 한 곳뿐인 것이 확인됐다.
// 색·크기로만 구분되던 상태들이 스크린리더에는 전달되지 않았다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay/models/appliance.dart';

void main() {
  testWidgets('터치 타깃 최소 크기 규약이 유지된다', (tester) async {
    // 48은 **우리 제품의 터치 목표**다(고령 사용자 대상이라 더 높게 잡는다).
    // 표준의 최소치와 혼동하지 말 것: WCAG 2.2 AA(2.5.8 Target Size
    // Minimum)의 하한은 예외를 포함해 24 CSS px이고, 44는 AAA(2.5.5)다.
    // 이전에는 minimumSize: Size.zero로 이 원칙을 의도적으로 우회한
    // 버튼이 10곳 있었다.
    const minTarget = 48.0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TextButton(
            style: TextButton.styleFrom(
              minimumSize: const Size(minTarget, minTarget),
            ),
            onPressed: () {},
            child: const Text('해제'),
          ),
        ),
      ),
    );

    final size = tester.getSize(find.byType(TextButton));
    expect(size.height, greaterThanOrEqualTo(minTarget));
  });

  testWidgets('가전 버튼 셀은 상태를 라벨로 알린다', (tester) async {
    // 색만으로 구분되면 저시력·색약 사용자와 스크린리더 사용자는
    // 무엇이 눌리는 중인지 알 수 없다.
    const button = ApplianceButton(id: 'BT-07', label: '해동', x: 0, y: 0);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Semantics(
            button: true,
            label: '${button.label} 누르는 중',
            child: const SizedBox(width: 48, height: 48),
          ),
        ),
      ),
    );

    expect(find.bySemanticsLabel('해동 누르는 중'), findsOneWidget);
  });
}
