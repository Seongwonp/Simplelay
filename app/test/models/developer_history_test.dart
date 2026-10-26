// 개발자 기록 줄 만들기·보드 상태 문장(2026-10-26).
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay/models/developer_history.dart';
import 'package:simplelay/services/dev_api_service.dart';

DevLogLine _line(String event,
        {String? command,
        String? code,
        String detail = '',
        Map<String, Object> board = const {}}) =>
    DevLogLine(
      at: DateTime(2026, 10, 26, 14),
      event: event,
      detail: detail,
      command: command,
      code: code,
      board: board,
    );

void main() {
  test('보드 상태 이름은 쉬운 문장으로', () {
    expect(devBoardStateSentence('ERROR_LIMIT'), '움직일 수 있는 범위 밖이라 보드가 거절했어요');
    expect(devBoardStateSentence('ERROR_STALL'), '모터가 막혀 보드가 멈췄어요');
    expect(devBoardStateSentence('ERROR_SOMETHING_NEW'), '보드가 오류를 알렸어요');
    expect(devBoardStateSentence(null), isNull);
    expect(devBoardCodeSentence('soft_limit'), '움직일 수 있는 범위 밖이라 보드가 거절했어요');
    expect(devBoardCodeSentence('not_homed'), isNull);
  });

  test('보드까지 가지 않은 거절은 보내지 않았다고 쓴다', () {
    final rows = devHistoryRows(_line('command_rejected',
        command: 'jog x + 3', code: 'step_too_large', detail: '한 번에 1mm까지만 움직여요'));
    expect(rows, ['→ 이동 x +3mm', '← 보내지 않음: 한 번에 1mm까지만 움직여요']);
  });

  test('목표 전에 멈춘 조그와 움직인 뒤 알람', () {
    expect(
        devHistoryRows(_line('command_accepted',
            command: 'jog y + 1',
            board: {'x_mm': 0.0, 'y_mm': 0.4, 'reached': false})),
        ['→ 이동 y +1mm', '← 목표 전에 멈춤 (0.00, 0.40)']);
    expect(
        devHistoryRows(_line('command_failed',
            command: 'jog x + 1',
            code: 'motion_alarm',
            board: {'board_state': 'ERROR_STALL', 'target_x_mm': 1.0, 'target_y_mm': 0.0})),
        ['→ 이동 (x 1.0, y 0.0)', '← 모터가 막혀 멈춤(ERROR_STALL)']);
  });

  test('명령이 아닌 기록은 한 줄', () {
    expect(devHistoryRows(_line('stopped', detail: 'user_stop')), ['· 정지 확인 user_stop']);
    expect(devHistoryRows(_line('command_accepted', command: 'home')), ['→ 원점', '← 완료']);
  });
}
