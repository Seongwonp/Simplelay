/// 실행·결과 화면 제목 규칙(평가 4차 10/18) — 사람이 한 명령문('즉석밥 데워줘')을 제목에 그대로 쓰지 않고
/// 행동 이름('즉석밥 데우기')으로. 폰 기록 제목(`app/lib/models/display_status.dart`의 `actionName`)과 같은 규칙이다.
/// 끝 동사를 모르면 문장을 그대로 둔다(지어내지 않는다).
library;

// 끝 동사 → 행동 이름. '줘'·'주세요'·'요'·'까요'를 뗀 줄기로 찾는다.
const _verbStems = {
  '켜': '켜기', '켤': '켜기',
  '꺼': '끄기', '끌': '끄기',
  '데워': '데우기', '데울': '데우기',
  '끓여': '끓이기', '끓일': '끓이기',
  '잠가': '잠그기', '잠글': '잠그기',
  '바꿔': '바꾸기', '바꿀': '바꾸기',
  '눌러': '누르기', '누를': '누르기',
  '돌려': '돌리기', '돌릴': '돌리기',
  '열어': '열기', '열': '열기',
  '틀어': '틀기', '틀': '틀기',
  '멈춰': '멈추기', '멈출': '멈추기',
  '줄여': '줄이기', '줄일': '줄이기',
  '올려': '올리기', '올릴': '올리기',
  '낮춰': '낮추기', '낮출': '낮추기',
  '높여': '높이기', '높일': '높이기',
  '해': '하기', '할': '하기',
};

/// 명령·질문·해요체 문장을 행동 이름('공기청정기 켜기')으로. 설정표 말('풍량'·'전원 켜기')도 쉬운 말로.
String actionName(String text) {
  var t = text.trim();
  while (t.isNotEmpty && '.!?'.contains(t[t.length - 1])) {
    t = t.substring(0, t.length - 1).trimRight();
  }
  final words = t.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return text.trim();
  // '꺼 줘'처럼 띄어 쓴 도움말을 붙인다.
  if (words.length > 1 && const {'줘', '주세요', '줄래', '줄래요'}.contains(words.last)) {
    final aux = words.removeLast();
    words[words.length - 1] = words.last + aux;
  }
  final last = words.last;
  String? stem;
  for (final end in const ['주세요', '줄래요', '줄래', '까요', '줘', '요']) {
    if (last.length > end.length && last.endsWith(end)) {
      stem = last.substring(0, last.length - end.length);
      break;
    }
  }
  if (stem != null) {
    final mapped = _verbStems[stem] ??
        // '실행해'·'시작할' → '실행하기'·'시작하기'
        ((stem.endsWith('해') || stem.endsWith('할')) && stem.length > 1
            ? '${stem.substring(0, stem.length - 1)}하기'
            : null);
    if (mapped != null) {
      words[words.length - 1] = mapped;
      // 목적격 조사(을/를)를 뗀다 — '풍량을 강으로' → '풍량 강으로'. 따옴표로 끝난 이름은 건드리지 않는다.
      for (var i = 0; i < words.length - 1; i++) {
        final w = words[i];
        if (w.length > 1 && (w.endsWith('을') || w.endsWith('를'))) {
          words[i] = w.substring(0, w.length - 1);
        }
      }
    }
  }
  return words
      .join(' ')
      .replaceAll('풍량', '바람 세기')
      .replaceAll('전원 켜기', '켜기')
      .replaceAll('전원 끄기', '끄기');
}
