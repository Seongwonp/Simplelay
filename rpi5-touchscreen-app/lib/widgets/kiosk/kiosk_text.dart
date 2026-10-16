import 'package:flutter/widgets.dart';

/// 어절 단위 줄바꿈(2026-10-16 디자인 규격 §1-3) — 한글은 글자마다 줄이 바뀔 수 있어 "멈/췄는지", "주세/요"처럼
/// 낱말 가운데가 끊겼다. 띄어쓰기 사이에서만 줄을 바꾸도록 낱말 안 글자 사이에 단어 잇기 문자(U+2060 WORD
/// JOINER, 보이지 않고 폭이 없다)를 넣어 그린다. 한 낱말이 한 줄보다 길면 그때만 낱말 안에서 끊긴다.
///
/// 문단 끝 낱말이 한 글자뿐이면("확인하는 중"의 '중') 앞 낱말과 줄 바꾸지 않는 띄어쓰기(U+00A0)로 묶어
/// 한 글자만 다음 줄에 떨어지지 않게 한다.
String keepWords(String text) =>
    text.split('\n').map((p) => _joinWords(_tieLastWord(p))).join('\n');

String _tieLastWord(String paragraph) {
  final i = paragraph.lastIndexOf(' ');
  if (i <= 0 || i == paragraph.length - 1) return paragraph;
  final last = paragraph.substring(i + 1);
  if (last.runes.length != 1) return paragraph;
  return '${paragraph.substring(0, i)} $last';
}

String _joinWords(String text) {
  final runes = text.runes.toList();
  final out = StringBuffer();
  for (var i = 0; i < runes.length; i++) {
    out.writeCharCode(runes[i]);
    if (i + 1 < runes.length && !_breakable(runes[i]) && !_breakable(runes[i + 1])) {
      out.writeCharCode(0x2060);
    }
  }
  return out.toString();
}

bool _breakable(int rune) => rune == 0x20 || rune == 0x0A || rune == 0x09 || rune == 0x2060;

/// [keepWords]로 그리는 글. 화면 읽기(semantics)와 글 찾기에는 원래 문장이 그대로 쓰인다 — 그리는 글자에만
/// 단어 잇기 문자가 들어간다([TextSpan.semanticsLabel]). [textKey]는 안쪽 [Text]에 붙는다(시험이 `Text`로 찾는다).
class KioskText extends StatelessWidget {
  const KioskText(
    this.data, {
    super.key,
    this.textKey,
    this.style,
    this.textAlign,
    this.maxLines,
    this.overflow,
    this.textWidthBasis,
  });

  final String data;
  final TextStyle? style;
  final TextAlign? textAlign;
  final int? maxLines;
  final TextOverflow? overflow;
  final Key? textKey;

  /// 여러 줄일 때 글 상자 폭을 가장 긴 줄에 맞출지(정지 단추처럼 아이콘 옆에 붙여 가운데 둘 때).
  final TextWidthBasis? textWidthBasis;

  @override
  Widget build(BuildContext context) => Text.rich(
        TextSpan(text: keepWords(data), semanticsLabel: data),
        key: textKey,
        style: style,
        textAlign: textAlign,
        maxLines: maxLines,
        overflow: overflow,
        textWidthBasis: textWidthBasis,
      );
}
