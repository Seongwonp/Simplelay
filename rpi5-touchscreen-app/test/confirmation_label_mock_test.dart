// 10/6 Copilot 리뷰(66990be): state_confirmed가 모의 판정보다 먼저 처리돼
// 모의 실행에도 "상태 확인됨"이 나왔다. 모의가 앞선다.
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/command_result.dart';

void main() {
  test('모의 실행의 state_confirmed는 연습 결과이다', () {
    expect(
        confirmationLabel(
            route: 'thinq',
            receipt: 'accepted',
            confirmation: 'state_confirmed',
            kind: ResultKind.success,
            executionMode: 'mock'),
        '연습 결과');
  });

  test('실제·미확인 실행은 상태 확인됨 그대로', () {
    for (final mode in ['real', 'uart', 'unknown', null]) {
      expect(
          confirmationLabel(
              route: 'thinq',
              receipt: 'accepted',
              confirmation: 'state_confirmed',
              kind: ResultKind.success,
              executionMode: mode),
          '설정 변경을 확인했어요');
    }
  });
}
