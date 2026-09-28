import 'dart:convert';

// 저장 매체는 플랫폼마다 다르다 — 네이티브는 JSON 파일(dart:io), 웹은
// localStorage. 조건부 import로 갈라서 이 파일 자체는 dart:io를 모른다.
// 웹 빌드에 File·Platform이 섞여 들어가 /kiosk/ 첫 진입이 깨지던 경로를
// 구조적으로 막는다(본선 준비 평가 9/21 P0).
import 'kiosk_settings_backend_io.dart'
    if (dart.library.html) 'kiosk_settings_backend_web.dart' as backend;

import '../widgets/kiosk/kiosk_timings.dart';

/// 키오스크 로컬 설정 스냅샷 — 음성 안내·큰 글씨·마지막 선택 가전.
///
/// 그동안 세션 한정(메모리)이라 정전·재부팅·앱 재시작마다 고령 사용자가
/// 설정(dot 3연타 진입)을 다시 찾아 들어가야 했다 — 접근성 설정일수록
/// 유지되는 것이 표준 요구(교차 리뷰 #14).
class KioskSettings {
  const KioskSettings({
    this.ttsEnabled = true,
    this.largeText = false,
    this.applianceId,
    this.countdownSeconds = KioskTimings.countdownSeconds,
  });

  final bool ttsEnabled;
  final bool largeText;

  /// 제안 카드가 자동으로 닫히기까지의 시간(초).
  final int countdownSeconds;

  /// 마지막으로 적용한 가전 id (kAppliances의 id). null = 기본 가전.
  final String? applianceId;

  KioskSettings copyWith({
    bool? ttsEnabled,
    bool? largeText,
    String? applianceId,
    int? countdownSeconds,
  }) =>
      KioskSettings(
        ttsEnabled: ttsEnabled ?? this.ttsEnabled,
        largeText: largeText ?? this.largeText,
        applianceId: applianceId ?? this.applianceId,
        countdownSeconds: countdownSeconds ?? this.countdownSeconds,
      );

  factory KioskSettings.fromJson(Map<String, dynamic> json) => KioskSettings(
        ttsEnabled: json['tts_enabled'] is bool
            ? json['tts_enabled'] as bool
            : true,
        largeText:
            json['large_text'] is bool ? json['large_text'] as bool : false,
        applianceId: json['appliance_id'] is String
            ? json['appliance_id'] as String
            : null,
        // 목록에 없는 값(수기 편집·구버전)은 기본값으로 — 0이나 음수가
        // 들어오면 제안이 뜨자마자 사라진다
        countdownSeconds:
            KioskTimings.countdownChoices.contains(json['countdown_seconds'])
                ? json['countdown_seconds'] as int
                : KioskTimings.countdownSeconds,
      );

  Map<String, dynamic> toJson() => {
        'tts_enabled': ttsEnabled,
        'large_text': largeText,
        'appliance_id': applianceId,
        'countdown_seconds': countdownSeconds,
      };
}

/// 설정을 영속화한다 — 네이티브는 JSON 파일 하나, 웹은 브라우저 저장소.
///
/// shared_preferences 대신 평문 파일인 이유: 키오스크(elinux/RPi5) 빌드에서
/// 플러그인 지원을 타지 않는 dart:io만 쓰고, SSH로 파일을 열어 바로 확인·
/// 수정할 수 있어 현장 디버깅이 쉽다. 경로 주입으로 테스트는 temp 파일 사용.
/// 파일 경로 결정·원자적 저장은 kiosk_settings_backend_io.dart에 있다.
class KioskSettingsStore {
  KioskSettingsStore({String? path}) : _path = path;

  final String? _path;
  // 생성자에서 만들지 않는다 — 저장 매체 준비 실패가 시작 화면 생성을
  // 막으면 안 된다. load()/save()의 예외 처리 안에서 처음 만든다.
  late final backend.SettingsBackend _backend = backend.SettingsBackend(_path);

  /// 마지막 save()가 실패했는지 — 호출자가 "저장하지 못했습니다"를 보여줄 수
  /// 있게 남긴다. 예외를 삼키기만 하면 사용자는 저장된 줄 안다.
  bool get lastSaveFailed => _lastSaveFailed;
  bool _lastSaveFailed = false;

  /// 읽기 실패(파일 없음·손상 JSON·권한·저장소 차단)는 전부 기본값 — 설정
  /// 때문에 키오스크가 못 뜨는 일은 없어야 한다. 본 파일이 손상됐으면 직전
  /// 저장분(.bak, 네이티브만)으로 한 번 더 시도한다.
  KioskSettings load() {
    try {
      for (final raw in _backend.readCandidates()) {
        final settings = _decode(raw);
        if (settings != null) return settings;
      }
    } catch (_) {
      // 저장 매체 자체를 쓸 수 없다 — 기본값
    }
    return const KioskSettings();
  }

  KioskSettings? _decode(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return KioskSettings.fromJson(decoded);
    } catch (_) {
      // 손상 — 호출자가 다음 후보로 넘어간다
    }
    return null;
  }

  /// 반환값은 저장 성공 여부. 실패해도 세션 내 동작은 그대로 유지된다.
  bool save(KioskSettings settings) {
    try {
      _backend.write(jsonEncode(settings.toJson()));
      _lastSaveFailed = false;
      return true;
    } catch (_) {
      _lastSaveFailed = true;
      return false;
    }
  }
}
