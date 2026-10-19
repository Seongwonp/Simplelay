import 'dart:async';

import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// speech_to_text 엔진 에러 id → 사용자 언어 안내.
///
/// raw 에러 id를 그대로 노출하지 않는다 — 서버 오류(_send의 statusCode
/// 매핑)와 같은 원칙. 순수 함수로 분리해 플러그인 없이 단위테스트한다.
String voiceErrorGuide(String errorId) => switch (errorId) {
      'error_no_match' => '말을 알아듣지 못했어요. 다시 말해 주세요.',
      'error_speech_timeout' => '말소리가 들리지 않았어요. 다시 말해 주세요.',
      'error_network' || 'error_network_timeout' => '인터넷이 끊겨 말을 듣지 못했어요. 버튼으로 해 주세요.',
      'error_audio_error' ||
      'error_client' =>
        '마이크를 사용할 수 없어요. 다른 앱이 사용 중인지 확인해 주세요.',
      'error_insufficient_permissions' => '마이크 권한이 필요해요. 휴대폰 설정에서 켜 주세요.',
      'error_busy' => '아직 들을 준비가 안 됐어요. 조금 뒤 다시 눌러 주세요.',
      _ => '듣기가 끊겼어요. 다시 말해 주세요.',
    };

/// 음성 인식기 계약. 홈 '말로 조작하기'와 실행 중 '멈춰' 듣기가 같은 엔진을
/// 나눠 쓰고, 시험은 가짜 인식기로 바꿔 끼운다.
abstract interface class SpeechRecognizer {
  bool get isListening;

  /// 엔진 준비. false면 이 기기에서 음성 인식을 쓸 수 없다(권한 거부·엔진 없음).
  /// **처음이면 OS가 마이크 권한을 묻는다** — 사용자가 마이크를 누른 자리에서만 부른다.
  Future<bool> initialize();

  /// 마이크 권한이 **이미** 있는가. 묻지 않는다(OS 창 없음). 실행 중 '멈춰' 듣기는
  /// 이것이 참일 때만 [initialize]한다(외부 평가 2026-10-13 M3).
  Future<bool> hasPermission();

  /// [onInterrupted]는 **다른 호출자가** 이 세션을 끊었을 때(새 listen·stop·cancel)
  /// 한 번 불린다. 침묵 종료([onSilence])나 오류([onError])로 끝난 세션에서는
  /// 불리지 않는다 — 엔진을 나눠 쓰는 쪽이 "아직 듣는 줄 아는" 상태로 남지 않게 한다.
  ///
  /// [onText]는 부분·최종 결과 모두에 불린다. [onFinal]은 엔진이 **최종** 결과라고
  /// 표시한 문장에만(onText 다음에) 불린다. [onDone]을 주면 엔진이 스스로 세션을
  /// 끝냈을 때(speech_to_text `done`) 한 번 불리고 그 세션은 끝난 것으로 친다 —
  /// 이때 [onSilence]는 오지 않는다. [onDone]을 주지 않으면(홈 '말로 조작하기')
  /// 지금처럼 침묵 타이머 하나로 끝을 정한다(10/8 인계 5차 §3).
  Future<void> listen({
    required void Function(String text) onText,
    required void Function(String finalText) onSilence,
    void Function(String errorId)? onError,
    void Function(double level)? onSoundLevel,
    void Function()? onInterrupted,
    void Function(String text)? onFinal,
    void Function()? onDone,
  });

  Future<void> stop();

  Future<void> cancel();
}

class VoiceService implements SpeechRecognizer {
  /// 이만큼 조용하면 듣기를 멈춘다. 화면이 이 숫자를 미리 말해준다 --
  /// 사용자가 생각하다 멈춘 사이에 듣기가 끝나는 것을 예측할 수 있어야 한다.
  static const silenceTimeout = Duration(seconds: 5);

  final SpeechToText _speech = SpeechToText();
  Timer? _silenceTimer;
  bool _initialized = false;
  void Function(String errorId)? _onError;
  // 세션 세대 — listen()마다 증가한다. 오류로 끝난 세션의 늦은 콜백이
  // 다음(또는 이미 끝난) 세션의 타이머를 되살리지 못하게 하는 열쇠.
  int _session = 0;
  bool _sessionFailed = false;
  // 지금 세션을 연 쪽에 "남이 끊었다"를 알릴 콜백. 정상 종료·오류 때는 먼저 비운다.
  void Function()? _onInterrupted;
  // 엔진 자체 종료('done')를 받겠다고 한 세션의 콜백. 정상·오류·남의 종료 때 비운다.
  void Function()? _onDone;

  void _interruptCurrent() {
    final callback = _onInterrupted;
    _onInterrupted = null;
    callback?.call();
  }

  @override
  bool get isListening => _speech.isListening;

  /// 엔진 초기화. onError는 여기(플러그인 계약)에서만 등록할 수 있어서,
  /// 세션별 콜백은 [_onError]에 보관했다가 전달한다. 재호출은 no-op —
  /// speech_to_text는 중복 initialize에 민감하다.
  @override
  Future<bool> hasPermission() async {
    if (_initialized) return true;
    try {
      return await _speech.hasPermission;
    } catch (_) {
      return false; // 모르면 없는 것으로 — 묻지 않는 쪽
    }
  }

  @override
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
        _onInterrupted = null; // 오류로 끝났다 — onError가 알린다
        _onDone = null;
        _onError?.call(error.errorMsg);
      },
      onStatus: (status) {
        // 'done'(엔진 자체 종료)에서 조기 전송하지 않는 건 의도다 —
        // "5초 동안 말이 없으면 전송" 계약을 침묵 타이머 하나로 유지한다.
        // 단, onDone을 준 세션(실행 중 '멈춰' 듣기)에는 엔진이 끝났다고 알린다 —
        // 엔진이 끝났는데 화면이 계속 "듣는 중"이면 안 된다(10/8 인계 5차 §3).
        if (status != SpeechToText.doneStatus) return;
        final done = _onDone;
        if (done == null || _sessionFailed) return;
        _onDone = null;
        _onInterrupted = null; // 엔진이 끝냈다 — onDone이 알린다
        _onError = null;
        _silenceTimer?.cancel();
        _session++; // 이 세션의 늦은 결과·타이머는 무효
        done();
      },
    );
    return _initialized;
  }

  /// [onSoundLevel]은 엔진이 알려주는 **실제** 입력 음량이다. 듣는 중
  /// 표시를 여기에 걸어야 화면이 마이크와 같은 것을 말한다 -- 정해진
  /// 애니메이션은 아무것도 안 들려도 똑같이 움직여서 "잘 듣고 있다"는
  /// 인상을 과장한다. 플랫폼이 음량을 안 주면 콜백이 한 번도 오지
  /// 않는다(그 경우의 표시는 호출자가 정한다).
  @override
  Future<void> listen({
    required void Function(String text) onText,
    required void Function(String finalText) onSilence,
    void Function(String errorId)? onError,
    void Function(double level)? onSoundLevel,
    void Function()? onInterrupted,
    void Function(String text)? onFinal,
    void Function()? onDone,
  }) async {
    var latestText = '';
    _interruptCurrent(); // 앞 세션을 연 쪽에 알린다(새 세션이 엔진을 가져간다)
    _onInterrupted = onInterrupted;
    _onDone = onDone;
    _onError = onError;
    _sessionFailed = false;
    final session = ++_session;

    // 이 세션이 아직 유효할 때만 타이머를 건다. 엔진이 listen()의 Future가
    // 반환되기 전에 동기적으로 오류를 던지면, 오류 콜백이 취소한 타이머를
    // 아래 마지막 resetTimer()가 되살려 5초 뒤 빈 발화를 전송하게 된다.
    void resetTimer() {
      if (session != _session || _sessionFailed) return;
      _silenceTimer?.cancel();
      _silenceTimer = Timer(silenceTimeout, () async {
        if (session != _session || _sessionFailed) return;
        _onInterrupted = null; // 침묵으로 정상 종료 — onSilence가 알린다
        _onDone = null;
        await stop();
        onSilence(latestText.trim()); // 텍스트 없어도 항상 호출해 listening 상태 해제
      });
    }

    await _speech.listen(
      // 세션 세대 검사는 onResult와 같은 이유다 -- 끝난 세션의 늦은
      // 음량 콜백이 다음 화면의 파형을 흔들지 않게 한다.
      onSoundLevelChange: onSoundLevel == null
          ? null
          : (level) {
              if (session != _session || _sessionFailed) return;
              onSoundLevel(level);
            },
      listenOptions: SpeechListenOptions(
        partialResults: true,
        cancelOnError: true,
        localeId: 'ko_KR',
      ),
      onResult: (SpeechRecognitionResult result) {
        if (session != _session || _sessionFailed) return;
        latestText = result.recognizedWords;
        onText(latestText);
        if (result.finalResult) {
          onFinal?.call(latestText);
          // onFinal이 세션을 끝냈을 수 있다(정지 요청 → cancel).
          if (session != _session) return;
        }
        resetTimer();
      },
    );
    resetTimer();
  }

  @override
  Future<void> stop() async {
    _interruptCurrent();
    _silenceTimer?.cancel();
    _session++; // 이후 도착하는 콜백은 전부 무효
    _onError = null; // 세션 종료 — 늦게 도착한 엔진 에러를 다음 세션에 흘리지 않기
    _onDone = null;
    await _speech.stop();
  }

  @override
  Future<void> cancel() async {
    _interruptCurrent();
    _silenceTimer?.cancel();
    _session++;
    _onError = null;
    _onDone = null;
    await _speech.cancel();
  }
}
