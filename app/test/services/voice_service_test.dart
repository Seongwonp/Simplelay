import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay/services/voice_service.dart';

void main() {
  group('voiceErrorGuide', () {
    test('인식 실패와 침묵 오류를 다시 말하기 안내로 바꾼다', () {
      expect(
        voiceErrorGuide('error_no_match'),
        '말을 알아듣지 못했어요. 다시 말해주세요.',
      );
      expect(
        voiceErrorGuide('error_speech_timeout'),
        '말소리가 들리지 않았어요. 다시 시도해주세요.',
      );
    });

    test('네트워크·마이크·권한 오류를 사용자 언어로 묶는다', () {
      expect(
        voiceErrorGuide('error_network_timeout'),
        '네트워크 문제로 음성 인식이 중단됐어요.',
      );
      expect(
        voiceErrorGuide('error_audio_error'),
        '마이크를 사용할 수 없어요. 다른 앱이 사용 중인지 확인해주세요.',
      );
      expect(
        voiceErrorGuide('error_insufficient_permissions'),
        '마이크 권한이 필요해요. 설정에서 허용해주세요.',
      );
    });

    test('알 수 없는 엔진 오류도 raw id를 노출하지 않는다', () {
      expect(
        voiceErrorGuide('vendor_specific_error'),
        '음성 인식이 중단됐어요. 다시 시도해주세요.',
      );
    });
  });
}
