import 'package:flutter/widgets.dart';

/// 어절 단위 줄바꿈(2026-10-16 디자인 규격 §1-3) — 한글은 글자마다 줄이 바뀔 수 있어 "멈/췄는지", "주세/요"처럼
/// 낱말 가운데가 끊겼다. 띄어쓰기 사이에서만 줄을 바꾸도록 낱말 안 글자 사이에 단어 잇기 문자(U+2060 WORD
/// JOINER, 보이지 않고 폭이 없다)를 넣어 그린다. 한 낱말이 한 줄보다 길면 그때만 낱말 안에서 끊긴다.
///
/// 문단 끝 낱말이 한 글자뿐이면("확인하는 중"의 '중') 앞 낱말과 줄 바꾸지 않는 띄어쓰기(U+00A0)로 묶어
/// 한 글자만 다음 줄에 떨어지지 않게 한다. 끝 두 낱말이 합쳐 6자 이하('알려 왔어요'·'봐 주세요'·'누르게 돼요.')면
/// 함께 넘긴다 — 한 덩어리 말이 갈라지거나 마지막 줄에 한 낱말만 남았다(UI 평가 3·4차 10/17).
String keepWords(String text) =>
    text.split('\n').map((p) => _joinWords(_tieLastWord(p))).join('\n');

/// 낱말마다 글자를 묶되 낱말 사이 띄어쓰기는 줄바꿈 자리로 남긴다(평가 16차 10/18 — 정지 단추 '다시 멈추기'가 끝 두 낱말
/// 묶음 때문에 큰 글씨에서 '다시 멈추 / 기'로 끊겼다).
String keepEachWord(String text) => _joinWords(text);

/// 어구 묶기(평가 5차 10/18) — 두 글자 이하 낱말('같이'·'냉동'·'지금')은 뒤 낱말과 줄 바꾸지 않는 띄어쓰기(U+00A0)로 잇는다.
/// 큰 글씨 제안 제목이 '라면이랑 같이 / 먹을 준비,'처럼 꾸미는 말과 꾸밈 받는 말 사이에서 끊겼다. 묶음은 [maxGroup]자
/// (띄어쓰기 포함)까지만 — 너무 긴 덩어리는 오히려 낱말 가운데에서 끊긴다. 끝에 쉼표·마침표가 붙은 낱말은 뒤와 잇지 않는다.
String keepPhrases(String text, {int maxGroup = 10}) => text.split('\n').map((p) {
      final words = p.split(' ');
      if (words.length < 2) return p;
      // seps[i]는 words[i] 앞의 띄어쓰기.
      final seps = List<String>.filled(words.length, ' ');
      var group = words.first.runes.length;
      for (var i = 1; i < words.length; i++) {
        final prev = words[i - 1];
        final w = words[i];
        final short = prev.isNotEmpty &&
            prev.runes.length <= 2 &&
            !RegExp(r'[,.?!·]$').hasMatch(prev);
        if (short && w.isNotEmpty && group + 1 + w.runes.length <= maxGroup) {
          seps[i] = '\u00A0';
          group += 1 + w.runes.length;
        } else if (short && w.isNotEmpty && seps[i - 1] == '\u00A0' &&
            prev.runes.length + 1 + w.runes.length <= maxGroup) {
          // 묶음이 넘치면 짧은 낱말은 앞이 아니라 뒤 낱말과 묶는다(평가 16차 10/18 — '나갈 때 우산 / 챙기세요'처럼
          // 목적어와 서술어 사이에서 끊겼다).
          seps[i - 1] = ' ';
          seps[i] = '\u00A0';
          group = prev.runes.length + 1 + w.runes.length;
        } else {
          group = w.runes.length;
        }
      }
      final out = StringBuffer(words.first);
      for (var i = 1; i < words.length; i++) {
        out
          ..write(seps[i])
          ..write(words[i]);
      }
      return out.toString();
    }).join('\n');

String _tieLastWord(String paragraph) {
  final i = paragraph.lastIndexOf(' ');
  if (i <= 0 || i == paragraph.length - 1) return paragraph;
  final last = paragraph.substring(i + 1);
  final prevStart = paragraph.lastIndexOf(' ', i - 1) + 1;
  final prev = paragraph.substring(prevStart, i);
  // 끝 두 낱말이 합쳐 6자 이하면 함께 넘긴다 — 마지막 줄에 한 낱말만 남지 않게(UI 평가 4차 10/17: '쉬어요'·'누르게 돼요.').
  final shortPair = prev.isNotEmpty && prev.runes.length + last.runes.length <= 6;
  if (last.runes.length != 1 && !shortPair) return paragraph;
  var head = paragraph.substring(0, i);
  // 묶은 덩어리 바로 앞이 한 글자 낱말이면('쓸 수 없어요'의 '쓸') 그것도 함께 넘긴다 — 줄 끝에 한 글자만 남지 않게.
  if (shortPair && prevStart > 1) {
    final before = paragraph.lastIndexOf(' ', prevStart - 2) + 1;
    if (paragraph.substring(before, prevStart - 1).runes.length == 1) {
      head = '${paragraph.substring(0, prevStart - 1)} ${paragraph.substring(prevStart, i)}';
    }
  }
  return '$head $last';
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

/// 짧은 안내 줄의 마침표 규칙(평가 10차 10/18) — 화면의 한 줄 안내·할 일 단계·창 본문은 **끝 마침표 없이**, 두 문장이면
/// 가운데 마침표만 둔다(큰 글자 줄과 같은 규칙, done_view). 서버 문장('…있어요. 우산 챙기세요.')은 끝만 다듬는다 —
/// 음성(TTS)·기록은 서버 문장 그대로다.
String kioskLine(String text) {
  var t = text.trimRight();
  while (t.endsWith('.')) {
    t = t.substring(0, t.length - 1).trimRight();
  }
  return t;
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
    this.phrases = false,
  });

  /// 짧은 낱말을 뒤 낱말과 묶는다([keepPhrases]) — 큰 제목(제안 질문)에만 쓴다.
  final bool phrases;

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
        TextSpan(text: keepWords(phrases ? keepPhrases(data) : data), semanticsLabel: data),
        key: textKey,
        style: style,
        textAlign: textAlign,
        maxLines: maxLines,
        overflow: overflow,
        textWidthBasis: textWidthBasis,
      );
}
