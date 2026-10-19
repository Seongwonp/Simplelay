// 사진 위 표시의 터치 크기(첫 사용 검토 10/19 #16): 버튼 표시는 44, 기다리는 자리는 40이라 접근성 최소 48dp보다 작았다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay/models/hub.dart';
import 'package:simplelay/widgets/panel_photo_view.dart';

void main() {
  testWidgets('누를 수 있는 표시는 모두 48×48 이상이고, 그림 크기는 그대로예요', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          child: PanelPhotoView(
            photoWidth: 1000,
            photoHeight: 800,
            semanticsLabel: '사진',
            onTapMark: (_) {},
            marks: const [
              PanelMark(id: 'b', kind: PanelMarkKind.button, point: PhotoPoint(300, 300), label: '시작'),
              PanelMark(id: 's', kind: PanelMarkKind.stop, point: PhotoPoint(600, 300), label: '취소'),
              PanelMark(id: 'park', kind: PanelMarkKind.park, point: PhotoPoint(500, 600)),
            ],
          ),
        ),
      ),
    ));
    for (final id in ['b', 's', 'park']) {
      final size = tester.getSize(find.byKey(Key('mark-$id')));
      expect(size.width, greaterThanOrEqualTo(48), reason: id);
      expect(size.height, greaterThanOrEqualTo(48), reason: id);
    }
    // 기다리는 자리의 점선 사각형은 종전처럼 40.
    final park = find.descendant(of: find.byKey(const Key('mark-park')), matching: find.byType(CustomPaint)).first;
    expect(tester.getSize(park), const Size(40, 40));
  });
}
