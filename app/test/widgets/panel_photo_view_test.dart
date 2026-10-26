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
    // 기다리는 자리는 실사용(10/26)에서 흐린 점선이 안 보여 44 실선 네모·'대기' 글자로 바꿨다.
    final park = find.descendant(of: find.byKey(const Key('mark-park')), matching: find.byType(Container)).first;
    expect(tester.getSize(park), const Size(44, 44));
    final box = tester.widget<Container>(park).decoration! as BoxDecoration;
    expect((box.border! as Border).top.width, greaterThanOrEqualTo(3));
    expect(find.descendant(of: find.byKey(const Key('mark-park')), matching: find.text('대기')), findsOneWidget);
  });

  testWidgets('누름 장치 칸은 원점·X·Y 이름표를 방향대로 붙이고, 귀퉁이를 끌면 끈 만큼 옮긴다', (tester) async {
    var corners = const [PhotoPoint(100, 100), PhotoPoint(900, 100), PhotoPoint(900, 700), PhotoPoint(100, 700)];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 500,
          child: StatefulBuilder(
            builder: (context, setState) => PanelPhotoView(
              photoWidth: 1000,
              photoHeight: 800,
              semanticsLabel: '사진',
              area: PanelArea(
                corners: corners,
                orientation: const AreaOrientation(),
                onCornerMoved: (i, p) => setState(() => corners = [...corners]..[i] = p),
              ),
            ),
          ),
        ),
      ),
    ));
    expect(find.text(kAreaOriginLabel), findsOneWidget);
    expect(find.text('X'), findsOneWidget);
    expect(find.text(kAreaYLabel), findsOneWidget);
    // 기본 방향: 원점 왼쪽 아래.
    expect(tester.getCenter(find.text(kAreaOriginLabel)).dy, greaterThan(300));
    // 한 프레임 안에 여러 번 움직여도(빠른 손가락) 끈 거리를 다 따른다.
    await tester.drag(find.byKey(const Key('area-corner-0')), const Offset(50, 25));
    await tester.pump();
    expect(corners[0].x, closeTo(200, 0.5));
    expect(corners[0].y, closeTo(150, 0.5));
  });

  testWidgets("귀퉁이 표시는 가전 추가 화면과 같은 말('귀퉁이')로 읽어요", (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          child: PanelPhotoView(
            photoWidth: 1000,
            photoHeight: 800,
            semanticsLabel: '사진',
            marks: [PanelMark(id: 'corner-0', kind: PanelMarkKind.corner, point: PhotoPoint(100, 80), number: 1)],
          ),
        ),
      ),
    ));
    // 표시의 이름은 사진 이름과 한 마디로 합쳐 읽힌다('사진' 다음 줄).
    expect(find.bySemanticsLabel(RegExp('1번 귀퉁이')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('모서리')), findsNothing);
    handle.dispose();
  });
}
