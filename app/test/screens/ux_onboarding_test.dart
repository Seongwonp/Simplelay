import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay/screens/onboarding_screen.dart';

void main() {
  testWidgets('첫 안내는 허브 연결과 실제 탭을 설명해요', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: OnboardingScreen()));
    expect(find.text('본체 연결'), findsOneWidget);
    expect(find.text('내 루틴'), findsOneWidget);
    expect(find.textContaining('RPi5'), findsNothing);
    expect(find.textContaining('자동 접속'), findsNothing);
    expect(find.text('시작하기'), findsOneWidget);
  });
}
