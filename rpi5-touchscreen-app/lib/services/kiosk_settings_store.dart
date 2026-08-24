import 'dart:convert';
import 'dart:io';

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
  });

  final bool ttsEnabled;
  final bool largeText;

  /// 마지막으로 적용한 가전 id (kAppliances의 id). null = 기본 가전.
  final String? applianceId;

  KioskSettings copyWith({
    bool? ttsEnabled,
    bool? largeText,
    String? applianceId,
  }) =>
      KioskSettings(
        ttsEnabled: ttsEnabled ?? this.ttsEnabled,
        largeText: largeText ?? this.largeText,
        applianceId: applianceId ?? this.applianceId,
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
      );

  Map<String, dynamic> toJson() => {
        'tts_enabled': ttsEnabled,
        'large_text': largeText,
        'appliance_id': applianceId,
      };
}

/// 설정을 JSON 파일 하나로 영속화한다.
///
/// shared_preferences 대신 평문 파일인 이유: 키오스크(elinux/RPi5) 빌드에서
/// 플러그인 지원을 타지 않는 dart:io만 쓰고, SSH로 파일을 열어 바로 확인·
/// 수정할 수 있어 현장 디버깅이 쉽다. 경로 주입으로 테스트는 temp 파일 사용.
class KioskSettingsStore {
  KioskSettingsStore({String? path}) : _file = File(path ?? _defaultPath());

  final File _file;

  static String _defaultPath() {
    final home = Platform.environment['HOME'];
    final base = (home == null || home.isEmpty) ? '.' : home;
    return '$base/.simplelay-kiosk.json';
  }

  /// 읽기 실패(파일 없음·손상 JSON·권한)는 전부 기본값 — 설정 파일 때문에
  /// 키오스크가 못 뜨는 일은 없어야 한다.
  KioskSettings load() {
    try {
      final decoded = jsonDecode(_file.readAsStringSync());
      if (decoded is Map<String, dynamic>) {
        return KioskSettings.fromJson(decoded);
      }
    } catch (_) {
      // 기본값으로 폴백
    }
    return const KioskSettings();
  }

  /// 쓰기 실패도 조용히 무시 — 영속화는 편의지 동작 요건이 아니다.
  void save(KioskSettings settings) {
    try {
      _file.writeAsStringSync(jsonEncode(settings.toJson()));
    } catch (_) {
      // 읽기 전용 파일시스템 등 — 세션 내 동작은 그대로 유지된다
    }
  }
}
