// 웹(/kiosk/ 배포·브라우저 시뮬레이터) 설정 저장 — 오리진별 localStorage.
//
// 파일 경로(path)는 쓰지 않는다. 네이티브 설정 파일과는 독립이다.
// Chromium을 --incognito로 띄우면 재시작 때 비워지므로 키오스크 서비스는
// 전용 --user-data-dir을 쓴다(scripts/simplelay-kiosk.service).
// ignore: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:html' as html;

const _storageKey = 'simplelay-kiosk-settings';

class SettingsBackend {
  SettingsBackend(String? path);

  Iterable<String> readCandidates() sync* {
    String? raw;
    try {
      raw = html.window.localStorage[_storageKey];
    } catch (_) {
      raw = null; // 저장소 차단(사생활 모드 정책 등) — 기본값으로
    }
    if (raw != null) yield raw;
  }

  void write(String json) {
    html.window.localStorage[_storageKey] = json;
  }
}
