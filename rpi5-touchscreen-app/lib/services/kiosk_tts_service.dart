// 실행 수단은 플랫폼마다 다르다 — 네이티브는 espeak-ng 프로세스(dart:io),
// 웹은 브라우저 speechSynthesis. 이 파일은 dart:io를 직접 쓰지 않는다.
import 'kiosk_tts_runner_io.dart'
    if (dart.library.html) 'kiosk_tts_runner_web.dart' as platform_tts;

/// 키오스크 음성 안내 — 네이티브는 espeak-ng CLI 프로세스, 웹은 브라우저
/// speechSynthesis로 말한다(kiosk_tts_runner_*.dart).
///
/// flutter_tts는 elinux 임베더를 지원하지 않으므로, RPi5(리눅스)에 설치된
/// espeak-ng를 직접 부른다(설치는 setup_rpi.sh가 담당). 타깃 사용자(고령·
/// 저시력)가 화면을 보지 않아도 제안 도착·실행 결과·위험 경보를 알 수 있게
/// 하는 것이 목적이다.
///
/// 설계 원칙:
/// - 음성은 **보조 채널** — espeak 부재·실패가 키오스크 동작을 절대 막지
///   않는다 (전부 삼키고 화면 표시는 그대로 진행).
/// - fire-and-forget — 발화가 끝나기를 기다리지 않는다. 연속 발화가 겹치면
///   espeak 프로세스가 병렬로 울릴 수 있으나, 발화 지점이 전부 화면 전이
///   순간이라 실사용에서 겹칠 일이 드물다.
/// - 러너 주입으로 테스트에서 실제 프로세스 실행 없이 발화 내용을 검증한다.
typedef TtsProcessRunner = Future<void> Function(List<String> command);

class KioskTtsService {
  KioskTtsService({TtsProcessRunner? runner})
      : _runner = runner ?? platform_tts.runTtsCommand;

  final TtsProcessRunner _runner;

  /// 설정 오버레이의 "음성 안내" 토글과 연결. 키오스크는 로컬 저장소가
  /// 없어(elinux에서 shared_preferences 미검증) 이 필드 자체는 메모리지만,
  /// KioskScreen이 KioskSettingsStore로 파일에 영속화한다 — 재부팅 시 기본
  /// 켜짐으로 복귀한다. 접근성 기기 특성상 기본 켜짐이 맞는 방향.
  bool enabled = true;

  Future<void> speak(String text) async {
    final trimmed = text.trim();
    if (!enabled || trimmed.isEmpty) return;
    try {
      // -v ko: 한국어 음성, -s 150: 고령 사용자 기준 약간 느린 속도,
      // -a 150: 키오스크 스피커에서 들리도록 볼륨 상향
      await _runner(['espeak-ng', '-v', 'ko', '-s', '150', '-a', '150', trimmed]);
    } catch (_) {
      // espeak-ng 미설치·실행 실패 — 음성은 보조 채널이므로 조용히 무시
    }
  }
}
