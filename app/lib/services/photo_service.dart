import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

/// image_picker를 얇게 감싼 래퍼 — VoiceService/BleService와 같은 이유로,
/// 테스트에서 실제 카메라를 띄우지 않고 provider를 오버라이드할 수 있게 한다.
class PhotoService {
  final ImagePicker _picker = ImagePicker();

  /// 카메라로 사진을 찍는다. 사용자가 촬영을 취소하면 null.
  ///
  /// 긴 변을 2048px로 제한한다 — 버튼 글씨를 읽기에 충분하고, 사진 인식으로
  /// 보낼 때 업로드가 수 MB로 커지지 않는다.
  Future<File?> takePhoto() async {
    final file = await _picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 85,
      maxWidth: 2048,
      maxHeight: 2048,
    );
    if (file == null) return null;
    return File(file.path);
  }

  /// 사진 바이트. 파일 입출력은 위젯 테스트의 가짜 시계에서 끝나지 않으므로
  /// 화면이 직접 읽지 않고 여기를 거친다(테스트에서 바꿔 끼운다).
  Future<Uint8List> readBytes(File file) => file.readAsBytes();

  /// 사진의 실제 크기(px). 사진 매핑은 사진 좌표계로 계산하므로 화면에 그린
  /// 크기가 아니라 원본 크기를 서버에 보낸다. 읽지 못하면 null.
  Future<ui.Size?> imageSize(File file) async {
    try {
      final bytes = await readBytes(file);
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final size = ui.Size(
          frame.image.width.toDouble(), frame.image.height.toDouble());
      frame.image.dispose();
      codec.dispose();
      return size;
    } catch (_) {
      return null;
    }
  }

  /// image_picker 임시 캐시의 사진을 문서 폴더로 복사해 영구 경로를 돌려준다.
  /// OS가 캐시를 언제든 지우므로 캐시 경로를 그대로 저장하면 사진이 사라진다.
  /// 실패는 null -- 등록을 막지 않는다(사진 없이 자리만 남는다).
  Future<String?> persist(File photo, String id) async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/appliance_photos');
      await dir.create(recursive: true);
      final saved = await photo.copy('${dir.path}/$id.jpg');
      return saved.path;
    } catch (_) {
      return null;
    }
  }
}
