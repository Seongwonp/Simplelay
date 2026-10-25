// 키오스크 QA(2026-10-24) — 기록 탭: 연습 기록도 결과(멈춤·실패…)를 함께 말하고, 이름은 누른 버튼('30초 → 시작').
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/kiosk_history.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/help_guide.dart';

KioskHistoryEntry _e(String id,
        {String status = 'succeeded', String? outcome, String mode = 'mock', String? purpose, List<String> buttons = const []}) =>
    KioskHistoryEntry.fromJson({
      'job_id': id,
      'finished_at': '2026-10-24T12:00:00+09:00',
      'status': status,
      if (outcome != null) 'outcome': outcome,
      if (purpose != null) 'purpose': purpose,
      'route': 'physical',
      'confirmation': 'press_confirmed',
      'execution_mode': mode,
      'appliance_id': 'microwave',
      'appliance_name': '전자레인지',
      'buttons': [for (final b in buttons) {'button': b}],
    })!;

void main() {
  helpMain();
  test('연습 기록은 연습과 결과를 함께', () {
    expect(_e('a', outcome: 'success').result.$1, '연습 · 완료');
    expect(_e('b', status: 'stopped', outcome: 'stopped').result.$1, '연습 · 멈춤');
    expect(_e('c', status: 'failed', outcome: 'failed').result.$1, '연습 · 실패');
    expect(_e('d', status: 'stopped', outcome: 'stopped').result.$2, KioskHistoryTone.stopped);
    // 실제 기록은 그대로.
    expect(_e('e', mode: 'real', outcome: 'success').result.$1, '완료');
  });

  test("이름은 누른 버튼 차례('30초 → 시작'), 목적 문장이 있으면 그 이름", () {
    expect(_e('a', buttons: ['30초', '시작']).title(), '전자레인지 30초 → 시작');
    expect(_e('b', buttons: ['해동']).title(), '전자레인지 해동 버튼 누르기');
    expect(_e('c', buttons: ['30초', '시작'], purpose: "'30초 데우기' 루틴").title(), '30초 데우기');
  });
}

void helpMain() {
  test("사용 방법 — 기록은 키오스크 '기록' 탭에서, 첫 장은 아래 탭을 말한다", () {
    final last = kHelpPages.last.body;
    expect(last, contains('기록 탭'));
    expect(last, isNot(contains('기록 보기')));
    expect(last, contains('자동 실행 끄기'));
    expect(kHelpPages.first.body, contains('화면 아래 단추'));
  });
}
