import 'dart:async';

import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// speech_to_text 엔진 에러 id → 사용자 언어 안내.
///
/// raw 에러 id를 그대로 노출하지 않는다 — 서버 오류(_send의 statusCode
/// 매핑)와 같은 원칙. 순수 함수로 분리해 플러그인 없이 단위테스트한다.
String voiceErrorGuide(String errorId) => switch (errorId) {
      'error_no_match' => '말을 알아듣지 못했어요. 다시 말해주세요.',
      'error_speech_timeout' => '말소리가 들리지 않았어요. 다시 시도해주세요.',
      'error_network' || 'error_network_timeout' => '네트워크 문제로 음성 인식이 중단됐어요.',
      'error_audio_error' ||
      'error_client' =>
        '마이크를 사용할 수 없어요. 다른 앱이 사용 중인지 확인해주세요.',
      'error_insufficient_permissions' => '마이크 권한이 필요해요. 설정에서 허용해주세요.',
      'error_busy' => '음성 인식이 아직 준비 중이에요. 잠시 후 다시 시도해주세요.',
      _ => '음성 인식이 중단됐어요. 다시 시도해주세요.',
    };

class VoiceService {
  final SpeechToText _speech = SpeechToText();
  Timer? _silenceTimer;
  bool _initialized = false;
  void Function(String errorId)? _onError;
  // 세션 세대 — listen()마다 증가한다. 오류로 끝난 세션의 늦은 콜백이
  // 다음(또는 이미 끝난) 세션의 타이머를 되살리지 못하게 하는 열쇠.
  int _session = 0;
  bool _sessionFailed = false;

  bool get isListening => _speech.isListening;

  /// 엔진 초기화. onError는 여기(플러그인 계약)에서만 등록할 수 있어서,
  /// 세션별 콜백은 [_onError]에 보관했다가 전달한다. 재호출은 no-op —
  /// speech_to_text는 중복 initialize에 민감하다.
  Future<bool> initialize() async {
    if (_initialized) return true;
    _initialized = await _speech.initialize(
      onError: (error) {
        // cancelOnError: true — 엔진은 이 시점에 세션을 이미 버렸다.
        // 침묵 타이머를 그대로 두면 5초 뒤 onSilence가 에러 직전의 부분
        // 인식 텍스트를 "정상 발화"로 전송해 버린다(교차 리뷰 #17) —
        // 타이머를 끊고 호출자에게 에러로 알린다.
        _silenceTimer?.cancel();
        _sessionFailed = true;
        _onError?.call(error.errorMsg);
      },
      onStatus: (status) {
        // 'done'(엔진 자체 종료)에서 조기 전송하지 않는 건 의도다 —
        // "5초 동안 말이 없으면 전송" 계약을 침묵 타이머 하나로 유지한다.
      },
    );
    return _initialized;
  }

  Future<void> listen({
    required void Function(String text) onText,
    required void Function(String finalText) onSilence,
    void Function(String errorId)? onError,
  }) async {
    var latestText = '';
    _onError = onError;
    _sessionFailed = false;
    final session = ++_session;

    // 이 세션이 아직 유효할 때만 타이머를 건다. 엔진이 listen()의 Future가
    // 반환되기 전에 동기적으로 오류를 던지면, 오류 콜백이 취소한 타이머를
    // 아래 마지막 resetTimer()가 되살려 5초 뒤 빈 발화를 전송하게 된다.
    void resetTimer() {
      if (session != _session || _sessionFailed) return;
      _silenceTimer?.cancel();
      _silenceTimer = Timer(const Duration(seconds: 5), () async {
        if (session != _session || _sessionFailed) return;
        await stop();
        onSilence(latestText.trim()); // 텍스트 없어도 항상 호출해 listening 상태 해제
      });
    }

    await _speech.listen(
      listenOptions: SpeechListenOptions(
        partialResults: true,
        cancelOnError: true,
        localeId: 'ko_KR',
      ),
      onResult: (SpeechRecognitionResult result) {
        if (session != _session || _sessionFailed) return;
        latestText = result.recognizedWords;
        onText(latestText);
        resetTimer();
      },
    );
    resetTimer();
  }

  Future<void> stop() async {
    _silenceTimer?.cancel();
    _session++; // 이후 도착하는 콜백은 전부 무효
    _onError = null; // 세션 종료 — 늦게 도착한 엔진 에러를 다음 세션에 흘리지 않기
    await _speech.stop();
  }

  Future<void> cancel() async {
    _silenceTimer?.cancel();
    _session++;
    _onError = null;
    await _speech.cancel();
  }
}
