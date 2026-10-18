/// 키오스크 시각 표기(평가 4차 10/18) — 한쪽만 24시로 쓰지 않는다. 모두 오전/오후 12시간제.
/// - 시계: '오전' + '7:08'(숫자는 크게, 오전/오후는 작게).
/// - 다음 루틴: '오후 10:00'(분까지 — 폰 루틴 화면과 같은 꼴, 평가 13차 10/18).
/// - 그 밖(예보·조용한 시간·LG 가전 읽은 시각): '오전 7시' · '오후 10시 30분'.
/// - 0시(자정)는 어디서나 '밤 12시'([ampmOf]).
library;

/// 오전/오후. 12시는 오후 12시. 0시(자정)는 '밤' — '오전 12시'는 낮 12시로 읽혔다(평가 13차 10/18, 예보 칸).
/// 시계·다음 루틴·예보·조용한 시간이 모두 이 함수를 거친다 — 0시 표기가 한 곳에서 같다.
String ampmOf(int hour) => hour == 0 ? '밤' : (hour < 12 ? '오전' : '오후');

/// 12시간제 시(1~12).
int hour12(int hour) => hour % 12 == 0 ? 12 : hour % 12;

/// 시계 숫자 — '7:08'(오전/오후는 [ampmOf]로 따로).
String clockDigits(int hour, int minute) => '${hour12(hour)}:${minute.toString().padLeft(2, '0')}';

/// 분까지 쓰는 시각 — '오후 10:00'(정각이어도 분까지).
String clockTime(int hour, int minute) => '${ampmOf(hour)} ${clockDigits(hour, minute)}';

/// 말로 읽는 시각 — '오전 7시' · '오후 10시 30분'.
String spokenTime(int hour, int minute) =>
    '${ampmOf(hour)} ${hour12(hour)}시${minute == 0 ? '' : ' $minute분'}';

(int, int)? _hhmm(String hhmm) {
  final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(hhmm.trim());
  if (m == null) return null;
  final h = int.parse(m.group(1)!);
  final mi = int.parse(m.group(2)!);
  if (h > 23 || mi > 59) return null;
  return (h, mi);
}

/// 'HH:MM' → '오전 7시'. 꼴이 다르면 그대로.
String spokenHhmm(String hhmm) {
  final t = _hhmm(hhmm);
  return t == null ? hhmm : spokenTime(t.$1, t.$2);
}

/// 'HH:MM' → '오후 10:00'. 꼴이 다르면 그대로.
String clockHhmm(String hhmm) {
  final t = _hhmm(hhmm);
  return t == null ? hhmm : clockTime(t.$1, t.$2);
}

/// 예보 칸 이름 '15시' → '오후 3시'. 다른 꼴('내일' 등)은 그대로.
String hourLabel12(String label) {
  final m = RegExp(r'^(\d{1,2})시$').firstMatch(label.trim());
  if (m == null) return label;
  final h = int.parse(m.group(1)!);
  if (h > 23) return label;
  return spokenTime(h, 0);
}
