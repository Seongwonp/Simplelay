import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/app_tts_service.dart';

/// 테스트에서 fake로 교체하는 지점 — 실행 결과 음성 안내 엔진.
final ttsServiceProvider = Provider<AppTtsService>((_) => AppTtsService());

/// 음성 안내 켜짐 여부. 타깃 사용자(고령·저시력) 특성상 기본 켜짐 —
/// 원치 않는 사용자는 설정에서 끈다.
class VoiceGuideNotifier extends StateNotifier<bool> {
  VoiceGuideNotifier() : super(true) {
    _load();
  }

  static const _prefsKey = 'voice_guide_enabled';

  Future<void> _load() async {
    // 저장소 접근 실패(플러그인 부재 등)는 기본값(켜짐) 유지로 끝낸다 —
    // 음성 안내 설정이 앱을 죽여선 안 된다.
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      state = prefs.getBool(_prefsKey) ?? true;
    } catch (_) {}
  }

  Future<void> set(bool enabled) async {
    state = enabled;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefsKey, enabled);
    } catch (_) {}
  }
}

final voiceGuideProvider = StateNotifierProvider<VoiceGuideNotifier, bool>(
  (ref) => VoiceGuideNotifier(),
);
