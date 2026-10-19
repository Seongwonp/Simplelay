import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay/services/voice_service.dart';

void main() {
  group('voiceErrorGuide', () {
    test('인식 실패와 침묵 오류를 다시 말하기 안내로 바꾼다', () {
      expect(
        voiceErrorGuide('error_no_match'),
        '말을 알아듣지 못했어요. 다시 말해 주세요.',
      );
      expect(
        voiceErrorGuide('error_speech_timeout'),
        '말소리가 들리지 않았어요. 다시 말해 주세요.',
      );
    });

    test('네트워크·마이크·권한 오류를 사용자 언어로 묶는다', () {
      expect(
        voiceErrorGuide('error_network_timeout'),
        '인터넷이 끊겨 말을 듣지 못했어요. 버튼으로 해 주세요.',
      );
      expect(
        voiceErrorGuide('error_audio_error'),
        '마이크를 사용할 수 없어요. 다른 앱이 사용 중인지 확인해 주세요.',
      );
      expect(
        voiceErrorGuide('error_insufficient_permissions'),
        '마이크 권한이 필요해요. 휴대폰 설정에서 켜 주세요.',
      );
    });

    test('알 수 없는 엔진 오류도 raw id를 노출하지 않는다', () {
      expect(
        voiceErrorGuide('vendor_specific_error'),
        '듣기가 끊겼어요. 다시 말해 주세요.',
      );
    });
  });
}
