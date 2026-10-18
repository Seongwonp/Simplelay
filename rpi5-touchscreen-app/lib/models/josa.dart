/// 가전 이름 뒤 조사(2026-10-15 문구 개선) — "전자레인지가", "밥솥이"처럼 받침을 보고 고른다.
/// 한글이 아니면(영문 이름 등) 받침이 있는 쪽('이')으로 둔다.
library;

int? _finalConsonant(String word) {
  final trimmed = word.trim();
  if (trimmed.isEmpty) return null;
  final code = trimmed.runes.last;
  if (code < 0xAC00 || code > 0xD7A3) return null;
  return (code - 0xAC00) % 28;
}

/// 이/가를 붙인 낱말.
String withSubject(String word) =>
    '$word${_finalConsonant(word) == 0 ? '가' : '이'}';

/// 을/를을 붙인 낱말 — "공기청정기를", "밥솥을".
String withObject(String word) =>
    '$word${_finalConsonant(word) == 0 ? '를' : '을'}';

/// 은/는을 붙인 낱말 — "오늘은", "내일은", "월요일은"(2차 독립 평가 B, 10/18).
String withTopic(String word) =>
    '$word${_finalConsonant(word) == 0 ? '는' : '은'}';
