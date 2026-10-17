/// 키오스크 시각 표기(평가 4차 10/18) — 한쪽만 24시로 쓰지 않는다. 모두 오전/오후 12시간제.
/// - 시계: '오전' + '7:08'(숫자는 크게, 오전/오후는 작게).
/// - 그 밖(다음 루틴·예보·조용한 시간·LG 가전 읽은 시각): '오전 7시' · '오후 10시 30분'.
library;

/// 오전/오후. 0시는 오전 12시, 12시는 오후 12시(휴대폰 시계와 같다).
String ampmOf(int hour) => hour < 12 ? '오전' : '오후';

/// 12시간제 시(1~12).
int hour12(int hour) => hour % 12 == 0 ? 12 : hour % 12;

/// 시계 숫자 — '7:08'(오전/오후는 [ampmOf]로 따로).
String clockDigits(int hour, int minute) => '${hour12(hour)}:${minute.toString().padLeft(2, '0')}';

/// 말로 읽는 시각 — '오전 7시' · '오후 10시 30분'.
String spokenTime(int hour, int minute) =>
    '${ampmOf(hour)} ${hour12(hour)}시${minute == 0 ? '' : ' $minute분'}';

/// 'HH:MM' → '오전 7시'. 꼴이 다르면 그대로.
String spokenHhmm(String hhmm) {
  final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(hhmm.trim());
  if (m == null) return hhmm;
  final h = int.parse(m.group(1)!);
  final mi = int.parse(m.group(2)!);
  if (h > 23 || mi > 59) return hhmm;
  return spokenTime(h, mi);
}

/// 예보 칸 이름 '15시' → '오후 3시'. 다른 꼴('내일' 등)은 그대로.
String hourLabel12(String label) {
  final m = RegExp(r'^(\d{1,2})시$').firstMatch(label.trim());
  if (m == null) return label;
  final h = int.parse(m.group(1)!);
  if (h > 23) return label;
  return spokenTime(h, 0);
}
