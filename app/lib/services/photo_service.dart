import 'dart:io';

import 'package:image_picker/image_picker.dart';

/// image_picker를 얇게 감싼 래퍼 — VoiceService/BleService와 같은 이유로,
/// 테스트에서 실제 카메라를 띄우지 않고 provider를 오버라이드할 수 있게 한다.
class PhotoService {
  final ImagePicker _picker = ImagePicker();

  /// 카메라로 사진을 찍는다. 사용자가 촬영을 취소하면 null.
  Future<File?> takePhoto() async {
    final file = await _picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 85,
    );
    if (file == null) return null;
    return File(file.path);
  }
}
