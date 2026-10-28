/// 한글·숫자 낱말 내부에 U+2060을 넣어 중간 줄바꿈을 막는다.
/// 화면 표시에만 사용하고 접근성 이름에는 원문을 사용한다.
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

/// 짧은 말과 숫자가 관련 낱말에서 분리되지 않게 한다.
///
/// 짧은 말 뒤, 숫자 앞, 가운뎃점 앞의 빈칸을 줄바꿈 없는 빈칸으로 바꾼다.
/// [wholeParts]는 길이가 [wholeMax] 이하인 가운뎃점 단위를 함께 묶는다.
/// 화면 표시에만 사용하고 접근성 이름에는 원문을 사용한다.
String keepPhrasesTogether(String text, {bool wholeParts = false, int wholeMax = 12}) {
  final parts = text.split(' · ');
  final glued = parts.map((part) {
    final tokens = part.split(' ');
    final whole = wholeParts && part.length <= wholeMax;
    final glue = <bool>[
      for (var i = 1; i < tokens.length; i++)
        (whole && !tokens[i - 1].endsWith(',')) ||
            _short(tokens[i - 1]) ||
            (tokens[i].isNotEmpty && _isDigit(tokens[i].codeUnitAt(0))),
    ];
    // 세 낱말 넘는 묶음이 짧은 말 이음만으로 통째로 붙으면(평가 13차 10/18: '안 본 알림 4건') 큰 글씨에서 한 줄을
    // 넘쳐 글자 중간('4/건')에서 꺾인다 — 짧은 말 이음 가운데 마지막 하나는 줄을 바꿀 수 있게 남긴다('안 본 / 알림 4건').
    if (!whole && glue.length >= 2 && glue.every((g) => g)) {
      for (var i = glue.length - 1; i >= 0; i--) {
        final next = tokens[i + 1];
        if (!(next.isNotEmpty && _isDigit(next.codeUnitAt(0)))) {
          glue[i] = false;
          break;
        }
      }
    }
    final out = StringBuffer(tokens.first);
    for (var i = 1; i < tokens.length; i++) {
      out
        ..write(glue[i - 1] ? kNoBreakSpace : ' ')
        ..write(tokens[i]);
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

/// 행동 이름의 마지막 낱말이 두 글자 이하면 앞 낱말과 묶는다.
String keepActionNameTogether(String text) {
  final i = text.lastIndexOf(' ');
  if (i <= 0 || text.length - i - 1 > 2) return keepWordsTogether(text);
  return keepWordsTogether('${text.substring(0, i)}$kNoBreakSpace${text.substring(i + 1)}');
}
