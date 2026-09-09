// 가전 그림의 **분기**를 고정한다.
//
// 골든으로 덮지 않는 이유: 위젯 테스트는 파일 이미지를 실제로 디코딩하지
// 못해서, 사진이 있는 화면도 빈 프레임으로 찍힌다. 그런 골든은 "사진 경로를
// 덮는다"고 말하면서 아무것도 검증하지 않는다. 픽셀 대신 **어느 쪽을
// 골랐는지**를 본다.
//
// 실제 사진이 화면에 어떻게 앉는지는 실기기 확인으로 남긴다.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay/models/appliance.dart';
import 'package:simplelay/widgets/appliance_portrait.dart';

ApplianceMap _appliance({String? photoPath}) => ApplianceMap(
      id: 'microwave',
      name: '전자레인지',
      category: ApplianceCategory.microwave,
      rows: 2,
      cols: 2,
      buttons: const [],
      photoPath: photoPath,
    );

/// 1×1 투명 PNG. 사용자 사진을 테스트에 들이지 않기 위한 최소 fixture다
/// (개인정보 경계 — 사진은 그 폰의 로컬 데이터로만 둔다).
final _pngBytes = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);

Future<Widget> _wrap(ApplianceMap appliance) async => MaterialApp(
      home: Scaffold(
        body: AppliancePortrait(appliance: appliance, size: 160),
      ),
    );

void main() {
  group('AppliancePortrait', () {
    testWidgets('사진이 있으면 그 사진을 쓴다', (tester) async {
      final dir = Directory.systemTemp.createTempSync('portrait_test');
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {
          // 윈도우는 이미지가 열려 있으면 파일을 놓아주지 않는다.
          // 임시 폴더 정리 실패로 테스트를 깨뜨리지 않는다.
        }
      });
      final file = File('${dir.path}/a.png')..writeAsBytesSync(_pngBytes);

      await tester.pumpWidget(
        await _wrap(_appliance(photoPath: file.path)),
      );

      expect(find.byType(Image), findsOneWidget);
    });

    testWidgets('사진이 없으면 실루엣을 그린다', (tester) async {
      await tester.pumpWidget(await _wrap(_appliance()));

      expect(find.byType(Image), findsNothing);
      expect(find.byType(CustomPaint), findsWidgets);
    });

    testWidgets('경로만 있고 파일이 없으면 실루엣으로 떨어진다', (tester) async {
      // 다른 폰에서 등록한 가전을 내려받으면 **경로만** 따라온다. 그때
      // 깨진 이미지 자리가 남으면 화면이 고장난 것처럼 보인다.
      await tester.pumpWidget(
        await _wrap(_appliance(photoPath: '/없는/경로/a.png')),
      );

      expect(find.byType(Image), findsNothing);
      expect(find.byType(CustomPaint), findsWidgets);
    });
  });

  group('AddPhotoHint', () {
    testWidgets('고령 사용자 기준 최소 터치 대상을 지킨다', (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: AddPhotoHint(onTap: () {}))),
      );

      final size = tester.getSize(find.byType(TextButton));
      expect(size.height, greaterThanOrEqualTo(48));
    });
  });
}
