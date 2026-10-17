// 글자 200%에서 화면이 넘치지 않는지 — 실제 화면을 실제 뷰포트에 렌더해서 본다.
//
// 글자를 키운 사용자일수록 안내나 조작을 잃는다. 오버플로는 렌더 중 예외로
// 드러나므로, 여기서는 "띄워보는 것" 자체가 검증이다.
//
// 골든이 있는 화면(홈·제안·상태·설정·수동)은 그쪽에서 이미 200%로 찍히지만,
// 첫 실행 안내·음성 화면과 '다시 찾기' 같은 특정 상태는 비어 있었다.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay/models/execution_status.dart';
import 'package:simplelay/providers/voice_provider.dart';
import 'package:simplelay/screens/onboarding_screen.dart';
import 'package:simplelay/screens/status_screen.dart';
import 'package:simplelay/screens/voice_screen.dart';

import '../helpers/test_helpers.dart';

const _phone = Size(390, 844);

/// 오인식이 길게 잡힌 상황 — 짧은 문장만 가정하면 이 화면은 쉽게 넘친다.
const _longHeard = '즉석밥 데워줘 그리고 에어컨도 켜줘 아니 잠깐만 다시 말할게 냉동식품 데워줘';

Future<void> _pumpAt200(
  WidgetTester tester,
  Widget screen, {
  List<Override> overrides = const [],
  ExecutionStatus? executionStatus,
}) async {
  tester.view.physicalSize = _phone;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    buildWithProviderState(
      overrides: overrides,
      executionStatus: executionStatus,
      child: MaterialApp(
        theme: ThemeData.dark(),
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
          child: screen,
        ),
      ),
    ),
  );
  await tester.pump();
  // 지연 애니메이션(파형 등)이 시작된 뒤에도 넘치지 않아야 한다.
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('첫 실행 안내가 200%에서 넘치지 않는다', (tester) async {
    await _pumpAt200(tester, const OnboardingScreen());
  });

  testWidgets('음성 화면이 긴 인식 문장 + 200%에서 넘치지 않는다', (tester) async {
    await _pumpAt200(
      tester,
      const VoiceScreen(),
      overrides: [
        voiceTextProvider.overrideWith((ref) => _longHeard),
      ],
    );
  });

  testWidgets('재시도 배너가 200%에서 넘치지 않는다', (tester) async {
    await _pumpAt200(
      tester,
      const StatusScreen(),
      executionStatus: const ExecutionStatus(
        phase: ExecutionPhase.retrying,
        label: '즉석밥 데워줘',
        message: '응답이 없어 다시 시도 중입니다.',
        currentButton: '1분 추가',
        totalSteps: 3,
        completedSteps: 1,
        currentAttempt: 2,
      ),
    );
  });
}
