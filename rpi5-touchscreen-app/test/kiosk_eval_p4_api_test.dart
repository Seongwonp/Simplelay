// 평가 4차(2026-10-18) — 새 순수 함수 단위 시험: 실행·결과 제목 규칙(actionName, 폰 기록 제목과 같은 규칙)과
// 시각 표기(오전/오후 12시간제).
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/action_name.dart';
import 'package:simplelay_touchscreen/models/ambient.dart';
import 'package:simplelay_touchscreen/models/kiosk_time.dart';

void main() {
  group('실행·결과 제목은 ~하기', () {
    for (final (said, title) in const [
      ('즉석밥 데워줘', '즉석밥 데우기'),
      ('공기청정기 켜 줘', '공기청정기 켜기'),
      ('공기청정기 켤까요?', '공기청정기 켜기'),
      ('공기청정기 꺼주세요.', '공기청정기 끄기'),
      ('세탁기 시작해줘', '세탁기 시작하기'),
      ('공기청정기 풍량을 강으로 바꿔줘', '공기청정기 바람 세기 강으로 바꾸기'),
      // 이미 행동 이름이거나 모르는 끝말은 그대로(지어내지 않는다).
      ('아침 데우기', '아침 데우기'),
      ('전자레인지', '전자레인지'),
      ('냉동 만두 데워서 라면이랑 같이 먹을 저녁 준비', '냉동 만두 데워서 라면이랑 같이 먹을 저녁 준비'),
    ]) {
      test('$said → $title', () => expect(actionName(said), title));
    }
  });

  group('시각 표기는 오전/오후 하나로', () {
    test('시계 숫자와 오전/오후', () {
      expect(ampmOf(0), '오전');
      expect(ampmOf(11), '오전');
      expect(ampmOf(12), '오후');
      expect(ampmOf(23), '오후');
      expect(clockDigits(7, 8), '7:08');
      expect(clockDigits(0, 5), '12:05');
      expect(clockDigits(23, 41), '11:41');
    });

    test('말로 읽는 시각 — 정각은 시만', () {
      expect(spokenTime(7, 0), '오전 7시');
      expect(spokenTime(22, 30), '오후 10시 30분');
      expect(spokenHhmm('07:00'), '오전 7시');
      expect(spokenHhmm('12:00'), '오후 12시');
      expect(spokenHhmm('모름'), '모름');
    });

    test("예보 칸 '15시' → '오후 3시', 다른 꼴은 그대로", () {
      expect(hourLabel12('15시'), '오후 3시');
      expect(hourLabel12('0시'), '오전 12시');
      expect(hourLabel12('9시'), '오전 9시');
      expect(hourLabel12('내일'), '내일');
    });

    test('다음 루틴: 언제는 오전/오후, 방식은 사람 말', () {
      const auto = KioskNextRun(name: '아침 공기청정기 끄기', dayLabel: '오늘', hhmm: '07:00', modeLabel: '자동 실행');
      expect(auto.when, '오늘 오전 7시');
      expect(auto.modeWord, '자동으로 해요');
      const ask = KioskNextRun(name: '저녁 데우기', dayLabel: '', hhmm: '19:30', modeLabel: '승인 후 실행');
      expect(ask.when, '오후 7시 30분');
      expect(ask.modeWord, '물어보고 해요');
    });
  });
}
