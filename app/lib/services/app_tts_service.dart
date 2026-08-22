import 'package:flutter_tts/flutter_tts.dart';

/// 실행 결과를 음성으로 읽어주는 래퍼 — 고령·저시력 사용자가 화면을 보지
/// 않아도 결과를 알 수 있게 한다.
///
/// 설계 원칙:
/// - 음성은 **보조 채널** — TTS 엔진 부재·초기화 실패가 앱 동작을 절대
///   막지 않는다 (전부 삼킴).
/// - lazy 초기화 — 첫 발화 때만 엔진을 만들고 ko-KR로 설정한다.
/// - 새 발화 전 이전 발화를 끊는다 — 상태가 빠르게 바뀔 때 안내가
///   밀려서 겹치지 않게.
class AppTtsService {
  FlutterTts? _tts;

  Future<FlutterTts> _instance() async {
    final existing = _tts;
    if (existing != null) return existing;
    final tts = FlutterTts();
    await tts.setLanguage('ko-KR');
    // 0.5 = flutter_tts 안드로이드 스케일에서 자연스러운 보통 속도
    await tts.setSpeechRate(0.5);
    _tts = tts;
    return tts;
  }

  Future<void> speak(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    try {
      final tts = await _instance();
      await tts.stop();
      await tts.speak(trimmed);
    } catch (_) {
      // 엔진 부재/미지원 기기 — 음성은 보조 채널이므로 조용히 무시
    }
  }
}
