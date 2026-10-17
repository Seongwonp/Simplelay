// 줄바꿈 사고 검사(평가 4차 10/18) — 실제로 그려진 글 문단에서 줄이 어디서 바뀌었는지 본다.
//
// '생활 습관 알아가 / 기', '세탁 / 기 설정이 남았어요'처럼 낱말 중간에서 꺾인 줄, 한 글자만 남은 줄,
// 'LG / 가전 설정 1번'처럼 한 덩어리여야 할 말이 갈린 줄을 찾는다. 넘침(overflow)은 렌더 중 예외로 이미 드러난다.
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

final _joiner = String.fromCharCode(0x2060);
final _nbsp = String.fromCharCode(0x00A0);

bool _isWordChar(String c) {
  if (c.isEmpty) return false;
  final u = c.codeUnitAt(0);
  return (u >= 0xAC00 && u <= 0xD7A3) || // 한글 음절
      (u >= 0x30 && u <= 0x39) || // 숫자
      (u >= 0x41 && u <= 0x5A) ||
      (u >= 0x61 && u <= 0x7A);
}

bool _isBlank(String c) => c == ' ' || c == '\n' || c == _nbsp || c == _joiner || c == '\t';

/// 한 문단을 줄로 나눈다 — 줄마다 그 줄에 그려진 글자의 위치(원문 기준).
///
/// 문단의 그려진 폭으로 같은 글을 다시 배치해서 본다 — RenderParagraph의 배치 상태는 고유 폭 계산(가장 좁은 폭)
/// 뒤의 것일 수 있어 그대로 물으면 글자마다 한 줄로 나온다.
List<List<int>> _lines(RenderParagraph p, String text) {
  final painter = TextPainter(
    text: p.text,
    textAlign: p.textAlign,
    textDirection: p.textDirection,
    textScaler: p.textScaler,
    maxLines: p.maxLines,
    ellipsis: p.overflow == TextOverflow.ellipsis ? String.fromCharCode(0x2026) : null,
    strutStyle: p.strutStyle,
    textWidthBasis: p.textWidthBasis,
    locale: p.locale,
  )..layout(maxWidth: p.size.width + 0.5);
  try {
    return _linesOf(painter, text);
  } finally {
    painter.dispose();
  }
}

List<List<int>> _linesOf(TextPainter p, String text) {
  final lines = <List<int>>[];
  double? lastTop;
  for (var i = 0; i < text.length; i++) {
    if (_isBlank(text[i])) continue;
    final boxes = p.getBoxesForSelection(TextSelection(baseOffset: i, extentOffset: i + 1));
    if (boxes.isEmpty) continue;
    final top = boxes.first.top;
    if (lastTop == null || top > lastTop + 1) {
      lines.add([i]);
      lastTop = top;
    } else {
      lines.last.add(i);
    }
  }
  return lines;
}

/// [within] 안(없으면 화면 전체)의 줄바꿈 사고 목록. 비면 통과.
///
/// - 낱말 중간: 앞 줄 끝 글자와 다음 줄 첫 글자 사이에 빈칸이 없고 둘 다 글자·숫자.
/// - 한 글자 줄: 두 줄 이상인 문단에서 글자·숫자가 하나뿐인 줄.
/// - [keepTogether]: 이 말이 문단에 있으면 한 줄에 있어야 한다.
List<String> brokenLines(WidgetTester tester, {Finder? within, List<String> keepTogether = const []}) {
  final problems = <String>[];
  final finder = within == null
      ? find.byType(RichText)
      : find.descendant(of: within, matching: find.byType(RichText));
  for (final element in finder.evaluate()) {
    final p = element.renderObject;
    if (p is! RenderParagraph || !p.hasSize || !p.attached) continue;
    final text = p.text.toPlainText(includeSemanticsLabels: false);
    if (text.contains(String.fromCharCode(0xFFFC))) continue; // 글 속 위젯(아이콘 등)은 따로 배치해야 해서 건너뛴다
    final plain = text.replaceAll(_joiner, '').replaceAll(_nbsp, ' ');
    final lines = _lines(p, text);
    if (lines.length < 2) continue;
    for (var k = 0; k < lines.length; k++) {
      final words = lines[k].where((i) => _isWordChar(text[i])).length;
      if (words == 1 && lines[k].length == 1) {
        problems.add('한 글자 줄: "$plain" → "${text[lines[k].single]}"');
      }
      if (k == 0) continue;
      final a = lines[k - 1].last, b = lines[k].first;
      final between = text.substring(a + 1, b);
      final hasSpace = between.contains(' ') || between.contains('\n');
      if (!hasSpace && _isWordChar(text[a]) && _isWordChar(text[b])) {
        problems.add('낱말 중간: "$plain" → "${text[a]}|${text[b]}"');
      }
    }
    for (final phrase in keepTogether) {
      var from = 0;
      while (true) {
        final at = plain.indexOf(phrase, from);
        if (at < 0) break;
        from = at + 1;
        // plain 위치 → 원문 위치(결합 문자만 빠졌다).
        final raw = <int>[];
        for (var i = 0, j = 0; i < text.length; i++) {
          if (text[i] == _joiner) continue;
          if (j >= at && j < at + phrase.length) raw.add(i);
          j++;
        }
        final lineOf = {
          for (var k = 0; k < lines.length; k++)
            for (final i in lines[k]) i: k,
        };
        final ks = {for (final i in raw) if (lineOf[i] != null) lineOf[i]!};
        if (ks.length > 1) problems.add('묶음이 갈림: "$plain" → "$phrase"');
      }
    }
  }
  return problems;
}

/// [finder]의 글이 몇 줄로 그려졌는지.
int lineCountOf(WidgetTester tester, Finder finder) {
  final p = tester.renderObject(find.descendant(of: finder, matching: find.byType(RichText), matchRoot: true).first);
  if (p is! RenderParagraph) return 0;
  return _lines(p, p.text.toPlainText(includeSemanticsLabels: false)).length;
}
