// 개발자 도구 '기록'의 줄 만들기와 모션 보드 상태의 쉬운 문장(2026-10-26).
//
// 허브의 `GET /dev/log` 한 줄(보낸 명령 + 보드 답)을 사람이 읽는 두 줄로 바꾼다:
//   → 이동 (x 2.0, y 0.0)
//   ← 도착 (2.00, 0.00) 오차 0.06
//   ← 범위 밖이라 거절(ERROR_LIMIT)
// 화면 위젯과 분리해 두어 문장만 따로 시험한다.
import '../services/dev_api_service.dart';

/// 보드 상태 이름(Touch Bridge `ERROR_*`) → 메시지 줄에 쓰는 문장.
String? devBoardStateSentence(String? state) => switch (state) {
      null => null,
      'ERROR_LIMIT' => '움직일 수 있는 범위 밖이라 보드가 거절했어요',
      'ERROR_NOT_HOMED' => '원점이 잡혀 있지 않아 보드가 거절했어요 — 원점을 먼저 눌러 주세요',
      'ERROR_STALL' => '모터가 막혀 보드가 멈췄어요',
      'ERROR_POSITION' => '목표 위치에 맞추지 못해 보드가 멈췄어요',
      'ERROR_TIMEOUT' => '보드가 정해진 시간 안에 동작을 끝내지 못했어요',
      'ERROR_PROTOCOL' => '보드가 명령을 받지 못했어요',
      'ERROR_INVALID_TOKEN' => '누를 위치 확인값이 맞지 않아 보드가 누르지 않았어요',
      final s when s.startsWith('ERROR_') => '보드가 오류를 알렸어요',
      _ => null,
    };

/// 기록 줄에 쓰는 짧은 말.
String _boardStateShort(String state) => switch (state) {
      'ERROR_LIMIT' => '범위 밖이라 거절',
      'ERROR_NOT_HOMED' => '원점이 없어 거절',
      'ERROR_STALL' => '모터가 막혀 멈춤',
      'ERROR_POSITION' => '목표 위치에 못 맞춰 멈춤',
      'ERROR_TIMEOUT' => '시간 안에 못 끝내 멈춤',
      'ERROR_PROTOCOL' => '명령을 받지 못함',
      'ERROR_INVALID_TOKEN' => '위치 확인값이 달라 안 누름',
      _ => '보드 오류',
    };

/// 서버 거절 코드 중 보드에서 온 것 → 문장(보드 상태 이름이 없을 때, 예: 옛 RPi4).
String? devBoardCodeSentence(String code) => switch (code) {
      'soft_limit' => devBoardStateSentence('ERROR_LIMIT'),
      'busy' => '보드가 이전 동작을 하고 있어 거절했어요',
      _ => null,
    };

String _f1(double v) => v.toStringAsFixed(1);
String _f2(double v) => v.toStringAsFixed(2);

/// 보낸 명령을 읽기 쉬운 말로. 보드가 목표를 알려 줬으면 절대 좌표로 쓴다.
String _sentText(DevLogLine line) {
  final command = line.command!;
  final parts = command.split(' ');
  final tx = line.boardNumber('target_x_mm');
  final ty = line.boardNumber('target_y_mm');
  switch (parts.first) {
    case 'jog':
      if (tx != null && ty != null) return '이동 (x ${_f1(tx)}, y ${_f1(ty)})';
      if (parts.length == 4) return '이동 ${parts[1]} ${parts[2]}${parts[3]}mm';
      return '이동';
    case 'home':
      return '원점';
    case 'status':
      return '상태 확인';
    case 'sensor':
      return '센서 읽기';
    case 'press':
      return parts.length > 1 ? '누르기 ${parts.sublist(1).join(' ')}' : '누르기';
    case 'press_here':
      return '현재 위치에서 스위치봇 한 번 누르기';
    case 'stop':
      return '정지';
  }
  return command;
}

String _replyText(DevLogLine line) {
  final state = line.boardState;
  final x = line.boardNumber('x_mm');
  final y = line.boardNumber('y_mm');
  final error = line.boardNumber('error_mm');
  switch (line.event) {
    case 'command_accepted':
      final where = (x != null && y != null) ? ' (${_f2(x)}, ${_f2(y)})' : '';
      if (line.board['reached'] == false) return '목표 전에 멈춤$where';
      if (line.command?.startsWith('jog') ?? false) {
        if (x == null || y == null) return '이동 응답 받음 · 위치 미확인';
        return '도착$where${error != null ? ' 오차 ${_f2(error)}' : ''}';
      }
      return '완료$where';
    case 'command_rejected':
      if (state != null) return '${_boardStateShort(state)}($state)';
      if (line.code == 'soft_limit') return '범위 밖이라 거절(${line.code})';
      if (line.board.isEmpty) {
        // 보드까지 가지 않은 거절 — 허브나 RPi4가 막았다.
        return '보내지 않음: ${line.detail}';
      }
      return '거절: ${line.detail}';
    case 'command_failed':
      if (state != null) return '${_boardStateShort(state)}($state)';
      return '실패: ${line.detail}';
  }
  return line.detail;
}

/// 기록 한 줄 → 화면에 보일 줄들(시각 없이). 명령이면 '→ 보냄'과 '← 답' 두 줄.
List<String> devHistoryRows(DevLogLine line) {
  if (line.command == null) {
    return ['· ${_eventText(line.event)}${line.detail.isEmpty ? '' : ' ${line.detail}'}'];
  }
  return ['→ ${_sentText(line)}', '← ${_replyText(line)}'];
}

String _eventText(String event) => switch (event) {
      'session_started' => '세션 시작',
      'start_rejected' => '세션 시작 거절',
      'stopped' => '정지 확인',
      'stop_unconfirmed' => '정지 미확인',
      'fault_cleared' => '잠금 풂',
      'command_rejected' => '거절',
      _ => event,
    };

String motionTraceRow(Map<String, dynamic> row) {
  final direction = switch (row['direction']) {
    'tx' => '→ 전송 시도',
    'rx' => '← 받음',
    'boot' => '보드 재시작 감지',
    'link_down' => '연결 끊김',
    'timeout' => '응답 시간 초과',
    _ => '통신',
  };
  final x = row['x_mm'];
  final y = row['y_mm'];
  final position = x is num && y is num ? '위치 ($x, $y)mm' : '위치 미확인';
  final tx = row['target_x_mm'];
  final ty = row['target_y_mm'];
  final reason = row['reason'];
  final error = row['error_mm'];
  final settle = row['settle_ms'];
  return '#${row['seq'] ?? '?'} · 기준 ${row['generation'] ?? '?'} · ${row['elapsed_ms'] ?? '?'}ms\n'
      '$direction ${row['action'] ?? row['state'] ?? ''} · ${row['commandId'] ?? '명령 번호 없음'}\n'
      '${row['context_id'] is String ? '실행·요청 ${row['context_id']}\n' : ''}'
      '${tx is num && ty is num ? '목표 ($tx, $ty)mm · ' : ''}$position'
      '${row['homed'] is bool ? ' · 원점 ${row['homed'] == true ? '확인' : '미확인'}' : ''}'
      '${reason == 'SETTLE' ? ' · 정착 실패' : reason == 'TOLERANCE' ? ' · 허용 오차 초과' : ''}'
      '${error is num ? ' · 오차 ${error}mm' : ''}'
      '${settle is int ? ' · 정착 대기 ${settle}ms' : ''}';
}
