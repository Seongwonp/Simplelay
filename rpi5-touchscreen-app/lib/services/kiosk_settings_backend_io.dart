// 네이티브(RPi elinux·데스크톱·테스트 VM) 설정 저장 — JSON 파일 하나.
//
// dart:io는 이 파일에만 둔다. 웹 빌드는 조건부 import로
// kiosk_settings_backend_web.dart를 대신 쓰므로 File·Platform이 웹 번들에
// 들어가지 않는다(본선 준비 평가 9/21 P0).
import 'dart:io';

class SettingsBackend {
  SettingsBackend(String? path) : _path = path;

  final String? _path;
  late final File _file = File(_path ?? _defaultPath());

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

  /// 읽을 후보를 우선순위대로 — 본 파일, 그다음 직전 저장분(.bak).
  /// 읽기 실패한 후보는 건너뛴다. JSON 판정은 호출자 몫이다.
  Iterable<String> readCandidates() sync* {
    for (final file in [_file, File('${_file.path}.bak')]) {
      String? raw;
      try {
        raw = file.readAsStringSync();
      } catch (_) {
        raw = null; // 없음·권한 — 다음 후보로
      }
      if (raw != null) yield raw;
    }
  }

  /// 원자적 저장: 임시 파일에 다 쓴 뒤 교체한다. 실패하면 예외를 던진다.
  ///
  /// 그냥 덮어쓰면 기록 도중 정전 시 본 파일이 잘린 JSON이 되고, 다음 부팅에
  /// 모든 설정이 기본값으로 돌아간다 — 키오스크는 벽 전원으로 상시 동작하는
  /// 기기라 쓰기 중 정전이 현실적인 시나리오다.
  void write(String json) {
    final tmp = File('${_file.path}.tmp');
    try {
      tmp.writeAsStringSync(json, flush: true);
      // 직전 파일을 백업한 뒤 같은 파일시스템의 임시 파일을 rename해 교체한다.
      // 쓰기·복사·rename 실패는 호출자에게 전달한다.
      if (_file.existsSync()) {
        _file.copySync('${_file.path}.bak');
      }
      tmp.renameSync(_file.path);
    } catch (_) {
      try {
        if (tmp.existsSync()) tmp.deleteSync();
      } catch (_) {
        // 임시 파일 정리 실패는 무시
      }
      rethrow;
    }
  }
}
