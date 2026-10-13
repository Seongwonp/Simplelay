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
