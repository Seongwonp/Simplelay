/// 한글 낱말 중간에서 줄이 꺾이지 않게(2026-10-14, 보드 날 발견 7).
///
/// Flutter는 한글 음절 사이 어디서나 줄을 바꾼다. 큰 글씨·좁은 폭에서 "세탁기 1단 / 계", "연결을 확인해 주 / 세요"처럼
/// 낱말 중간이 갈렸다. 같은 낱말 안의 한글 음절·숫자 사이에 단어 결합 문자(U+2060)를 넣어 낱말 경계(빈칸)에서만
/// 줄이 바뀌게 한다 — 숫자와 단위 사이에 이미 쓰던 방식(외부 평가 2026-10-13 L3)을 낱말 전체로 넓힌 것이다.
/// 화면 글자에만 쓴다. 접근성 이름에는 원문을 쓴다.
String keepWordsTogether(String text) {
  const joiner = 0x2060;
  final runes = text.runes.toList();
  final out = StringBuffer();
  for (var i = 0; i < runes.length; i++) {
    final c = runes[i];
    out.writeCharCode(c);
    if (i + 1 >= runes.length) continue;
    final next = runes[i + 1];
    if (_joinable(c) && _joinable(next)) out.writeCharCode(joiner);
  }
  return out.toString();
}

bool _joinable(int c) =>
    (c >= 0xAC00 && c <= 0xD7A3) || // 한글 음절
    (c >= 0x30 && c <= 0x39); // 숫자

/// 줄바꿈 없는 빈칸(U+00A0).
final kNoBreakSpace = String.fromCharCode(0x00A0);

/// 짧은 말과 숫자가 앞뒤 낱말에서 떨어지지 않게(평가 4차 10/18: 'LG / 가전 설정 1번', '읽지 않은 알림 / 4건').
///
/// [keepWordsTogether](낱말 안)에 더해, 다음 빈칸을 줄바꿈 없는 빈칸으로 바꾼다.
/// - 한 글자 말·짧은 영문 뒤('끝 알림', '안 해요', 'LG 가전') — 짧은 말만 줄 끝에 홀로 남지 않게.
/// - 숫자로 시작하는 말 앞('알림 4건', '설정 1번', '매일 22:00') — 숫자가 무엇의 숫자인지와 붙어 있게.
/// - 가운뎃점 앞(' · ') — 가운뎃점이 줄 머리에 오지 않게. 가운뎃점 뒤에서는 줄을 바꿀 수 있다.
/// - [wholeParts]면 가운뎃점으로 나뉜 묶음('LG 가전 설정 1번') 하나를 통째로 붙인다(12자까지). 보통 글씨에서만
///   켠다 — 큰 글씨에서는 묶음이 한 줄보다 길어져 오히려 글자 중간에서 꺾인다.
/// 화면 글자에만 쓴다. 접근성 이름에는 원문을 쓴다.
String keepPhrasesTogether(String text, {bool wholeParts = false}) {
  final parts = text.split(' · ');
  final glued = parts.map((part) {
    final tokens = part.split(' ');
    final whole = wholeParts && part.length <= 12;
    final out = StringBuffer(tokens.first);
    for (var i = 1; i < tokens.length; i++) {
      final prev = tokens[i - 1], next = tokens[i];
      final glue = (whole && !prev.endsWith(',')) ||
          _short(prev) ||
          (next.isNotEmpty && _isDigit(next.codeUnitAt(0)));
      out
        ..write(glue ? kNoBreakSpace : ' ')
        ..write(next);
    }
    return out.toString();
  }).join('$kNoBreakSpace· ');
  return keepWordsTogether(glued);
}

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

/// 한 글자 말('끝'·'안'·'내') 또는 세 글자 이하 영문('LG'). 쉼표로 끝난 말은 아니다.
bool _short(String t) =>
    t.isNotEmpty &&
    !t.endsWith(',') &&
    (t.length == 1 || (t.length <= 3 && RegExp(r'^[A-Za-z]+$').hasMatch(t)));
