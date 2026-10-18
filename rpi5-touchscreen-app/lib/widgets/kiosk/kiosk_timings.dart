/// 화면 전환·카운트다운 타이밍의 단일 출처.
///
/// kiosk_screen(전환 로직)과 suggestion_view·done_view(진행바 표시)가 같은
/// 값을 봐야 바와 실제 전환이 어긋나지 않는다 — 이전에는 세 파일이 각자
/// 하드코딩해서 한쪽만 바꾸면 조용히 어긋났다.
class KioskTimings {
  /// 제안 화면 자동 닫힘 카운트다운의 기본값(초).
  ///
  /// 10초는 고령 사용자에게 짧았다 — 음성 안내를 듣고, 화면을 보고, 몇 걸음
  /// 걸어와서, 읽고, 판단하고, 누르기까지가 그 안에 들어가지 않는다.
  /// 사용자가 설정에서 바꿀 수 있고(KioskSettings.countdownSeconds),
  /// 이 값은 설정이 없을 때의 기본값이다.
  static const int countdownSeconds = 20;

  /// 설정에서 고를 수 있는 값 — 시연 리듬과 접근성을 함께 맞추기 위해.
  static const List<int> countdownChoices = [10, 20, 30];

  /// 완료 화면 → 대기 화면 자동 복귀
  static const Duration doneReturn = Duration(seconds: 10);

  /// 큰 글씨 완료 화면 자동 복귀 — 글이 길어져 스크롤이 생길 수 있어 두 배(UI 평가 4차 10/17).
  static const Duration doneReturnLarge = Duration(seconds: 20);

  /// 자동 실행 결과 한 줄을 보이는 시간(2026-10-14) — 읽고 지나갈 만큼만.
  static const Duration autoRunNotice = Duration(seconds: 12);

  /// 서버가 total_steps를 안 줄 때(UART 집계 모드)만 쓰는 폴백 채움 시간
  static const Duration execBarFill = Duration(seconds: 9);

  /// 정지로 끝난 실행의 확인 보고(stop_level)를 다시 묻는 간격·횟수(kiosk_screen `_followStopReport`).
  static const Duration stopFollowInterval = Duration(seconds: 1);
  static const int stopFollowTries = 3;

  /// '멈추는 중이에요'를 보이는 가장 긴 시간(휴리스틱 평가 10/18 — 기다림 상한을 화면에 말한다). kiosk_screen은
  /// 틱이 [stopFollowTries] + 2를 넘는 순간(그 다음 틱) 기다리기를 끝낸다 — 1초 간격이면 6초. 보통은 그보다 일찍
  /// (보고가 오거나 세 번 물은 뒤) 끝난다.
  static Duration get stopConfirmMaxWait => stopFollowInterval * (stopFollowTries + 3);
}
