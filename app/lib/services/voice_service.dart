import 'dart:async';

import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

class VoiceService {
  final SpeechToText _speech = SpeechToText();
  Timer? _silenceTimer;

  bool get isListening => _speech.isListening;

  Future<bool> initialize() => _speech.initialize();

  Future<void> listen({
    required void Function(String text) onText,
    required void Function(String finalText) onSilence,
  }) async {
    var latestText = '';
    void resetTimer() {
      _silenceTimer?.cancel();
      _silenceTimer = Timer(const Duration(seconds: 5), () async {
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
        latestText = result.recognizedWords;
        onText(latestText);
        resetTimer();
      },
    );
    resetTimer();
  }

  Future<void> stop() async {
    _silenceTimer?.cancel();
    await _speech.stop();
  }

  Future<void> cancel() async {
    _silenceTimer?.cancel();
    await _speech.cancel();
  }
}
