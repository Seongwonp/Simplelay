import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';

/// 기준 이미지가 없는 새 화면도 갱신 전에 실제 렌더를 검토할 수 있게 남긴다.
class ReviewGoldenComparator extends GoldenFileComparator {
  ReviewGoldenComparator(this.delegate);
  final GoldenFileComparator delegate;

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    final name = golden.pathSegments.last.replaceFirst('.png', '_testImage.png');
    final file = File('test/failures/$name');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(imageBytes);
    return delegate.compare(imageBytes, golden);
  }

  @override
  Future<void> update(Uri golden, Uint8List imageBytes) => delegate.update(golden, imageBytes);

  @override
  Uri getTestUri(Uri key, int? version) => delegate.getTestUri(key, version);
}
