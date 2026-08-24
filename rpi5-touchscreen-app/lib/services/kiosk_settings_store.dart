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

  /// 마지막 save()가 실패했는지 — 호출자가 "저장하지 못했습니다"를 보여줄 수
  /// 있게 남긴다. 예외를 삼키기만 하면 사용자는 저장된 줄 안다.
  bool get lastSaveFailed => _lastSaveFailed;
  bool _lastSaveFailed = false;

  /// 쓰기 가능 경로 우선순위:
  ///   1. SIMPLELAY_KIOSK_SETTINGS — 배포에서 명시 지정(systemd Environment)
  ///   2. $HOME
  ///   3. 현재 디렉터리 — 최후 폴백. 앱 샌드박스나 읽기 전용 루트에서는
  ///      실패할 수 있으므로 실기기에서는 1번을 쓰는 것이 맞다.
  static String _defaultPath() {
    final explicit = Platform.environment['SIMPLELAY_KIOSK_SETTINGS'];
    if (explicit != null && explicit.isNotEmpty) return explicit;
    final home = Platform.environment['HOME'];
    final base = (home == null || home.isEmpty) ? '.' : home;
    return '$base/.simplelay-kiosk.json';
  }

  /// 읽기 실패(파일 없음·손상 JSON·권한)는 전부 기본값 — 설정 파일 때문에
  /// 키오스크가 못 뜨는 일은 없어야 한다. 본 파일이 손상됐으면 직전 저장분
  /// (.bak)으로 한 번 더 시도한다.
  KioskSettings load() {
    final fromMain = _tryLoad(_file);
    if (fromMain != null) return fromMain;
    final fromBackup = _tryLoad(File('${_file.path}.bak'));
    if (fromBackup != null) return fromBackup;
    return const KioskSettings();
  }

  KioskSettings? _tryLoad(File file) {
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is Map<String, dynamic>) return KioskSettings.fromJson(decoded);
    } catch (_) {
      // 없거나 손상 — 호출자가 다음 후보로 넘어간다
    }
    return null;
  }

  /// 원자적 저장: 임시 파일에 다 쓴 뒤 교체한다.
  ///
  /// 그냥 덮어쓰면 기록 도중 정전 시 본 파일이 잘린 JSON이 되고, 다음 부팅에
  /// 모든 설정이 기본값으로 돌아간다 — 키오스크는 벽 전원으로 상시 동작하는
  /// 기기라 쓰기 중 정전이 현실적인 시나리오다.
  ///
  /// 반환값은 저장 성공 여부. 실패해도 세션 내 동작은 그대로 유지된다.
  bool save(KioskSettings settings) {
    final tmp = File('${_file.path}.tmp');
    try {
      tmp.writeAsStringSync(jsonEncode(settings.toJson()), flush: true);
      // 직전 성공본을 백업으로 남긴 뒤 교체 — rename은 같은 파일시스템에서
      // 원자적이라 "둘 중 하나는 온전한 파일"이 항상 보장된다.
      if (_file.existsSync()) {
        _file.copySync('${_file.path}.bak');
      }
      tmp.renameSync(_file.path);
      _lastSaveFailed = false;
      return true;
    } catch (_) {
      try {
        if (tmp.existsSync()) tmp.deleteSync();
      } catch (_) {
        // 임시 파일 정리 실패는 무시
      }
      _lastSaveFailed = true;
      return false;
    }
  }
}
