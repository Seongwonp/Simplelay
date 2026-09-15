import 'rpi_api_service.dart';

/// 사진 인식 초안을 편집기 격자에 채울 수 없을 때. 메시지는 화면에 그대로 보여줄 문장이다.
class PanelScanFillException implements Exception {
  const PanelScanFillException(this.message);
  final String message;

  @override
  String toString() => 'PanelScanFillException: $message';
}

/// 편집기에 채울 결과.
class PanelScanFill {
  const PanelScanFill({
    required this.rows,
    required this.cols,
    required this.grid,
    required this.filled,
    required this.skipped,
    required this.unnamed,
  });

  final int rows;
  final int cols;

  /// `grid[y][x]` = 라벨, 빈 칸은 null.
  final List<List<String?>> grid;

  /// 채운 버튼 수.
  final int filled;

  /// 앱이 넣지 않은 항목과 이유.
  final List<String> skipped;

  /// 인식이 이름을 읽지 못해 임시 이름이 붙은 버튼 — 사람이 고쳐야 한다.
  final List<String> unnamed;
}

/// 서버 초안 → 편집기 격자.
///
/// **다이얼은 넣지 않는다.** 이 앱의 가전 정의에는 아직 '돌리는 조작'이 없어서,
/// 넣으면 누르는 버튼으로 저장되고 실제로 다이얼을 누르게 된다.
/// 격자가 앱 상한보다 크면 잘라 넣지 않고 거절한다 -- 일부만 넣으면 배치가
/// 사진과 어긋난 채 저장될 수 있다.
PanelScanFill fillFromPanelScan(PanelScanDraft draft, {required int maxGrid}) {
  if (draft.rows < 1 ||
      draft.cols < 1 ||
      draft.rows > maxGrid ||
      draft.cols > maxGrid) {
    throw PanelScanFillException(
      '사진 속 버튼 배치가 ${draft.rows}행 × ${draft.cols}열이라 앱 격자'
      '(최대 $maxGrid × $maxGrid)에 담을 수 없어요. 직접 배치해 주세요.',
    );
  }
  final grid = List.generate(
    draft.rows,
    (_) => List<String?>.filled(draft.cols, null),
  );
  final skipped = <String>[];
  final unnamed = <String>[];
  var filled = 0;
  for (final b in draft.buttons) {
    if (b.kind != 'button') {
      skipped.add("'${b.label}'은(는) 다이얼이라 넣지 않았어요 — 앱은 아직 누르는 버튼만 등록해요");
      continue;
    }
    final inside = b.x >= 0 && b.x < draft.cols && b.y >= 0 && b.y < draft.rows;
    if (!inside || grid[b.y][b.x] != null) {
      skipped.add("'${b.label}'은(는) 위치가 격자와 맞지 않아 넣지 않았어요");
      continue;
    }
    grid[b.y][b.x] = b.label;
    filled++;
    if (!b.labelFromModel) unnamed.add(b.label);
  }
  return PanelScanFill(
    rows: draft.rows,
    cols: draft.cols,
    grid: grid,
    filled: filled,
    skipped: skipped,
    unnamed: unnamed,
  );
}
