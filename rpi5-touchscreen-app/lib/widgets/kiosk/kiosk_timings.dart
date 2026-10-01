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

  /// 서버가 total_steps를 안 줄 때(UART 집계 모드)만 쓰는 폴백 채움 시간
  static const Duration execBarFill = Duration(seconds: 9);
}
