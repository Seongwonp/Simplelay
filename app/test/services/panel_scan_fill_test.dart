import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay/services/panel_scan_fill.dart';
import 'package:simplelay/services/rpi_api_service.dart';

PanelScanButton _b(String label, int x, int y,
        {String kind = 'button', bool named = true}) =>
    PanelScanButton(
      id: 'B-$x$y',
      label: label,
      x: x,
      y: y,
      kind: kind,
      labelFromModel: named,
    );

void main() {
  test('누르는 버튼만 격자에 채우고, 이름 못 읽은 버튼을 따로 모은다', () {
    final fill = fillFromPanelScan(
      PanelScanDraft(rows: 2, cols: 3, buttons: [
        _b('해동', 0, 0),
        _b('버튼 2', 1, 0, named: false),
        _b('출력', 2, 0, kind: 'dial'),
        _b('시작', 2, 1),
      ]),
      maxGrid: 6,
    );

    expect(fill.rows, 2);
    expect(fill.cols, 3);
    expect(fill.grid, [
      ['해동', '버튼 2', null],
      [null, null, '시작'],
    ]);
    expect(fill.filled, 3);
    expect(fill.unnamed, ['버튼 2']);
    // 다이얼을 누르는 버튼으로 저장하면 실제로 다이얼을 누르게 된다.
    expect(fill.skipped.single, contains('다이얼'));
  });

  test('앱 격자보다 큰 초안은 잘라 넣지 않고 거절한다', () {
    for (final size in [(7, 3), (3, 7)]) {
      expect(
        () => fillFromPanelScan(
          PanelScanDraft(rows: size.$1, cols: size.$2, buttons: [_b('시작', 0, 0)]),
          maxGrid: 6,
        ),
        throwsA(isA<PanelScanFillException>()
            .having((e) => e.message, 'message', contains('6줄 6칸까지'))),
      );
    }
  });

  test('격자 밖이거나 같은 칸에 겹친 버튼은 넣지 않는다', () {
    final fill = fillFromPanelScan(
      PanelScanDraft(rows: 1, cols: 2, buttons: [
        _b('전원', 0, 0),
        _b('겹침', 0, 0),
        _b('밖', 5, 0),
      ]),
      maxGrid: 6,
    );

    expect(fill.grid, [
      ['전원', null],
    ]);
    expect(fill.filled, 1);
    expect(fill.skipped, hasLength(2));
  });

  test('다이얼뿐이면 채운 버튼이 0개다', () {
    final fill = fillFromPanelScan(
      PanelScanDraft(rows: 1, cols: 1, buttons: [_b('온도', 0, 0, kind: 'dial')]),
      maxGrid: 6,
    );

    expect(fill.filled, 0);
  });
}
