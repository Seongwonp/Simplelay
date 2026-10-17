/// 폰이 보여 주는 시각은 한 꼴 — '오전 7:00'·'오후 10:04'(평가 7·8차 10/18).
///
/// 기록·루틴·조용한 시간·잠시 쉬기·LG 가전 읽은 시각·자동으로 하기 문장이 모두 이 파일의 함수를 쓴다.
/// 서버로 보내는 값('HH:MM')과 시간대 판정은 바꾸지 않는다 — 보여 주는 글만.
library;

/// 'HH:MM'(24시) → '오전 7:00'·'오후 10:00'. 모르는 꼴은 그대로 둔다.
String ampmClock(String hhmm) {
  final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(hhmm.trim());
  if (m == null) return hhmm;
  final h = int.parse(m[1]!);
  if (h > 23) return hhmm;
  final h12 = h % 12 == 0 ? 12 : h % 12;
  return '${h < 12 ? '오전' : '오후'} $h12:${m[2]}';
}

/// 문장 안의 'HH:MM'을 [ampmClock] 꼴로('매일 22:00' → '매일 오후 10:00').
String withAmPm(String text) =>
    text.replaceAllMapped(RegExp(r'(?<![\d:])(\d{1,2}:\d{2})(?![\d:])'), (m) => ampmClock(m[1]!));

/// 이 기기 시각 → '오후 10:04'.
String ampmOf(DateTime t) => ampmClock('${t.hour}:${t.minute.toString().padLeft(2, '0')}');

/// 낭독용 — '오후 10시 4분'(0분이면 '오후 10시').
String ampmSpoken(DateTime t) {
  final h12 = t.hour % 12 == 0 ? 12 : t.hour % 12;
  return '${t.hour < 12 ? '오전' : '오후'} $h12시${t.minute == 0 ? '' : ' ${t.minute}분'}';
}

/// 시간대 'HH:MM~HH:MM' → '오후 10:00~오전 7:00'.
String ampmRange(String start, String end) => '${ampmClock(start)}~${ampmClock(end)}';

/// 본체가 규칙 문장에 쓰는 말로 읽은 시각('22:00' → '밤 10시', '07:30' → '아침 7시 30분').
/// 본체 `spoken_time`과 같은 규칙이다 — 이 꼴과 **정확히** 맞는 조각만 [withAmPmSpoken]이 바꾼다.
String? serverSpokenTime(String hhmm) {
  final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(hhmm.trim());
  if (m == null) return null;
  final h = int.parse(m[1]!), min = int.parse(m[2]!);
  if (h > 23 || min > 59) return null;
  final part = h == 0
      ? '밤'
      : h >= 21
          ? '밤'
          : h >= 18
              ? '저녁'
              : h >= 12
                  ? '낮'
                  : h >= 6
                      ? '아침'
                      : '새벽';
  final h12 = h % 12 == 0 ? 12 : h % 12;
  return '$part $h12시${min == 0 ? '' : ' $min분'}';
}

/// 본체 문장 안의 '밤 10시'를 그 규칙의 시각([hhmm])과 정확히 맞을 때만 '오후 10:00'으로. 맞지 않으면 그대로 —
/// 뜻을 추측해 바꾸지 않는다.
String withAmPmSpoken(String text, String? hhmm) {
  if (hhmm == null) return text;
  final spoken = serverSpokenTime(hhmm);
  if (spoken == null) return text;
  final at = RegExp('(?<![가-힣\\d])${RegExp.escape(spoken)}(?!\\s?\\d|\\d)');
  return text.replaceFirst(at, ampmClock(hhmm));
}
