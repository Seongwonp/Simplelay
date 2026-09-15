import 'dart:io';
import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';

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
}
