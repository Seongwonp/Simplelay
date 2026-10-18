// 연습용 LG 세탁기(2026-10-18, 사용자 요청) — 실제 공기청정기 옆에 서버가 세우는 모의 세탁기.
//
// - 세탁기 상태(runState·timer·remoteControlEnable)를 사람 말 줄로 보인다(모르는 값은 그대로).
// - 조작은 서버 대응표와 같은 '빨래 시작·잠시 멈춤'(set_operation START·STOP), 한 번 묻는 문장은 빨래 말로.
// - 공기청정기 표·문장은 그대로다.
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay/widgets/thinq_state_card.dart';

const _washer = <String, dynamic>{
  'runState': {'currentState': 'RUNNING'},
  'remoteControlEnable': {'remoteControlEnabled': true},
  'timer': {'remainHour': 0, 'remainMinute': 45},
};

void main() {
  test('세탁기 상태 줄: 빨래하는 중 · 남은 시간 45분 · 휴대폰으로 시작 켜져 있어요', () {
    expect(thinqStateRows(_washer), [
      ('빨래', '빨래하는 중'),
      ('남은 시간', '45분'),
      ('휴대폰으로 시작', '켜져 있어요'),
    ]);
  });

  test('모르는 운전 상태는 그대로, 남은 시간은 시간·분', () {
    expect(thinqStateRows({'runState': {'currentState': 'SOMETHING'}}), [('빨래', 'SOMETHING')]);
    expect(thinqRemainText(1, 5), '1시간 5분');
    expect(thinqRemainText(2, 0), '2시간');
    expect(thinqRemainText(null, null), isNull);
  });

  test('세탁기 조작 줄: 빨래 시작·잠시 멈춤, 지금 값은 운전 상태에서', () {
    final running = thinqControlsFor(_washer).single;
    expect(running.action, 'set_operation');
    expect(running.arg, 'operation');
    expect(running.choices, [('START', '시작'), ('STOP', '잠시 멈춤')]);
    expect(running.current, 'START');
    expect(thinqControlsFor({'runState': {'currentState': 'PAUSE'}}).single.current, 'STOP');
    expect(thinqControlsFor({'runState': {'currentState': 'INITIAL'}}).single.current, isNull);
    expect(running.question('START', '시작'), '빨래를 시작할까요?');
    expect(running.question('STOP', '잠시 멈춤'), '빨래를 잠시 멈출까요?');
  });

  test('공기청정기 조작 줄은 그대로', () {
    final controls = thinqControlsFor({
      'operation': {'airPurifierOperationMode': 'POWER_ON'},
      'airFlow': {'windStrength': 'LOW'},
    });
    expect(controls.map((c) => c.action), ['set_power', 'set_wind_strength', 'set_job_mode']);
  });
}
