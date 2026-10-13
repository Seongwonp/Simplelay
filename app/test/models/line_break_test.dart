// 한글 낱말 중간 줄바꿈(2026-10-14, 보드 날 발견 7): 홈 루틴 줄 "1단 / 계", 가전 타일 "연결을 확인해 주 / 세요".
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay/models/line_break.dart';

/// [text]를 여러 폭으로 줄 나눔했을 때 [word]의 첫 글자와 끝 글자가 늘 같은 줄인가.
void _expectWordNeverSplit(String text, String word, {double fontSize = 28}) {
  final plain = text.replaceAll('\u2060', '');
  final start = plain.indexOf(word);
  expect(start, greaterThanOrEqualTo(0), reason: '$word not in $plain');
  // 원문 위치 → 결합 문자를 넣은 글의 위치.
  int at(int plainIndex) {
    var seen = -1;
    for (var i = 0; i < text.length; i++) {
      if (text[i] == '\u2060') continue;
      seen++;
      if (seen == plainIndex) return i;
    }
    return -1;
  }

  final first = at(start), last = at(start + word.length - 1);
  for (var w = 600.0; w >= fontSize * word.length + 4; w -= 3) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: TextStyle(fontSize: fontSize)),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: w);
    final a = tp.getBoxesForSelection(TextSelection(baseOffset: first, extentOffset: first + 1));
    final b = tp.getBoxesForSelection(TextSelection(baseOffset: last, extentOffset: last + 1));
    tp.dispose();
    expect((a.first.top - b.first.top).abs() < 1, isTrue,
        reason: '폭 $w에서 "$word"가 두 줄로 갈렸다: $plain');
  }
}

void main() {
  test('같은 낱말의 한글·숫자 사이에만 결합 문자를 넣는다', () {
    expect(keepWordsTogether('세탁기 1단계'), '세\u2060탁\u2060기 1\u2060단\u2060계');
    expect(keepWordsTogether('연결을 확인해 주세요'), '연\u2060결\u2060을 확\u2060인\u2060해 주\u2060세\u2060요');
    expect(keepWordsTogether('평일 07:30 · 전자레인지'), '평\u2060일 0\u20607:3\u20600 · 전\u2060자\u2060레\u2060인\u2060지');
    expect(keepWordsTogether('공기청정기(모의)'), '공\u2060기\u2060청\u2060정\u2060기(모\u2060의)');
    expect(keepWordsTogether(''), '');
  });

  test('"1단계"·"주세요"·"전자레인지"는 어느 폭에서도 낱말 중간에서 갈리지 않는다', () {
    _expectWordNeverSplit(keepWordsTogether('직접 실행할 때 · 세탁기 1\u2060단계'), '1단계');
    _expectWordNeverSplit(keepWordsTogether('직접 실행할 때 · 전자레인지 2단계'), '전자레인지');
    _expectWordNeverSplit(keepWordsTogether('연결을 확인해 주세요'), '주세요', fontSize: 14);
  });
}
